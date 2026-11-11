import Foundation
import Accelerate

/// Loudness constants used by ITU-R BS.1770 and EBU R 128.
public struct LoudnessConstants {
    public static let targetMomentary: Float = -23
    public static let targetIntegrated: Float = -23
    public static let absoluteGateLU: Float = -70
    public static let relativeGateLU: Float = -10
    /// Finite display floor for digital silence; avoids freezing the last value.
    public static let displayFloorLUFS: Float = -120
}

/// Streaming BS.1770 loudness meter.
///
/// Audio is accumulated into 100 ms power blocks. These produce 400 ms M
/// windows and integrated gating blocks with 75% overlap. S is a sliding
/// window whose duration defaults to the EBU value of 3 seconds.
public final class LoudnessMeter {
    public struct Reading: Sendable {
        public let momentaryLUFS: Float
        public let shortTermLUFS: Float
        public let integratedLUFS: Float
        public let loudnessRangeLU: Float

        public static let empty = Reading(
            momentaryLUFS: -.infinity,
            shortTermLUFS: -.infinity,
            integratedLUFS: -.infinity,
            loudnessRangeLU: 0
        )
    }

    public struct HistoryPoint: Sendable {
        public let momentary: Float
        public let shortTerm: Float
        public let peak: Float

        public init(momentary: Float, shortTerm: Float, peak: Float) {
            self.momentary = momentary
            self.shortTerm = shortTerm
            self.peak = peak
        }
    }

    private let sampleRate: Double
    private let channelCount: Int
    private let filters: [KWeightingFilter]
    private let blockFrames: Int
    private var pending: [[Float]]

    /// One mean-square value per 100 ms, already summed across channels.
    /// Kept from reset to stop so integrated loudness truly spans the
    /// measurement instead of silently becoming a rolling three-minute value.
    private var blockPowers: [Float] = []
    /// Bounded loudness histograms keep integrated/LRA calculations O(1) in
    /// memory and prevent repeated scans of a multi-hour measurement history.
    private let integratedHistogramMin: Float = -70
    private let integratedHistogramStep: Float = 0.1
    private var integratedCounts = [Int](repeating: 0, count: 1001)
    private var integratedPowerSums = [Double](repeating: 0, count: 1001)
    private let lraHistogramMin: Float = -70
    private let lraHistogramStep: Float = 0.1
    private var lraCounts = [Int](repeating: 0, count: 901)
    private var lraAbsoluteLevelSum: Double = 0
    private var lraAbsoluteCount = 0
    private var blockCounter = 0
    private var integratedCounter = 0
    private var lastSamplePeakDB: Float = -.infinity

    public private(set) var history: [HistoryPoint] = []
    /// 30 seconds at 5 history points per second (one point every 200 ms).
    public var historyCapacity: Int = 150
    public private(set) var momentary: Float = -.infinity
    public private(set) var shortTerm: Float = -.infinity
    public private(set) var integrated: Float = -.infinity
    public private(set) var loudnessRange: Float = 0

    /// A custom S window is supported, but 3 seconds is the EBU default.
    public var shortTermSeconds: Double = 3.0 {
        didSet {
            let normalized = shortTermSeconds.isFinite
                ? max(0.1, min(60, shortTermSeconds))
                : 3.0
            if shortTermSeconds != normalized { shortTermSeconds = normalized }
        }
    }
    /// EMA weight for the new sample while the displayed value is falling.
    /// 1 means no display smoothing. The measurement itself remains unchanged.
    public var displaySmoothing: Float = 1.0 {
        didSet { resetSmoothers() }
    }
    public var numberSmoothing: Float = 1.0
    public var calibrationOffset: Float = 0.0

    private let lock = NSLock()
    private var smoothM: Float = -.infinity
    private var smoothS: Float = -.infinity
    private var graphM: Float = -.infinity
    private var graphS: Float = -.infinity

    public init(sampleRate: Double, channelCount: Int = 1) {
        self.sampleRate = max(1, sampleRate)
        self.channelCount = max(1, channelCount)
        self.blockFrames = max(1, Int((max(1, sampleRate) * 0.1).rounded()))
        self.filters = (0..<max(1, channelCount)).map { _ in KWeightingFilter(sampleRate: Float(max(1, sampleRate))) }
        self.pending = (0..<max(1, channelCount)).map { _ in [] }
        self.pending.indices.forEach { pending[$0].reserveCapacity(blockFrames * 2) }
    }

