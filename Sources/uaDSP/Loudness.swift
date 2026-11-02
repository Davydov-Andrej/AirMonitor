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

/// Измеритель громкости ITU-R BS.1770-4.
/// - Momentary (400 мс) и Short-term (3 с) обновляются 10 раз/с (шаг 100 мс) —
///   так же, как в Youlean Loudness Meter и на пультах.
/// - History: поток точек 10 Гц для бегущего графика.
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

        public init(momentary: Float, shortTerm: Float, peak: Float) {
            self.momentary = momentary
            self.shortTerm = shortTerm
            self.peak = peak
        }
    }

    private let sampleRate: Double
    private let kFilter: KWeightingFilter

    /// Подблок 100 мс (единица истории и скользящих окон).
    private let subBlockSize: Int
    private var pending: [Float] = []

    /// Средние квадраты подблоков (100 мс каждый) — кольцо.
    private var subMeanSquares: [Float] = []
    private let subCapacity = 1800  // 3 минуты для integrated/LRA окон

    /// История 10 Гц.
    public private(set) var history: [HistoryPoint] = []
    public var historyCapacity: Int = 600  // 60 секунд по умолчанию

    public private(set) var momentary: Float = -Float.infinity
    public private(set) var shortTerm: Float = -Float.infinity
    public private(set) var integrated: Float = -Float.infinity
    public private(set) var loudnessRange: Float = 0
    public private(set) var truePeakDB: Float = -Float.infinity

    private let lock = NSLock()

    public init(sampleRate: Double) {
        self.sampleRate = sampleRate
        self.kFilter = KWeightingFilter(sampleRate: Float(sampleRate))
        self.subBlockSize = max(1, Int(sampleRate * 0.1))
        self.pending.reserveCapacity(subBlockSize * 2)
        self.subMeanSquares.reserveCapacity(subCapacity)
    }

    public func process(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }

        pending.append(contentsOf: samples)

        while pending.count >= subBlockSize {
            let block = Array(pending[0..<subBlockSize])
            pending.removeFirst(subBlockSize)
            processSubBlock(block)
        }

        if pending.count > subBlockSize * 4 {
            pending.removeFirst(pending.count - subBlockSize)
        }
    }

    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        pending.removeAll()
        subMeanSquares.removeAll()
        history.removeAll()
        momentary = -Float.infinity
        shortTerm = -Float.infinity
        integrated = -Float.infinity
        loudnessRange = 0
    }

    public func resetHistory() {
        lock.lock()
        defer { lock.unlock() }
        history.removeAll()
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

    /// Копия истории для UI.
    public func historySnapshot() -> [HistoryPoint] {
        lock.lock()
        defer { lock.unlock() }
        return history
    }

    // MARK: - Private

    private func processSubBlock(_ block: [Float]) {
        let filtered = kFilter.process(block)

        var sumSquares: Float = 0
        vDSP_svesq(filtered, 1, &sumSquares, vDSP_Length(filtered.count))
        let meanSquare = sumSquares / Float(filtered.count)
        subMeanSquares.append(meanSquare)
        if subMeanSquares.count > subCapacity {
            subMeanSquares.removeFirst(subMeanSquares.count - subCapacity)
        }

        // True peak по сырому отфильтрованному блоку.
        if let maxAbs = filtered.map({ abs($0) }).max(), maxAbs > 0 {
            let peak = 20 * log10(maxAbs)
            if peak > truePeakDB { truePeakDB = peak }
        }

        // Momentary: последние 4 подблока (400 мс).
        momentary = windowLoudness(last: 4)

        // Short-term: последние 30 подблоков (3 с).
        shortTerm = windowLoudness(last: 30)

        // История 10 Гц.
        let hp = HistoryPoint(momentary: momentary, shortTerm: shortTerm, peak: truePeakDB)
        history.append(hp)
        if history.count > historyCapacity {
            history.removeFirst(history.count - historyCapacity)
        }

        updateIntegrated()
    }

    /// Громкость окна из `last` подблоков: −0.691 + 10·log10(среднее).
    /// Тихие подблоки (< −70 LU) исключаются — так работает гейтинг.
    private func windowLoudness(last: Int) -> Float {
        guard !subMeanSquares.isEmpty else { return -Float.infinity }
        let window = subMeanSquares.suffix(last)
        var sum: Float = 0
        var count = 0
        for ms in window {
            let db = -0.691 + 10 * log10(max(ms, 1e-12))
            if db > LoudnessConstants.absoluteGateLU {
                sum += ms
                count += 1
            }
        }
        guard count > 0 else { return -Float.infinity }
        return -0.691 + 10 * log10(sum / Float(count))
    }

    /// Integrated с двойным гейтингом (absolute −70 LU, relative −10 LU).
    private func updateIntegrated() {
        guard !subMeanSquares.isEmpty else { return }

        var levels: [Float] = []
        levels.reserveCapacity(subMeanSquares.count)
        for ms in subMeanSquares {
            let db = -0.691 + 10 * log10(max(ms, 1e-12))
            levels.append(db)
        }

        // Absolute gate
        let absolutely = levels.filter { $0 > LoudnessConstants.absoluteGateLU }
        guard !absolutely.isEmpty else { return }
        var powers: [Float] = []
        for ms in subMeanSquares {
            let db = -0.691 + 10 * log10(max(ms, 1e-12))
            if db > LoudnessConstants.absoluteGateLU {
                powers.append(ms)
            }
        }
        let firstPass = -0.691 + 10 * log10(powers.reduce(0, +) / Float(powers.count))

        // Relative gate (−10 LU от первого прохода)
        let relThreshold = firstPass + LoudnessConstants.relativeGateLU
        var gatedPowers: [Float] = []
        for ms in subMeanSquares {
            let db = -0.691 + 10 * log10(max(ms, 1e-12))
            if db > max(LoudnessConstants.absoluteGateLU, relThreshold) {
                gatedPowers.append(ms)
            }
        }
        if !gatedPowers.isEmpty {
            integrated = -0.691 + 10 * log10(gatedPowers.reduce(0, +) / Float(gatedPowers.count))
        }

        // LRA: 10-й и 95-й перцентили коротких окон (3 с = 30 подблоков).
        if subMeanSquares.count >= 60 {
            var shortLevels: [Float] = []
            let step = 5  // каждые 0.5 с
            var i = 30
            while i <= subMeanSquares.count {
                let slice = subMeanSquares[(i - 30)..<i]
                let l = -0.691 + 10 * log10(max(slice.reduce(0, +) / 30, 1e-12))
                shortLevels.append(l)
                i += step
            }
            if shortLevels.count >= 10 {
                let sorted = shortLevels.sorted()
                let q10 = sorted[sorted.count * 10 / 100]
                let q95 = sorted[sorted.count * 95 / 100]
                loudnessRange = max(0, q95 - q10)
            }
        }
    }
}

