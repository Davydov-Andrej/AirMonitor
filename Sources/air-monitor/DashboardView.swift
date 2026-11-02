import SwiftUI
import yaCore

/// Дашборд: каждая шина — отдельный блок-строка.
/// Внутри блока (Youlean-стиль): вертикальные метры со шкалой + метрики +
/// график громкости; ниже — спектр и тональный баланс.
/// Шины можно перетаскивать за ручку (⠿) для изменения порядка.
struct DashboardView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Дашборд")
                    .font(.title2)
                if let scene = model.currentSceneName {
                    Text("Сцена: \(scene)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                sceneMenu
                Button {
                    model.beginAddBus()
                } label: {
                    Label("Добавить шину", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
            }

            if model.buses.isEmpty {
                ContentUnavailableView(
                    "Нет шин мониторинга",
                    systemImage: "waveform",
                    description: Text("Нажмите «Добавить шину», выберите устройство и каналы (Main, Monitor и др.), а затем «Старт»")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 14) {
                        ForEach(model.buses) { bus in
                            BusDashboardCardContainer(
                                bus: bus,
                                holder: model.holder(for: bus),
                                onDelete: { model.removeBus(id: bus.id) },
                                onRename: { newName in model.renameBus(id: bus.id, to: newName) },
                                onEdit: { model.beginEditBus(id: bus.id) },
                                onMoveUp: { model.moveBusUp(id: bus.id) },
                                onMoveDown: { model.moveBusDown(id: bus.id) },
                                onResizeSpectrum: { fraction in
                                    model.setBusSpectrumFraction(id: bus.id, fraction: fraction)
                                },
                                canMoveUp: model.buses.first?.id != bus.id,
                                canMoveDown: model.buses.last?.id != bus.id
                            )
                        }
                    }
                }
            }
        }
        .padding()
        .sheet(isPresented: $model.isPresentingAddBus) {
            AddBusSheet()
        }
        .sheet(isPresented: $model.isPresentingSaveScene) {
            SaveSceneSheet()
        }
    }

    private var sceneMenu: some View {
        Menu {
            Button("Сохранить сцену как…") {
                model.sceneSaveName = model.currentSceneName ?? ""
                model.isPresentingSaveScene = true
            }
            Divider()
            ForEach(model.scenes) { scene in
                Button {
                    model.restoreScene(named: scene.name)
                } label: {
                    HStack {
                        Text(scene.name)
                        if scene.name == model.currentSceneName {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
            if !model.scenes.isEmpty {
                Divider()
                Menu("Удалить сцену…") {
                    ForEach(model.scenes) { scene in
                        Button(scene.name, role: .destructive) {
                            model.deleteScene(named: scene.name)
                        }
                    }
                }
            }
        } label: {
            Label("Сцены", systemImage: "square.stack.3d.up")
        }
    }
}

/// Диалог сохранения сцены.
struct SaveSceneSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            Text("Сохранить сцену").font(.title3)
            TextField("Имя сцены", text: $model.sceneSaveName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 300)
            HStack {
                Button("Отмена") { dismiss() }
                Button("Сохранить") {
                    model.saveScene(named: model.sceneSaveName)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.sceneSaveName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding()
    }
}

/// Изолированный контейнер карточки: перерисовывается только при обновлении
/// снимка СВОЕЙ шины, а не всего дашборда.
struct BusDashboardCardContainer: View {
    let bus: MonitorBus
    let holder: BusSnapshotHolder
    let onDelete: () -> Void
    let onRename: (String) -> Void
    var onEdit: () -> Void = {}
    var onMoveUp: () -> Void = {}
    var onMoveDown: () -> Void = {}
    var onResizeSpectrum: (Double) -> Void = { _ in }
    var canMoveUp: Bool = false
    var canMoveDown: Bool = false

    var body: some View {
        // Без внешнего TimelineView: статичная часть карточки (метры, метрики,
        // header) НЕ пересоздаётся 20 раз/с. Живые Canvas-графики обновляются
        // собственными TimelineView внутри (см. BusDashboardCard).
        BusDashboardCard(
            id: bus.id,
            name: bus.config.name,
            mode: bus.config.mode,
            holder: holder,
            isConnected: bus.isConnected,
            onDelete: onDelete,
            onRename: onRename,
            onEdit: onEdit,
            onMoveUp: onMoveUp,
            onMoveDown: onMoveDown,
            onResizeSpectrum: onResizeSpectrum,
            spectrumFraction: bus.config.spectrumWidthFraction,
            canMoveUp: canMoveUp,
            canMoveDown: canMoveDown
        )
    }
}

/// Карточка шины (Youlean-вёрстка).
struct BusDashboardCard: View {
    let id: BusID
    let name: String
    let mode: BusMode
    let holder: BusSnapshotHolder
    var isConnected: Bool = true
    let onDelete: () -> Void
    let onRename: (String) -> Void
    var onEdit: () -> Void = {}
    var onMoveUp: () -> Void = {}
    var onMoveDown: () -> Void = {}
    var onResizeSpectrum: (Double) -> Void = { _ in }
    var spectrumFraction: Double = 0.5
    var canMoveUp: Bool = false
    var canMoveDown: Bool = false

    private var busSpectrumFraction: Double {
        max(0.25, min(0.75, spectrumFraction))
    }

    private func clampedFraction(_ f: Double) -> Double {
        max(0.25, min(0.75, f))
    }

    @EnvironmentObject var model: AppModel
    @State private var isRenaming = false
    @State private var renameText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            // Верхний ряд: метр(ы) + метрики + график громкости.
            HStack(alignment: .top, spacing: 14) {
                meterBlock
                    .fixedSize()

                // Живая секция: перерисовка по таймеру, статика рядом не дёргается.
                TimelineView(.animation(minimumInterval: 0.05, paused: false)) { _ in
                    LoudnessHistoryChart(
                        monoHistory: summaryChannel?.loudnessHistory ?? [],
                        leftHistory: isStereo ? leftChannel?.loudnessHistory ?? [] : [],
                        rightHistory: isStereo ? rightChannel?.loudnessHistory ?? [] : [],
                        target: -23,
                        windowSeconds: 15
                    )
                    .frame(maxWidth: .infinity)
                    .frame(height: 150)
                    .id("loudness")
                }
            }

            Divider()

            // Нижний ряд: Спектр | Баланс — ширина регулируется перетаскиванием.
            GeometryReader { geo in
                let width = geo.size.width
                let dragWidth = width * CGFloat(busSpectrumFraction)
                HStack(alignment: .top, spacing: 0) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Спектр")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TimelineView(.animation(minimumInterval: 0.05, paused: false)) { _ in
                            SpectrumCurveChart(
                                fine: summaryChannel?.fineCurve ?? [],
                                bands: summaryChannel?.rtaBands ?? []
                            )
                            .frame(height: 130)
                        }
                    }
                    .frame(width: dragWidth, alignment: .leading)

                    Divider()
                        .frame(height: 150)
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 1)
                                .onEnded { value in
                                    let newFraction = busSpectrumFraction + Double(value.translation.width / width)
                                    onResizeSpectrum(clampedFraction(newFraction))
                                }
                        )

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Тональный баланс")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TimelineView(.animation(minimumInterval: 0.05, paused: false)) { _ in
                            TonalBalanceChart(
                                balances: summaryChannel?.tonalBalances ?? [],
                                hasSignal: summaryChannel?.tonalBalances.isEmpty == false
                            )
                            .frame(height: 130)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 8)
                }
            }
            .frame(height: 155)
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.gray.opacity(0.2)))
        .alert("Переименовать", isPresented: $isRenaming) {
            TextField("Имя шины", text: $renameText)
            Button("OK") { onRename(renameText) }
            Button("Отмена", role: .cancel) {}
        }
    }

    // MARK: - Доступ к каналам

    private var isStereo: Bool {
        if case .stereo = mode { return true }
        return false
    }

    private var snapshot: BusSnapshot? { holder.snapshot }

    /// Сводный канал: для стерео — «Стерео», для моно — единственный.
    private var summaryChannel: ChannelSnapshot? {
        guard let snapshot else { return nil }
        if isStereo {
            return snapshot.mono ?? snapshot.channels.first
        }
        return snapshot.channels.first
    }

    private var leftChannel: ChannelSnapshot? {
        guard let snapshot, isStereo else { return nil }
        return snapshot.channels.first
    }

    private var rightChannel: ChannelSnapshot? {
        guard let snapshot, isStereo else { return nil }
        return snapshot.channels.dropFirst().first
    }

    // MARK: - Метр

    /// Метры: моно — один столбик; стерео — два смежных (L/R) в одной рамке.
    @ViewBuilder
    private var meterBlock: some View {
        // Метры/метрики — живые данные: обновляются по своему таймеру
        // (после переноса TimelineView внутрь карточек статика не дёргается,
        // но и живая часть требует собственной обёртки).
        TimelineView(.animation(minimumInterval: 0.05, paused: false)) { _ in
            meterContent
        }
    }

    private var meterContent: some View {
        Group {
            if isStereo {
                HStack(alignment: .top, spacing: 10) {
                    StereoMeterPair(
                        left: leftChannel,
                        right: rightChannel
                    )
                    MetricsColumn(
                        title: "Стерео",
                        snapshot: summaryChannel,
                        showHints: model.showMetricHints,
                        extraMetrics: [
                            ("Crest", "динамика", summaryChannel?.crestFactorDB),
                            ("Корр.", "L/R", snapshot?.correlation),
                        ]
                    )
                }
            } else {
                HStack(alignment: .top, spacing: 10) {
                    SingleMeter(snapshot: summaryChannel)
                    MetricsColumn(
                        title: summaryChannel.map { String($0.label.suffix(2)).trimmingCharacters(in: .whitespaces) } ?? "",
                        snapshot: summaryChannel,
                        showHints: model.showMetricHints,
                        extraMetrics: [("Crest", "динамика", summaryChannel?.crestFactorDB)]
                    )
                }
            }
        }
    }

    private var meterColumnHeight: CGFloat { 150 }

    private var header: some View {
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

            Text(name)
                .font(.headline)
            Text(modeLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.gray.opacity(0.15)))
            if snapshot == nil {
                Text("ожидает «Старт»")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            if !isConnected {
                Label("устройство отключено", systemImage: "cable.connector.slash")
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .help("Анализ прерван. Подключите устройство — мониторинг продолжится автоматически.")
            }
            Spacer()
            Menu {
                Button("Переименовать") {
                    renameText = name
                    isRenaming = true
                }
                Button("Изменить источник…") { onEdit() }
                Divider()
                Button("Удалить", role: .destructive) { onDelete() }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
        }
    }

    private var modeLabel: String {
        switch mode {
        case .stereo(let l, let r): return "Стерео \(l + 1)/\(r + 1)"
        case .mono(let ch): return "Моно " + ch.map { "\($0 + 1)" }.joined(separator: "+")
        }
    }
}