    /// Processes a mono signal.
    public func process(_ samples: [Float]) {
        processChannels([samples])
    }

    /// Processes stereo as one programme, combining channel energies before
    /// applying integrated and LRA gates.
    public func processStereo(left: [Float], right: [Float]) {
        let count = min(left.count, right.count)
        guard count > 0 else { return }
        // processChannels сам ограничивает обработку самым коротким каналом;
        // передаём исходные массивы без копирования каждого callback-а.
        processChannels([left, right])
    }

    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        pending.indices.forEach { pending[$0].removeAll(keepingCapacity: true) }
        filters.forEach { $0.reset() }
        blockPowers.removeAll(keepingCapacity: true)
        integratedCounts.indices.forEach { integratedCounts[$0] = 0 }
        integratedPowerSums.indices.forEach { integratedPowerSums[$0] = 0 }
        lraCounts.indices.forEach { lraCounts[$0] = 0 }
        lraAbsoluteLevelSum = 0
        lraAbsoluteCount = 0
        history.removeAll(keepingCapacity: true)
        blockCounter = 0
        integratedCounter = 0
        lastSamplePeakDB = -.infinity
        momentary = -.infinity
        shortTerm = -.infinity
        integrated = -.infinity
        loudnessRange = 0
        smoothM = -.infinity
        smoothS = -.infinity
        graphM = -.infinity
        graphS = -.infinity
    }

    public func resetHistory() {
        lock.lock()
        history.removeAll(keepingCapacity: true)
        lock.unlock()
    }

    public func reading() -> Reading {
        lock.lock()
        defer { lock.unlock() }
        return Reading(
            momentaryLUFS: momentary + calibrationOffset,
            shortTermLUFS: shortTerm + calibrationOffset,
            integratedLUFS: integrated + calibrationOffset,
            loudnessRangeLU: loudnessRange
        )
    }

    public func historySnapshot() -> [HistoryPoint] {
        lock.lock()
        defer { lock.unlock() }
        guard calibrationOffset != 0 else { return history }
        return history.map {
            HistoryPoint(
                momentary: $0.momentary + calibrationOffset,
                shortTerm: $0.shortTerm + calibrationOffset,
                peak: $0.peak
            )
        }
    }

    private func processChannels(_ channels: [[Float]]) {
        guard !channels.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }

        let count = min(channelCount, channels.count)
        guard count > 0 else { return }
        let frameCount = channels.prefix(count).map(\.count).min() ?? 0
        guard frameCount > 0 else { return }

        var inputPeak: Float = 0
        for channel in channels.prefix(count) {
            for sample in channel.prefix(frameCount) {
                inputPeak = max(inputPeak, abs(sample))
            }
        }
        if inputPeak > 0 {
            lastSamplePeakDB = max(lastSamplePeakDB, 20 * log10(inputPeak))
        }

        for channel in 0..<count {
            pending[channel].append(contentsOf: channels[channel].prefix(frameCount))
        }

        while pending[0].count >= blockFrames {
            var combinedMeanSquare: Float = 0
            for channel in 0..<count {
                let block = Array(pending[channel].prefix(blockFrames))
                pending[channel].removeFirst(blockFrames)
                let filtered = filters[channel].process(block)
                var sumSquares: Float = 0
                vDSP_svesq(filtered, 1, &sumSquares, vDSP_Length(filtered.count))
                combinedMeanSquare += sumSquares / Float(blockFrames)
            }
            process100msBlock(combinedMeanSquare)
        }
    }

    private func process100msBlock(_ meanSquare: Float) {
        blockPowers.append(max(0, meanSquare))
        blockCounter += 1

        var rawMomentary: Float?
        if blockPowers.count >= 4 {
            let power = blockPowers.suffix(4).reduce(0, +) / 4
            recordIntegratedPower(power)
            rawMomentary = loudness(power)
        }

        let shortBlocks = max(1, Int((shortTermSeconds / 0.1).rounded()))
        var rawShortTerm: Float?
        if blockPowers.count >= shortBlocks {
            let power = blockPowers.suffix(shortBlocks).reduce(0, +) / Float(shortBlocks)
            rawShortTerm = loudness(power)
        }

        if blockPowers.count >= 30, blockCounter % 10 == 0 {
            let power = blockPowers.suffix(30).reduce(0, +) / 30
            recordLRA(loudness(power))
            updateLRA()
        }

        integratedCounter += 1
        if integratedCounter >= 10 {
            integratedCounter = 0
            updateIntegrated()
        }

        updateDisplayValues(rawMomentary: rawMomentary, rawShortTerm: rawShortTerm)
        if blockCounter % 2 == 0 {
            history.append(HistoryPoint(
                momentary: graphM,
                shortTerm: graphS,
                peak: lastSamplePeakDB
            ))
            if history.count > historyCapacity {
                history.removeFirst(history.count - historyCapacity)
            }
        }
        let retainedBlocks = max(30, max(1, Int((shortTermSeconds / 0.1).rounded())))
        if blockPowers.count > retainedBlocks {
            blockPowers.removeFirst(blockPowers.count - retainedBlocks)
        }
    }

    private func updateDisplayValues(rawMomentary: Float?, rawShortTerm: Float?) {
        let numFall = numberSmoothing.isFinite ? max(0, min(1, numberSmoothing)) : 0.05
        let numRise = numFall >= 0.999 ? 1 : min(0.9, numFall * 4)
        let graphFall = displaySmoothing.isFinite ? max(0, min(1, displaySmoothing)) : 0.02
        let graphRise = graphFall >= 0.999 ? 1 : min(0.9, graphFall * 4)

        if let rawMomentary {
            momentary = smooth(raw: rawMomentary, previous: &smoothM, rise: numRise, fall: numFall)
            graphM = smooth(raw: rawMomentary, previous: &graphM, rise: graphRise, fall: graphFall)
        }
        if let rawShortTerm {
            shortTerm = smooth(raw: rawShortTerm, previous: &smoothS, rise: numRise, fall: numFall)
            graphS = smooth(raw: rawShortTerm, previous: &graphS, rise: graphRise, fall: graphFall)
        }
    }

    private func smooth(raw: Float, previous: inout Float, rise: Float, fall: Float) -> Float {
        // Silence used to produce -infinity, which this EMA rejected and then
        // held the previous reading forever. Use a finite display floor and
        // bypass the optional release smoothing at that floor.
        let sanitized = raw.isFinite ? max(LoudnessConstants.displayFloorLUFS, raw)
                                     : LoudnessConstants.displayFloorLUFS
        if sanitized <= LoudnessConstants.displayFloorLUFS {
            previous = LoudnessConstants.displayFloorLUFS
            return previous
        }
        let target = previous.isFinite ? previous : raw
        let alpha = sanitized > target ? rise : fall
        let value = target + alpha * (sanitized - target)
        previous = value
        return value
    }

    private func updateIntegrated() {
        var absoluteCount = 0
        var absolutePower: Double = 0
        for i in integratedCounts.indices {
            absoluteCount += integratedCounts[i]
            absolutePower += integratedPowerSums[i]
        }
        guard absoluteCount > 0 else { return }
        let firstPass = loudness(Float(absolutePower / Double(absoluteCount)))
        let threshold = max(LoudnessConstants.absoluteGateLU, firstPass + LoudnessConstants.relativeGateLU)
        let firstBin = min(integratedCounts.count, max(0, Int(ceil((threshold - integratedHistogramMin) / integratedHistogramStep))))
        guard firstBin < integratedCounts.count else { return }
        var gatedCount = 0
        var gatedPower: Double = 0
        for i in firstBin..<integratedCounts.count {
            gatedCount += integratedCounts[i]
            gatedPower += integratedPowerSums[i]
        }
        guard gatedCount > 0 else { return }
        integrated = loudness(Float(gatedPower / Double(gatedCount)))
    }

    private func updateLRA() {
        // EBU Tech 3342 uses an absolute gate and a relative gate 20 LU below
        // the absolute-gated short-term loudness distribution.
        guard lraAbsoluteCount >= 10 else { return }
        let relative = Float(lraAbsoluteLevelSum / Double(lraAbsoluteCount)) - 20
        let threshold = max(LoudnessConstants.absoluteGateLU, relative)
        let firstBin = min(lraCounts.count, max(0, Int(ceil((threshold - lraHistogramMin) / lraHistogramStep))))
        guard firstBin < lraCounts.count else { return }
        let gatedCount = lraCounts[firstBin...].reduce(0, +)
        guard gatedCount >= 10 else { return }
        let p10 = histogramPercentile(counts: lraCounts, from: firstBin, total: gatedCount, fraction: 0.10,
                                      minimum: lraHistogramMin, step: lraHistogramStep)
        let p95 = histogramPercentile(counts: lraCounts, from: firstBin, total: gatedCount, fraction: 0.95,
                                      minimum: lraHistogramMin, step: lraHistogramStep)
        loudnessRange = max(0, p95 - p10)
    }

    private func recordIntegratedPower(_ power: Float) {
        let level = loudness(power)
        guard level >= LoudnessConstants.absoluteGateLU else { return }
        let index = min(integratedCounts.count - 1,
                        max(0, Int((level - integratedHistogramMin) / integratedHistogramStep)))
        integratedCounts[index] += 1
        integratedPowerSums[index] += Double(power)
    }

    private func recordLRA(_ level: Float) {
        guard level >= LoudnessConstants.absoluteGateLU else { return }
        let index = min(lraCounts.count - 1,
                        max(0, Int((level - lraHistogramMin) / lraHistogramStep)))
        lraCounts[index] += 1
        lraAbsoluteLevelSum += Double(level)
        lraAbsoluteCount += 1
    }

    private func histogramPercentile(
        counts: [Int], from start: Int, total: Int, fraction: Double,
        minimum: Float, step: Float
    ) -> Float {
        let target = Int((Double(total - 1) * fraction).rounded(.down))
        var seen = 0
        for i in start..<counts.count {
            seen += counts[i]
            if seen > target { return minimum + Float(i) * step }
        }
        return minimum + Float(counts.count - 1) * step
    }

    private func loudness(_ meanSquare: Float) -> Float {
        guard meanSquare.isFinite, meanSquare > 0 else { return LoudnessConstants.displayFloorLUFS }
        return max(LoudnessConstants.displayFloorLUFS, -0.691 + 10 * log10(meanSquare))
    }

    private func resetSmoothers() {
        lock.lock()
        smoothM = -.infinity
        smoothS = -.infinity
        graphM = -.infinity
        graphS = -.infinity
        lock.unlock()
    }
}

