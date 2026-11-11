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
    /// Автодеградирование разрешения при высокой нагрузке (отключается вручную).
    public var autoDowngrade: Bool
    /// Окно short-term громкости в секундах (по умолчанию 3 с по EBU).
    public var shortTermSeconds: Double
    /// Сглаживание кривой по соседним полосам (0 = нет, N = ±N полос).
    /// 0 — мелкие пики узких полос; 3-5 — ровная «общая картина».
    public var neighborSmoothing: Float
    /// Сглаживание ГРАФИКА громкости (история): EMA-вес нового значения при спаде.
    /// 1.0 = без сглаживания; 0.1 = сильное. Числа не трогает.
    public var loudnessSmoothing: Float
    /// Сглаживание ЧИСЕЛ M/S в UI (Youlean-стиль): рост мгновенный, спад плавный.
    /// 1.0 = выкл (сырые значения); 0.3 = плавные числа.
    public var numberSmoothing: Float

    public init(
        bandsPerOctave: Int = 3,
        attack: Float = 0.8,
        release: Float = 0.08,
        peakHoldSeconds: Float = 1.5,
        showFineCurve: Bool = true,
        autoDowngrade: Bool = true,
        shortTermSeconds: Double = 3.0,
        neighborSmoothing: Float = 0,
        loudnessSmoothing: Float = 0.02,
        numberSmoothing: Float = 0.05
    ) {
        self.bandsPerOctave = bandsPerOctave
        self.attack = attack
        self.release = release
        self.peakHoldSeconds = peakHoldSeconds
        self.showFineCurve = showFineCurve
        self.autoDowngrade = autoDowngrade
        self.shortTermSeconds = shortTermSeconds.isFinite
            ? max(0.1, min(60, shortTermSeconds))
            : 3.0
        self.neighborSmoothing = neighborSmoothing
        self.loudnessSmoothing = loudnessSmoothing
        self.numberSmoothing = numberSmoothing
    }

    public static let `default` = RTASettings()

    /// Пресеты скорости отклика (как Peak/Slow Average на пультах).
    public static let presets: [(name: String, settings: RTASettings)] = [
        ("Пики (мгновенно)", RTASettings(bandsPerOctave: 3, attack: 0.95, release: 0.4, peakHoldSeconds: 1.5, showFineCurve: true)),
        ("Быстрый (по умолчанию)", RTASettings(bandsPerOctave: 3, attack: 0.8, release: 0.08, peakHoldSeconds: 1.5, showFineCurve: true)),
        ("Средний", RTASettings(bandsPerOctave: 3, attack: 0.4, release: 0.03, peakHoldSeconds: 2.0, showFineCurve: true)),
        ("Медленный (усреднение)", RTASettings(bandsPerOctave: 3, attack: 0.15, release: 0.01, peakHoldSeconds: 3.0, showFineCurve: false)),
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

    private var ring: [Float]
    private var ringHead = 0
    private var ringCount = 0
    private var fftBlock: [Float]
    private let lock = NSLock()

    public init(length: Int, sampleRate: Float, settings: RTASettings = .default, windowType: FFT.WindowType = .hann) {
        self.settings = settings
        let safeRate = sampleRate.isFinite && sampleRate > 0 ? sampleRate : 48000
        let fft = FFT(length: length, sampleRate: safeRate, windowType: windowType)
            ?? FFT(length: 16384, sampleRate: safeRate, windowType: windowType)!
        self.fft = fft
        self.ring = [Float](repeating: 0, count: fft.length)
        self.fftBlock = [Float](repeating: 0, count: fft.length)
        rebuildBands()
    }

    public func updateSettings(_ newSettings: RTASettings) {
        lock.lock()
        defer { lock.unlock() }
        self.settings = newSettings
        if !newSettings.autoDowngrade {
            downgradeLevel = 0
            loadEma = 0
            highLoadSeconds = 0
            lowLoadSeconds = 0
        }
        rebuildBands()
    }

    public func process(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }

        let length = fft.length
        let hop = max(1, length / 4)
        let t0 = CFAbsoluteTimeGetCurrent()
        for sample in samples {
            ring[(ringHead + ringCount) % length] = sample
            ringCount += 1
            if ringCount == length {
                for i in 0..<length {
                    fftBlock[i] = ring[(ringHead + i) % length]
                }
                let power = fft.powerSpectrum(fftBlock.withUnsafeBufferPointer { $0 })
                if power.count == fft.halfLength {
                    integrate(power)
                }
                ringHead = (ringHead + hop) % length
                ringCount -= hop
            }
        }
        let spent = CFAbsoluteTimeGetCurrent() - t0

        // Автодеградирование: если кадр занимает > 60% интервала FFT — нагрузка
        // высока, снижаем разрешение тонкой кривой (ступени: 24 → 12 → 6 → off).
        if settings.autoDowngrade {
            let audioDuration = Double(samples.count) / Double(max(fft.sampleRate, 1))
            updateLoadBudget(spent: Float(spent), audioDuration: Float(audioDuration))
        }
    }

    /// Текущий уровень автодеградирования (0 = полный, 3 = тонкая кривая выкл).
    public private(set) var downgradeLevel: Int = 0
    private var loadEma: Float = 0
    private var highLoadSeconds: Float = 0
    private var lowLoadSeconds: Float = 0

    private func updateLoadBudget(spent: Float, audioDuration: Float) {
        // Сопоставляем стоимость обработки с длительностью входного аудио.
        // EMA задана в секундах, поэтому результат не зависит от размера
        // callback-а и частоты, с которой OS отдаёт аудиокадры.
        let dt = max(audioDuration, 0.0001)
        let ratio = min(4.0, max(0, spent / dt))
        let alpha = 1 - expf(-dt / 0.5)
        loadEma += alpha * (ratio - loadEma)

        let target: Int
        if loadEma > 1.8 { target = 3 }       // кривая выкл
        else if loadEma > 1.2 { target = 2 }  // 1/6 октавы
        else if loadEma > 0.8 { target = 1 }  // 1/12 октавы
        else { target = 0 }                   // максимум (1/24)
        if target != downgradeLevel {
            if target > downgradeLevel {
                highLoadSeconds += dt
                lowLoadSeconds = 0
                if highLoadSeconds >= 2 {
                    downgradeLevel = target
                    needsRebuild = true
                    highLoadSeconds = 0
                }
            } else {
                lowLoadSeconds += dt
                highLoadSeconds = 0
                if lowLoadSeconds >= 5 {
                    downgradeLevel = target
                    needsRebuild = true
                    lowLoadSeconds = 0
                }
            }
        } else {
            highLoadSeconds = 0
            lowLoadSeconds = 0
        }
    }
    private var needsRebuild = false

    // MARK: - Ядро

    private func rebuildBands() {
        let oldBandCenters = bandCenterHz
        let oldBandLevels = bandEnergy.map { dBFromEnergy($0) }
        let oldBandPeaks = bandPeak
        let oldPeakSeconds = bandPeakTicks
        let oldFineCenters = fineCenterHz.isEmpty ? oldBandCenters : fineCenterHz
        let oldFineLevels = fineCenterHz.isEmpty ? oldBandLevels : fineEnergy.map { dBFromEnergy($0) }
        let oldFinePeaks = fineCenterHz.isEmpty ? oldBandPeaks : finePeak
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

        let bandsPerOctave = min(48, max(1, settings.bandsPerOctave))
        let oct = buildGrid(Float(bandsPerOctave))
        bandCenterHz = oct.centers
        bandRange = oct.ranges
        bandEnergy = oct.centers.map { center in
            powf(10, interpolateDB(center, centers: oldBandCenters, values: oldBandLevels, fallback: -120) / 10)
        }
        bandPeak = oct.centers.map {
            interpolateDB($0, centers: oldBandCenters, values: oldBandPeaks, fallback: -120)
        }
        bandPeakTicks = oct.centers.map {
            max(0, interpolateDB($0, centers: oldBandCenters, values: oldPeakSeconds, fallback: 0))
        }

        if settings.showFineCurve && downgradeLevel < 3 {
            // Тонкая кривая масштабируется с настройкой полос и автодеградированием:
            // уровень 0 = максимум (cap 24), 1 = 12, 2 = 6, 3 = выкл.
            let capByLevel: [Float] = [24, 12, 6, 0]
            let cap = capByLevel[downgradeLevel]
            let finePPO = min(cap, max(6, Float(bandsPerOctave) * 4))
            let fine = buildGrid(finePPO)
            fineCenterHz = fine.centers
            fineRange = fine.ranges
            fineEnergy = fine.centers.map {
                powf(10, interpolateDB($0, centers: oldFineCenters, values: oldFineLevels, fallback: -120) / 10)
            }
            finePeak = fine.centers.map {
                interpolateDB($0, centers: oldFineCenters, values: oldFinePeaks, fallback: -120)
            }
        } else {
            fineCenterHz = []
            fineRange = []
            fineEnergy = []
            finePeak = []
        }
        publishBands()
    }

    private func interpolateDB(_ frequency: Float, centers: [Float], values: [Float], fallback: Float) -> Float {
        guard !centers.isEmpty, centers.count == values.count else { return fallback }
        guard frequency > centers[0] else { return values[0] }
        guard frequency < centers[centers.count - 1] else { return values[values.count - 1] }
        var upper = 1
        while upper < centers.count && centers[upper] < frequency { upper += 1 }
        let lower = upper - 1
        let x0 = log2f(centers[lower])
        let x1 = log2f(centers[upper])
        let x = log2f(frequency)
        let t = (x - x0) / max(x1 - x0, 1e-9)
        return values[lower] + t * (values[upper] - values[lower])
    }

    private func integrate(_ power: [Float]) {
        let attack = settings.attack.isFinite ? min(1, max(0.001, settings.attack)) : 0.8
        let release = settings.release.isFinite ? min(1, max(0.001, settings.release)) : 0.08
        let peakHoldSeconds = settings.peakHoldSeconds.isFinite
            ? min(60, max(0, settings.peakHoldSeconds))
            : 1.5

        // EMA с честной постоянной времени: alpha зависит от фактического
        // интервала между FFT (иначе при 47 FFT/с и alpha 0.95 атака сходится
        // за 2 кадра и не отличается от 0.25 при постоянном сигнале).
        // attack/release трактуются как доля за 60 Гц-кадр:
        // tau = -frame / ln(1 - alpha), alphaPerFFT = 1 - exp(-fftInterval / tau).
        let fftInterval = fft.sampleRate > 0 ? Float(fft.length / 4) / fft.sampleRate : 1.0 / 60.0
        func alphaPerFFT(_ base: Float) -> Float {
            let clamped = min(0.999, max(0.001, base))
            let tau60 = -1.0 / 60.0 / log(1.0 - clamped)
            return Float(1.0 - exp(-Double(fftInterval) / Double(tau60)))
        }
        let attackAlpha = alphaPerFFT(attack)
        let releaseAlpha = alphaPerFFT(release)

        // Октавные полосы: интеграл энергии (сумма, не среднее).
        for i in 0..<bandRange.count {
            let range = bandRange[i]
            guard range.upperBound <= power.count else { continue }
            var sum: Float = 0
            for b in range { sum += power[b] }
            let alpha = sum > bandEnergy[i] ? attackAlpha : releaseAlpha
            bandEnergy[i] += alpha * (sum - bandEnergy[i])
            let db = dBFromEnergy(bandEnergy[i])
            if db > bandPeak[i] {
                bandPeak[i] = db
                bandPeakTicks[i] = peakHoldSeconds
            } else {
                bandPeakTicks[i] = max(0, bandPeakTicks[i] - fftInterval)
                if bandPeakTicks[i] == 0 {
                    bandPeak[i] = db
                }
            }
        }

        // Тонкая кривая
        for i in 0..<fineRange.count {
            let range = fineRange[i]
            guard range.upperBound <= power.count else { continue }
            var sum: Float = 0
            for b in range { sum += power[b] }
            let alpha = sum > fineEnergy[i] ? attackAlpha : releaseAlpha
            fineEnergy[i] += alpha * (sum - fineEnergy[i])
        }

        bandsDirty = true
    }

    private var bandsDirty = false

    private func dBFromEnergy(_ e: Float) -> Float {
        guard e > 1e-14 else { return -120 }
        return 10 * log10(e)
    }

    /// Скользящее усреднение по соседним полосам.
    /// radius: 0 = без сглаживания; целое N = окно ±N; промежуточные (0.5, 1.5)
    /// дают взвешенное окно — мягкая градация между целыми шагами.
    private func smoothed(_ values: [Float], radius: Float) -> [Float] {
        guard radius > 0.01, values.count > 1 else { return values }
        let full = Int(radius)
        let frac = radius - Float(full)
        var out = [Float](repeating: 0, count: values.count)
        for i in values.indices {
            var sum: Float = values[i]
            var weight: Float = 1
            // полные кольца соседей (вес 1): d = 1...full
            if full >= 1 {
                for d in 1...full {
                    if i - d >= 0 { sum += values[i - d]; weight += 1 }
                    if i + d < values.count { sum += values[i + d]; weight += 1 }
                }
            }
            // частичное кольцо (вес frac): d = full+1 при дробном радиусе;
            // при radius < 1 (full=0) — это единственное кольцо, d = 1.
            if frac > 0.01 {
                let d = full + 1
                if i - d >= 0 { sum += values[i - d] * frac; weight += frac }
                if i + d < values.count { sum += values[i + d] * frac; weight += frac }
            }
            out[i] = sum / weight
        }
        return out
    }

    private func publishBands() {
        // Сглаживание уровней по соседям (настройка «Сглаживание»).
        let radius = settings.neighborSmoothing.isFinite
            ? Float(max(0, min(settings.neighborSmoothing, 12)))
            : 0
        let smoothLevels = smoothed(bandEnergy.map { dBFromEnergy($0) }, radius: radius)
        let smoothPeaks = smoothed(bandPeak, radius: radius)

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
                    levelDB: smoothLevels[i],
                    peakDB: smoothPeaks[i]
                )
            )
        }
        bands = newBands

        var fine: [SpectrumPoint] = []
        fine.reserveCapacity(fineCenterHz.count)
        if settings.showFineCurve {
            let fineSmoothed = smoothed(fineEnergy.map { dBFromEnergy($0) }, radius: radius * 3)
            for (i, center) in fineCenterHz.enumerated() {
                fine.append(
                    SpectrumPoint(id: i, frequency: center, magnitudeDB: fineSmoothed[i])
                )
            }
        }
        fineCurve = fine
        bandsDirty = false
    }

    /// Полосы и кривая для UI (пересобираются только если данные изменились).
    public func snapshotData() -> (bands: [RTABand], fine: [SpectrumPoint]) {
        lock.lock()
        defer { lock.unlock() }
        if needsRebuild {
            rebuildBands()
            needsRebuild = false
        }
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
