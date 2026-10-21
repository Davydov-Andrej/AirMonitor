import SwiftUI
import yaCore

/// Баланс микса: по каждой шине, по каждому каналу — отклонение энергии
/// в инструментальных полосах от референсной кривой.
struct BalanceView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Баланс микса по частотным полосам")
                .font(.title2)
            Text("Отклонение энергии от референсной кривой, нормализованное по уровню сигнала. >0 — полоса перегружена, <0 — утонула.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if model.snapshot.buses.isEmpty {
                ContentUnavailableView("Нет данных", systemImage: "waveform", description: Text("Запустите захват и выберите каналы"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 16) {
                        ForEach(model.snapshot.buses) { bus in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(bus.name)
                                    .font(.headline)
                                HStack(alignment: .top, spacing: 12) {
                                    ForEach(bus.displayChannels) { channel in
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(channel.label)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                            BalancePane(channel: channel, sampleRate: Float(bus.sampleRate))
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }
                            }
                            .padding()
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
                        }
                    }
                }
            }
        }
        .padding()
    }
}

/// Панель одной шины/канала: полосы отклонений.
struct BalancePane: View {
    let channel: ChannelSnapshot
    let sampleRate: Float

    var body: some View {
        let balances = InstrumentBalanceAnalyzer(
            spectrum: channel.spectrum,
            sampleRate: sampleRate
        ).balances()

        VStack(spacing: 6) {
            ForEach(balances) { balance in
                BalanceRow(balance: balance)
            }
        }
    }
}

struct BalanceRow: View {
    let balance: InstrumentBalance

    var body: some View {
        HStack(spacing: 10) {
            Text(balance.band.localizedName)
                .font(.caption)
                .frame(width: 180, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(Color.gray.opacity(0.2))
                    Rectangle()
                        .fill(Color.blue.opacity(0.25))
                        .frame(width: geo.size.width / 2)
                    let frac = deviationFraction
                    Capsule()
                        .fill(deviationColor)
                        .frame(width: max(4, abs(frac) * geo.size.width / 2), height: 12)
                        .offset(x: frac >= 0
                                ? geo.size.width / 2
                                : geo.size.width / 2 - abs(frac) * geo.size.width / 2)
                }
            }
            .frame(height: 12)
            Text(String(format: "%+.1f dB", balance.deviationDB))
                .font(.system(.caption, design: .monospaced))
                .frame(width: 60, alignment: .trailing)
        }
    }

    private var deviationColor: Color {
        if balance.deviationDB > 3 { return .red }
        if balance.deviationDB < -3 { return .orange }
        return .green
    }

    private var deviationFraction: CGFloat {
        let clamped = max(Float(-1), min(1, balance.deviationDB / 12))
        return CGFloat(clamped)
    }
}

extension InstrumentBalance: Identifiable {
    public var id: String { band.rawName }
}