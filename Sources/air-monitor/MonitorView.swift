import SwiftUI
import yaCore

/// Монитор: уровни по всем шинам.
struct MonitorView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Уровни и динамика")
                .font(.title2)
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 320))], spacing: 12) {
                    ForEach(model.snapshot.buses) { bus in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(bus.name)
                                .font(.headline)
                            ForEach(bus.displayChannels) { channel in
                                ChannelMeterCard(snapshot: channel)
                            }
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
                    .font(.headline)
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
            }

            HStack(spacing: 12) {
                metric("Momentary", snapshot.momentaryLUFS, suffix: " LUFS")
                metric("Short", snapshot.shortTermLUFS, suffix: " LUFS")
            }
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
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