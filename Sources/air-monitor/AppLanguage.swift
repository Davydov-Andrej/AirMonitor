import Foundation

enum AppLanguage: String, CaseIterable, Identifiable {
    case russian = "ru"
    case english = "en"

    var id: String { rawValue }
    var title: String { self == .russian ? "Русский" : "English" }
    var locale: Locale { Locale(identifier: rawValue) }

    static var current: AppLanguage {
        AppLanguage(rawValue: UserDefaults.standard.string(forKey: "AirMonitor.appLanguage") ?? "ru") ?? .russian
    }
}

/// Look up strings that SwiftUI cannot localize automatically: computed labels,
/// CoreGraphics text, tooltips, model errors and updater status.
func L(_ russian: String) -> String {
    guard AppLanguage.current == .english,
          let path = Bundle.main.path(forResource: "en", ofType: "lproj") else { return russian }
    let bundle = Bundle(path: path) ?? .main
    return bundle.localizedString(forKey: russian, value: russian, table: nil)
}

func LF(_ russianFormat: String, _ arguments: CVarArg...) -> String {
    String(format: L(russianFormat), locale: AppLanguage.current.locale, arguments: arguments)
}
