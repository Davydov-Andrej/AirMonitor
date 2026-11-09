import SwiftUI
import yaCore

/// Монитор: метры + история громкости по всем шинам.
/// Порядок шин — как на дашборде (model.buses), данные — из холдеров.
struct MonitorView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Уровни и динамика")
                    .font(.title2)
                Spacer()
                // Окно усреднения метрики S (short-term громкости).
                Menu {
                    Picker("Окно S", selection: Binding(
                        get: { model.rtaSettings.shortTermSeconds },
                        set: { model.rtaSettings.shortTermSeconds = $0 }
                    )) {
                        Text("S: 0.4 с").tag(0.4)
                        Text("S: 1 с (по умолчанию)").tag(1.0)
                        Text("S: 2 с").tag(2.0)
                        Text("S: 3 с (стандарт EBU)").tag(3.0)
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label("Окно S: \(sWindowLabel)", systemImage: "timer")
                }
                // Сглаживание ГРАФИКА громкости (числа всегда точные по стандарту).
                Menu {
                    Picker("Сглаживание", selection: Binding(
                        get: { model.rtaSettings.loudnessSmoothing },
                        set: { model.rtaSettings.loudnessSmoothing = $0 }
                    )) {
                        // Значение — вес нового отсчёта при СПАДЕ (EMA):
                        // 1 = спад мгновенный (без сглаживания), 0.1 = длинный плавный хвост.
                        // Рост всегда мгновенный — пики видны сразу (как в Youlean).
                        Text("Выкл — спад мгновенный").tag(Float(1.0))
                        Text("Лёгкое (0.7)").tag(Float(0.7))
                        Text("Среднее (0.4)").tag(Float(0.4))
                        Text("Сильное (0.2)").tag(Float(0.2))
                        Text("Максимальное (0.1)").tag(Float(0.1))
                        Text("Экстра (0.05)").tag(Float(0.05))
                        Text("Экстра+ (0.02) — почти прямая").tag(Float(0.02))
                    }
                    .pickerStyle(.inline)

                Divider()

                // Сглаживание ЧИСЕЛ M/S (опционально; выкл = сырые значения).
                Picker("Числа", selection: Binding(
                    get: { model.rtaSettings.numberSmoothing },
                    set: { model.rtaSettings.numberSmoothing = $0 }
                )) {
                    Text("Выкл — точные значения (для сверки)").tag(Float(1.0))
                    Text("Лёгкое (0.7)").tag(Float(0.7))
                    Text("Плавные (0.4)").tag(Float(0.4))
                    Text("Сильное (0.25)").tag(Float(0.25))
                    Text("Как Youlean (0.15)").tag(Float(0.15))
                    Text("Очень сильное (0.1)").tag(Float(0.1))
                    Text("Экстра (0.05)").tag(Float(0.05))
                }
                .pickerStyle(.inline)
                .help("Сглаживание числовых значений M/S. Рост всегда мгновенный (пики видны сразу), спад плавный. Выключите для сверки с эталонными метрами.")

                Divider()

                // Калибровка: подгонка под эталонный метр (±дБ).
                Picker("LUFS-офсет", selection: Binding(
                    get: { model.lufsOffset },
                    set: { model.lufsOffset = $0 }
                )) {
                    Text("Калибровка: −1 дБ").tag(Float(-1))
                    Text("Калибровка: −0.5 дБ").tag(Float(-0.5))
                    Text("Калибровка: 0 (по стандарту)").tag(Float(0))
                    Text("Калибровка: +0.5 дБ").tag(Float(0.5))
                    Text("Калибровка: +1 дБ").tag(Float(1))
                }
                .pickerStyle(.inline)
                .help("Если значения устойчиво расходятся с эталонным метром (Youlean и др.), выберите компенсирующий офсет. Сохраняется между запусками.")
                } label: {
                    Label("Сглаживание: \(smoothingLabel)", systemImage: "circle.lefthalf.filled")
                }
            }
            if model.buses.isEmpty {
                ContentUnavailableView("Нет шин", systemImage: "waveform", description: Text("Добавьте шину на дашборде и запустите захват"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 14) {
                        ForEach(Array(model.buses.enumerated()), id: \.element.id) { index, bus in
                            MonitorBusRowContainer(
                                bus: bus,
                                holder: model.holder(for: bus),
                                onMoveUp: { model.moveBusUp(id: bus.id) },
                                onMoveDown: { model.moveBusDown(id: bus.id) },
                                canMoveUp: index > 0,
                                canMoveDown: index < model.buses.count - 1
                            )
                        }
                    }
                }
            }
        }
        .padding()
    }

    private var sWindowLabel: String {
        let v = model.rtaSettings.shortTermSeconds
        return v.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(v)) : String(format: "%.1f", v)
    }

    private var smoothingLabel: String {
        switch model.rtaSettings.loudnessSmoothing {
        case 0.95...: return "выкл"
        case 0.55..<0.95: return "лёгкое"
        case 0.3..<0.55: return "среднее"
        case 0.15..<0.3: return "сильное"
        case 0.07..<0.15: return "макс."
        default: return "экстра"
        }
    }
}

