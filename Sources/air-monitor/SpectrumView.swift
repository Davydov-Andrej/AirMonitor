import SwiftUI
import yaCore

/// Спектр: общая панель настроек RTA сверху + график на шину.
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
            if model.snapshot.buses.isEmpty {
                ContentUnavailableView(
                    "Нет данных",
                    systemImage: "waveform",
                    description: Text("Запустите захват (Старт), чтобы увидеть спектры")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 16) {
                        ForEach(model.snapshot.buses) { bus in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(bus.name)
                                    .font(.headline)
                                ForEach(bus.displayChannels) { channel in
                                    SpectrumChannelCard(channel: channel)
                                }
                            }
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

struct SpectrumChannelCard: View {
    let channel: ChannelSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SpectrumCurveChart(fine: channel.fineCurve, bands: channel.rtaBands)
                .frame(height: 240)
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
    }
}