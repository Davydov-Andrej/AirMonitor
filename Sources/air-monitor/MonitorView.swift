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
                        Text("S: 1 с").tag(1.0)
                        Text("S: 2 с").tag(2.0)
                        Text("S: 3 с (по умолчанию, стандарт EBU)").tag(3.0)
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label("S: \(sWindowLabel) с", systemImage: "timer")
                        .lineLimit(1)
                        .frame(width: 92, alignment: .trailing)
                }
                .menuStyle(.borderedButton)
                .frame(width: 112, alignment: .trailing)
                .fixedSize(horizontal: true, vertical: false)
                // Сглаживание ГРАФИКА громкости (отдельная EMA-цепочка).
                Menu {
                    Picker("Сглаживание", selection: Binding(
                        get: { model.rtaSettings.loudnessSmoothing },
                        set: { model.rtaSettings.loudnessSmoothing = $0 }
                    )) {
                        // Вес нового отсчёта при спаде: 1 = без сглаживания;
                        // меньше = длиннее хвост. Рост быстрее спада, с ограничением 0.9.
                        Text("Выкл").tag(Float(1.0))
                        Text("Лёгкое (0.15)").tag(Float(0.15))
                        Text("Слабое (0.05)").tag(Float(0.05))
                        Text("Среднее (0.02) — стандарт").tag(Float(0.02))
                        Text("Сильное (0.008)").tag(Float(0.008))
                        Text("Максимальное (0.003)").tag(Float(0.003))
                    }
                    .pickerStyle(.inline)

                Divider()

                // Сглаживание ЧИСЕЛ M/S: своя EMA-цепочка.
                Picker("Числа", selection: Binding(
                    get: { model.rtaSettings.numberSmoothing },
                    set: { model.rtaSettings.numberSmoothing = $0 }
                )) {
                    Text("Выкл — точные значения (для сверки)").tag(Float(1.0))
                    Text("Лёгкое (0.3)").tag(Float(0.3))
                    Text("Слабое (0.12)").tag(Float(0.12))
                    Text("Среднее (0.05) — стандарт").tag(Float(0.05))
                    Text("Сильное (0.02)").tag(Float(0.02))
                    Text("Максимальное (0.008)").tag(Float(0.008))
                }
                .pickerStyle(.inline)
                .help("Отдельно сглаживает отображаемые значения M/S: чем меньше значение, тем длиннее спад. Интегральная громкость и LRA от этой настройки не меняются. Выкл показывает несглаженные M/S.")

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
                    Label("Настройки", systemImage: "slider.horizontal.3")
                        .lineLimit(1)
                        .frame(width: 104, alignment: .trailing)
                }
                .menuStyle(.borderedButton)
                .frame(width: 124, alignment: .trailing)
                .fixedSize(horizontal: true, vertical: false)
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
                    .frame(width: showHints ? 200 : 160, alignment: .leading)
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
