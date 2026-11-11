import SwiftUI
import yaCore

enum DashboardColumnLayout: Int, CaseIterable, Identifiable {
    case one = 1
    case two = 2

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .one: "Одна колонка"
        case .two: "Две колонки"
        }
    }
}

enum DashboardCardSize: String, CaseIterable, Identifiable {
    case compact
    case standard
    case large

    var id: String { rawValue }

    var title: String {
        switch self {
        case .compact: "Компактный"
        case .standard: "Стандартный"
        case .large: "Крупный"
        }
    }

    var meterHeight: CGFloat {
        switch self {
        case .compact: 118
        case .standard: 150
        case .large: 190
        }
    }

    var loudnessHeight: CGFloat {
        switch self {
        case .compact: 130
        case .standard: 150
        case .large: 190
        }
    }

    var spectrumHeight: CGFloat {
        switch self {
        case .compact: 100
        case .standard: 130
        case .large: 170
        }
    }

    var lowerSectionHeight: CGFloat { spectrumHeight + 25 }

    var cardPadding: CGFloat {
        switch self {
        case .compact: 9
        case .standard: 12
        case .large: 16
        }
    }

    var sectionSpacing: CGFloat {
        switch self {
        case .compact: 7
        case .standard: 10
        case .large: 13
        }
    }

    var moduleSizeScale: CGFloat {
        switch self {
        case .compact: 0.95
        case .standard: 1
        case .large: 1.05
        }
    }
}

extension DashboardModule {
    var isGraph: Bool {
        switch self {
        case .levels: false
        case .loudness, .spectrum, .mixBalance: true
        }
    }

    var title: String {
        switch self {
        case .levels: "Уровни и метрики"
        case .loudness: "LUFS по времени"
        case .spectrum: "Спектр АЧХ"
        case .mixBalance: "Баланс микса"
        }
    }

    var symbol: String {
        switch self {
        case .levels: "meter"
        case .loudness: "waveform.path"
        case .spectrum: "chart.bar.xaxis"
        case .mixBalance: "slider.horizontal.3"
        }
    }

    var defaultWidth: Double {
        switch self {
        case .levels: 330
        case .loudness: 330
        case .spectrum: 330
        case .mixBalance: 370
        }
    }

    var defaultHeight: Double { 240 }
    var minimumWidth: Double {
        switch self {
        case .levels: 300
        case .loudness: 320
        case .spectrum: 300
        case .mixBalance: 360
        }
    }
    var minimumHeight: Double { 200 }
}
