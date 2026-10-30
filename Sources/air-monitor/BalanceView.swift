import SwiftUI
import yaCore

/// Тональный баланс: по каждой шине — отклонения полос от референса + подсказки.
struct BalanceView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Тональный баланс")
                    .font(.title2)
                Spacer()
                Text("Отклонения от референса по полосам")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if model.snapshot.buses.isEmpty {
                ContentUnavailableView("Нет данных", systemImage: "waveform", description: Text("Запустите захват и выберите каналы"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 16) {
                        ForEach(model.snapshot.buses) { bus in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text(bus.name)
                                        .font(.headline)
                                    Spacer()
                                    if let correlation = bus.correlation {
                                        Text(String(format: "Корр. L/R: %.2f", correlation))
                                            .font(.caption.monospacedDigit())
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                HStack(alignment: .top, spacing: 16) {
                                    ForEach(bus.displayChannels) { channel in
                                        BalancePane(channel: channel, sampleRate: Float(bus.sampleRate))
                                    }
                                }
                            }
                            .padding()
                            .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
                        }
                    }
                }
            }
        }
        .padding()
    }
}

struct BalancePane: View {
    let channel: ChannelSnapshot
    let sampleRate: Float

    var body: some View {
        let analyzer = InstrumentBalanceAnalyzer(
            spectrum: channel.spectrum,
            sampleRate: sampleRate
        )
        let balances = analyzer.balances()

        VStack(alignment: .leading, spacing: 8) {
            Text(channel.label)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)

            // Вертикальные столбики: вверх = перегруз, вниз = недостаток.
            HStack(alignment: .bottom, spacing: 6) {
                ForEach(balances) { balance in
                    BalanceBar(balance: balance)
                }
            }
            .frame(height: 120)

            // Подсказки
            if !analyzer.tips.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(analyzer.tips, id: \.self) { tip in
                        HStack(alignment: .top, spacing: 4) {
                            Image(systemName: "lightbulb")
                                .font(.caption2)
                                .foregroundStyle(.yellow)
                            Text(tip)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Один столбик баланса: 0 дБ = референс (середина), вверх = перегруз.
struct BalanceBar: View {
    let balance: InstrumentBalance

    var body: some View {
        GeometryReader { geo in
            let mid = geo.size.height / 2
            let t = max(-1, min(1, balance.deviationDB / 12))
            let barH = CGFloat(abs(t)) * mid
            let y = t >= 0 ? mid - barH : mid
            VStack(spacing: 0) {
                ZStack(alignment: .center) {
                    Rectangle()
                        .fill(Color.gray.opacity(0.15))
                    Rectangle()
                        .fill(Color.primary.opacity(0.08))
                        .frame(height: 1)
                        .offset(y: 0)
                    Rectangle()
                        .fill(color)
                        .frame(height: max(2, barH))
                        .offset(y: t >= 0 ? -(barH / 2) : (barH / 2))
                }
            }
            .frame(height: geo.size.height)
            .overlay(alignment: .bottom) {
                EmptyView()
            }
        }
        .frame(width: 26)
        .help("\(balance.band.localizedName): \(String(format: "%+.1f", balance.deviationDB)) дБ")
    }

    private var color: Color {
        if balance.deviationDB > 6 { return .red }
        if balance.deviationDB > 3 { return .orange }
        if balance.deviationDB < -6 { return .blue }
        if balance.deviationDB < -3 { return .cyan }
        return .green
    }
}

extension InstrumentBalance: Identifiable {
    public var id: String { band.rawName }
}