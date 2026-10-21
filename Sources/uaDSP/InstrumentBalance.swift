import Foundation

/// Инструмент, определяемый по спектральной энергии в характерных полосах.
/// Используется для "баланса микса": понимаем, каких элементов слишком много
/// (маскирование/громкость) и каких не хватает.
public enum InstrumentBand: CaseIterable, Identifiable, Sendable {
    case subBass       // 20–60 Гц — бочка / саб
    case kickDrum      // 30–120 Гц — удар бочки
    case bass          // 40–200 Гц — бас, низ контрабаса
    case lowMids       // 120–300 Гц — каркас микса, гул
    case mids          // 300–1000 Гц — «мясо», вокал низ, гитары
    case voice         // 800–3500 Гц — вокал, речь, петлички
    case sibilance     // 4–8 кГц — сибилянты, резкость
    case highs         // 8–16 кГц — тарелки, воздух
    case air           // 12–20 кГц — воздух, хай-хэты

    public var id: String { rawName }

    public var rawName: String {
        switch self {
        case .subBass: return "sub"
        case .kickDrum: return "kick"
        case .bass: return "bass"
        case .lowMids: return "low-mids"
        case .mids: return "mids"
        case .voice: return "voice"
        case .sibilance: return "sibilance"
        case .highs: return "highs"
        case .air: return "air"
        }
    }

    public var localizedName: String {
        switch self {
        case .subBass: return "Саб (20–60 Гц)"
        case .kickDrum: return "Бочка (30–120 Гц)"
        case .bass: return "Бас (40–200 Гц)"
        case .lowMids: return "Низкие середины (120–300 Гц)"
        case .mids: return "Середина (300–1 кГц)"
        case .voice: return "Вокал (0.8–3.5 кГц)"
        case .sibilance: return "Сибилянты (4–8 кГц)"
        case .highs: return "Верх (8–16 кГц)"
        case .air: return "Воздух (12–20 кГц)"
        }
    }

    public var centerFrequency: Float {
        switch self {
        case .subBass: return 40
        case .kickDrum: return 70
        case .bass: return 100
        case .lowMids: return 200
        case .mids: return 500
        case .voice: return 1800
        case .sibilance: return 6000
        case .highs: return 12000
        case .air: return 16000
        }
    }

    public var range: ClosedRange<Float> {
        switch self {
        case .subBass: return 20...60
        case .kickDrum: return 30...120
        case .bass: return 40...200
        case .lowMids: return 120...300
        case .mids: return 300...1000
        case .voice: return 800...3500
        case .sibilance: return 4000...8000
        case .highs: return 8000...16000
        case .air: return 12000...20000
        }
    }
}

/// Результат спектрального сравнения текущего микса с референсом.
public struct InstrumentBalance {
    public let band: InstrumentBand
    /// Энергия в дБFS средняя по полосе за окно.
    public let energyDB: Float
    /// Отклонение от референсной кривой, дБ. >0 — переизбыток, <0 — недостаток.
    public let deviationDB: Float
    /// Насколько отклонение значимо (0...1) после порога.
    public let significance: Float
}

/// "Ожидаемая" энегия по полосе для «плоского здорового» микса.
/// Это калибровочные значения на 0 дБ RMS. Реальные мониторы использовать
/// как ориентир для жанра.
public struct ReferenceCurve: Sendable {
    public let name: String
    public let bands: [InstrumentBand: Float]

    public static let defaultSpeech = ReferenceCurve(
        name: "Речь / подкаст",
        bands: [
            .subBass: -46,
            .kickDrum: -40,
            .bass: -32,
            .lowMids: -24,
            .mids: -14,
            .voice: -8,
            .sibilance: -16,
            .highs: -26,
            .air: -32,
        ]
    )

    public static let defaultMusic = ReferenceCurve(
        name: "Музыка (концерт)",
        bands: [
            .subBass: -28,
            .kickDrum: -18,
            .bass: -16,
            .lowMids: -14,
            .mids: -10,
            .voice: -8,
            .sibilance: -14,
            .highs: -18,
            .air: -22,
        ]
    )

    public func deviation(of energy: Float, for band: InstrumentBand) -> Float {
        let target = bands[band] ?? -20
        return energy - target
    }
}
