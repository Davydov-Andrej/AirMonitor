import Foundation
import Accelerate

/// Единицы громкости по ITU-R BS.1770-4 / EBU R128.
public struct LoudnessConstants {
    public static let targetMomentary: Float = -23
    public static let targetIntegrated: Float = -23
    public static let gatingThresholdLU: Float = -70
    public static let absoluteGateLU: Float = -70
    public static let relativeGateLU: Float = -10
}

/// Измеряет громкость в реальном времени: momentary (400 мс),
/// short-term (3 с), integrated + LR. K-weighting — каскад из
/// high-shelf (RS=1.5147) и high-pass (FC=38.135 Гц).
public final class LoudnessMeter {

    public struct Reading: Sendable {
        public let momentaryLUFS: Float
        public let shortTermLUFS: Float
        public let integratedLUFS: Float
        public let loudnessRangeLU: Float
        public let truePeakDB: Float

        public static let empty = Reading(
            momentaryLUFS: -Float.infinity,
            shortTermLUFS: -Float.infinity,
            integratedLUFS: -Float.infinity,
            loudnessRangeLU: 0,
            truePeakDB: -Float.infinity
        )
    }

    /// Точка истории громкости (для бегущего графика).
    public struct HistoryPoint: Sendable {
        public let momentary: Float
        public let shortTerm: Float
        public let peak: Float
    }

    private let sampleRate: Double
    private let blockSize: Int
    private var allSamples: [Float] = []
    private var blockStart = 0
    private var blockLevels: [Float] = []
    private var kFilter: KWeightingFilter

    /// История short-term громкости (шаг ~0.4 с) — для графика.
    public private(set) var history: [HistoryPoint] = []
    /// Максимум истории (по умолчанию 15 минут эфира).
    public var historyCapacity: Int = 2250

    public private(set) var momentary: Float = -Float.infinity
    public private(set) var shortTerm: Float = -Float.infinity
    public private(set) var integrated: Float = -Float.infinity
    public private(set) var loudnessRange: Float = 0
    public private(set) var truePeakDB: Float = -Float.infinity

    public init(sampleRate: Double) {
        self.sampleRate = sampleRate
        self.blockSize = Int(sampleRate * 0.4)
        self.kFilter = KWeightingFilter(sampleRate: Float(sampleRate))
        self.allSamples.reserveCapacity(blockSize * 300)
    }

    public func process(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        allSamples.append(contentsOf: samples)

        while allSamples.count - blockStart >= blockSize {
            let end = blockStart + blockSize
            let block = Array(allSamples[blockStart..<end])
            blockStart = end
            processBlock(block)
        }

        if allSamples.count > blockSize * 300 {
            let drop = allSamples.count - blockSize * 200
            allSamples.removeFirst(drop)
            blockStart -= drop
            if blockStart < 0 { blockStart = 0 }
        }
    }

    public func resetHistory() {
        lock.lock()
        history.removeAll()
        blockLevels.removeAll()
        integrated = -Float.infinity
        lock.unlock()
    }

    public func reading() -> Reading {
        lock.lock()
        defer { lock.unlock() }
        return Reading(
            momentaryLUFS: momentary,
            shortTermLUFS: shortTerm,
            integratedLUFS: integrated,
            loudnessRangeLU: loudnessRange,
            truePeakDB: truePeakDB
        )
    }

    private let lock = NSLock()

    // MARK: - Private

    private func processBlock(_ block: [Float]) {
        let filtered = kFilter.process(block)

        var sumSquares: Float = 0
        vDSP_svesq(filtered, 1, &sumSquares, vDSP_Length(filtered.count))
        let meanSquare = sumSquares / Float(filtered.count)

        if meanSquare > 1e-12 {
            let level = -0.691 + 10 * log10(meanSquare)
            blockLevels.append(level)
            if blockLevels.count > 2000 {
                blockLevels.removeFirst(1000)
            }

            momentary = level
            shortTerm = mean(of: Array(blockLevels.suffix(shortTermBlockCount)))

            let gateThreshold = currentGateThreshold
            let gated = blockLevels.filter { $0 >= gateThreshold }
            if !gated.isEmpty {
                integrated = mean(of: gated)
            }

            loudnessRange = computeLoudnessRange()
        } else {
            momentary = -Float.infinity
            // short-term продолжаем считать (там окна длинные)
            shortTerm = mean(of: Array(blockLevels.suffix(shortTermBlockCount)))
        }

        // История: точка на каждый 0.4-секундный блок.
        let hp = HistoryPoint(momentary: momentary, shortTerm: shortTerm, peak: truePeakDB)
        lock.lock()
        history.append(hp)
        if history.count > historyCapacity {
            history.removeFirst(history.count - historyCapacity)
        }
        lock.unlock()

        trackTruePeak(in: filtered)
    }