/// ITU-R BS.1770 K-weighting filter. Coefficients are recalculated from the
/// standard pole/zero frequencies for the actual input sample rate.
final class KWeightingFilter {
    private let highShelf: Biquad
    private let highPass: Biquad

    init(sampleRate: Float) {
        let fs = Double(max(sampleRate, 1))
        highShelf = Biquad.kWeightingShelf(sampleRate: fs)
        highPass = Biquad.kWeightingHighPass(sampleRate: fs)
    }

    func process(_ input: [Float]) -> [Float] {
        highPass.process(highShelf.process(input))
    }

    func reset() {
        highShelf.reset()
        highPass.reset()
    }
}

final class Biquad {
    private let b0: Float
    private let b1: Float
    private let b2: Float
    private let a1: Float
    private let a2: Float
    private var z1: Float = 0
    private var z2: Float = 0

    private init(b0: Double, b1: Double, b2: Double, a1: Double, a2: Double) {
        self.b0 = Float(b0)
        self.b1 = Float(b1)
        self.b2 = Float(b2)
        self.a1 = Float(a1)
        self.a2 = Float(a2)
    }

    static func kWeightingShelf(sampleRate fs: Double) -> Biquad {
        let f0 = 1681.974450955533
        let gainDB = 3.999843853973347
        let q = 0.7071752369554196
        let k = tan(Double.pi * f0 / fs)
        let vh = pow(10, gainDB / 20)
        let vb = pow(vh, 0.4996667741545416)
        let a0 = 1 + k / q + k * k
        return Biquad(
            b0: (vh + vb * k / q + k * k) / a0,
            b1: 2 * (k * k - vh) / a0,
            b2: (vh - vb * k / q + k * k) / a0,
            a1: 2 * (k * k - 1) / a0,
            a2: (1 - k / q + k * k) / a0
        )
    }

    static func kWeightingHighPass(sampleRate fs: Double) -> Biquad {
        let f0 = 38.13547087602444
        let q = 0.5003270373238773
        let k = tan(Double.pi * f0 / fs)
        let a0 = 1 + k / q + k * k
        return Biquad(
            b0: 1 / a0,
            b1: -2 / a0,
            b2: 1 / a0,
            a1: 2 * (k * k - 1) / a0,
            a2: (1 - k / q + k * k) / a0
        )
    }

    func process(_ input: [Float]) -> [Float] {
        var output = [Float](repeating: 0, count: input.count)
        for i in input.indices {
            let x = input[i]
            let y = b0 * x + z1
            z1 = b1 * x - a1 * y + z2
            z2 = b2 * x - a2 * y
            output[i] = y
        }
        return output
    }

    func reset() {
        z1 = 0
        z2 = 0
    }
}
