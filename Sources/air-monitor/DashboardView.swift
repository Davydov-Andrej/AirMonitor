import SwiftUI
import yaCore

/// Дашборд: карточка на каждую шину (Main, Monitor, ...).
struct DashboardView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Дашборд")
                    .font(.title2)
                Spacer()
                Button {
                    model.isPresentingAddBus = true
                } label: {
                    Label("Добавить шину", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isCapturing)
            }

            if model.snapshot.buses.isEmpty {
                ContentUnavailableView(
                    "Нет шин мониторинга",
                    systemImage: "waveform",
                    description: Text("Нажмите «Добавить шину», выберите устройство и каналы (Main, Monitor и др.), а затем «Старт»")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 560), spacing: 16)], spacing: 16) {
                        ForEach(model.buses) { bus in
                            if let preview = model.busPreview(for: bus) {
                                BusDashboardCard(
                                    id: bus.id,
                                    name: bus.config.name,
                                    mode: bus.config.mode,
                                    snapshot: preview,
                                    onDelete: { model.removeBus(id: bus.id) },
                                    onRename: { newName in model.renameBus(id: bus.id, to: newName) }
                                )
                            }
                        }
                    }
                }
            }
        }
        .padding()
        .sheet(isPresented: $model.isPresentingAddBus) {
            AddBusSheet()
        }
    }
}

/// Карточка шины на дашборде.
struct BusDashboardCard: View {
    let id: BusID
    let name: String
    let mode: BusMode
    let snapshot: BusSnapshot
    let onDelete: () -> Void
    let onRename: (String) -> Void

    @State private var isRenaming = false
    @State private var renameText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(name)
                    .font(.headline)
                Text(modeLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.gray.opacity(0.15)))
                Spacer()
                if let correlation = snapshot.correlation {
                    Text(String(format: "Кор: %.2f", correlation))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(correlation > 0.7 ? .green : (correlation > 0.3 ? .orange : .red))
                }
                Menu {
                    Button("Переименовать") {
                        renameText = name
                        isRenaming = true
                    }
                    Divider()
                    Button("Удалить", role: .destructive) {
                        onDelete()
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
            }

            HStack(spacing: 12) {
                ForEach(snapshot.displayChannels) { ch in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(ch.label)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        VUMeterView(valueDB: ch.vuDB, peakDB: ch.peakDB)
                        HStack(spacing: 8) {
                            metric("Peak", ch.peakDB)
                            metric("RMS", ch.rmsDB)
                            metric("TruePeak", ch.truePeakDB)
                        }
                        HStack(spacing: 8) {
                            metric("LUFS", ch.momentaryLUFS, suffix: "")
                            metric("Short", ch.shortTermLUFS, suffix: "")
                        }
                    }
                }
            }

            Divider()

            Text("Спектр")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let first = snapshot.displayChannels.first {
                RTABarsChart(bands: first.rtaBands)
                    .frame(height: 90)
            }

            Text("Баланс полос")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let first = snapshot.displayChannels.first {
                InstrumentBalanceStrip(spectrum: first.spectrum, sampleRate: Float(snapshot.sampleRate))
            }
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.gray.opacity(0.2)))
        .alert("Переименовать", isPresented: $isRenaming) {
            TextField("Имя шины", text: $renameText)
            Button("OK") { onRename(renameText) }
            Button("Отмена", role: .cancel) {}
        }
    }

    private var modeLabel: String {
        switch mode {
        case .stereo(let l, let r): return "Стерео \(l + 1)/\(r + 1)"
        case .mono(let ch): return "Моно " + ch.map { "\($0 + 1)" }.joined(separator: "+")
        }
    }

    private func metric(_ title: String, _ value: Float, suffix: String = " dB") -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            Text(value.isFinite ? String(format: "%.1f%@", value, suffix) : "--")
                .font(.system(size: 11, design: .monospaced).weight(.medium))
        }
    }
}

/// Полосы RTA-спектра.
struct RTABarsChart: View {
    let bands: [RTABand]

    private let minDB: Float = -80

    var body: some View {
        GeometryReader { geo in
            Canvas { context, size in
                guard !bands.isEmpty else { return }
                let slot = size.width / CGFloat(bands.count)
                let barWidth = slot * 0.8

                for band in bands {
                    let x = CGFloat(band.id) * slot + (slot - barWidth) / 2
                    let clampedLevel = max(minDB, band.levelDB)
                    let clampedPeak = max(minDB, band.peakDB)
                    let levelHeight = barHeight(clampedLevel, size: size)
                    let peakHeight = barHeight(clampedPeak, size: size)

                    let bar = Path(CGRect(x: x, y: size.height - levelHeight, width: barWidth, height: levelHeight))
                    context.fill(bar, with: .color(barColor(band.levelDB)))

                    let peakLine = Path(CGRect(x: x, y: size.height - peakHeight, width: barWidth, height: 2))
                    context.fill(peakLine, with: .color(.black.opacity(0.7)))
                }
            }
        }
        .drawingGroup()
    }

    private func barHeight(_ db: Float, size: CGSize) -> CGFloat {
        let t = (db - minDB) / 80
        return max(2, CGFloat(t) * size.height)
    }

    private func barColor(_ db: Float) -> Color {
        if db > -6 { return .red }
        if db > -12 { return .orange }
        if db > -20 { return .yellow }
        return .green
    }
}

/// Баланс инструментальных полос (компактно).
struct InstrumentBalanceStrip: View {
    let spectrum: [SpectrumPoint]
    let sampleRate: Float

    var body: some View {
        let balances = InstrumentBalanceAnalyzer(spectrum: spectrum, sampleRate: sampleRate).balances()
        HStack(spacing: 8) {
            ForEach(balances) { balance in
                VStack(spacing: 2) {
                    Rectangle()
                        .fill(color(for: balance.deviationDB))
                        .frame(height: rectHeight(for: balance.deviationDB))
                    Text(balance.band.rawName)
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func rectHeight(for deviationDB: Float) -> CGFloat {
        let t = max(Float(-1), min(1, deviationDB / 12))
        return 4 + CGFloat(abs(t)) * 20
    }

    private func color(for deviationDB: Float) -> Color {
        if deviationDB > 3 { return .red }
        if deviationDB < -3 { return .orange }
        return .green
    }
}