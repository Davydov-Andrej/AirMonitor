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
                ForEach(RTASettings.presets, id: \.name) { preset in
                    Button {
                        model.rtaSettings = preset.settings
                    } label: {
                        HStack {
                            Text(preset.name)
                            if isPreset(preset.settings) {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
                Divider()
                // Окно усреднения метрики S (short-term громкости).
                Picker("Окно S", selection: Binding(
                    get: { model.rtaSettings.shortTermSeconds },
                    set: { model.rtaSettings.shortTermSeconds = $0 }
                )) {
                    Text("S: 0.4 с").tag(0.4)
                    Text("S: 1 с (по умолчанию)").tag(1.0)
                    Text("S: 3 с (стандарт EBU)").tag(3.0)
                }
                .pickerStyle(.inline)
            } label: {
                Label(presetName, systemImage: "gauge.with.needle")
            }

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

                Divider()

                // Скорость спада: как быстро график опускается после пика.
                // Быстрый спад = видны сигналы ниже, скрытые громким пиком.
                Picker("Спад", selection: Binding(
                    get: { model.rtaSettings.release },
                    set: { model.rtaSettings.release = $0 }
                )) {
                    Text("Мгновенный").tag(Float(0.6))
                    Text("Быстрый").tag(Float(0.25))
                    Text("Средний (по умолчанию)").tag(Float(0.08))
                    Text("Медленный").tag(Float(0.03))
                    Text("Усреднение").tag(Float(0.01))
                }
                .pickerStyle(.inline)

                Divider()
            } label: {
                Label("Полосы: 1/\(model.rtaSettings.bandsPerOctave) окт", systemImage: "slider.horizontal.3")
            }
        }
    }

    private var presetName: String {
        for (name, settings) in RTASettings.presets where isPreset(settings) {
            return name
        }
        return "Скорость: своя"
    }

    private func isPreset(_ s: RTASettings) -> Bool {
        abs(s.attack - model.rtaSettings.attack) < 0.01
            && abs(s.release - model.rtaSettings.release) < 0.001
            && s.bandsPerOctave == model.rtaSettings.bandsPerOctave
            && s.showFineCurve == model.rtaSettings.showFineCurve
    }
}

struct SpectrumBusCardContainer: View {
    let bus: MonitorBus
    let holder: BusSnapshotHolder

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.05)) { _ in
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
                if let snapshot = holder.snapshot {
                    ForEach(snapshot.displayChannels) { channel in
                        SpectrumCurveChart(fine: channel.fineCurve, bands: channel.rtaBands)
                            .frame(height: 200)
                    }
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