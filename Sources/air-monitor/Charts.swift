import SwiftUI
import yaCore

private extension InstrumentBand {
    var displayName: String { L(localizedName) }
}

private enum LiveChartHover {
    static func spectrum(holder: BusSnapshotHolder, point: CGPoint, size: CGSize) -> String {
        guard size.width > 0,
              let snapshot = holder.snapshot,
              let channel = snapshot.mono ?? snapshot.channels.first else { return "" }
        let ratio = max(0, min(1, point.x / size.width))
        let frequency = powf(10, log10f(20) + Float(ratio) * (log10f(20_000) - log10f(20)))
        let candidates = channel.fineCurve.isEmpty
            ? channel.rtaBands.map { SpectrumPoint(id: $0.id, frequency: $0.centerFrequency, magnitudeDB: $0.levelDB) }
            : channel.fineCurve
        guard let nearest = candidates.min(by: { abs($0.frequency - frequency) < abs($1.frequency - frequency) }) else { return "" }
        let frequencyLabel = nearest.frequency >= 1000
            ? LF("%.2f кГц", nearest.frequency / 1000)
            : LF("%.0f Гц", nearest.frequency)
        return LF("%@: %.1f дБFS", frequencyLabel, nearest.magnitudeDB)
    }

    static func loudness(holder: BusSnapshotHolder, isStereo: Bool, point: CGPoint, size: CGSize) -> String {
        guard size.width > 0,
              let snapshot = holder.snapshot else { return "" }
        let capacity = 150 // 30 с × 5 точек/с; history обновляется каждые 200 мс.
        let xIndex = Int((max(0, min(1, point.x / size.width)) * CGFloat(capacity - 1)).rounded())
        func pointAt(_ history: [LoudnessMeter.HistoryPoint]) -> LoudnessMeter.HistoryPoint? {
            let index = xIndex - max(0, capacity - history.count)
            return history.indices.contains(index) ? history[index] : nil
        }
        func level(_ value: Float) -> String { value.isFinite ? String(format: "%.1f", value) : "—" }

        let monoHistory = (isStereo ? snapshot.mono : snapshot.channels.first)?.loudnessHistory ?? []
        guard let mono = pointAt(monoHistory) else { return "" }
        guard isStereo else {
            return "M \(level(mono.momentary)) · S \(level(mono.shortTerm)) LUFS"
        }

        let left = snapshot.channels.first.flatMap { pointAt($0.loudnessHistory) }
        let right = snapshot.channels.dropFirst().first.flatMap { pointAt($0.loudnessHistory) }
        var values = ["Stereo M \(level(mono.momentary)) / S \(level(mono.shortTerm))"]
        if let left { values.append("L M \(level(left.momentary))") }
        if let right { values.append("R M \(level(right.momentary))") }
        return values.joined(separator: "  ·  ") + " LUFS"
    }

    static func balance(holder: BusSnapshotHolder, point: CGPoint, size: CGSize) -> String {
        guard size.width > 0,
              let snapshot = holder.snapshot,
              let channel = snapshot.mono ?? snapshot.channels.first else { return "" }
        let values = channel.tonalBalances
        guard !values.isEmpty else { return "" }
        let index = min(values.count - 1, max(0, Int(point.x / size.width * CGFloat(values.count))))
        let value = values[index]
        return LF("%@: %+.1f дБ · уровень %.1f дБFS", value.band.displayName, value.deviationDB, value.energyDB)
    }
}

extension InstrumentBalance: Identifiable {
    public var id: String { band.rawName }
}

/// Бегущий график громкости: окно последних N секунд. Режимы:
/// моно (M/S-заливка+линия), стерео (3 линии: стерео, L, R).
struct LoudnessHistoryChart: View {
    @Environment(\.colorScheme) private var colorScheme
    let holder: BusSnapshotHolder
    var isStereo: Bool = false

    var body: some View {
        LiveCanvas(
            makeDrawer: { [holder, isStereo, colorScheme] in
                CGChart.loudnessDrawer(holder: holder, isStereo: isStereo, isDark: colorScheme == .dark)
            },
            makeBackground: { CGChart.loudnessBackground() },
            dataVersion: { [holder] in holder.dataVersion },
            hoverText: { [holder, isStereo] point, size in
                LiveChartHover.loudness(holder: holder, isStereo: isStereo, point: point, size: size)
            }
        )
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(alignment: .topLeading) {
            HStack(spacing: 8) {
                if isStereo {
                    legendFill(.blue.opacity(colorScheme == .dark ? 0.23 : 0.16), "S стерео")
                    legendLine(.primary.opacity(0.55), "M стерео")
                    legendLine(.red, "M L")
                    legendLine(.blue, "M R")
                } else {
                    legendFill(.blue.opacity(colorScheme == .dark ? 0.23 : 0.16), "S")
                    legendLine(.blue, "M")
                }
                legendLine(.green, "−23 LUFS (ориентир)", dashed: true)
            }
            .padding(4)
        }
    }

    private func legendLine(_ color: Color, _ label: String, dashed: Bool = false) -> some View {
        HStack(spacing: 3) {
            if dashed {
                HStack(spacing: 2) {
                    ForEach(0..<3, id: \.self) { _ in
                        Rectangle().fill(color).frame(width: 3, height: 1)
                    }
                }
                .frame(width: 12, height: 2)
            } else {
                Capsule().fill(color).frame(width: 12, height: 2)
            }
            Text(L(label)).font(.system(size: 8)).foregroundStyle(.secondary)
        }
    }

