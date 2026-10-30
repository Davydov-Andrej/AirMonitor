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
                            BusDashboardCard(
                                id: bus.id,
                                name: bus.config.name,
                                mode: bus.config.mode,
                                snapshot: model.busPreview(for: bus),
                                onDelete: { model.removeBus(id: bus.id) },
                                onRename: { newName in model.renameBus(id: bus.id, to: newName) },
                                onEdit: { model.beginEditBus(id: bus.id) },
                                onMoveUp: { model.moveBusUp(id: bus.id) },
                                onMoveDown: { model.moveBusDown(id: bus.id) },
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

/// Карточка шины (Youlean-вёрстка).
struct BusDashboardCard: View {
    let id: BusID
    let name: String
    let mode: BusMode
    let snapshot: BusSnapshot?
    let onDelete: () -> Void
    let onRename: (String) -> Void
    var onEdit: () -> Void = {}
    var onMoveUp: () -> Void = {}
    var onMoveDown: () -> Void = {}
    var canMoveUp: Bool = false
    var canMoveDown: Bool = false

    @EnvironmentObject var model: AppModel
    @State private var isRenaming = false
    @State private var renameText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            // Верхний ряд: вертикальные метры + метрики + график громкости.
            HStack(alignment: .top, spacing: 14) {
                ForEach(channelLabels, id: \.self) { label in
                    VerticalMeterColumn(
                        label: label,
                        snapshot: snapshot?.displayChannels.first { $0.label == label },
                        showHints: model.showMetricHints
                    )
                }

                LoudnessHistoryChart(
                    history: snapshot?.displayChannels.first?.loudnessHistory ?? [],
                    target: -23,
                    windowSeconds: 15
                )
                .frame(maxWidth: .infinity)
                .frame(height: meterColumnHeight)
            }

            Divider()

            HStack(alignment: .top, spacing: 14) {
                // Спектр
                VStack(alignment: .leading, spacing: 4) {
                    Text("Спектр")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    SpectrumCurveChart(
                        fine: snapshot?.displayChannels.first?.fineCurve ?? [],
                        bands: snapshot?.displayChannels.first?.rtaBands ?? []
                    )
                    .frame(height: 130)
                }
                .frame(maxWidth: .infinity)

                // Баланс
                VStack(alignment: .leading, spacing: 4) {
                    Text("Тональный баланс")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TonalBalanceChart(
                        spectrum: snapshot?.displayChannels.first?.spectrum ?? [],
                        sampleRate: Float(snapshot?.sampleRate ?? 48000)
                    )
                    .frame(height: 130)
                }
                .frame(maxWidth: .infinity)
            }
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

    private var meterColumnHeight: CGFloat { 170 }

    private var header: some View {
        HStack(spacing: 8) {
            // Ручки перемещения
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
            Spacer()
            if let correlation = snapshot?.correlation {
                Text(String(format: "Кор: %.2f", correlation))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(correlation > 0.7 ? .green : (correlation > 0.3 ? .orange : .red))
            }
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

    private var channelLabels: [String] {
        if let snapshot, !snapshot.displayChannels.isEmpty {
            return snapshot.displayChannels.map { $0.label }
        }
        switch mode {
        case .stereo(let l, let r): return ["L \(l + 1)", "R \(r + 1)"]
        case .mono(let ch): return ch.map { "Ch \($0 + 1)" }
        }
    }

    private var modeLabel: String {
        switch mode {
        case .stereo(let l, let r): return "Стерео \(l + 1)/\(r + 1)"
        case .mono(let ch): return "Моно " + ch.map { "\($0 + 1)" }.joined(separator: "+")
        }
    }
}

/// Вертикальный блок одного канала: шкала + метр + числовые метрики.
struct VerticalMeterColumn: View {
    let label: String
    let snapshot: ChannelSnapshot?
    var showHints: Bool = false

    private let maxDB: Float = 6
    private let minDB: Float = -60

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)

            HStack(alignment: .top, spacing: 4) {
                // Шкала делений
                ScaleRuler(maxDB: maxDB, minDB: minDB)
                    .frame(width: 16, height: 140)

                // Вертикальный метр
                ZStack(alignment: .bottom) {
                    Capsule()
                        .fill(Color.black.opacity(0.1))
                        .frame(width: 14, height: 140)
                    GeometryReader { geo in
                        VStack {
                            Spacer(minLength: 0)
                            // уровень RMS
                            RoundedRectangle(cornerRadius: 2)
                                .fill(rmsColor)
                                .frame(height: levelHeight(rmsDB, in: geo.size.height))
                                .opacity(0.75)
                        }
                    }
                    .frame(width: 14, height: 140)

                    // RMS-фон, поверх — пиковая насечка
                    PeakTick(valueDB: snapshot?.peakDB ?? -Float.infinity, maxDB: maxDB, minDB: minDB)
                        .frame(width: 22, height: 140)
                }
                .frame(width: 22, height: 140)
            }

            // Метрики колонкой
            VStack(alignment: .leading, spacing: 2) {
                metricRow("Peak", "пик", snapshot?.peakDB)
                metricRow("RMS", "среднее", snapshot?.rmsDB)
                metricRow("TruePk", "ист.пик", snapshot?.truePeakDB)
                metricRow("M", "момент.", snapshot?.momentaryLUFS)
                metricRow("S", "3 сек", snapshot?.shortTermLUFS)
                metricRow("I", "интегр.", snapshot?.integratedLUFS)
            }
        }
    }

    private var rmsDB: Float { snapshot?.rmsDB ?? -Float.infinity }
    private var rmsColor: Color {
        let v = rmsDB
        if !v.isFinite { return .green.opacity(0.3) }
        if v > -3 { return .red }
        if v > -9 { return .yellow }
        return .green
    }

    private func levelHeight(_ db: Float, in height: CGFloat) -> CGFloat {
        guard db.isFinite else { return 0 }
        let clamped = max(minDB, min(maxDB, db))
        let t = (clamped - minDB) / (maxDB - minDB)
        return CGFloat(t) * height
    }

    @ViewBuilder
    private func metricRow(_ name: String, _ hint: String, _ value: Float?) -> some View {
        HStack(spacing: 4) {
            Text(showHints ? "\(name) (\(hint))" : name)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            Spacer()
            if let value, value.isFinite {
                Text(String(format: "%.1f", value))
                    .font(.system(size: 10, design: .monospaced).weight(.medium))
            } else {
                Text("--")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
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