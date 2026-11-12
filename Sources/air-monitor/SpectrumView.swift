import SwiftUI
import yaCore

/// Спектр: общая панель настроек RTA + график на шину (порядок = дашборд).
struct SpectrumView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Спектр (АЧХ)")
                    .font(.title2)
                Spacer()
                rtaSettingsMenu
            }
            if model.buses.isEmpty {
                ContentUnavailableView(
                    "Нет шин",
                    systemImage: "waveform",
                    description: Text("Добавьте шину на дашборде и запустите захват")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 16) {
                        ForEach(model.buses) { bus in
                            SpectrumBusCardContainer(bus: bus, holder: model.holder(for: bus))
                        }
                    }
                }
            }
        }
        .padding()
    }

    /// Выпадающие настройки анализатора — применяются мгновенно.
    private var rtaSettingsMenu: some View {
        HStack(spacing: 8) {
            Menu {
                Picker("Полос на октаву", selection: Binding(
                    get: { model.rtaSettings.bandsPerOctave },
                    set: { model.rtaSettings.bandsPerOctave = $0 }
                )) {
                    Text("1/1 октавы (9 полос)").tag(1)
                    Text("1/3 октавы (31) — как на пультах").tag(3)
                    Text("1/6 октавы (61)").tag(6)
                    Text("1/12 октавы (121)").tag(12)
                }
                .pickerStyle(.inline)

                Divider()

                Toggle("Пик-холд", isOn: Binding(
                    get: { model.rtaSettings.peakHoldSeconds > 0 },
                    set: { model.rtaSettings.peakHoldSeconds = $0 ? 1.5 : 0 }
                ))

                Toggle("Тонкая кривая (детальные пики EQ)", isOn: $model.rtaSettings.showFineCurve)

                Toggle("Авто-снижение разрешения при нагрузке", isOn: Binding(
                    get: { model.rtaSettings.autoDowngrade },
                    set: { model.rtaSettings.autoDowngrade = $0 }
                ))
                .help(L("При высокой загрузке CPU автоматически уменьшает детальность тонкой кривой (1/24 → 1/12 → 1/6 октавы → выкл), чтобы спектр не пропадал. Выключите, если хотите всегда максимальную детальность."))
            } label: {
                Label(LF("Полосы: 1/%d окт", model.rtaSettings.bandsPerOctave), systemImage: "slider.horizontal.3")
            }

            // Динамика кривой: атака, спад, сглаживание.
            Menu {
                Picker("Атака", selection: Binding(
                    get: { model.rtaSettings.attack },
                    set: { model.rtaSettings.attack = $0 }
                )) {
                    Text("Мгновенная (0.95)").tag(Float(0.95))
                    Text("Очень быстрая (0.85)").tag(Float(0.85))
                    Text("Быстрая (0.70)").tag(Float(0.70))
                    Text("Средняя (0.55)").tag(Float(0.55))
                    Text("Плавная (0.40)").tag(Float(0.40))
                    Text("Медленная (0.25)").tag(Float(0.25))
                    Text("Усреднение (0.12)").tag(Float(0.12))
                }
                .pickerStyle(.inline)

                Divider()

                Picker("Спад", selection: Binding(
                    get: { model.rtaSettings.release },
                    set: { model.rtaSettings.release = $0 }
                )) {
                    Text("Мгновенный (0.60)").tag(Float(0.60))
                    Text("Очень быстрый (0.40)").tag(Float(0.40))
                    Text("Быстрый (0.25)").tag(Float(0.25))
                    Text("Средне-быстрый (0.14)").tag(Float(0.14))
                    Text("Средний (0.08)").tag(Float(0.08))
                    Text("Медленный (0.04)").tag(Float(0.04))
                    Text("Очень медленный (0.02)").tag(Float(0.02))
                    Text("Усреднение (0.01)").tag(Float(0.01))
                }
                .pickerStyle(.inline)

                Divider()

                Picker("Сглаживание", selection: Binding(
                    get: { model.rtaSettings.neighborSmoothing },
                    set: { model.rtaSettings.neighborSmoothing = $0 }
                )) {
                    Text("Нет — мелкие пики, точные узкие полосы").tag(Float(0))
                    Text("Лёгкое (0.5)").tag(Float(0.5))
                    Text("Соседние ±1").tag(Float(1))
                    Text("±1.5").tag(Float(1.5))
                    Text("Соседние ±2").tag(Float(2))
                    Text("±2.5").tag(Float(2.5))
                    Text("Соседние ±3 — ровная кривая").tag(Float(3))
                    Text("±4").tag(Float(4))
                    Text("Соседние ±5 — общая картина").tag(Float(5))
                    Text("Сильное ±8 — только общий контур").tag(Float(8))
                }
                .pickerStyle(.inline)
            } label: {
                Label("Динамика", systemImage: "waveform.path.ecg")
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

struct SpectrumBusCardContainer: View {
    let bus: MonitorBus
    let holder: BusSnapshotHolder

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.05, paused: false)) { _ in
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(bus.config.name)
                        .font(.headline)
                    if !bus.isConnected {
                        Label("устройство отключено", systemImage: "cable.connector.slash")
                            .font(.caption2)
                            .foregroundStyle(.red)
                    }
                    Spacer()
                }
                if holder.snapshot != nil {
                    SpectrumCurveChart(holder: holder)
                        .frame(height: 200)
                } else {
                    Text("ожидает «Старт»")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, minHeight: 60)
                }
            }
            .padding()
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
        }
    }
}
