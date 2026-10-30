import SwiftUI
import yaCore

/// Монитор: уровни + история громкости по всем шинам.
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
                        ForEach(model.snapshot.buses) { bus in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text(bus.name).font(.headline)
                                    Spacer()
                                    if let integrated = bus.displayChannels.first?.integratedLUFS, integrated.isFinite {
                                        Text(String(format: "Integrated %.1f LUFS", integrated))
                                            .font(.caption.monospacedDigit())
                                            .foregroundStyle(.secondary)
                                    }
                                    if let lra = bus.displayChannels.first?.loudnessRangeLU, lra > 0 {
                                        Text(String(format: "LRA %.1f LU", lra))
                                            .font(.caption.monospacedDigit())
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                ForEach(bus.displayChannels) { channel in
                                    ChannelMeterCard(snapshot: channel)
                                }
                            }
                            .padding()
                            .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
                        }
                    }
                }
            }
        }
        .padding()
    }
}

struct ChannelMeterCard: View {
    let snapshot: ChannelSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(snapshot.label)
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text(snapshot.peakDB.isFinite
                     ? String(format: "%.1f dBFS", snapshot.peakDB)
                     : "--")
                    .font(.title3.monospacedDigit())
            }

            VUMeterView(valueDB: snapshot.vuDB, peakDB: snapshot.peakDB)

            HStack(spacing: 12) {
                metric("Peak", snapshot.peakDB)
                metric("RMS", snapshot.rmsDB)
                metric("TruePeak", snapshot.truePeakDB)
                metric("Crest", snapshot.crestFactorDB, suffix: " dB")
                metric("Integr.", snapshot.integratedLUFS, suffix: " LU")
            }

            LoudnessHistoryChart(history: snapshot.loudnessHistory, target: -23)
                .frame(height: 70)
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.03)))
    }

    private func metric(_ name: String, _ value: Float, suffix: String = " dB") -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value.isFinite ? String(format: "%.1f%@", value, suffix) : "--")
                .font(.system(.body, design: .monospaced).weight(.medium))
        }
    }
}