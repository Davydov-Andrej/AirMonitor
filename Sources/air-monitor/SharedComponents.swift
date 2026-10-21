import SwiftUI

/// Горизонтальный VU-метр.
struct VUMeterView: View {
    let valueDB: Float
    let peakDB: Float

    private let minDB: Float = -60
    private let maxDB: Float = 6

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Color.black.opacity(0.12))
                HStack(spacing: 0) {
                    Color.green.frame(width: width * 0.6)
                    Color.yellow.frame(width: width * 0.25)
                    Color.red.frame(width: width * 0.15)
                }
                .clipShape(Capsule())
                .opacity(0.5)
                Capsule()
                    .fill(fillColor)
                    .frame(width: levelFraction * width)
                Rectangle()
                    .fill(Color.black)
                    .frame(width: 2, height: geo.size.height * 0.7)
                    .offset(x: peakFraction * width)
            }
        }
        .frame(height: 12)
    }

    private var levelFraction: CGFloat {
        let clamped = max(minDB, min(valueDB, maxDB))
        return CGFloat((clamped - minDB) / (maxDB - minDB))
    }

    private var peakFraction: CGFloat {
        let clamped = max(minDB, min(peakDB, maxDB))
        return CGFloat((clamped - minDB) / (maxDB - minDB))
    }

    private var fillColor: Color {
        if valueDB > 0 { return .red }
        if valueDB > -6 { return .yellow }
        return .green
    }
}