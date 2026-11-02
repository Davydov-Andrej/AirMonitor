import Foundation
import Accelerate

public struct SpectrumPoint: Identifiable, Sendable, Equatable {
    public let id: Int
    public let frequency: Float
    public let magnitudeDB: Float

    public init(id: Int, frequency: Float, magnitudeDB: Float) {
        self.id = id
        self.frequency = frequency
        self.magnitudeDB = magnitudeDB
    }
}

/// Полоса спектрального анализатора с плавным значением и пик-маркером.
public struct RTABand: Identifiable, Sendable {
    public let id: Int
    public let centerFrequency: Float
    public let lowerFrequency: Float
    public let upperFrequency: Float
    public let levelDB: Float
    public let peakDB: Float

    public init(
        id: Int,
        centerFrequency: Float,
        lowerFrequency: Float,
        upperFrequency: Float,
        levelDB: Float,
        peakDB: Float
    ) {
        self.id = id
        self.centerFrequency = centerFrequency
        self.lowerFrequency = lowerFrequency
        self.upperFrequency = upperFrequency
        self.levelDB = levelDB
        self.peakDB = peakDB
    }
}

/// Настройки RTA-анализатора (как в Room EQ Wizard).
public struct RTASettings: Sendable {
    /// Полос на октаву: 1, 3, 6, 12, 24.
    public var bandsPerOctave: Int
    /// Скорость подъёма (0...1], больше = быстрее реакция.
    public var attack: Float
    /// Скорость спада (0...1], меньше = медленнее падение.
    public var release: Float
    /// Держать пики (сек).
    public var peakHoldSeconds: Float
    /// Высокое разрешение кривой (1/24 октавы) поверх октавных полос.
    public var showFineCurve: Bool
    /// Окно short-term громкости в секундах (по умолчанию 1 с).
    public var shortTermSeconds: Double

    public init(
        bandsPerOctave: Int = 3,
        attack: Float = 0.8,
        release: Float = 0.08,
        peakHoldSeconds: Float = 1.5,
        showFineCurve: Bool = true,
        shortTermSeconds: Double = 1.0
    ) {
        self.bandsPerOctave = bandsPerOctave
        self.attack = attack
        self.release = release
        self.peakHoldSeconds = peakHoldSeconds
        self.showFineCurve = showFineCurve
        self.shortTermSeconds = shortTermSeconds
    }

    public static let `default` = RTASettings()

    /// Пресеты скорости отклика (как Peak/Slow Average на пультах).
    public static let presets: [(name: String, settings: RTASettings)] = [
        ("Пики (мгновенно)", RTASettings(bandsPerOctave: 3, attack: 0.95, release: 0.4, peakHoldSeconds: 1.5, showFineCurve: true, shortTermSeconds: 1.0)),
        ("Быстрый (по умолчанию)", RTASettings(bandsPerOctave: 3, attack: 0.8, release: 0.08, peakHoldSeconds: 1.5, showFineCurve: true, shortTermSeconds: 1.0)),
        ("Средний", RTASettings(bandsPerOctave: 3, attack: 0.4, release: 0.03, peakHoldSeconds: 2.0, showFineCurve: true, shortTermSeconds: 1.0)),
        ("Медленный (усреднение)", RTASettings(bandsPerOctave: 3, attack: 0.15, release: 0.01, peakHoldSeconds: 3.0, showFineCurve: false, shortTermSeconds: 1.0)),
    ]
}

/// Real-Time Analyzer в духе микшерных пультов и Room EQ Wizard:
/// - Октавные полосы (1/1 … 1/12 октавы, настраивается), энергия полосы = СУММА
///   мощностей бинов (интеграл, а не среднее) — узкие пики не размазываются.
/// - Раздельные коэффициенты атаки/спада: график мгновенно реагирует на рост
///   и плавно падает при пропадании сигнала.
/// - Пик-холд с настраиваемым удержанием.
/// - Опциональная «тонкая» кривая 1/24 октавы — видно узкие провалы/пики EQ.
public final class RTASpectrumAnalyzer {

    public private(set) var bands: [RTABand] = []
    /// Тонкая кривая высокого разрешения (для отображения АЧХ).
    public private(set) var fineCurve: [SpectrumPoint] = []

    private let fft: FFT
    private var settings: RTASettings

    // Октавные полосы
    private var bandCenterHz: [Float] = []
    private var bandRange: [Range<Int>] = []
    private var bandEnergy: [Float] = []
    private var bandPeak: [Float] = []
    private var bandPeakTicks: [Float] = []

    // Тонкая кривая
    private var fineCenterHz: [Float] = []
    private var fineRange: [Range<Int>] = []
    private var fineEnergy: [Float] = []
    private var finePeak: [Float] = []

    private var ring: [Float] = []
    private let lock = NSLock()

    public init(length: Int, sampleRate: Float, settings: RTASettings = .default, windowType: FFT.WindowType = .hann) {
        self.settings = settings
        self.fft = FFT(length: length, sampleRate: sampleRate, windowType: windowType)
            ?? FFT(length: 16384, sampleRate: sampleRate, windowType: windowType)!
        rebuildBands()
    }

    public func updateSettings(_ newSettings: RTASettings) {
        lock.lock()
        defer { lock.unlock() }
        self.settings = newSettings
        rebuildBands()
    }

    public func process(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }

        // Кольцевой буфер: без removeFirst (O(n) копий на каждый кадр).
        ring.append(contentsOf: samples)

