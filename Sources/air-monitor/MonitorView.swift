import SwiftUI
import yaCore

/// Монитор: метры + история громкости по всем шинам.
/// Порядок шин — как на дашборде (model.buses), данные — из холдеров.
struct MonitorView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Уровни и динамика")
                    .font(.title2)
                Spacer()
            }
            if model.buses.isEmpty {
                ContentUnavailableView("Нет шин", systemImage: "waveform", description: Text("Добавьте шину на дашборде и запустите захват"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 14) {
                        ForEach(Array(model.buses.enumerated()), id: \.element.id) { index, bus in
                            MonitorBusRowContainer(
                                bus: bus,
                                holder: model.holder(for: bus),
                                onMoveUp: { model.moveBusUp(id: bus.id) },
                                onMoveDown: { model.moveBusDown(id: bus.id) },
                                canMoveUp: index > 0,
                                canMoveDown: index < model.buses.count - 1
                            )
                        }
                    }
                }
            }
        }
        .padding()
    }
}

/// Изолированный контейнер: обновляется только при изменении снимка шины.
struct MonitorBusRowContainer: View {
    let bus: MonitorBus
    @ObservedObject var holder: BusSnapshotHolder
    var onMoveUp: () -> Void = {}
    var onMoveDown: () -> Void = {}
    var canMoveUp: Bool = false
    var canMoveDown: Bool = false
    @EnvironmentObject var model: AppModel

    var body: some View {
        MonitorBusRow(
            busName: bus.config.name,
            busMode: bus.config.mode,
            snapshot: holder.snapshot,
            isConnected: bus.isConnected,
            showHints: model.showMetricHints,
            onMoveUp: onMoveUp,
            onMoveDown: onMoveDown,
            canMoveUp: canMoveUp,
            canMoveDown: canMoveDown
        )
    }
}

struct MonitorBusRow: View {
    let busName: String
    let busMode: BusMode
    let snapshot: BusSnapshot?
    var isConnected: Bool = true
    var showHints: Bool = false
    var onMoveUp: () -> Void = {}
    var onMoveDown: () -> Void = {}
    var canMoveUp: Bool = false
    var canMoveDown: Bool = false

    var isStereo: Bool {
        if case .stereo = busMode { return true }
        return false
    }

    var summary: ChannelSnapshot? {
        guard let snapshot else { return nil }
        if isStereo { return snapshot.mono ?? snapshot.channels.first }
        return snapshot.channels.first
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

                Text(busName).font(.headline)
                Text(modeLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !isConnected {
                    Label("устройство отключено", systemImage: "cable.connector.slash")
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
                Spacer()
                if let correlation = snapshot?.correlation {
                    Text(String(format: "Корр. L/R: %.2f", correlation))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            HStack(alignment: .top, spacing: 14) {
                if isStereo {
                    StereoMeterPair(
                        left: snapshot?.channels.first,
                        right: snapshot?.channels.dropFirst().first
                    )
                } else {
                    SingleMeter(snapshot: summary)
                }
                MetricsColumn(
                    title: "",
                    snapshot: summary,
                    showHints: showHints
                )
                LoudnessHistoryChart(
                    monoHistory: summary?.loudnessHistory ?? [],
                    leftHistory: isStereo ? snapshot?.channels.first?.loudnessHistory ?? [] : [],
                    rightHistory: isStereo ? snapshot?.channels.dropFirst().first?.loudnessHistory ?? [] : [],
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
        switch busMode {
        case .stereo(let l, let r): return "Стерео \(l + 1)/\(r + 1)"
        case .mono(let ch): return "Моно " + ch.map { "\($0 + 1)" }.joined(separator: "+")
        }
    }
}