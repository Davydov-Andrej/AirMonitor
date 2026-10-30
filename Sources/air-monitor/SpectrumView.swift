import SwiftUI
import yaCore

/// Спектр: по каждой шине — полосы RTA + кривая (усреднённый спектр).
struct SpectrumView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Спектр (АЧХ)")
                .font(.title2)
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
}

struct SpectrumChannelCard: View {
    let channel: ChannelSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(channel.label)
                    .font(.subheadline)
                Spacer()
                Text("октавные полосы + кривая 1/24 октавы")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            SpectrumCurveChart(fine: channel.fineCurve, bands: channel.rtaBands)
                .frame(height: 220)
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
    }
}