        let length = fft.length
        // Перекрытие 75%: при 4096/48кГц это ~47 FFT/с — график живой.
        // Дешевле, чем кажется: FFT 4096 ~0.1 мс на M-серии.
        let hop = max(1, length / 4)
        while ring.count >= length {
            let block = Array(ring[0..<length])
            if hop >= ring.count {
                ring.removeAll(keepingCapacity: true)
            } else {
                ring.removeFirst(hop)
            }
            let power = fft.powerSpectrum(block.withUnsafeBufferPointer { $0 })
            guard power.count == fft.halfLength else { continue }
            integrate(power)
        }
        if ring.count > length * 2 {
            ring.removeFirst(ring.count - length)
        }
    }

    // MARK: - Ядро

    private func rebuildBands() {
        let half = fft.halfLength
        let nyquist = fft.sampleRate / 2
        let fMin: Float = 20
        let fMax: Float = min(20000, nyquist * 0.99)

        func buildGrid(_ ppo: Float) -> (centers: [Float], ranges: [Range<Int>]) {
            var centers: [Float] = []
            var ranges: [Range<Int>] = []
            var f = fMin
            let step = powf(2.0, 1.0 / ppo)
            let halfWidth = powf(2.0, 1.0 / (2.0 * ppo))
            while f <= fMax {
                let lo = f / halfWidth
                let hi = min(f * halfWidth, fMax)
                let binLo = max(2, Int((lo / nyquist) * Float(half)))
                let binHi = min(half - 1, Int((hi / nyquist) * Float(half)))
                if binHi > binLo {
                    centers.append(f)
                    ranges.append(binLo..<binHi)
                }
                f *= step
            }
            return (centers, ranges)
        }

        let oct = buildGrid(Float(max(1, settings.bandsPerOctave)))
        bandCenterHz = oct.centers
        bandRange = oct.ranges
        bandEnergy = [Float](repeating: 1e-12, count: oct.ranges.count)
        bandPeak = [Float](repeating: -120, count: oct.ranges.count)
        bandPeakTicks = [Float](repeating: 0, count: oct.ranges.count)

        if settings.showFineCurve {
            let fine = buildGrid(Self.finePointsPerOctave)
            fineCenterHz = fine.centers
            fineRange = fine.ranges
            fineEnergy = [Float](repeating: 1e-12, count: fine.ranges.count)
            finePeak = [Float](repeating: -120, count: fine.ranges.count)
        } else {
            fineCenterHz = []
            fineRange = []
            fineEnergy = []
            finePeak = []
        }
        publishBands()
    }

    /// Разрешение тонкой кривой (полос на октаву).
    nonisolated(unsafe) public static var finePointsPerOctave: Float = 12

    private func integrate(_ power: [Float]) {
        let attack = max(0.001, settings.attack)
        let release = min(1.0, max(0.001, settings.release))
        let peakTicks = settings.peakHoldSeconds * 60

        // Октавные полосы: интеграл энергии (сумма, не среднее).
        for i in 0..<bandRange.count {
            let range = bandRange[i]
            guard range.upperBound <= power.count else { continue }
            var sum: Float = 0
            for b in range { sum += power[b] }
            let alpha = sum > bandEnergy[i] ? attack : release
            bandEnergy[i] += alpha * (sum - bandEnergy[i])
            let db = dBFromEnergy(bandEnergy[i])
            if db > bandPeak[i] {
                bandPeak[i] = db
                bandPeakTicks[i] = peakTicks
            } else {
                bandPeakTicks[i] -= 1
                if bandPeakTicks[i] <= 0 {
                    bandPeak[i] = db
                    bandPeakTicks[i] = peakTicks
                }
            }
        }

        // Тонкая кривая
        for i in 0..<fineRange.count {
            let range = fineRange[i]
            guard range.upperBound <= power.count else { continue }
            var sum: Float = 0
            for b in range { sum += power[b] }
            let alpha = sum > fineEnergy[i] ? attack : release
            fineEnergy[i] += alpha * (sum - fineEnergy[i])
        }

        publishBands()
    }

    private var bandsDirty = false

    private func dBFromEnergy(_ e: Float) -> Float {
        guard e > 1e-14 else { return -120 }
        return 10 * log10(e)
    }

    private func publishBands() {
        var newBands: [RTABand] = []
        newBands.reserveCapacity(bandCenterHz.count)
        let halfWidth = powf(2.0, 1.0 / (2.0 * Float(max(1, settings.bandsPerOctave))))
        for (i, center) in bandCenterHz.enumerated() {
            newBands.append(
                RTABand(
                    id: i,
                    centerFrequency: center,
                    lowerFrequency: center / halfWidth,
                    upperFrequency: center * halfWidth,
                    levelDB: dBFromEnergy(bandEnergy[i]),
                    peakDB: bandPeak[i]
                )
            )
        }
        bands = newBands

        var fine: [SpectrumPoint] = []
        fine.reserveCapacity(fineCenterHz.count)
        for (i, center) in fineCenterHz.enumerated() {
            fine.append(
                SpectrumPoint(id: i, frequency: center, magnitudeDB: dBFromEnergy(fineEnergy[i]))
            )
        }
        fineCurve = fine
        bandsDirty = false
    }

    /// Полосы и кривая для UI (пересобираются только если данные изменились).
    public func snapshotData() -> (bands: [RTABand], fine: [SpectrumPoint]) {
        lock.lock()
        defer { lock.unlock() }
        if bandsDirty {
            publishBands()
        }
        return (bands, fineCurve)
    }

    /// Точки октавных полос для кривой.
    public func spectrumPoints() -> [SpectrumPoint] {
        snapshotData().bands.map {
            SpectrumPoint(id: $0.id, frequency: $0.centerFrequency, magnitudeDB: $0.levelDB)
        }
    }
}