// MARK: - Метры

let meterHeight: CGFloat = 150
let meterMaxDB: Float = 6
let meterMinDB: Float = -60

/// Один вертикальный метр с RMS-заливкой и пиковой насечкой.
struct SingleMeter: View {
    let snapshot: ChannelSnapshot?

    var body: some View {
        HStack(spacing: 3) {
            ScaleRuler(maxDB: meterMaxDB, minDB: meterMinDB)
                .frame(width: 14, height: meterHeight)
            ZStack(alignment: .bottom) {
                Capsule()
                    .fill(Color.black.opacity(0.1))
                MeterFill(db: snapshot?.rmsDB ?? -Float.infinity)
                PeakTickOverlay(valueDB: snapshot?.peakDB ?? -Float.infinity)
            }
            .frame(width: 16, height: meterHeight)
        }
    }
}

/// Стерео-пара: два смежных столбика в одной рамке + общая шкала.
struct StereoMeterPair: View {
    let left: ChannelSnapshot?
    let right: ChannelSnapshot?

    var body: some View {
        HStack(spacing: 3) {
            ScaleRuler(maxDB: meterMaxDB, minDB: meterMinDB)
                .frame(width: 14, height: meterHeight)
            HStack(spacing: 2) {
                ZStack(alignment: .bottom) {
                    Rectangle().fill(Color.black.opacity(0.08))
                    MeterFill(db: left?.rmsDB ?? -Float.infinity)
                    PeakTickOverlay(valueDB: left?.peakDB ?? -Float.infinity)
                }
                ZStack(alignment: .bottom) {
                    Rectangle().fill(Color.black.opacity(0.08))
                    MeterFill(db: right?.rmsDB ?? -Float.infinity, tint: .blue)
                    PeakTickOverlay(valueDB: right?.peakDB ?? -Float.infinity)
                }
            }
            .frame(width: 30, height: meterHeight)
        }
    }
}

