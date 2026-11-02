import SwiftUI
import yaCore

/// Монитор: метры + история громкости по всем шинам (та же вёрстка, что
/// и дашборд, но без спектра/баланса).
struct MonitorView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Уровни и динамика")
                .font(.title2)
            if model.snapshot.buses.isEmpty {
                ContentUnavailableView("Нет данных", systemImage: "waveform", description: Text("Запустите захват (Старт)"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 14) {
                        let busList = model.snapshot.buses
                        ForEach(Array(zip(busList.indices, busList)), id: \.1.id) { index, bus in
                            MonitorBusRow(
                                bus: bus,
                                onMoveUp: { model.moveBusSnapshot(id: bus.id, delta: -1) },
                                onMoveDown: { model.moveBusSnapshot(id: bus.id, delta: 1) },
                                canMoveUp: index > 0,
                                canMoveDown: index < busList.count - 1
                            )
                        }
                    }
                }
            }
        }
        .padding()
    }
}

struct MonitorBusRow: View {
    let bus: BusSnapshot
    var onMoveUp: () -> Void = {}
    var onMoveDown: () -> Void = {}
    var canMoveUp: Bool = false
    var canMoveDown: Bool = false
    @EnvironmentObject var model: AppModel

    var isStereo: Bool {
        if case .stereo = bus.mode { return true }
        return false
    }

    var summary: ChannelSnapshot? {
        if isStereo { return bus.mono ?? bus.channels.first }
        return bus.channels.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                VStack(spacing: 2) {
                    Button(action: onMoveUp) {
                        Image(systemName: "chevron.up")
                            .font(.caption2)
                            .foregroundStyle(canMoveUp ? .primary : .tertiary)
                    }
                    .buttonStyle(.borderless)
                    .disabled(!canMoveUp)
                    Button(action: onMoveDown) {
                        Image(systemName: "chevron.down")
                            .font(.caption2)
                            .foregroundStyle(canMoveDown ? .primary : .tertiary)
                    }
                    .buttonStyle(.borderless)
                    .disabled(!canMoveDown)
                }

                Text(bus.name).font(.headline)
                Text(modeLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if let correlation = bus.correlation {
                    Text(String(format: "Корр. L/R: %.2f", correlation))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            HStack(alignment: .top, spacing: 14) {
                if isStereo {
                    StereoMeterPair(left: bus.channels.first, right: bus.channels.dropFirst().first)
                } else {
                    SingleMeter(snapshot: summary)
                }
                MetricsColumn(
                    title: "",
                    snapshot: summary,
                    showHints: model.showMetricHints
                )
                LoudnessHistoryChart(
                    monoHistory: summary?.loudnessHistory ?? [],
                    leftHistory: isStereo ? bus.channels.first?.loudnessHistory ?? [] : [],
                    rightHistory: isStereo ? bus.channels.dropFirst().first?.loudnessHistory ?? [] : [],
                    target: -23,
                    windowSeconds: 15
                )
                .frame(maxWidth: .infinity)
                .frame(height: meterHeight)
            }
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private var modeLabel: String {
        switch bus.mode {
        case .stereo(let l, let r): return "Стерео \(l + 1)/\(r + 1)"
        case .mono(let ch): return "Моно " + ch.map { "\($0 + 1)" }.joined(separator: "+")
        }
    }
}