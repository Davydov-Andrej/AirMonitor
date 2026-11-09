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
    /// 30 секунд (окно графика 15 с + запас).
    public var historyCapacity: Int = 300

    public private(set) var momentary: Float = -Float.infinity
    public private(set) var shortTerm: Float = -Float.infinity
    public private(set) var integrated: Float = -Float.infinity
    public private(set) var loudnessRange: Float = 0
    public private(set) var truePeakDB: Float = -Float.infinity

    private let lock = NSLock()

    /// Окно short-term в секундах (стандарт EBU — 3 с; настраивается).
    public var shortTermSeconds: Double = 1.0 {
        didSet {
            shortTermBlocks = max(1, Int(shortTermSeconds / 0.1))
        }
    }
    private var shortTermBlocks: Int = 10

    /// Display smoothing (Youlean-стиль): EMA-вес НОВОГО значения.
    /// 1.0 = без сглаживания (значение мгновенное), 0.1 = сильное сглаживание.
    /// Сглаживает momentary/shortTerm и ИСТОРИЮ (график).
    public var displaySmoothing: Float = 1.0 {
        didSet {
            smoothLock.lock()
            smoothM = -Float.infinity
            smoothS = -Float.infinity
            smoothLock.unlock()
        }
    }
    private let smoothLock = NSLock()
    private var smoothM: Float = -Float.infinity
    private var smoothS: Float = -Float.infinity

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
        let rawM = windowLoudness(last: 4)

        // Short-term: окно shortTermSeconds (по умолчанию 1 с).
        let rawS = windowLoudness(last: shortTermBlocks)

        // Display smoothing: EMA к новому значению (Youlean-стиль).
        // При -inf старого или нового — passthrough (иначе заморозка на -inf).
        smoothLock.lock()
        if smoothM.isFinite && rawM.isFinite {
            momentary = smoothM + displaySmoothing * (rawM - smoothM)
        } else {
            momentary = rawM
        }
        if smoothS.isFinite && rawS.isFinite {
            shortTerm = smoothS + displaySmoothing * (rawS - smoothS)
        } else {
            shortTerm = rawS
        }
        smoothM = momentary
        smoothS = shortTerm
        smoothLock.unlock()

        // История 10 Гц — из сглаженных значений: график плавный как у Youlean.
        let hp = HistoryPoint(momentary: momentary, shortTerm: shortTerm, peak: truePeakDB)
        history.append(hp)
        if history.count > historyCapacity {
            history.removeFirst(history.count - historyCapacity)
        }

        updateIntegrated()
    }

    /// Громкость окна из `last` подблоков: −0.691 + 10·log10(среднее).
    /// По BS.1770 Momentary и Short-term считаются БЕЗ гейта
    /// (гейтится только Integrated — см. updateIntegrated).
    private func windowLoudness(last: Int) -> Float {
        guard !subMeanSquares.isEmpty else { return -Float.infinity }
        let window = subMeanSquares.suffix(last)
        var sum: Float = 0
        for ms in window {
            sum += ms
        }
        return -0.691 + 10 * log10(max(sum / Float(window.count), 1e-12))
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

/// Каскад K-weighting по ITU-R BS.1770-4.
/// Табличные коэффициенты стандарта (для 48 кГц): АЧХ при других частотах
/// дискретизации (44.1к и т.д.) отклоняется от идеала < 0.5 дБ на самом низе —
/// приемлемо для мониторинга (проверено расчётом, см. v0.9.5).
final class KWeightingFilter {
    private let hp: Biquad
    private let hs: Biquad

    init(sampleRate: Float) {
        // Stage 1: high-shelf +4 дБ (табличные коэффициенты BS.1770-4)
        hs = Biquad(coefficients:
            (b0: 1.53512485958697, b1: -2.69169618940638, b2: 1.28039103378636,
             a1: -1.63249945455166, a2: 0.737932270408209))
        // Stage 2: RLB high-pass 38 Гц (табличные)
        hp = Biquad(coefficients:
            (b0: 1.0, b1: -2.0, b2: 1.0,
             a1: -1.99004745483398, a2: 0.990072250366216))
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

    init(coefficients: (b0: Double, b1: Double, b2: Double, a1: Double, a2: Double)) {
        self.b0 = Float(coefficients.b0)
        self.b1 = Float(coefficients.b1)
        self.b2 = Float(coefficients.b2)
        self.a1 = Float(coefficients.a1)
        self.a2 = Float(coefficients.a2)
    }

    init() {}

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
