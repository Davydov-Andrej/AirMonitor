import Foundation

/// Режим референса тонального баланса.
public enum BalanceReference: String, CaseIterable, Sendable {
    case music = "Музыка"
    case speech = "Речь"
    case flat = "Плоский"

    public var id: String { rawValue }
}

/// Тональный баланс в духе iZotope Tonal Balance Control:
/// - Энергия по инструментальным полосам, нормированная на общий уровень
///   микса — бас больше не «всегда +30 дБ».
/// - Отклонение = форма текущего спектра минус форма референса.
/// - Подсказки: что перегружено / что утонуло и что с этим делать.
public final class InstrumentBalanceAnalyzer {

    public struct Output: Sendable {
        public let bands: [InstrumentBalance]
        public let hasSignal: Bool
        public let tips: [String]
    }

    private let output: Output

    public init(spectrum: [SpectrumPoint], sampleRate: Float, reference: BalanceReference = .music) {
        self.output = Self.compute(spectrum: spectrum, sampleRate: sampleRate, reference: reference)
    }

    public init(spectrumDB: [Float], sampleRate: Float, fftLength: Int, reference: BalanceReference = .music) {
        let half = spectrumDB.count / 2
        var points: [SpectrumPoint] = []
        for (bin, db) in spectrumDB.enumerated() where bin < half {
            let freq = Float(bin) * sampleRate / Float(fftLength)
            guard freq > 20, freq < sampleRate / 2 else { continue }
            points.append(SpectrumPoint(id: bin, frequency: freq, magnitudeDB: db))
        }
        self.output = Self.compute(spectrum: points, sampleRate: sampleRate, reference: reference)
    }

    public func balances() -> [InstrumentBalance] {
        output.bands
    }

    public var tips: [String] { output.tips }
    public var hasSignal: Bool { output.hasSignal }

    // MARK: - Private

    private static func compute(spectrum: [SpectrumPoint], sampleRate: Float, reference: BalanceReference) -> Output {
        guard !spectrum.isEmpty else {
            return Output(bands: emptyBands(), hasSignal: false, tips: [])
        }

        // 1. Энергия по полосам (дБ, среднее по точкам полосы).
        var sums: [InstrumentBand: Float] = [:]
        var counts: [InstrumentBand: Int] = [:]
        var totalLinear: Float = 0

        for point in spectrum {
            let linear = powf(10, point.magnitudeDB / 20)
            totalLinear += linear * linear
            for band in InstrumentBand.allCases where band.range.contains(point.frequency) {
                sums[band, default: 0] += point.magnitudeDB
                counts[band, default: 0] += 1
            }
        }

        guard totalLinear > 1e-10 else {
            return Output(bands: emptyBands(), hasSignal: false, tips: [])
        }

        let overallDB = 10 * log10(totalLinear)

        // 2. Нормализация формы: центрируем полосы вокруг среднего.
        var normalized: [InstrumentBand: Float] = [:]
        for band in InstrumentBand.allCases {
            guard let count = counts[band], count > 0 else { continue }
            let raw = sums[band]! / Float(count)
            normalized[band] = raw - overallDB * 0.25
        }

        // 3. Референсная форма.
        let curve: [InstrumentBand: Float]
        switch reference {
        case .music: curve = ReferenceCurve.defaultMusic.bands
        case .speech: curve = ReferenceCurve.defaultSpeech.bands
        case .flat: curve = flatCurve()
        }
        let refValues = Array(curve.values)
        let refMean = refValues.reduce(0, +) / Float(max(refValues.count, 1))

        // 4. Отклонения и подсказки.
        var bandsOut: [InstrumentBalance] = []
        var tips: [String] = []

        for band in InstrumentBand.allCases {
            guard let level = normalized[band], let ref = curve[band] else { continue }
            let refCentered = ref - refMean
            let deviation = level - refCentered
            let significance = min(1, max(0, abs(deviation) / 12))

            bandsOut.append(
                InstrumentBalance(
                    band: band,
                    energyDB: level,
                    deviationDB: deviation,
                    significance: significance
                )
            )
            addTips(for: band, deviation: deviation, to: &tips)
        }

        guard !bandsOut.isEmpty else {
            return Output(bands: emptyBands(), hasSignal: false, tips: [])
        }
        return Output(bands: bandsOut, hasSignal: true, tips: tips)
    }

    private static func addTips(for band: InstrumentBand, deviation: Float, to tips: inout [String]) {
        switch band {
        case .subBass, .kickDrum, .bass:
            if deviation > 6 {
                tips.append("Низ перегружен (+\(String(format: "%.0f", deviation)) дБ): бочка/бас перекрывают вокал. Срез 60–120 Гц на 2–4 дБ или high-pass на невокальных дорожках.")
            } else if deviation < -8 {
                tips.append("Низ утонул: микс «лёгкий». Поднимите 60–120 Гц, если жанр это предполагает.")
            }
        case .lowMids:
            if deviation > 6 {
                tips.append("Гул в низких серединах: микс «замылен». Срез 200–400 Гц на 2–3 дБ.")
            } else if deviation < -6 {
                tips.append("Провал в низких серединах: микс «пустой». Проверьте срезы 200–300 Гц.")
            }
        case .mids:
            if deviation < -8 {
                tips.append("Середина утонула — вокал/гитары не читаются. Поднимите 300–1000 Гц или уберите маскирующий бас.")
            }
        case .voice:
            if deviation < -6 {
                tips.append("Вокальный диапазон (0.8–3.5 кГц) тихий — речь теряется. Поднимите 1–3 дБ или уберите конкуренцию в 1–2 кГц.")
            } else if deviation > 6 {
                tips.append("Вокальный диапазон перегружен — резковато. Деликатный де-эссер при колющих сибилянтах.")
            }
        case .sibilance:
            if deviation > 8 {
                tips.append("Сибилянты/резкость (4–8 кГц) выражены — де-эссер или срез 5–7 кГц.")
            }
        case .highs, .air:
            if deviation < -8 {
                tips.append("Верх утонул — микс глухой. Shelf +1–2 дБ на 10 кГц.")
            } else if deviation > 8 {
                tips.append("Верх перегружен — шипение/резкость. Срез 8–12 кГц на 1–2 дБ.")
            }
        }
    }

    private static func flatCurve() -> [InstrumentBand: Float] {
        var curve: [InstrumentBand: Float] = [:]
        for band in InstrumentBand.allCases {
            curve[band] = -20
        }
        return curve
    }

    private static func emptyBands() -> [InstrumentBalance] {
        InstrumentBand.allCases.map {
            InstrumentBalance(band: $0, energyDB: -120, deviationDB: 0, significance: 0)
        }
    }
}