struct MeterFill: View {
    let db: Float
    var tint: Color = .green

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                RoundedRectangle(cornerRadius: 1)
                    .fill(fillColor)
                    .frame(height: levelHeight(in: geo.size.height))
            }
        }
    }

    private var fillColor: Color {
        guard db.isFinite else { return tint.opacity(0.25) }
        if db > -3 { return .red }
        if db > -9 { return .yellow }
        return tint
    }

    private func levelHeight(in height: CGFloat) -> CGFloat {
        guard db.isFinite else { return 0 }
        let clamped = max(meterMinDB, min(meterMaxDB, db))
        return CGFloat((clamped - meterMinDB) / (meterMaxDB - meterMinDB)) * height
    }
}

struct PeakTickOverlay: View {
    let valueDB: Float

    var body: some View {
        GeometryReader { geo in
            let clamped = max(meterMinDB, min(meterMaxDB, valueDB.isFinite ? valueDB : meterMinDB))
            let y = geo.size.height * (1 - CGFloat((clamped - meterMinDB) / (meterMaxDB - meterMinDB)))
            Rectangle()
                .fill(valueDB > meterMaxDB - 1 ? Color.red : Color.primary.opacity(0.85))
                .frame(height: 2)
                .offset(y: y)
        }
        .allowsHitTesting(false)
    }
}

