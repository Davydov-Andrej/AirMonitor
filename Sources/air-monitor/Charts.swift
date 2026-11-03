import SwiftUI
import yaCore

extension InstrumentBalance: Identifiable {
    public var id: String { band.rawName }
}

/// Бегущий график громкости: окно последних N секунд. Режимы:
/// моно (M/S-заливка+линия), стерео (3 линии: стерео, L, R).
struct LoudnessHistoryChart: View {
    let holder: BusSnapshotHolder
    var isStereo: Bool = false

    var body: some View {
        LiveCanvas(
            makeDrawer: { [holder, isStereo] in CGChart.loudnessDrawer(holder: holder, isStereo: isStereo) },
            makeBackground: { CGChart.loudnessBackground() },
            dataVersion: { [holder] in holder.dataVersion }
        )
        .background(Color.black.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}


/// Спектр: тонкая кривая + октавные полосы. Подписи осей — статичный слой
/// поверх Canvas (Text внутри Canvas ресолвится каждый кадр — дорого).
struct SpectrumCurveChart: View {
    let holder: BusSnapshotHolder

    var body: some View {
        LiveCanvas(
            makeDrawer: { [holder] in CGChart.spectrumDrawer(holder: holder) },
            makeBackground: { CGChart.spectrumBackground() },
            dataVersion: { [holder] in holder.dataVersion }
        )
        .background(Color.black.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 6))
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
            dataVersion: { [holder] in holder.dataVersion }
        )
        .background(Color.black.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 6))
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
                            .fill(Color.gray.opacity(0.15))
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
                .help("\(balance.band.localizedName): \(String(format: "%+.1f", balance.deviationDB)) дБ")
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