import Foundation
import AppKit
import CoreGraphics
import yaCore

/// Отрисовщики графиков на CGContext (вне SwiftUI-обновлений).
/// Вызываются из CADisplayLink (LiveCanvas) — каждые ~16 мс, независимо от
/// активности окна. Данные захватываются при создании drawer'а.
enum CGChart {

    // MARK: - Спектр (АЧХ)

    /// Статичная сетка+подписи: переиспользуется между кадрами без пересчёта.
    static func drawGrid(ctx: CGContext, size: CGSize,
                         dbLabels: [Int], freqLabels: [(Float, String)],
                         xPos: (Float, CGFloat) -> CGFloat,
                         yPos: (Float, CGFloat) -> CGFloat) {
        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 8),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        for db in dbLabels {
            let y = yPos(Float(db), size.height)
            let path = CGMutablePath()
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: size.width, y: y))
            stroke(ctx, path, color: .separatorColor, width: 0.5, alpha: 0.15)
            drawText(ctx: ctx, NSAttributedString(string: "\(db)", attributes: labelAttrs),
                     at: CGPoint(x: 4, y: y + 1), height: size.height)
        }
        for (freq, label) in freqLabels {
            let fx = xPos(freq, size.width)
            let path = CGMutablePath()
            path.move(to: CGPoint(x: fx, y: 0))
            path.addLine(to: CGPoint(x: fx, y: size.height))
            stroke(ctx, path, color: .separatorColor, width: 0.5, alpha: 0.12)
            let text = NSAttributedString(string: label, attributes: labelAttrs)
            let textX = max(2, min(size.width - text.size().width - 2, fx - text.size().width / 2))
            drawText(ctx: ctx, text, at: CGPoint(x: textX, y: size.height - 12), height: size.height)
        }
    }

    /// Статичный фон спектра: сетка + подписи (кэшируется LiveCanvas).
    static func spectrumBackground() -> (CGContext, CGSize) -> Void {
        let dbLabels = [10, -2, -14, -26, -38, -50, -62, -74, -86]
        let freqLabels: [(Float, String)] = [
            (63, "63"), (250, "250"), (1000, "1k"), (4000, "4k"), (16000, "16k")
        ]
        let minDB: Float = -90
        let maxDB: Float = 10
        func xPos(_ freq: Float, width: CGFloat) -> CGFloat {
            let t = (log10f(max(freq, 20)) - log10f(20)) / (log10f(20000) - log10f(20))
            return CGFloat(max(0, min(1, t))) * width
        }
        func yPos(_ db: Float, height: CGFloat) -> CGFloat {
            let t = (db - minDB) / (maxDB - minDB)
            return height * (1 - CGFloat(max(0, min(1, t))))
        }
        return { ctx, size in
            drawGrid(ctx: ctx, size: size, dbLabels: dbLabels, freqLabels: freqLabels,
                     xPos: xPos, yPos: yPos)
            // Подпись оси дБ
            let unitAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 7),
                .foregroundColor: NSColor.tertiaryLabelColor,
            ]
            drawText(ctx: ctx, NSAttributedString(string: "дБFS", attributes: unitAttrs),
                     at: CGPoint(x: 4, y: 2), height: size.height)
        }
    }

    /// Статичный фон громкости: сетка LU + целевая линия (кэшируется LiveCanvas).
    static func loudnessBackground() -> (CGContext, CGSize) -> Void {
        let minLU: Float = -40
        let maxLU: Float = 0
        let target: Float = -23
        func yPos(_ lu: Float, height: CGFloat) -> CGFloat {
            height * (1 - CGFloat((lu - minLU) / (maxLU - minLU)))
        }
        return { ctx, size in
            let labelAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 8),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
            var lu = minLU + 10
            while lu < maxLU {
                let y = yPos(lu, height: size.height)
                let path = CGMutablePath()
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
                stroke(ctx, path, color: .separatorColor, width: 0.5, alpha: 0.15)
                drawText(ctx: ctx, NSAttributedString(string: "\(Int(lu)) LUFS", attributes: labelAttrs),
                         at: CGPoint(x: 3, y: y + 1), height: size.height)
                lu += 10
            }
            // Горизонтальная ось: возраст данных, справа «сейчас».
            let windowSeconds = 30.0
            let timeLabels: [(Double, String)] = [
                (25, "−25 с"), (20, "−20 с"), (15, "−15 с"),
                (10, "−10 с"), (5, "−5 с"), (0, "сейчас")
            ]
            for (sec, label) in timeLabels {
                let x = size.width * CGFloat((windowSeconds - sec) / windowSeconds)
                let tick = CGMutablePath()
                tick.move(to: CGPoint(x: x, y: 0))
                tick.addLine(to: CGPoint(x: x, y: size.height))
                stroke(ctx, tick, color: .separatorColor, width: 0.5, alpha: 0.1)
                let text = NSAttributedString(string: label, attributes: labelAttrs)
                let textX = max(2, min(size.width - text.size().width - 2, x - text.size().width / 2))
                drawText(ctx: ctx, text, at: CGPoint(x: textX, y: size.height - 12), height: size.height)
            }
            let ty = yPos(target, height: size.height)
            let targetPath = CGMutablePath()
            targetPath.move(to: CGPoint(x: 0, y: ty))
            targetPath.addLine(to: CGPoint(x: size.width, y: ty))
            stroke(ctx, targetPath, color: .systemGreen, width: 1, alpha: 0.45, dash: [4, 3])
            // Это ориентир на временном графике M/S; цель EBU R 128
            // относится к Integrated loudness, а не к каждому мгновению.
            let reference = NSAttributedString(string: "ориентир −23 LUFS", attributes: labelAttrs)
            drawText(ctx: ctx, reference,
                     at: CGPoint(x: max(3, size.width - reference.size().width - 4), y: ty + 2),
                     height: size.height)
        }
    }

    static func spectrumDrawer(holder: BusSnapshotHolder, isDark: Bool = false) -> (CGContext, CGSize, CGPoint?, String) -> Void {
        // Данные резолвятся КАЖДЫЙ кадр: holder живой, snapshot обновляется DSP-потоком.
        let drawer = spectrumDrawerBuilder(isDark: isDark)
        return { ctx, size, _, _ in
            let snapshot = holder.snapshot
            let channel = snapshot?.mono ?? snapshot?.channels.first
            drawer(ctx, size, channel?.fineCurve ?? [], channel?.rtaBands ?? [])
        }
    }

    static func spectrumDrawerBuilder(isDark: Bool = false) -> (CGContext, CGSize, [SpectrumPoint], [RTABand]) -> Void {
        let minDB: Float = -90
        let maxDB: Float = 10
        func xPos(_ freq: Float, width: CGFloat) -> CGFloat {
            let t = (log10f(max(freq, 20)) - log10f(20)) / (log10f(20000) - log10f(20))
            return CGFloat(max(0, min(1, t))) * width
        }
        func yPos(_ db: Float, height: CGFloat) -> CGFloat {
            let t = (db - minDB) / (maxDB - minDB)
            return height * (1 - CGFloat(max(0, min(1, t))))
        }

        return { ctx, size, fine, bands in
            // Октавные полосы + пик-холд
            if !bands.isEmpty {
                let slot = size.width / CGFloat(bands.count)
                for band in bands {
                    let x = CGFloat(band.id) * slot
                    let h = yPos(band.levelDB, height: size.height)
                    let rect = CGRect(x: x + 1, y: 0, width: slot - 2, height: h)
                    fill(ctx, CGPath(rect: rect, transform: nil), color: .controlAccentColor, alpha: isDark ? 0.24 : 0.18)
                    if band.peakDB > minDB {
                        let ph = yPos(band.peakDB, height: size.height)
                        let peak = CGRect(x: x + 1, y: ph, width: slot - 2, height: 1.5)
                        fill(ctx, CGPath(rect: peak, transform: nil), color: .labelColor, alpha: isDark ? 0.48 : 0.4)
                    }
                }
            }

            // Тонкая кривая
            if fine.count > 1 {
                let path = CGMutablePath()
                for (i, point) in fine.enumerated() {
                    let p = CGPoint(x: xPos(point.frequency, width: size.width),
                                    y: yPos(point.magnitudeDB, height: size.height))
                    if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
                }
                stroke(ctx, path, color: .controlAccentColor, width: 1.6, roundJoin: true)
            }
        }
    }

    // MARK: - Громкость (история)

    static func loudnessDrawer(holder: BusSnapshotHolder, isStereo: Bool, isDark: Bool = false) -> (CGContext, CGSize, CGPoint?, String) -> Void {
        let inner = loudnessDrawerBuilder(isDark: isDark)
        return { ctx, size, _, _ in
            let snapshot = holder.snapshot
            let mono = isStereo ? (snapshot?.mono ?? snapshot?.channels.first) : snapshot?.channels.first
            let history = mono?.loudnessHistory ?? []
            inner(ctx, size,
                  history,
                  isStereo ? snapshot?.channels.first?.loudnessHistory ?? [] : [],
                  isStereo ? snapshot?.channels.dropFirst().first?.loudnessHistory ?? [] : [])
        }
    }

    static func loudnessDrawerBuilder(isDark: Bool = false) -> (CGContext, CGSize, [LoudnessMeter.HistoryPoint], [LoudnessMeter.HistoryPoint], [LoudnessMeter.HistoryPoint]) -> Void {
        let minLU: Float = -40
        let maxLU: Float = 0
        let stepHz = 5.0 // LoudnessMeter adds one history point every 200 ms.

        func yPos(_ lu: Float, height: CGFloat) -> CGFloat {
            let floorLU = minLU + 1
            let clamped = lu.isFinite ? max(minLU, min(maxLU, lu)) : floorLU
            return height * (1 - CGFloat((clamped - minLU) / (maxLU - minLU)))
        }

        func seriesPath(points: [LoudnessMeter.HistoryPoint], capacity: Int, keyPath: (LoudnessMeter.HistoryPoint) -> Float, width: CGFloat, height: CGFloat, closeToBottom: Bool) -> CGPath {
            let path = CGMutablePath()
            let stepX = width / CGFloat(max(capacity - 1, 1))
            let offset = CGFloat(capacity - points.count)
            var started = false
            for (i, p) in points.enumerated() {
                let x = (offset + CGFloat(i)) * stepX
                let y = yPos(keyPath(p), height: height)
                if closeToBottom && !started {
                    path.move(to: CGPoint(x: x, y: height))
                    path.addLine(to: CGPoint(x: x, y: y))
                    started = true
                } else if !started {
                    path.move(to: CGPoint(x: x, y: y))
                    started = true
                } else {
                    path.addLine(to: CGPoint(x: x, y: y))
                }
            }
            if closeToBottom, !points.isEmpty {
                path.addLine(to: CGPoint(x: (offset + CGFloat(points.count - 1)) * stepX, y: height))
                path.closeSubpath()
            }
            return path
        }

        return { ctx, size, monoHistory, leftHistory, rightHistory in
            let windowSeconds: Double = 30
            let capacity = Int(windowSeconds * stepHz)
            let isStereo = !leftHistory.isEmpty || !rightHistory.isEmpty

            // Стерео: заливка по сумме + 3 линии. Моно: заливка + линия.
            if isStereo {
                let fillPath = seriesPath(points: monoHistory, capacity: capacity, keyPath: { $0.shortTerm },
                                          width: size.width, height: size.height, closeToBottom: true)
                fill(ctx, fillPath, color: .systemBlue, alpha: isDark ? 0.23 : 0.16)
                let left = seriesPath(points: leftHistory, capacity: capacity, keyPath: { $0.momentary },
                                      width: size.width, height: size.height, closeToBottom: false)
                stroke(ctx, left, color: .systemRed, width: 1.2, roundJoin: true)
                let right = seriesPath(points: rightHistory, capacity: capacity, keyPath: { $0.momentary },
                                       width: size.width, height: size.height, closeToBottom: false)
                stroke(ctx, right, color: .systemBlue, width: 1.2, roundJoin: true)
                let mono = seriesPath(points: monoHistory, capacity: capacity, keyPath: { $0.momentary },
                                      width: size.width, height: size.height, closeToBottom: false)
                stroke(ctx, mono, color: .labelColor, width: 2, alpha: 0.55, roundJoin: true)
            } else {
                let fillPath = seriesPath(points: monoHistory, capacity: capacity, keyPath: { $0.shortTerm },
                                          width: size.width, height: size.height, closeToBottom: true)
                fill(ctx, fillPath, color: .systemBlue, alpha: isDark ? 0.23 : 0.16)
                let line = seriesPath(points: monoHistory, capacity: capacity, keyPath: { $0.momentary },
                                      width: size.width, height: size.height, closeToBottom: false)
                stroke(ctx, line, color: .systemBlue, width: 1.2, roundJoin: true)
            }
        }
    }

    // MARK: - Тональный баланс

    static func balanceDrawer(holder: BusSnapshotHolder) -> (CGContext, CGSize, CGPoint?, String) -> Void {
        let inner = balanceDrawerBuilder()
        return { ctx, size, _, _ in
            let snapshot = holder.snapshot
            let channel = snapshot?.mono ?? snapshot?.channels.first
            inner(ctx, size, channel?.tonalBalances ?? [], channel?.tonalBalances.isEmpty == false)
        }
    }

    static func balanceBackground() -> (CGContext, CGSize) -> Void {
        let labels = InstrumentBand.allCases.map(\.rawName)
        return { ctx, size in
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 7),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
            let slot = size.width / CGFloat(max(labels.count, 1))
            for (i, label) in labels.enumerated() {
                let text = NSAttributedString(string: label, attributes: attrs)
                let width = text.size().width
                drawText(ctx: ctx, text,
                         at: CGPoint(x: CGFloat(i) * slot + (slot - width) / 2, y: 2),
                         height: size.height)
            }
            for (db, label) in [(20, "+20"), (0, "0"), (-20, "−20")] {
                let y = size.height * (1 - CGFloat(db + 20) / 40) * 0.92 + size.height * 0.04
                let path = CGMutablePath()
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
                stroke(ctx, path, color: .separatorColor, width: 0.5, alpha: db == 0 ? 0.18 : 0.1)
                drawText(ctx: ctx, NSAttributedString(string: "\(label) дБ", attributes: attrs),
                         at: CGPoint(x: 3, y: y + 1), height: size.height)
            }
        }
    }

    static func balanceDrawerBuilder() -> (CGContext, CGSize, [InstrumentBalance], Bool) -> Void {
        let spanDB: Float = 40

        func yPos(_ db: Float, height: CGFloat) -> CGFloat {
            let t = (db + spanDB / 2) / spanDB
            return height * (1 - CGFloat(max(0, min(1, t)))) * 0.92 + height * 0.04
        }

        return { ctx, size, balances, hasSignal in
            guard !balances.isEmpty, hasSignal else {
                return
            }

            // Отклонения уже рассчитаны относительно референса, поэтому
            // нулевая линия и допуск ±4 дБ должны быть центрированы на 0.
            let upperY = yPos(4, height: size.height)
            let lowerY = yPos(-4, height: size.height)
            let zone = CGRect(x: 0, y: upperY, width: size.width, height: lowerY - upperY)
            fill(ctx, CGPath(rect: zone, transform: nil), color: .systemGreen, alpha: 0.16)

            let zeroY = yPos(0, height: size.height)
            let refLine = CGMutablePath()
            refLine.move(to: CGPoint(x: 0, y: zeroY))
            refLine.addLine(to: CGPoint(x: size.width, y: zeroY))
            stroke(ctx, refLine, color: .systemGreen, width: 1, alpha: 0.5)

            // Кривая
            let slot = size.width / CGFloat(max(balances.count, 1))
            let path = CGMutablePath()
            for (i, balance) in balances.enumerated() {
                let p = CGPoint(x: CGFloat(i) * slot + slot / 2,
                                y: yPos(balance.deviationDB, height: size.height))
                if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
            }
            stroke(ctx, path, color: .controlAccentColor, width: 2, roundJoin: true)

            // Точки за допуском
            for (i, balance) in balances.enumerated() where abs(balance.deviationDB) > 4 {
                let x = CGFloat(i) * slot + slot / 2
                let y = yPos(balance.deviationDB, height: size.height)
                let rect = CGRect(x: x - 3, y: y - 3, width: 6, height: 6)
                fill(ctx, CGPath(ellipseIn: rect, transform: nil),
                     color: balance.deviationDB > 0 ? .systemRed : .systemOrange, alpha: 1)
            }

        }
    }

    // MARK: - Примитивы

    /// Текст: drawer получает координаты сверху вниз; локально переворачиваем
    /// только глифы, сохраняя исходную позицию подписи.
    /// Текст на CGContext через CoreText: работает на любом потоке,
    /// без NSGraphicsContext (которого нет на display-link битмапе).
    /// Координаты: SwiftUI-стиль (y сверху) — рисуем с локальным флипом.
    private static func drawText(ctx: CGContext, _ str: NSAttributedString, at point: CGPoint, height _: CGFloat) {
        let line = CTLineCreateWithAttributedString(str)
        ctx.saveGState()
        ctx.translateBy(x: point.x, y: point.y)
        ctx.scaleBy(x: 1, y: -1)
        ctx.textPosition = CGPoint.zero
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }



    private static func stroke(_ ctx: CGContext, _ path: CGPath, color: NSColor,
                               width: CGFloat, alpha: CGFloat = 1, dash: [CGFloat]? = nil, roundJoin: Bool = false) {
        ctx.saveGState()
        ctx.setStrokeColor(color.withAlphaComponent(alpha).cgColor)
        ctx.setLineWidth(width)
        if roundJoin { ctx.setLineJoin(.round) }
        if let dash { ctx.setLineDash(phase: 0, lengths: dash) }
        ctx.addPath(path)
        ctx.strokePath()
        ctx.restoreGState()
    }

    private static func fill(_ ctx: CGContext, _ path: CGPath, color: NSColor, alpha: CGFloat = 1) {
        ctx.saveGState()
        ctx.setFillColor(color.withAlphaComponent(alpha).cgColor)
        ctx.addPath(path)
        ctx.fillPath()
        ctx.restoreGState()
    }
}
