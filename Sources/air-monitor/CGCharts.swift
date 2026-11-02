import Foundation
import AppKit
import CoreGraphics
import yaCore

/// Отрисовщики графиков на CGContext (вне SwiftUI-обновлений).
/// Вызываются из CADisplayLink (LiveCanvas) — каждые ~16 мс, независимо от
/// активности окна. Данные захватываются при создании drawer'а.
enum CGChart {

    // MARK: - Спектр (АЧХ)

    static func spectrumDrawer(holder: BusSnapshotHolder) -> (CGContext, CGSize) -> Void {
        let snapshot = holder.snapshot
        let channel = snapshot?.mono ?? snapshot?.channels.first
        return spectrumDrawer(fine: channel?.fineCurve ?? [], bands: channel?.rtaBands ?? [])
    }

    static func spectrumDrawer(fine: [SpectrumPoint], bands: [RTABand]) -> (CGContext, CGSize) -> Void {
        let minDB: Float = -90
        let maxDB: Float = 10
        let dbLabels = [10, -2, -14, -26, -38, -50, -62, -74, -86]
        let freqLabels: [(Float, String)] = [
            (63, "63"), (250, "250"), (1000, "1k"), (4000, "4k"), (16000, "16k")
        ]

        func xPos(_ freq: Float, width: CGFloat) -> CGFloat {
            let t = (log10f(max(freq, 20)) - log10f(20)) / (log10f(20000) - log10f(20))
            return CGFloat(max(0, min(1, t))) * width
        }
        func yPos(_ db: Float, height: CGFloat) -> CGFloat {
            let t = (db - minDB) / (maxDB - minDB)
            return height * (1 - CGFloat(max(0, min(1, t))))
        }

        return { ctx, size in
            let labelAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 8),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]

            // Сетка по Y + подписи дБ
            for db in dbLabels {
                let y = yPos(Float(db), height: size.height)
                let path = CGMutablePath()
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
                stroke(ctx, path, color: .gray, width: 0.5, alpha: 0.15)
                NSAttributedString(string: "\(db)", attributes: labelAttrs)
                    .draw(at: CGPoint(x: 4, y: y + 1))
            }

            // Тики частот + подписи
            for (freq, label) in freqLabels {
                let fx = xPos(freq, width: size.width)
                let path = CGMutablePath()
                path.move(to: CGPoint(x: fx, y: 0))
                path.addLine(to: CGPoint(x: fx, y: size.height))
                stroke(ctx, path, color: .gray, width: 0.5, alpha: 0.12)
                let str = NSAttributedString(string: label, attributes: labelAttrs)
                str.draw(at: CGPoint(x: fx + 3, y: size.height - 12))
            }

