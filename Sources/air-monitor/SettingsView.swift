import SwiftUI
import yaCore

/// Настройки: обновление UI, подсказки, порядок шин.
struct SettingsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Section("Отображение") {
                Toggle("Русские пояснения к метрикам (Peak (пик), RMS (среднее)…)", isOn: $model.showMetricHints)
            }

            Section("Порядок шин") {
                if model.buses.isEmpty {
                    Text("Нет шин").foregroundStyle(.secondary)
                } else {
                    ForEach(model.buses) { bus in
                        Text(bus.config.name)
                    }
                    .onMove { from, to in
                        model.moveBus(from: from, to: to)
                    }
                    Text("Также можно менять порядок кнопками ▲▼ в заголовке блока шины на дашборде.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("О приложении") {
                LabeledContent("Версия") { Text("0.4") }
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