/// Изолированный контейнер: обновляется только при изменении снимка шины.
struct MonitorBusRowContainer: View {
    let bus: MonitorBus
    let holder: BusSnapshotHolder
    var onMoveUp: () -> Void = {}
    var onMoveDown: () -> Void = {}
    var canMoveUp: Bool = false
    var canMoveDown: Bool = false
    @EnvironmentObject var model: AppModel

    var body: some View {
        MonitorBusRow(
            busName: bus.config.name,
            busMode: bus.config.mode,
            holder: holder,
            isConnected: bus.isConnected,
            showHints: model.showMetricHints,
            onMoveUp: onMoveUp,
            onMoveDown: onMoveDown,
            canMoveUp: canMoveUp,
            canMoveDown: canMoveDown
        )
    }
}

struct MonitorBusRow: View {
    let busName: String
    let busMode: BusMode
    let holder: BusSnapshotHolder
    var isConnected: Bool = true
    var showHints: Bool = false
    var onMoveUp: () -> Void = {}
    var onMoveDown: () -> Void = {}
    var canMoveUp: Bool = false
    var canMoveDown: Bool = false

    var isStereo: Bool {
        if case .stereo = busMode { return true }
        return false
    }

    private var snapshot: BusSnapshot? { holder.snapshot }

    var summary: ChannelSnapshot? {
        guard let snapshot else { return nil }
        if isStereo { return snapshot.mono ?? snapshot.channels.first }
        return snapshot.channels.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                VStack(spacing: 2) {
                    Button(action: onMoveUp) {
                        Image(systemName: "chevron.up")
                            .font(.caption2)
                            .foregroundStyle(canMoveUp ? .primary : .tertiary)
                    }
                    .buttonStyle(.borderless)
                    .disabled(!canMoveUp)
                    Button(action: onMoveDown) {
                        Image(systemName: "chevron.down")
                            .font(.caption2)
                            .foregroundStyle(canMoveDown ? .primary : .tertiary)
                    }
                    .buttonStyle(.borderless)
                    .disabled(!canMoveDown)
                }

                Text(busName).font(.headline)
                Text(modeLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !isConnected {
                    Label("устройство отключено", systemImage: "cable.connector.slash")
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
                Spacer()
                if let correlation = snapshot?.correlation {
                    Text(String(format: "Корр. L/R: %.2f", correlation))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            TimelineView(.animation(minimumInterval: 0.05, paused: false)) { _ in
                HStack(alignment: .top, spacing: 14) {
                    if isStereo {
                        StereoMeterPair(
                            left: snapshot?.channels.first,
                            right: snapshot?.channels.dropFirst().first
                        )
                    } else {
                        SingleMeter(snapshot: summary)
                    }
                    MetricsColumn(
                        title: "",
                        snapshot: summary,
                        showHints: showHints
                    )
                    LoudnessHistoryChart(holder: holder, isStereo: isStereo)
                    .frame(maxWidth: .infinity)
                    .frame(height: meterHeight)
                }
            }
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private var modeLabel: String {
        switch busMode {
        case .stereo(let l, let r): return "Стерео \(l + 1)/\(r + 1)"
        case .mono(let ch): return "Моно " + ch.map { "\($0 + 1)" }.joined(separator: "+")
        }
    }
}