            // Октавные полосы + пик-холд
            if !bands.isEmpty {
                let slot = size.width / CGFloat(bands.count)
                for band in bands {
                    let x = CGFloat(band.id) * slot
                    let h = yPos(band.levelDB, height: size.height)
                    let rect = CGRect(x: x + 1, y: 0, width: slot - 2, height: h)
                    fill(ctx, CGPath(rect: rect, transform: nil), color: .controlAccentColor, alpha: 0.18)
                    if band.peakDB > minDB {
                        let ph = yPos(band.peakDB, height: size.height)
                        let peak = CGRect(x: x + 1, y: ph, width: slot - 2, height: 1.5)
                        fill(ctx, CGPath(rect: peak, transform: nil), color: .labelColor, alpha: 0.4)
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

    static func loudnessDrawer(holder: BusSnapshotHolder, isStereo: Bool) -> (CGContext, CGSize) -> Void {
        let snapshot = holder.snapshot
        let mono = isStereo ? (snapshot?.mono ?? snapshot?.channels.first) : snapshot?.channels.first
        return loudnessDrawer(
            monoHistory: mono?.loudnessHistory ?? [],
            leftHistory: isStereo ? snapshot?.channels.first?.loudnessHistory ?? [] : [],
            rightHistory: isStereo ? snapshot?.channels.dropFirst().first?.loudnessHistory ?? [] : [],
            target: -23,
            windowSeconds: 15
        )
    }

    static func loudnessDrawer(
        monoHistory: [LoudnessMeter.HistoryPoint],
        leftHistory: [LoudnessMeter.HistoryPoint],
        rightHistory: [LoudnessMeter.HistoryPoint],
        target: Float,
        windowSeconds: Double
    ) -> (CGContext, CGSize) -> Void {
        let minLU: Float = -40
        let maxLU: Float = 0
        let stepHz = 10.0

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
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: y))
                    started = true
                } else if !started {
                    path.move(to: CGPoint(x: x, y: y))
                    started = true
                } else {
                    path.addLine(to: CGPoint(x: x, y: y))
                }
            }
            if closeToBottom, let last = points.last {
                path.addLine(to: CGPoint(x: (offset + CGFloat(points.count - 1)) * stepX, y: 0))
                path.closeSubpath()
            }
            return path
        }

        return { ctx, size in
            let labelAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 8),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]

            // Сетка + подписи LU
            var lu = minLU + 10
            while lu < maxLU {
                let y = yPos(lu, height: size.height)
                let path = CGMutablePath()
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
                stroke(ctx, path, color: .gray, width: 0.5, alpha: 0.15)
                NSAttributedString(string: "\(Int(lu))", attributes: labelAttrs)
                    .draw(at: CGPoint(x: 3, y: y + 1))
                lu += 10
            }

            // Целевая линия
            let ty = yPos(target, height: size.height)
            let targetPath = CGMutablePath()
            targetPath.move(to: CGPoint(x: 0, y: ty))
            targetPath.addLine(to: CGPoint(x: size.width, y: ty))
            stroke(ctx, targetPath, color: .systemGreen, width: 1, alpha: 0.45, dash: [4, 3])

            let capacity = Int(windowSeconds * stepHz)
            let isStereo = !leftHistory.isEmpty || !rightHistory.isEmpty

            // Стерео: заливка по сумме + 3 линии. Моно: заливка + линия.
            if isStereo {
                let fillPath = seriesPath(points: monoHistory, capacity: capacity, keyPath: { $0.shortTerm },
                                          width: size.width, height: size.height, closeToBottom: true)
                fill(ctx, fillPath, color: .systemBlue, alpha: 0.16)
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
                fill(ctx, fillPath, color: .systemBlue, alpha: 0.16)
                let line = seriesPath(points: monoHistory, capacity: capacity, keyPath: { $0.momentary },
                                      width: size.width, height: size.height, closeToBottom: false)
                stroke(ctx, line, color: .systemBlue, width: 1.2, roundJoin: true)
            }
        }
    }

    // MARK: - Тональный баланс

    static func balanceDrawer(holder: BusSnapshotHolder) -> (CGContext, CGSize) -> Void {
        let snapshot = holder.snapshot
        let channel = snapshot?.mono ?? snapshot?.channels.first
        return balanceDrawer(
            balances: channel?.tonalBalances ?? [],
            hasSignal: channel?.tonalBalances.isEmpty == false
        )
    }

    static func balanceDrawer(balances: [InstrumentBalance], hasSignal: Bool) -> (CGContext, CGSize) -> Void {
        let spanDB: Float = 40

        func yPos(_ db: Float, height: CGFloat) -> CGFloat {
            let t = (db + spanDB / 2) / spanDB
            return height * (1 - CGFloat(max(0, min(1, t)))) * 0.92 + height * 0.04
        }

        return { ctx, size in
            guard !balances.isEmpty, hasSignal else {
                ChartCG.drawCenteredText(ctx, "нет сигнала", in: size)
                return
            }

            let deviations = balances.map { $0.deviationDB }
            let mean = deviations.reduce(0, +) / Float(deviations.count)

            // Целевая зона ±4 дБ
            let upperY = yPos(mean - 4, height: size.height)
            let lowerY = yPos(mean + 4, height: size.height)
            let zone = CGRect(x: 0, y: upperY, width: size.width, height: lowerY - upperY)
            fill(ctx, CGPath(rect: zone, transform: nil), color: .systemGreen, alpha: 0.12)

            let zeroY = yPos(mean, height: size.height)
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

            // Подписи полос
            let labelAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 7),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
            for (i, balance) in balances.enumerated() {
                let x = CGFloat(i) * slot + slot / 2
                let str = NSAttributedString(string: balance.band.rawName, attributes: labelAttrs)
                let b = str.boundingRect(with: size, options: [.usesLineFragmentOrigin])
                str.draw(at: CGPoint(x: x - b.width / 2, y: 2))
            }
        }
    }

    // MARK: - Примитивы

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