    private var shortTermBlockCount: Int {
        // 3 с / 0.4 с = 7.5 → 8 блоков
        8
    }

    private var currentGateThreshold: Float {
        guard let maxLevel = blockLevels.max() else {
            return LoudnessConstants.absoluteGateLU
        }
        let relative = maxLevel + LoudnessConstants.relativeGateLU
        return max(LoudnessConstants.absoluteGateLU, relative)
    }

    private func computeLoudnessRange() -> Float {
        guard blockLevels.count >= 20 else { return 0 }
        let sorted = blockLevels.sorted()
        let q10 = sorted[sorted.count * 10 / 100]
        let q95 = sorted[sorted.count * 95 / 100]
        return max(0, q95 - q10)
    }

    private func trackTruePeak(in filtered: [Float]) {
        guard var maxLinear: Float = filtered.max() else { return }
        maxLinear = abs(maxLinear)
        guard maxLinear > 0 else { return }
        let peakDB = 20 * log10(maxLinear)
        if peakDB > truePeakDB {
            truePeakDB = peakDB
        }
    }

    private func mean(of values: [Float]) -> Float {
        values.reduce(0, +) / Float(max(values.count, 1))
    }
}

/// Каскад K-weighting: high-pass 38.135 Гц → high-shelf +4 дБ (RS=1.5147).
final class KWeightingFilter {
    private let hp: Biquad
    private let hs: Biquad

    init(sampleRate: Float) {
        hp = Biquad.highPass(frequency: 38.135, sampleRate: sampleRate, q: 0.500327)
        hs = Biquad.highShelfGain(db: 4.0, frequency: 1681.9744509555319, sampleRate: sampleRate)
    }

    func process(_ input: [Float]) -> [Float] {
        let stage1 = hp.process(input)
        return hs.process(stage1)
    }
}

final class Biquad {
    private var b0: Float
    private var b1: Float
    private var b2: Float
    private var a1: Float
    private var a2: Float
    private var z1: Float = 0
    private var z2: Float = 0

    private init(b0: Float, b1: Float, b2: Float, a1: Float, a2: Float) {
        self.b0 = b0
        self.b1 = b1
        self.b2 = b2
        self.a1 = a1
        self.a2 = a2
    }

    static func highPass(frequency: Float, sampleRate: Float, q: Float) -> Biquad {
        let w0 = 2 * Float.pi * frequency / sampleRate
        let cosw = cosf(w0)
        let alpha = sinf(w0) / (2 * q)
        let b0 = (1 + cosw) / 2
        let b1 = -(1 + cosw)
        let b2 = (1 + cosw) / 2
        let a0 = 1 + alpha
        return normalized(b0, b1, b2, a0: a0, a1: -2 * cosw, a2: 1 - alpha)
    }

    static func highShelfGain(db: Float, frequency: Float, sampleRate: Float) -> Biquad {
        let A = powf(10, db / 40)
        let w0 = 2 * Float.pi * frequency / sampleRate
        let cosw = cosf(w0)
        let sinw = sinf(w0)
        let S = Float(1.0)
        let alpha = sinw / 2 * sqrtf((A + 1 / A) * (1 / S - 1) + 2)
        let twoSqrtA = 2 * sqrtf(A) * alpha

        let b0 = A * ((A + 1) + (A - 1) * cosw + twoSqrtA)
        let b1 = -2 * A * ((A - 1) + (A + 1) * cosw)
        let b2 = A * ((A + 1) + (A - 1) * cosw - twoSqrtA)
        let a0 = (A + 1) - (A - 1) * cosw + twoSqrtA
        let a1 = 2 * ((A - 1) - (A + 1) * cosw)
        let a2 = (A + 1) - (A - 1) * cosw - twoSqrtA
        return normalized(b0, b1, b2, a0: a0, a1: a1, a2: a2)
    }

    private static func normalized(
        _ b0: Float, _ b1: Float, _ b2: Float,
        a0: Float, a1: Float, a2: Float
    ) -> Biquad {
        Biquad(
            b0: b0 / a0,
            b1: b1 / a0,
            b2: b2 / a0,
            a1: a1 / a0,
            a2: a2 / a0
        )
    }

    func process(_ input: [Float]) -> [Float] {
        guard !input.isEmpty else { return [] }
        var output = [Float](repeating: 0, count: input.count)
        for i in 0..<input.count {
            let x = input[i]
            let y = b0 * x + z1
            z1 = b1 * x - a1 * y + z2
            z2 = b2 * x - a2 * y
            output[i] = y
        }
        return output
    }
}
