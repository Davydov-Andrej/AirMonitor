import SwiftUI
import yaCore

/// Настройки: спектроанализатор, обновление, порядок шин.
struct SettingsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Section("Спектроанализатор (RTA)") {
                Picker("Полос на октаву", selection: rtaBandsBinding) {
                    Text("1/1 октавы (9)").tag(1)
                    Text("1/3 октавы (31) — как на пультах").tag(3)
                    Text("1/6 октавы (61)").tag(6)
                    Text("1/12 октавы (121)").tag(12)
                }

                VStack(alignment: .leading) {
                    LabeledContent("Атака (скорость подъёма)") {
                        Text(String(format: "%.0f%%", model.rtaSettings.attack * 100))
                            .monospacedDigit()
                    }
                    Slider(value: Binding(
                        get: { Double(model.rtaSettings.attack) },
                        set: { model.rtaSettings.attack = Float($0) }
                    ), in: 0.1...1)
                }

                VStack(alignment: .leading) {
                    LabeledContent("Спад (скорость падения)") {
                        Text(String(format: "%.0f%%", model.rtaSettings.release * 100))
                            .monospacedDigit()
                    }
                    Slider(value: Binding(
                        get: { Double(model.rtaSettings.release) },
                        set: { model.rtaSettings.release = Float($0) }
                    ), in: 0.005...0.3)
                }

                VStack(alignment: .leading) {
                    LabeledContent("Удержание пиков, с") {
                        Text(String(format: "%.1f", model.rtaSettings.peakHoldSeconds))
                            .monospacedDigit()
                    }
                    Slider(value: Binding(
                        get: { Double(model.rtaSettings.peakHoldSeconds) },
                        set: { model.rtaSettings.peakHoldSeconds = Float($0) }
                    ), in: 0.5...5)
                }

                Toggle("Тонкая кривая (1/24 октавы)", isOn: $model.rtaSettings.showFineCurve)

                Text("Больше полос — детальнее картинка, но медленнее. Быстрая атака + медленный спад — так работают анализаторы на пультах: график мгновенно реагирует на рост и плавно опадает.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Обновление данных") {
                VStack(alignment: .leading) {
                    LabeledContent("Частота обновления UI") {
                        Text(String(format: "%.0f Гц", model.updateRateHz))
                            .monospacedDigit()
                    }
                    Slider(value: $model.updateRateHz, in: 5...60, step: 5)
                }
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
                }
                Text("Порядок можно менять перетаскиванием.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("О приложении") {
                LabeledContent("Версия") { Text("0.3") }
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

    private var rtaBandsBinding: Binding<Int> {
        Binding(
            get: { model.rtaSettings.bandsPerOctave },
            set: { model.rtaSettings.bandsPerOctave = $0 }
        )
    }
}