/// Каскад K-weighting: high-pass 38.135 Гц → high-shelf +4 дБ (1.68 кГц).
final class KWeightingFilter {
    private let hp: Biquad
    private let hs: Biquad

    init(sampleRate: Float) {
        hp = Biquad.highPass(frequency: 38.135, sampleRate: sampleRate, q: 0.500327)
        hs = Biquad.highShelfGain(db: 4.0, frequency: 1681.97, sampleRate: sampleRate)
    }

    func process(_ input: [Float]) -> [Float] {
        hp.process(hs.process(input))
    }
}

final class Biquad {
    private var b0: Float = 0
    private var b1: Float = 0
    private var b2: Float = 0
    private var a1: Float = 0
    private var a2: Float = 0
    private var z1: Float = 0
    private var z2: Float = 0

    static func highPass(frequency: Float, sampleRate: Float, q: Float) -> Biquad {
        let b = Biquad()
        let w0 = 2 * Float.pi * frequency / sampleRate
        let cosw0 = cosf(w0)
        let alpha = sinf(w0) / (2 * q)
        let a0 = 1 + alpha
        b.b0 = ((1 + cosw0) / 2) / a0
        b.b1 = -(1 + cosw0) / a0
        b.b2 = ((1 + cosw0) / 2) / a0
        b.a1 = (-2 * cosw0) / a0
        b.a2 = (1 - alpha) / a0
        return b
    }

    static func highShelfGain(db: Float, frequency: Float, sampleRate: Float) -> Biquad {
        let b = Biquad()
        let A = powf(10, db / 40)
        let w0 = 2 * Float.pi * frequency / sampleRate
        let cosw0 = cosf(w0)
        let sinw0 = sinf(w0)
        let S: Float = 1.0  // slope
        let alpha = sinw0 / 2 * sqrt((A + 1 / A) * (1 / S - 1) + 2)
        let twoSqrtAalpha = 2 * sqrtf(A) * alpha
        let a0 = (A + 1) - (A - 1) * cosw0 + twoSqrtAalpha
        b.b0 = (A * ((A + 1) + (A - 1) * cosw0 + twoSqrtAalpha)) / a0
        b.b1 = (-2 * A * ((A - 1) + (A + 1) * cosw0)) / a0
        b.b2 = (A * ((A + 1) + (A - 1) * cosw0 - twoSqrtAalpha)) / a0
        b.a1 = (2 * ((A - 1) - (A + 1) * cosw0)) / a0
        b.a2 = ((A + 1) - (A - 1) * cosw0 - twoSqrtAalpha) / a0
        return b
    }

    func process(_ input: [Float]) -> [Float] {
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