    private func legendFill(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 3) {
            RoundedRectangle(cornerRadius: 1).fill(color).frame(width: 10, height: 7)
            Text(L(label)).font(.system(size: 8)).foregroundStyle(.secondary)
        }
    }
}


/// Спектр: тонкая кривая + октавные полосы. Подписи осей — статичный слой
/// поверх Canvas (Text внутри Canvas ресолвится каждый кадр — дорого).
struct SpectrumCurveChart: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.colorScheme) private var colorScheme
    let holder: BusSnapshotHolder

    var body: some View {
        LiveCanvas(
            makeDrawer: { [holder, colorScheme] in
                CGChart.spectrumDrawer(holder: holder, isDark: colorScheme == .dark)
            },
            makeBackground: { CGChart.spectrumBackground() },
            dataVersion: { [holder] in holder.dataVersion },
            hoverText: { [holder] point, size in
                LiveChartHover.spectrum(holder: holder, point: point, size: size)
            }
        )
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(alignment: .topLeading) {
            HStack(spacing: 8) {
                if let divisions = fineCurveDivisions {
                    legendLine(.accentColor, LF("кривая ≈1/%d окт", divisions))
                } else {
                    legendLine(.secondary.opacity(0.45), "тонкая кривая выкл.")
                }
                legendLine(.accentColor.opacity(colorScheme == .dark ? 0.24 : 0.18), LF("полосы 1/%d окт", model.rtaSettings.bandsPerOctave))
                if model.rtaSettings.peakHoldSeconds > 0 {
                    legendLine(.primary.opacity(0.4), LF("пик-холд %.1f с", model.rtaSettings.peakHoldSeconds))
                } else {
                    legendLine(.primary.opacity(0.4), "пик-холд выкл.")
                }
            }
            .padding(4)
        }
    }

    private func legendLine(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 3) {
            RoundedRectangle(cornerRadius: 1).fill(color).frame(width: 10, height: 3)
            Text(L(label)).font(.system(size: 8)).foregroundStyle(.secondary)
        }
    }

    private var fineCurveDivisions: Int? {
        guard let channel = holder.snapshot?.mono ?? holder.snapshot?.channels.first,
              channel.fineCurve.count > 1,
              let first = channel.fineCurve.first?.frequency,
              let last = channel.fineCurve.last?.frequency,
              first > 0, last > first else { return nil }
        let octaveSpan = log2(Double(last / first))
        guard octaveSpan > 0 else { return nil }
        return max(1, Int((Double(channel.fineCurve.count - 1) / octaveSpan).rounded()))
    }
}

/// Тональный баланс в стиле iZotope Tonal Balance Control:
/// кривая текущего баланса поверх целевой зоны референса.
/// Балансы считаются в DSP-потоке (ChannelAnalyzerSet) — UI только рисует.
struct TonalBalanceChart: View {
    let holder: BusSnapshotHolder

    var body: some View {
        LiveCanvas(
            makeDrawer: { [holder] in CGChart.balanceDrawer(holder: holder) },
            makeBackground: { CGChart.balanceBackground() },
            dataVersion: { [holder] in holder.dataVersion },
            hoverText: { [holder] point, size in
                LiveChartHover.balance(holder: holder, point: point, size: size)
            }
        )
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(alignment: .topLeading) {
            HStack(spacing: 8) {
                legendLine(.accentColor, "отклонение от референса")
                legendFill(.green.opacity(0.12), "зона ±4 дБ")
                legendDot(.red, "выше +4 дБ")
                legendDot(.orange, "ниже −4 дБ")
            }
            .padding(4)
        }
    }

    private func legendLine(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 3) {
            Capsule().fill(color).frame(width: 10, height: 2)
            Text(L(label)).font(.system(size: 8)).foregroundStyle(.secondary)
        }
    }

    private func legendFill(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 3) {
            RoundedRectangle(cornerRadius: 1).fill(color).frame(width: 9, height: 6)
            Text(L(label)).font(.system(size: 8)).foregroundStyle(.secondary)
        }
    }

    private func legendDot(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 3) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text(L(label)).font(.system(size: 8)).foregroundStyle(.secondary)
        }
    }
}


/// Баланс инструментальных полос (компактно) с отклонениями от референса.
struct InstrumentBalanceStrip: View {
    let spectrum: [SpectrumPoint]
    let sampleRate: Float

    var body: some View {
        let analyzer = InstrumentBalanceAnalyzer(spectrum: spectrum, sampleRate: sampleRate)
        let balances = analyzer.balances()
        HStack(spacing: 8) {
            ForEach(balances) { balance in
                VStack(spacing: 2) {
                    // Центральная ось = референс. Столбик вверх = перегруз.
                    ZStack(alignment: .bottom) {
                        Rectangle()
                            .fill(Color.primary.opacity(0.10))
                        RoundedRectangle(cornerRadius: 2)
                            .fill(color(for: balance.deviationDB))
                            .frame(height: barHeight(balance.deviationDB))
                    }
                    .frame(height: 40)
                    Text(balance.band.rawName)
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .help(LF("%@: %+.1f дБ", balance.band.displayName, balance.deviationDB))
            }
        }
    }

    /// Высота столбика: центр — референс (0), вверх — перегруз, вниз — недостаток.
    private func barHeight(_ deviationDB: Float) -> CGFloat {
        let t = max(-1, min(1, deviationDB / 12))
        return CGFloat(20 + t * 18)  // 20 = половина высоты 40
    }

    private func color(for deviationDB: Float) -> Color {
        if deviationDB > 6 { return .red }
        if deviationDB > 3 { return .orange }
        if deviationDB < -6 { return .blue }
        if deviationDB < -3 { return .cyan }
        return .green
    }
}
