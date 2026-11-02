import SwiftUI
import yaCore

/// Тональный баланс: по каждой шине — график с целевой зоной.
/// Порядок = дашборд.
struct BalanceView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Тональный баланс")
                    .font(.title2)
                Spacer()
                Text("Отклонения от референса по полосам")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if model.buses.isEmpty {
                ContentUnavailableView("Нет шин", systemImage: "waveform", description: Text("Добавьте шину на дашборде и запустите захват"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 16) {
                        ForEach(model.buses) { bus in
                            BalanceBusCardContainer(bus: bus, holder: model.holder(for: bus))
                        }
                    }
                }
            }
        }
        .padding()
    }
}

struct BalanceBusCardContainer: View {
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
                    if let correlation = holder.snapshot?.correlation {
                        Text(String(format: "Корр. L/R: %.2f", correlation))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }

                if let snapshot = holder.snapshot {
                    let summary = snapshot.mono ?? snapshot.channels.first
                    TonalBalanceChart(holder: holder)
                    .frame(height: 180)
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