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
                Text("1/3 октавы · 31 полоса")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            SpectrumChart(points: channel.spectrum, minDB: -80, maxDB: 0)
                .frame(height: 180)
            RTABarsChart(bands: channel.rtaBands)
                .frame(height: 70)
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
    }
}

struct SpectrumChart: View {
    let points: [SpectrumPoint]
    let minDB: Float
    let maxDB: Float

    var body: some View {
        Canvas { context, size in
            guard points.count > 1 else { return }

            for i in 1..<6 {
                let y = size.height * CGFloat(i) / 6
                var line = Path()
                line.move(to: CGPoint(x: 0, y: y))
                line.addLine(to: CGPoint(x: size.width, y: y))
                context.stroke(line, with: .color(.gray.opacity(0.25)), lineWidth: 0.5)
            }

            let dx = size.width / CGFloat(max(points.count - 1, 1))
            var path = Path()
            for (i, point) in points.enumerated() {
                let y = yPosition(point.magnitudeDB, height: size.height)
                let x = CGFloat(i) * dx
                if i == 0 {
                    path.move(to: CGPoint(x: x, y: y))
                } else {
                    path.addLine(to: CGPoint(x: x, y: y))
                }
            }
            context.stroke(path, with: .color(.accentColor), style: StrokeStyle(lineWidth: 1.5))

            let labels: [(Float, String)] = [(20, "20"), (100, "100"), (1000, "1k"), (10000, "10k"), (20000, "20k")]
            for (freq, label) in labels {
                let fx = xPosition(freq, width: size.width)
                let text = Text(label).font(.system(size: 9)).foregroundStyle(.secondary)
                context.draw(text, at: CGPoint(x: fx, y: size.height - 10))
            }

            for db in [Float(0), -20, -40, -60, -80] {
                let fy = yPosition(db, height: size.height)
                let text = Text("\(Int(db))").font(.system(size: 9)).foregroundStyle(.secondary)
                context.draw(text, at: CGPoint(x: 8, y: fy - 4), anchor: .topLeading)
            }
        }
        .drawingGroup()
    }

    private func xPosition(_ freq: Float, width: CGFloat) -> CGFloat {
        let logMin = log10f(20)
        let logMax = log10f(20000)
        let t = (log10f(freq) - logMin) / (logMax - logMin)
        return CGFloat(max(0, min(1, t))) * width
    }

    private func yPosition(_ db: Float, height: CGFloat) -> CGFloat {
        let t = (db - minDB) / (maxDB - minDB)
        return height * (1 - CGFloat(max(0, min(1, t))))
    }
}