import SwiftUI
import yaCore

/// Бегущий график громкости (Youlean-стиль): моментальная и short-term
/// громкость во времени + целевая линия.
struct LoudnessHistoryChart: View {
    let history: [LoudnessMeter.HistoryPoint]
    var target: Float = -23

    private let minLU: Float = -40
    private let maxLU: Float = 0

    var body: some View {
        Canvas { context, size in
            guard !history.isEmpty else {
                drawPlaceholder(context: context, size: size)
                return
            }

            // Целевая линия
            let targetY = yPos(target, size: size)
            var targetPath = Path()
            targetPath.move(to: CGPoint(x: 0, y: targetY))
            targetPath.addLine(to: CGPoint(x: size.width, y: targetY))
            context.stroke(targetPath, with: .color(.green.opacity(0.5)), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))

            // Линии сетки
            for lu in stride(from: minLU + 10, to: maxLU, by: 10) {
                let y = yPos(lu, size: size)
                var grid = Path()
                grid.move(to: CGPoint(x: 0, y: y))
                grid.addLine(to: CGPoint(x: size.width, y: y))
                context.stroke(grid, with: .color(.gray.opacity(0.15)), lineWidth: 0.5)
            }

            let n = history.count
            let stepX = size.width / CGFloat(max(n - 1, 1))

            // Short-term (светлая заливка)
            var stPath = Path()
            stPath.move(to: CGPoint(x: 0, y: size.height))
            for (i, point) in history.enumerated() {
                guard point.shortTerm.isFinite else { continue }
                stPath.addLine(to: CGPoint(x: CGFloat(i) * stepX, y: yPos(point.shortTerm, size: size)))
            }
            stPath.addLine(to: CGPoint(x: size.width, y: size.height))
            stPath.closeSubpath()
            context.fill(stPath, with: .color(.blue.opacity(0.18)))

            // Momentary (линия)
            var mPath = Path()
            var started = false
            for (i, point) in history.enumerated() {
                guard point.momentary.isFinite else { continue }
                let pt = CGPoint(x: CGFloat(i) * stepX, y: yPos(point.momentary, size: size))
                if started {
                    mPath.addLine(to: pt)
                } else {
                    mPath.move(to: pt)
                    started = true
                }
            }
            context.stroke(mPath, with: .color(.blue), lineWidth: 1.2)
        }
        .background(Color.black.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func drawPlaceholder(context: GraphicsContext, size: CGSize) {
        let text = Text("Нет данных").font(.caption).foregroundStyle(.secondary)
        context.draw(text, at: CGPoint(x: size.width / 2, y: size.height / 2))
    }

    private func yPos(_ lu: Float, size: CGSize) -> CGFloat {
        let clamped = max(minLU, min(maxLU, lu))
        return size.height * (1 - CGFloat((clamped - minLU) / (maxLU - minLU)))
    }
}

/// Спектр: тонкая кривая (1/24 октавы) + октавные полосы (bars) поверх.
struct SpectrumCurveChart: View {
    let fine: [SpectrumPoint]
    let bands: [RTABand]

    private let minDB: Float = -90
    private let maxDB: Float = 10

    var body: some View {
        Canvas { context, size in
            // Сетка
            for i in 1..<5 {
                let y = size.height * CGFloat(i) / 5
                var line = Path()
                line.move(to: CGPoint(x: 0, y: y))
                line.addLine(to: CGPoint(x: size.width, y: y))
                context.stroke(line, with: .color(.gray.opacity(0.18)), lineWidth: 0.5)
            }

            // Подписи частот (лог-шкала)
            let labels: [(Float, String)] = [(63, "63"), (250, "250"), (1000, "1k"), (4000, "4k"), (16000, "16k")]
            for (freq, label) in labels {
                let fx = xPos(freq, width: size.width)
                var tick = Path()
                tick.move(to: CGPoint(x: fx, y: 0))
                tick.addLine(to: CGPoint(x: fx, y: size.height))
                context.stroke(tick, with: .color(.gray.opacity(0.12)), lineWidth: 0.5)
                let text = Text(label).font(.system(size: 8)).foregroundStyle(.secondary)
                context.draw(text, at: CGPoint(x: fx + 3, y: size.height - 8), anchor: .topLeading)
            }

            // Октавные полосы (ленты позади кривой)
            if !bands.isEmpty {
                let slot = size.width / CGFloat(bands.count)
                for band in bands {
                    let x = CGFloat(band.id) * slot
                    let h = barHeight(band.levelDB, size: size)
                    var rect = Path(CGRect(x: x + 1, y: size.height - h, width: slot - 2, height: h))
                    context.fill(rect, with: .color(.accentColor.opacity(0.18)))
                    // пик-холд
                    let ph = barHeight(band.peakDB, size: size)
                    var peak = Path(CGRect(x: x + 1, y: size.height - ph, width: slot - 2, height: 1.5))
                    context.fill(peak, with: .color(.white.opacity(0.35)))
                }
            }

            // Тонкая кривая поверх
            if fine.count > 1 {
                var path = Path()
                for (i, point) in fine.enumerated() {
                    let x = xPos(point.frequency, width: size.width)
                    let y = yPos(point.magnitudeDB, size: size)
                    if i == 0 {
                        path.move(to: CGPoint(x: x, y: y))
                    } else {
                        path.addLine(to: CGPoint(x: x, y: y))
                    }
                }
                context.stroke(path, with: .color(.accentColor), style: StrokeStyle(lineWidth: 1.6, lineJoin: .round))
            }
        }
        .drawingGroup()
        .background(Color.black.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func xPos(_ freq: Float, width: CGFloat) -> CGFloat {
        let logMin = log10f(20)
        let logMax = log10f(20000)
        let t = (log10f(max(freq, 20)) - logMin) / (logMax - logMin)
        return CGFloat(max(0, min(1, t))) * width
    }

    private func yPos(_ db: Float, size: CGSize) -> CGFloat {
        let t = (db - minDB) / (maxDB - minDB)
        return size.height * (1 - CGFloat(max(0, min(1, t))))
    }

    private func barHeight(_ db: Float, size: CGSize) -> CGFloat {
        yPos(db, size: size)
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