import SwiftUI

/// Информация о приложении; пользовательские параметры находятся рядом с инструментами.
struct SettingsView: View {
    var body: some View {
        Form {
            Section("AirMonitor") {
                LabeledContent("Версия") { Text(appVersion) }
                LabeledContent("Лог движка") {
                    Text("~/Library/Logs/AirMonitor/engine.log")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Dev"
    }

}
