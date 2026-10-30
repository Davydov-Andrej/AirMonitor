import SwiftUI
import yaCore

/// Бегущий график громкости (Youlean-стиль): окно последних N секунд,
/// моментальная и short-term громкость, целевая линия, подписи осей.
struct LoudnessHistoryChart: View {
    let history: [LoudnessMeter.HistoryPoint]
    var target: Float = -23
    /// Окно отображения в секундах (история идёт 10 Гц).
    var windowSeconds: Double = 15

    private let minLU: Float = -40
    private let maxLU: Float = 0

    /// Срез последних windowSeconds секунд.
    private var visible: [LoudnessMeter.HistoryPoint] {
        let count = Int(windowSeconds * 10)
        return history.suffix(count)
    }

    var body: some View {
        Canvas { context, size in
            // Сетка + подписи LU
            for lu in stride(from: minLU + 10, to: maxLU, by: 10) {
                let y = yPos(lu, size: size)
                var grid = Path()
                grid.move(to: CGPoint(x: 0, y: y))
                grid.addLine(to: CGPoint(x: size.width, y: y))
                context.stroke(grid, with: .color(.gray.opacity(0.15)), lineWidth: 0.5)
                let text = Text("\(Int(lu))").font(.system(size: 8)).foregroundStyle(.secondary)
                context.draw(text, at: CGPoint(x: 3, y: y + 2), anchor: .topLeading)
            }

            // Целевая линия
            let targetY = yPos(target, size: size)
            var targetPath = Path()
            targetPath.move(to: CGPoint(x: 0, y: targetY))
            targetPath.addLine(to: CGPoint(x: size.width, y: targetY))
            context.stroke(targetPath, with: .color(.green.opacity(0.45)), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))

            let points = visible
            guard !points.isEmpty else {
                let text = Text("нет сигнала").font(.system(size: 9)).foregroundStyle(.tertiary)
                context.draw(text, at: CGPoint(x: size.width / 2, y: size.height / 2))
                return
            }

            // По времени до конца окна (график растёт справа налево — справа «сейчас»).
            let stepX = size.width / CGFloat(max(Int(windowSeconds * 10) - 1, 1))
            let offset = CGFloat(Int(windowSeconds * 10) - points.count)

            // Short-term (заливка)
            var stPath = Path()
            stPath.move(to: CGPoint(x: size.width, y: size.height))
            var hasST = false
            for (i, point) in points.enumerated() {
                guard point.shortTerm.isFinite else { continue }
                let x = (offset + CGFloat(i)) * stepX
                stPath.addLine(to: CGPoint(x: x, y: yPos(point.shortTerm, size: size)))
                hasST = true
            }
            if hasST {
                stPath.addLine(to: CGPoint(x: size.width, y: size.height))
                stPath.closeSubpath()
                context.fill(stPath, with: .color(.blue.opacity(0.18)))
            }

            // Momentary (линия)
            var mPath = Path()
            var started = false
            for (i, point) in points.enumerated() {
                guard point.momentary.isFinite else { continue }
                let x = (offset + CGFloat(i)) * stepX
                let y = yPos(point.momentary, size: size)
                if started {
                    mPath.addLine(to: CGPoint(x: x, y: y))
                } else {
                    mPath.move(to: CGPoint(x: x, y: y))
                    started = true
                }
            }
            if started {
                context.stroke(mPath, with: .color(.blue), lineWidth: 1.3)
            }
        }
        .background(Color.black.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 6))
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
            // Сетка + подписи дБ по Y
            for db in stride(from: maxDB, to: minDB, by: -12) {
                let y = yPos(db, size: size)
                var line = Path()
                line.move(to: CGPoint(x: 0, y: y))
                line.addLine(to: CGPoint(x: size.width, y: y))
                context.stroke(line, with: .color(.gray.opacity(0.15)), lineWidth: 0.5)
                let text = Text("\(Int(db))").font(.system(size: 8)).foregroundStyle(.secondary)
                context.draw(text, at: CGPoint(x: 4, y: y + 2), anchor: .topLeading)
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
                    if band.peakDB > minDB {
                        let ph = barHeight(band.peakDB, size: size)
                        var peak = Path(CGRect(x: x + 1, y: size.height - ph, width: slot - 2, height: 1.5))
                        context.fill(peak, with: .color(.primary.opacity(0.4)))
                    }
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

/// Тональный баланс в стиле iZotope Tonal Balance Control:
/// кривая текущего баланса поверх целевой зоны референса.
/// Отображается для сводного канала шины, а не на каждый канал.
struct TonalBalanceChart: View {
    let spectrum: [SpectrumPoint]
    let sampleRate: Float

    private let spanDB: Float = 40  // окно отображения ±20 дБ вокруг среднего

    var body: some View {
        let analyzer = InstrumentBalanceAnalyzer(spectrum: spectrum, sampleRate: sampleRate)
        let balances = analyzer.balances()

        Canvas { context, size in
            guard !balances.isEmpty, analyzer.hasSignal else {
                let text = Text("нет сигнала").font(.system(size: 9)).foregroundStyle(.tertiary)
                context.draw(text, at: CGPoint(x: size.width / 2, y: size.height / 2))
                return
            }

            // Среднее отклонение — центр графика.
            let deviations = balances.map { $0.deviationDB }
            let mean = deviations.reduce(0, +) / Float(deviations.count)

            // Целевая зона (референс = 0, допуски ±4 дБ).
            let zeroY = yPos(mean, size: size)
            let upperY = yPos(mean - 4, size: size)
            let lowerY = yPos(mean + 4, size: size)

            // Зона допуска
            var zone = Path(CGRect(x: 0, y: upperY, width: size.width, height: lowerY - upperY))
            context.fill(zone, with: .color(.green.opacity(0.12)))

            // Линия референса
            var refLine = Path()
            refLine.move(to: CGPoint(x: 0, y: zeroY))
            refLine.addLine(to: CGPoint(x: size.width, y: zeroY))
            context.stroke(refLine, with: .color(.green.opacity(0.5)), lineWidth: 1)

            // Кривая баланса
            let slot = size.width / CGFloat(max(balances.count, 1))
            var path = Path()
            for (i, balance) in balances.enumerated() {
                let x = CGFloat(i) * slot + slot / 2
                let y = yPos(balance.deviationDB, size: size)
                if i == 0 {
                    path.move(to: CGPoint(x: x, y: y))
                } else {
                    path.addLine(to: CGPoint(x: x, y: y))
                }
            }
            context.stroke(path, with: .color(.accentColor), style: StrokeStyle(lineWidth: 2, lineJoin: .round))

            // Точки выхода за допуск — красным.
            for (i, balance) in balances.enumerated() where abs(balance.deviationDB) > 4 {
                let x = CGFloat(i) * slot + slot / 2
                let y = yPos(balance.deviationDB, size: size)
                let rect = CGRect(x: x - 3, y: y - 3, width: 6, height: 6)
                context.fill(Path(ellipseIn: rect), with: .color(balance.deviationDB > 0 ? .red : .orange))
            }

            // Подписи полос внизу
            for (i, balance) in balances.enumerated() where i % 2 == 0 {
                let x = CGFloat(i) * slot + slot / 2
                let text = Text(balance.band.rawName).font(.system(size: 7)).foregroundStyle(.secondary)
                context.draw(text, at: CGPoint(x: x, y: size.height - 7))
            }
        }
        .background(Color.black.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func yPos(_ db: Float, size: CGSize) -> CGFloat {
        let t = (db + spanDB / 2) / spanDB
        return size.height * (1 - CGFloat(max(0, min(1, t)))) * 0.92 + size.height * 0.04
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