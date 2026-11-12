import SwiftUI

/// Информация о приложении; пользовательские параметры находятся рядом с инструментами.
struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var updates: AppUpdateManager
    var body: some View {
        Form {
            Section("Оформление") {
                Picker("Язык приложения", selection: $model.appLanguage) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.title).tag(language)
                    }
                }
                Picker("Оформление приложения", selection: $model.appTheme) {
                    ForEach(AppTheme.allCases) { theme in
                        Text(theme.title).tag(theme)
                    }
                }
            }
            Section("AirMonitor") {
                LabeledContent("Версия") { Text(AirMonitorInfo.version) }
                Text("Мониторинг входного звука, уровней, громкости LUFS и спектра в реальном времени.")
                LabeledContent("Платформа") { Text("macOS 14 и новее · Apple Silicon и Intel") }
                Link("Репозиторий AirMonitor на GitHub", destination: AirMonitorInfo.repositoryURL)
                Text("Баланс микса находится в разработке.")
                    .foregroundStyle(.secondary)
            }
            Section("Обновления") {
                Toggle("Автоматически проверять обновления", isOn: Binding(
                    get: { updates.automaticallyChecks }, set: { updates.setAutomaticChecks($0) }))
                Toggle("Автоматически загружать обновления", isOn: Binding(
                    get: { updates.automaticallyDownloads }, set: { updates.setAutomaticDownloads($0) }))
                    .disabled(!updates.automaticallyChecks)
                HStack {
                    Button("Проверить обновления") { Task { await updates.checkForUpdates() } }
                        .disabled(!updates.canCheck || updates.isChecking)
                    if updates.isChecking { ProgressView().controlSize(.small) }
                    Link("Открыть релизы", destination: AirMonitorInfo.releasesURL)
                }
                Text(updates.status)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                if let date = updates.lastChecked {
                    LabeledContent("Последняя проверка") { Text(date, format: .dateTime.day().month().hour().minute()) }
                }
                Text("При установке обновления мониторинг остановится, а приложение перезапустится. Статистика текущего измерения начнётся заново. Сцены и настройки сохраняются между версиями.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Диагностика") {
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

}