/// Числовые метрики: колонка справа от метра.
struct MetricsColumn: View {
    let title: String
    let snapshot: ChannelSnapshot?
    var showHints: Bool = false
    var extraMetrics: [(String, String, Float?)] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if !title.isEmpty {
                Text(title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            // Громкость — первичные метрики: сверху, крупно, жирно.
            lufsRow("M", "громкость сейчас", snapshot?.momentaryLUFS,
                    tooltip: "Momentary loudness (LUFS) — громкость «прямо сейчас» по ITU-R BS.1770: K-взвешенный сигнал за последние 400 мс.")
            lufsRow("S", "громкость за окно", snapshot?.shortTermLUFS,
                    tooltip: "Short-term loudness (LUFS) — громкость за окно усреднения (настраивается на вкладке «Монитор»: по умолчанию 1 с, стандарт EBU — 3 с).")
            Divider()
                .frame(height: 0.5)
                .padding(.vertical, 1)
            metricRow("Peak", "макс. сэмпл", snapshot?.peakDB,
                      tooltip: "Peak (dBFS) — максимальная амплитуда сэмпла за всё время мониторинга. 0 dBFS — потолок шкалы, выше — клиппинг.")
            metricRow("RMS", "текущий уровень", snapshot?.rmsDB,
                      tooltip: "RMS (dBFS) — среднеквадратичный уровень с интеграцией ~100 мс. Это заливка столбика: реальная громкость без мгновенных пиков.")
            metricRow("TruePk", "межсэмпл. пик", snapshot?.truePeakDB,
                      tooltip: "True Peak (dBTP) — пик с учётом колебаний МЕЖДУ сэмплами (восстановит ЦАП). Может быть выше Peak. Для эфира нормируют ниже −1 dBTP.")
            metricRow("I", "громкость эфира", snapshot?.integratedLUFS,
                      tooltip: "Integrated loudness (LUFS) — итоговая громкость с начала захвата с гейтингом. Норматив эфира EBU R128: −23 LUFS.")
            metricRow("LRA", "диапазон громк.", snapshot?.loudnessRangeLU,
                      tooltip: "Loudness Range (LU) — разброс громкости (10–95 перцентили). Малый = ровный эфир, большой = резкие перепады.")
            ForEach(extraMetrics, id: \.0) { m in
                metricRow(m.0, m.1, m.2)
            }
        }
        .frame(minWidth: 118, alignment: .leading)
    }

    /// Выделенная строка громкости: крупнее и жирнее обычных метрик.
    @ViewBuilder
    private func lufsRow(_ name: String, _ hint: String, _ value: Float?, tooltip: String) -> some View {
        HStack(spacing: 4) {
            Text(showHints ? "\(name) (\(hint))" : name)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .help(tooltip)
            Spacer()
            if let value, value.isFinite {
                Text(String(format: "%.1f", value))
                    .font(.system(size: 14, design: .monospaced).weight(.bold))
                    .help(tooltip)
            } else {
                Text("--")
                    .font(.system(size: 14, design: .monospaced).weight(.bold))
                    .foregroundStyle(.tertiary)
                    .help(tooltip)
            }
        }
    }

    /// Словарь подсказок по имени метрики — покрывает и extraMetrics.
    private static let tooltips: [String: String] = [
        "Crest": "Crest factor (дБ) — разница между пиковым и средним уровнем. Большой = динамичный сигнал (удары, речь с паузами), малый = сжатый/постоянный сигнал.",
        "Корр.": "Корреляция L/R (−1…+1). +1 — моно-совместимый сигнал (в колонках одинаково), 0 — широкий стерео, −1 — противофаза (уходит из моно, опасно для клубных систем).",
        "Peak": "Peak (dBFS) — максимальная амплитуда сэмпла за всё время мониторинга. 0 dBFS — потолок шкалы, выше — клиппинг.",
        "RMS": "RMS (dBFS) — среднеквадратичный уровень с интеграцией ~100 мс. Это заливка столбика: реальная громкость без мгновенных пиков.",
        "TruePk": "True Peak (dBTP) — пик с учётом колебаний МЕЖДУ сэмплами (восстановит ЦАП). Может быть выше Peak. Для эфира нормируют ниже −1 dBTP.",
        "I": "Integrated loudness (LUFS) — итоговая громкость с начала захвата с гейтингом. Норматив эфира EBU R128: −23 LUFS.",
        "LRA": "Loudness Range (LU) — разброс громкости (10–95 перцентили). Малый = ровный эфир, большой = резкие перепады.",
    ]

    @ViewBuilder
    private func metricRow(_ name: String, _ hint: String, _ value: Float?, tooltip: String? = nil) -> some View {
        HStack(spacing: 4) {
            Text(showHints ? "\(name) (\(hint))" : name)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .help(tooltip ?? Self.tooltips[name] ?? "")
            Spacer()
            if let value, value.isFinite {
                Text(String(format: "%.1f", value))
                    .font(.system(size: 10, design: .monospaced).weight(.medium))
                    .help(tooltip ?? Self.tooltips[name] ?? "")
            } else {
                Text("--")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .help(tooltip ?? Self.tooltips[name] ?? "")
            }
        }
    }
}

/// Вертикальная шкала с делениями.
struct ScaleRuler: View {
    let maxDB: Float
    let minDB: Float

    var body: some View {
        GeometryReader { geo in
            Canvas { context, size in
                for db in stride(from: maxDB, through: minDB, by: -12) {
                    let t = (maxDB - db) / (maxDB - minDB)
                    let y = CGFloat(t) * size.height
                    var tick = Path()
                    tick.move(to: CGPoint(x: size.width - 4, y: y))
                    tick.addLine(to: CGPoint(x: size.width, y: y))
                    context.stroke(tick, with: .color(.secondary.opacity(0.6)), lineWidth: 1)
                    if db != maxDB {
                        let text = Text("\(Int(db))").font(.system(size: 7)).foregroundStyle(.tertiary)
                        context.draw(text, at: CGPoint(x: 0, y: y - 4), anchor: .topLeading)
                    }
                }
            }
        }
    }
}

/// Пиковая насечка на вертикальном метре.
struct PeakTick: View {
    let valueDB: Float
    let maxDB: Float
    let minDB: Float

    var body: some View {
        GeometryReader { geo in
            let clamped = max(minDB, min(maxDB, valueDB.isFinite ? valueDB : minDB))
            let t = CGFloat((clamped - minDB) / (maxDB - minDB))
            let y = geo.size.height * (1 - t)
            Rectangle()
                .fill(valueDB > maxDB - 1 ? Color.red : Color.black.opacity(0.8))
                .frame(height: 2)
                .offset(y: y)
        }
        .allowsHitTesting(false)
    }
}