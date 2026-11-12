import SwiftUI
import yaCore

/// Дашборд: каждая шина — отдельная карточка с независимыми инструментами.
/// Инструменты автоматически переносятся по ширине или вручную раскладываются
/// в два ряда; шины и инструменты переставляются перетаскиванием.
struct DashboardView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Дашборд")
                    .font(.title2)
                if let scene = model.currentSceneName {
                    Text(LF("Сцена: %@", scene))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                dashboardViewMenu
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
                    LazyVGrid(
                        columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: model.dashboardColumns.rawValue),
                        spacing: 14
                    ) {
                        ForEach(model.buses) { bus in
                            BusDashboardCardContainer(
                                bus: bus,
                                holder: model.holder(for: bus),
                                cardSize: model.dashboardCardSize,
                                autoWrapModules: model.dashboardAutoWrapModules,
                                onDelete: { model.removeBus(id: bus.id) },
                                onRename: { newName in model.renameBus(id: bus.id, to: newName) },
                                onDropBus: { sourceID, after in
                                    guard let uuid = UUID(uuidString: sourceID) else { return false }
                                    model.moveBus(id: BusID(uuid: uuid), relativeTo: bus.id, after: after)
                                    return true
                                },
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

    private var dashboardViewMenu: some View {
        Menu {
            Picker("Компоновка", selection: $model.dashboardColumns) {
                ForEach(DashboardColumnLayout.allCases) { layout in
                    Text(layout.title).tag(layout)
                }
            }
            .pickerStyle(.inline)
            Divider()
            Picker("Размер карточек", selection: $model.dashboardCardSize) {
                ForEach(DashboardCardSize.allCases) { size in
                    Text(size.title).tag(size)
                }
            }
            .pickerStyle(.inline)
            Divider()
            Toggle("Автоперенос инструментов по ширине", isOn: $model.dashboardAutoWrapModules)
            Toggle("Растягивать графики на свободное место", isOn: $model.dashboardAutoStretchGraphs)
            if !model.dashboardAutoWrapModules {
                Text("Для ручного переноса перетащите блок за ручку в область нужного ряда.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Toggle("Пояснения к метрикам", isOn: $model.showMetricHints)
        } label: {
            Label("Вид", systemImage: "rectangle.grid.2x2")
        }
        .fixedSize(horizontal: true, vertical: false)
        .help(L("Инструменты переносятся на следующий ряд по ширине. Графики могут заполнять свободное место в своей строке."))
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
        .fixedSize(horizontal: true, vertical: false)
    }
}

/// Диалог сохранения сцены.
struct SaveSceneSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            Text(L("Сохранить сцену")).font(.title3)
            TextField(L("Имя сцены"), text: $model.sceneSaveName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 300)
            HStack {
                Button(L("Отмена")) { dismiss() }
                Button(L("Сохранить")) {
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
    var cardSize: DashboardCardSize = .standard
    var autoWrapModules: Bool = true
    let onDelete: () -> Void
    let onRename: (String) -> Void
    var onDropBus: (String, Bool) -> Bool = { _, _ in false }
    var onEdit: () -> Void = {}
    var onMoveUp: () -> Void = {}
    var onMoveDown: () -> Void = {}
    var onResizeSpectrum: (Double) -> Void = { _ in }
    var canMoveUp: Bool = false
    var canMoveDown: Bool = false
    @State private var isDropTargeted = false
    @State private var cardHeight: CGFloat = 0

    var body: some View {
        // Без внешнего TimelineView: статичная часть карточки (метры, метрики,
        // header) НЕ пересоздаётся 20 раз/с. Живые Canvas-графики обновляются
        // собственными TimelineView внутри (см. BusDashboardCard).
        BusDashboardCard(
            id: bus.id,
            name: bus.config.name,
            mode: bus.config.mode,
            holder: holder,
            cardSize: cardSize,
            autoWrapModules: autoWrapModules,
            dragIdentifier: bus.id.uuid.uuidString,
            hiddenDashboardModules: bus.config.hiddenDashboardModules,
            dashboardModuleOrder: bus.config.dashboardModuleOrder,
            dashboardModuleWidths: bus.config.dashboardModuleWidths,
            dashboardModuleHeights: bus.config.dashboardModuleHeights,
            dashboardModuleRows: bus.config.dashboardModuleRows,
            dashboardModuleRowOverrides: bus.config.dashboardModuleRowOverrides,
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
        .background {
            GeometryReader { geometry in
                Color.clear
                    .onAppear { cardHeight = geometry.size.height }
                    .onChange(of: geometry.size.height) { _, height in cardHeight = height }
            }
        }
        .dropDestination(for: String.self) { items, location in
            guard let sourceID = items.first else { return false }
            return onDropBus(sourceID, location.y > cardHeight / 2)
        } isTargeted: { isDropTargeted = $0 }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.accentColor, lineWidth: 2)
                    .allowsHitTesting(false)
            }
        }
    }
}

private struct DashboardModuleRow: Identifiable {
    let index: Int
    let modules: [DashboardModule]
    var id: Int { index }
}

private enum DashboardFrameKey: Hashable {
    case module(DashboardModule)
    case row(Int)
}

private struct DashboardFramePreferenceKey: PreferenceKey {
    static let defaultValue: [DashboardFrameKey: CGRect] = [:]

    static func reduce(value: inout [DashboardFrameKey: CGRect], nextValue: () -> [DashboardFrameKey: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private struct DashboardInsertion: Equatable {
    let target: DashboardModule?
    let row: Int
    let after: Bool
}

private struct EmptyDashboardModuleRow: View {
    let rowIndex: Int
    var isTargeted = false

    var body: some View {
        RoundedRectangle(cornerRadius: 7)
            .fill(Color.accentColor.opacity(isTargeted ? 0.10 : 0.025))
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(Color.secondary.opacity(isTargeted ? 0.55 : 0.22), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                Text(isTargeted ? L("Отпустите, чтобы перенести сюда") : LF("Перетащите сюда — ряд %d", rowIndex + 1))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .contentShape(RoundedRectangle(cornerRadius: 7))
    }
}

/// Карточка шины (Youlean-вёрстка).
struct BusDashboardCard: View {
    let id: BusID
    let name: String
    let mode: BusMode
    let holder: BusSnapshotHolder
    var cardSize: DashboardCardSize = .standard
    var autoWrapModules: Bool = true
    var dragIdentifier: String = ""
    var hiddenDashboardModules: Set<DashboardModule> = [.mixBalance]
    var dashboardModuleOrder: [DashboardModule] = DashboardModule.allCases
    var dashboardModuleWidths: [String: Double] = [:]
    var dashboardModuleHeights: [String: Double] = [:]
    var dashboardModuleRows: [String: Int] = [:]
    var dashboardModuleRowOverrides: [String: Int] = [:]
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

    @EnvironmentObject var model: AppModel
    @State private var isRenaming = false
    @State private var renameText = ""
    @State private var moduleAreaWidth: CGFloat = 0
    @State private var moduleFrames: [DashboardFrameKey: CGRect] = [:]
    @State private var draggedModule: DashboardModule?
    @State private var dragPointer: CGPoint?
    @State private var dragGrabOffset: CGSize?
    @State private var insertion: DashboardInsertion?
    @State private var resizePreviewHeights: [DashboardModule: CGFloat] = [:]

    var body: some View {
        let modules = visibleModules
        let rows = arrangedModuleRows(availableWidth: moduleAreaWidth)
        VStack(alignment: .leading, spacing: cardSize.sectionSpacing) {
            header
            if modules.isEmpty {
                Text("Все блоки скрыты. Откройте меню «Блоки» в заголовке шины, чтобы добавить их.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 100)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(rows.filter { !$0.modules.isEmpty || draggedModule != nil }) { row in moduleRow(row) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: moduleAreaHeight(for: rows), alignment: .top)
                .background {
                    GeometryReader { geometry in
                        Color.clear
                            .onAppear { updateModuleAreaWidth(geometry.size.width) }
                            .onChange(of: geometry.size.width) { _, width in updateModuleAreaWidth(width) }
                    }
                }
            }
        }
        .padding(cardSize.cardPadding)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.2)))
        .coordinateSpace(name: "bus-card")
        // Keep a stable drag-session recognizer on the card. Moving a tile between
        // row ForEach trees can cancel the tile's own gesture before onEnded fires.
        .simultaneousGesture(
            DragGesture(minimumDistance: 3, coordinateSpace: .named("bus-card"))
                .onChanged { value in
                    guard let module = draggedModule else { return }
                    // Continue tracking after the dragged tile is reparented into
                    // the other row and SwiftUI cancels its local gesture.
                    updateModuleDrag(module, start: value.startLocation, point: value.location)
                }
                .onEnded { value in
                    guard let module = draggedModule else { return }
                    endModuleDrag(module, at: value.location)
                }
        )
        .onPreferenceChange(DashboardFramePreferenceKey.self) { frames in
            guard frames != moduleFrames else { return }
            moduleFrames = frames
            // Opening an empty row changes the layout while a drag is in progress.
            // Recheck the pointer once SwiftUI publishes the new row frames.
            if let draggedModule, let dragPointer {
                DispatchQueue.main.async {
                    guard self.draggedModule == draggedModule else { return }
                    updateInsertion(for: draggedModule, at: dragPointer)
                }
            }
        }
        .overlay(alignment: .topLeading) { floatingDraggedModule }
        .alert(L("Переименовать"), isPresented: $isRenaming) {
            TextField(L("Имя шины"), text: $renameText)
            Button("OK") { onRename(renameText) }
            Button(L("Отмена"), role: .cancel) {}
        }
        .onChange(of: visibleModules) { _, _ in persistAutomaticRows() }
        .onChange(of: dashboardModuleWidths) { _, _ in persistAutomaticRows(clearRowOverrides: true) }
        .onChange(of: cardSize) { _, _ in persistAutomaticRows(clearRowOverrides: true) }
        .onChange(of: autoWrapModules) { _, enabled in
            if enabled {
                persistAutomaticRows(clearRowOverrides: true)
            } else {
                model.clearDashboardModuleRowOverrides(on: id)
            }
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

    @ViewBuilder
    private func moduleContent(_ module: DashboardModule, height: CGFloat) -> some View {
        switch module {
        case .levels:
            TimelineView(.animation(minimumInterval: 0.05, paused: false)) { _ in
                meterContent(height: max(100, height - 38))
            }
        case .loudness:
            LoudnessHistoryChart(holder: holder, isStereo: isStereo)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .spectrum:
            SpectrumCurveChart(holder: holder)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .mixBalance:
            TonalBalanceChart(holder: holder)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var visibleModules: [DashboardModule] {
        var order = dashboardModuleOrder
        for module in DashboardModule.allCases where !order.contains(module) { order.append(module) }
        return order.filter { !hiddenDashboardModules.contains($0) }
    }

    private func moduleWidth(_ module: DashboardModule) -> CGFloat {
        let saved = dashboardModuleWidths[module.rawValue] ?? module.defaultWidth
        return CGFloat(saved) * cardSize.moduleSizeScale
    }

    private func moduleHeight(_ module: DashboardModule) -> CGFloat {
        let saved = dashboardModuleHeights[module.rawValue] ?? module.defaultHeight
        return CGFloat(saved) * cardSize.moduleSizeScale
    }

    private func arrangedModuleRows(
        availableWidth: CGFloat,
        rowOverrides: [String: Int]? = nil
    ) -> [DashboardModuleRow] {
        let modules = visibleModules
        guard !modules.isEmpty else { return [] }

        if autoWrapModules {
            var rows: [[DashboardModule]] = [[]]
            var currentWidth: CGFloat = 0
            for module in modules {
                let spacing: CGFloat = rows.last!.isEmpty ? 0 : 8
                let nextWidth = rowMinimumWidth(module) + spacing
                if !rows.last!.isEmpty,
                   availableWidth > 0, currentWidth + nextWidth > max(0, availableWidth - 4) {
                    rows.append([])
                    currentWidth = 0
                }
                let rowSpacing: CGFloat = rows.last!.isEmpty ? 0 : 8
                rows[rows.count - 1].append(module)
                currentWidth += rowMinimumWidth(module) + rowSpacing
            }
            let overrides = rowOverrides ?? dashboardModuleRowOverrides
            for module in modules {
                guard let desiredRow = overrides[module.rawValue].map({ max(0, min(1, $0)) }) else { continue }
                for rowIndex in rows.indices {
                    rows[rowIndex].removeAll { $0 == module }
                }
                while rows.count <= desiredRow { rows.append([]) }
                rows[desiredRow].append(module)
            }
            let orderIndex = Dictionary(uniqueKeysWithValues: modules.enumerated().map { ($0.element, $0.offset) })
            for rowIndex in rows.indices {
                rows[rowIndex].sort { (orderIndex[$0] ?? 0) < (orderIndex[$1] ?? 0) }
            }
            return rows.enumerated().map { DashboardModuleRow(index: $0.offset, modules: $0.element) }
        }

        let firstRow = modules.filter { (dashboardModuleRows[$0.rawValue] ?? 0) == 0 }
        let secondRow = modules.filter { (dashboardModuleRows[$0.rawValue] ?? 0) == 1 }
        return [
            DashboardModuleRow(index: 0, modules: firstRow),
            DashboardModuleRow(index: 1, modules: secondRow),
        ]
    }

    private func rowMinimumWidth(_ module: DashboardModule) -> CGFloat {
        module.isGraph ? CGFloat(module.minimumWidth) * cardSize.moduleSizeScale : moduleWidth(module)
    }

    private func effectiveModuleWidths(in modules: [DashboardModule], availableWidth: CGFloat) -> [DashboardModule: CGFloat] {
        var widths = Dictionary(uniqueKeysWithValues: modules.map { ($0, moduleWidth($0)) })
        let graphs = modules.filter(\.isGraph)
        guard !graphs.isEmpty, availableWidth > 0 else { return widths }

        let spacing = CGFloat(max(0, modules.count - 1)) * 8
        let fixedWidth = modules.filter { !$0.isGraph }.reduce(CGFloat(0)) { $0 + moduleWidth($1) }
        let graphSpace = max(0, availableWidth - spacing - fixedWidth)
        var deficit = graphs.reduce(CGFloat(0)) { $0 + (widths[$1] ?? 0) } - graphSpace

        if deficit < 0 {
            guard model.dashboardAutoStretchGraphs else { return widths }
            let share = -deficit / CGFloat(graphs.count)
            for graph in graphs { widths[graph, default: 0] += share }
            return widths
        }

        var active = graphs.filter { (widths[$0] ?? 0) > CGFloat($0.minimumWidth) * cardSize.moduleSizeScale }
        while deficit > 0.5, !active.isEmpty {
            let share = deficit / CGFloat(active.count)
            var stillActive: [DashboardModule] = []
            for graph in active {
                let current = widths[graph] ?? 0
                let minimum = CGFloat(graph.minimumWidth) * cardSize.moduleSizeScale
                let reduction = min(share, max(0, current - minimum))
                widths[graph] = current - reduction
                deficit -= reduction
                if current - reduction > minimum + 0.5 { stillActive.append(graph) }
            }
            active = stillActive
        }
        return widths
    }

    private func updateModuleAreaWidth(_ width: CGFloat) {
        guard abs(moduleAreaWidth - width) > 1 else { return }
        moduleAreaWidth = width
        persistAutomaticRows(width: width, clearRowOverrides: true)
    }

    private func persistAutomaticRows(width: CGFloat? = nil, clearRowOverrides: Bool = false) {
        guard autoWrapModules else { return }
        let availableWidth = width ?? moduleAreaWidth
        if clearRowOverrides {
            model.clearDashboardModuleRowOverrides(on: id)
        }
        let overrides: [String: Int]? = clearRowOverrides ? [:] : nil
        model.setDashboardModuleRows(
            arrangedModuleRows(availableWidth: availableWidth, rowOverrides: overrides).map(\.modules),
            on: id
        )
    }

    private func moduleAreaHeight(for rows: [DashboardModuleRow]) -> CGFloat {
        let visibleRows = rows.filter { !$0.modules.isEmpty || draggedModule != nil }
        guard !visibleRows.isEmpty else { return 0 }
        return visibleRows.reduce(CGFloat(0)) { total, row in
            total + moduleRowHeight(row)
        } + CGFloat(max(0, visibleRows.count - 1)) * 8
    }

    private func moduleRowHeight(_ row: DashboardModuleRow) -> CGFloat {
        guard !row.modules.isEmpty else { return 44 }
        let heights = row.modules.map { resizePreviewHeights[$0] ?? moduleHeight($0) }
        return (heights.max() ?? 240) + 8
    }

    private func moduleRow(_ row: DashboardModuleRow) -> some View {
        Group {
            if row.modules.isEmpty {
                EmptyDashboardModuleRow(
                    rowIndex: row.index,
                    isTargeted: insertion?.target == nil && insertion?.row == row.index
                )
            } else {
                let rowHeight = moduleRowHeight(row)
                let widths = effectiveModuleWidths(in: row.modules, availableWidth: max(0, moduleAreaWidth - 4))
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 8) {
                        ForEach(row.modules) { module in
                            let width = widths[module] ?? moduleWidth(module)
                            let height = moduleHeight(module)
                            DashboardModuleTile(
                                module: module,
                                width: width,
                                height: height,
                                minimumWidth: CGFloat(module.minimumWidth) * cardSize.moduleSizeScale,
                                minimumHeight: CGFloat(module.minimumHeight) * cardSize.moduleSizeScale,
                                snapWidths: row.modules.filter { $0 != module }.compactMap { widths[$0] },
                                snapHeights: row.modules.filter { $0 != module }.map(moduleHeight),
                                isBeingDragged: draggedModule == module,
                                isDropTargeted: insertion?.target == module,
                                content: { moduleContent(module, height: height) },
                                onResize: { newWidth, newHeight in
                                    let scale = cardSize.moduleSizeScale
                                    model.setDashboardModuleSize(
                                        module,
                                        on: id,
                                        width: Double(newWidth / scale),
                                        height: Double(newHeight / scale)
                                    )
                                },
                                onResizeHeightChanged: { resizePreviewHeights[module] = $0 },
                                onDragChanged: { start, point in updateModuleDrag(module, start: start, point: point) },
                                onDragEnded: { point in endModuleDrag(module, at: point) }
                            )
                        }
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 2)
                }
                .scrollIndicators(.automatic)
                .frame(height: rowHeight)
            }
        }
        .background {
            GeometryReader { geometry in
                Color.clear.preference(
                    key: DashboardFramePreferenceKey.self,
                    value: [.row(row.index): geometry.frame(in: .named("bus-card"))]
                )
            }
        }
    }

    @ViewBuilder
    private var floatingDraggedModule: some View {
        if let module = draggedModule,
           let pointer = dragPointer,
           let grabOffset = dragGrabOffset,
           let row = arrangedModuleRows(availableWidth: moduleAreaWidth).first(where: { $0.modules.contains(module) }) {
            let widths = effectiveModuleWidths(in: row.modules, availableWidth: max(0, moduleAreaWidth - 4))
            let width = widths[module] ?? moduleWidth(module)
            let height = moduleHeight(module)
            DashboardModuleFloatingTile(module: module, content: { moduleContent(module, height: height) })
                .frame(width: width, height: height)
                .position(
                    x: pointer.x - grabOffset.width + width / 2,
                    y: pointer.y - grabOffset.height + height / 2
                )
                .allowsHitTesting(false)
                .zIndex(100)
        }
    }

    private func updateModuleDrag(_ module: DashboardModule, start: CGPoint, point: CGPoint) {
        if draggedModule != module {
            let frame = moduleFrames[.module(module)] ?? CGRect(origin: start, size: .zero)
            draggedModule = module
            dragGrabOffset = CGSize(width: start.x - frame.minX, height: start.y - frame.minY)
            insertion = nil
        }
        dragPointer = point
        updateInsertion(for: module, at: point)
    }

    private func endModuleDrag(_ module: DashboardModule, at point: CGPoint) {
        guard draggedModule == module else { return }
        updateInsertion(for: module, at: point)
        draggedModule = nil
        dragPointer = nil
        dragGrabOffset = nil
        insertion = nil
    }

    private func updateInsertion(for source: DashboardModule, at point: CGPoint) {
        let rows = arrangedModuleRows(availableWidth: moduleAreaWidth)
        for row in rows {
            for target in row.modules where target != source {
                guard let frame = moduleFrames[.module(target)], frame.contains(point) else { continue }
                let next = DashboardInsertion(target: target, row: row.index, after: point.x >= frame.midX)
                guard insertion != next else { return }
                insertion = next
                withAnimation(.snappy(duration: 0.16)) {
                    model.moveDashboardModule(
                        source,
                        on: id,
                        relativeTo: target,
                        after: next.after,
                        row: row.index,
                        autoWrapRowOverride: autoWrapModules
                    )
                }
                return
            }
        }
        for row in rows {
            let rowFrame: CGRect
            if let measured = moduleFrames[.row(row.index)] {
                rowFrame = measured
            } else if row.index == 1, let firstRow = moduleFrames[.row(0)] {
                // The empty second row is inserted during this same drag. Its
                // preference frame may arrive one event later, so derive its
                // drop rectangle from row 1 until SwiftUI publishes the frame.
                let rowHeight = row.modules.map(moduleHeight).max() ?? 44
                rowFrame = CGRect(
                    x: firstRow.minX,
                    y: firstRow.maxY + 8,
                    width: max(firstRow.width, moduleAreaWidth),
                    height: rowHeight
                )
            } else {
                continue
            }
            guard rowFrame.contains(point) else { continue }
            let rowTargets = row.modules.filter { $0 != source }
            if let target = rowTargets.min(by: { left, right in
                let leftX = moduleFrames[.module(left)]?.midX ?? rowFrame.midX
                let rightX = moduleFrames[.module(right)]?.midX ?? rowFrame.midX
                return abs(leftX - point.x) < abs(rightX - point.x)
            }), let targetFrame = moduleFrames[.module(target)] {
                let next = DashboardInsertion(target: target, row: row.index, after: point.x >= targetFrame.midX)
                guard insertion != next else { return }
                insertion = next
                withAnimation(.snappy(duration: 0.16)) {
                    model.moveDashboardModule(
                        source,
                        on: id,
                        relativeTo: target,
                        after: next.after,
                        row: row.index,
                        autoWrapRowOverride: autoWrapModules
                    )
                }
                return
            }

            let next = DashboardInsertion(target: nil, row: row.index, after: false)
            guard insertion != next else { return }
            insertion = next
            withAnimation(.snappy(duration: 0.16)) {
                if autoWrapModules {
                    model.setDashboardModuleRowOverride(source, on: id, row: row.index)
                } else {
                    model.setDashboardModuleRow(source, on: id, row: row.index)
                }
            }
            return
        }
        insertion = nil
    }

    private func meterContent(height: CGFloat) -> some View {
        Group {
            if isStereo {
                HStack(alignment: .top, spacing: 10) {
                    StereoMeterPair(
                        left: leftChannel,
                        right: rightChannel,
                        height: height
                    )
                    MetricsColumn(
                        title: "Стерео",
                        snapshot: summaryChannel,
                        showHints: model.showMetricHints,
                        extraMetrics: [
                            ("Crest", "пик/RMS", summaryChannel?.crestFactorDB),
                            ("Корр.", "L/R", snapshot?.correlation),
                        ]
                    )
                }
            } else {
                HStack(alignment: .top, spacing: 10) {
                    SingleMeter(snapshot: summaryChannel, height: height)
                    MetricsColumn(
                        title: summaryChannel.map { String($0.label.suffix(2)).trimmingCharacters(in: .whitespaces) } ?? "",
                        snapshot: summaryChannel,
                        showHints: model.showMetricHints,
                        extraMetrics: [("Crest", "пик/RMS", summaryChannel?.crestFactorDB)]
                    )
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 3)
                .contentShape(Rectangle())
                .draggable(dragIdentifier)
                .help(L("Перетащите, чтобы изменить положение блока"))

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
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.10)))
            if snapshot == nil {
                Text("ожидает «Старт»")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            if !isConnected {
                Label("устройство отключено", systemImage: "cable.connector.slash")
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .help(L("Анализ прерван. Подключите устройство — мониторинг продолжится автоматически."))
            }
            Spacer()
            Menu {
                Button("Переименовать") {
                    renameText = name
                    isRenaming = true
                }
                Button("Изменить источник…") { onEdit() }
                Divider()
                Section("Блоки этой шины") {
                    ForEach(DashboardModule.allCases) { module in
                        Toggle(module.title, isOn: Binding(
                            get: { !hiddenDashboardModules.contains(module) },
                            set: { model.setDashboardModuleVisible(module, on: id, visible: $0) }
                        ))
                    }
                }
                Button("Сбросить компоновку блоков") {
                    model.resetDashboardModules(on: id)
                }
                Divider()
                Button("Удалить", role: .destructive) { onDelete() }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize(horizontal: true, vertical: false)
        }
    }

    private var modeLabel: String {
        switch mode {
        case .stereo(let l, let r): return LF("Стерео %d/%d", l + 1, r + 1)
        case .mono(let ch): return L("Моно ") + ch.map { "\($0 + 1)" }.joined(separator: "+")
        }
    }
}

private struct DashboardModuleFloatingTile<Content: View>: View {
    let module: DashboardModule
    let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "line.3.horizontal")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Image(systemName: module.symbol)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(module.title)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                if module == .mixBalance {
                    Text("В разработке")
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(.orange)
                }
            }
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color(nsColor: .windowBackgroundColor).opacity(0.88)))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.accentColor.opacity(0.55), lineWidth: 1))
        .shadow(color: .black.opacity(0.24), radius: 10, y: 5)
    }
}

private struct DashboardModuleTile<Content: View>: View {
    let module: DashboardModule
    let width: CGFloat
    let height: CGFloat
    let minimumWidth: CGFloat
    let minimumHeight: CGFloat
    let snapWidths: [CGFloat]
    let snapHeights: [CGFloat]
    let isBeingDragged: Bool
    let isDropTargeted: Bool
    let content: () -> Content
    let onResize: (CGFloat, CGFloat) -> Void
    let onResizeHeightChanged: (CGFloat?) -> Void
    let onDragChanged: (CGPoint, CGPoint) -> Void
    let onDragEnded: (CGPoint) -> Void
    @State private var resizeStart: CGSize?
    @State private var draftSize: CGSize?
    @State private var resizeSnapWidths: [CGFloat]?
    @State private var resizeSnapHeights: [CGFloat]?
    @Environment(\.displayScale) private var displayScale

    init(
        module: DashboardModule,
        width: CGFloat,
        height: CGFloat,
        minimumWidth: CGFloat,
        minimumHeight: CGFloat,
        snapWidths: [CGFloat],
        snapHeights: [CGFloat],
        isBeingDragged: Bool,
        isDropTargeted: Bool,
        @ViewBuilder content: @escaping () -> Content,
        onResize: @escaping (CGFloat, CGFloat) -> Void,
        onResizeHeightChanged: @escaping (CGFloat?) -> Void,
        onDragChanged: @escaping (CGPoint, CGPoint) -> Void,
        onDragEnded: @escaping (CGPoint) -> Void
    ) {
        self.module = module
        self.width = width
        self.height = height
        self.minimumWidth = minimumWidth
        self.minimumHeight = minimumHeight
        self.snapWidths = snapWidths
        self.snapHeights = snapHeights
        self.isBeingDragged = isBeingDragged
        self.isDropTargeted = isDropTargeted
        self.content = content
        self.onResize = onResize
        self.onResizeHeightChanged = onResizeHeightChanged
        self.onDragChanged = onDragChanged
        self.onDragEnded = onDragEnded
    }

    var body: some View {
        let size = draftSize ?? CGSize(width: width, height: height)
        let renderSize = resizeStart ?? CGSize(width: width, height: height)
        let contentScaleX = size.width / max(renderSize.width, 1)
        let contentScaleY = size.height / max(renderSize.height, 1)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "line.3.horizontal")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(5)
                    .contentShape(Rectangle())
                    .highPriorityGesture(dragGesture)
                    .help(L("Перетащите блок: соседние блоки переставляются по мере движения"))
                Image(systemName: module.symbol)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(module.title)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                if module == .mixBalance {
                    Text("В разработке")
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(.orange)
                }
                Spacer(minLength: 0)
            }
            content()
                // Keep the expensive chart view at a stable layout size during
                // a resize. SwiftUI scales that already-rendered content under
                // the pointer and performs one crisp relayout on release.
                .frame(
                    width: max(1, renderSize.width - 12),
                    height: max(1, renderSize.height - 32),
                    alignment: .topLeading
                )
                .scaleEffect(x: contentScaleX, y: contentScaleY, anchor: .topLeading)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(6)
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .background {
            GeometryReader { geometry in
                Color.clear.preference(
                    key: DashboardFramePreferenceKey.self,
                    value: [.module(module): geometry.frame(in: .named("bus-card"))]
                )
            }
        }
        .background(RoundedRectangle(cornerRadius: 7).fill(Color(nsColor: .windowBackgroundColor).opacity(0.28)))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.primary.opacity(0.10)))
        .overlay(alignment: .bottomTrailing) {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
                // Give the resize handle precedence over the surrounding
                // horizontal ScrollView's pan gesture. Otherwise SwiftUI can
                // alternate between resizing and scrolling as the pointer moves.
                .highPriorityGesture(resizeGesture)
                .help(L("Потяните за угол, чтобы изменить размер блока"))
                .padding(2)
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 7)
                    .stroke(Color.accentColor, lineWidth: 2)
                    .allowsHitTesting(false)
            }
        }
        .opacity(isBeingDragged ? 0 : 1)
        .zIndex(isBeingDragged ? 100 : (isDropTargeted ? 2 : 0))
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named("bus-card"))
            .onChanged { value in onDragChanged(value.startLocation, value.location) }
            .onEnded { value in onDragEnded(value.location) }
    }

    private var resizeGesture: some Gesture {
        // The handle itself moves as the card grows. Global coordinates keep
        // its translation independent of the changing local layout origin.
        DragGesture(minimumDistance: 2, coordinateSpace: .global)
            .onChanged { value in
                let start = resizeStart ?? CGSize(width: width, height: height)
                if resizeStart == nil {
                    resizeStart = start
                    resizeSnapWidths = snapWidths
                    resizeSnapHeights = snapHeights
                }
                let rawWidth = min(1_200, max(minimumWidth, start.width + value.translation.width))
                let rawHeight = min(700, max(minimumHeight, start.height + value.translation.height))
                let scale = max(displayScale, 1)
                let nextSize = CGSize(
                    width: ((rawWidth * scale).rounded() / scale).clamped(to: minimumWidth...1_200),
                    height: ((rawHeight * scale).rounded() / scale).clamped(to: minimumHeight...700)
                )
                if draftSize != nextSize {
                    withTransaction(Transaction(animation: nil)) {
                        draftSize = nextSize
                        onResizeHeightChanged(nextSize.height)
                    }
                }
            }
            .onEnded { value in
                let start = resizeStart ?? CGSize(width: width, height: height)
                let rawWidth = min(1_200, max(minimumWidth, start.width + value.translation.width))
                let rawHeight = min(700, max(minimumHeight, start.height + value.translation.height))
                let scale = max(displayScale, 1)
                let finalWidth = ((snapOnRelease(rawWidth, to: resizeSnapWidths ?? snapWidths) * scale).rounded() / scale)
                    .clamped(to: minimumWidth...1_200)
                let finalHeight = ((snapOnRelease(rawHeight, to: resizeSnapHeights ?? snapHeights) * scale).rounded() / scale)
                    .clamped(to: minimumHeight...700)
                resizeStart = nil
                draftSize = nil
                resizeSnapWidths = nil
                resizeSnapHeights = nil
                withTransaction(Transaction(animation: nil)) {
                    onResize(finalWidth, finalHeight)
                    onResizeHeightChanged(nil)
                }
            }
    }

    private func snapOnRelease(_ value: CGFloat, to candidates: [CGFloat]) -> CGFloat {
        guard let nearest = candidates.min(by: { abs($0 - value) < abs($1 - value) }) else { return value }
        // Keep the pointer-to-size response linear while dragging. Snap only
        // after release so the magnet never slows or nudges the block under
        // the pointer mid-gesture.
        return abs(nearest - value) <= 10 ? nearest : value
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(range.upperBound, max(range.lowerBound, self))
    }
}

// MARK: - Метры

let meterHeight: CGFloat = 150
let meterMaxDB: Float = 6
let meterMinDB: Float = -60

/// Один вертикальный метр с RMS-заливкой и пиковой насечкой.
struct SingleMeter: View {
    let snapshot: ChannelSnapshot?
    var height: CGFloat = meterHeight

    var body: some View {
        HStack(spacing: 3) {
            ScaleRuler(maxDB: meterMaxDB, minDB: meterMinDB)
                .frame(width: 14, height: height)
            ZStack(alignment: .bottom) {
                Capsule()
                    .fill(Color.primary.opacity(0.1))
                MeterFill(db: snapshot?.rmsDB ?? -Float.infinity)
                PeakTickOverlay(valueDB: snapshot?.peakDB ?? -Float.infinity)
            }
            .frame(width: 16, height: height)
        }
    }
}

/// Стерео-пара: два смежных столбика в одной рамке + общая шкала.
struct StereoMeterPair: View {
    let left: ChannelSnapshot?
    let right: ChannelSnapshot?
    var height: CGFloat = meterHeight

    var body: some View {
        HStack(spacing: 3) {
            ScaleRuler(maxDB: meterMaxDB, minDB: meterMinDB)
                .frame(width: 14, height: height)
            HStack(spacing: 2) {
                ZStack(alignment: .bottom) {
                    Rectangle().fill(Color.primary.opacity(0.08))
                    MeterFill(db: left?.rmsDB ?? -Float.infinity)
                    PeakTickOverlay(valueDB: left?.peakDB ?? -Float.infinity)
                }
                ZStack(alignment: .bottom) {
                    Rectangle().fill(Color.primary.opacity(0.08))
                    MeterFill(db: right?.rmsDB ?? -Float.infinity, tint: .blue)
                    PeakTickOverlay(valueDB: right?.peakDB ?? -Float.infinity)
                }
            }
            .frame(width: 30, height: height)
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
    @EnvironmentObject var model: AppModel
    let title: String
    let snapshot: ChannelSnapshot?
    var showHints: Bool = false
    var extraMetrics: [(String, String, Float?)] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if !title.isEmpty {
                Text(L(title))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            // Громкость — первичные метрики: сверху, крупно, жирно.
            lufsRow("M", "громкость сейчас", snapshot?.momentaryLUFS,
                    tooltip: Self.momentaryTooltip)
            lufsRow("S", "громкость за окно", snapshot?.shortTermLUFS,
                    tooltip: shortTermTooltip)
            Divider()
                .frame(height: 0.5)
                .padding(.vertical, 1)
            metricRow("Peak", "макс. сэмпл", snapshot?.peakDB,
                      tooltip: Self.tooltips["Peak"])
            metricRow("RMS", "текущий уровень", snapshot?.rmsDB,
                      tooltip: Self.tooltips["RMS"])
            metricRow("TruePk", "межсэмпл. пик", snapshot?.truePeakDB,
                      tooltip: Self.tooltips["TruePk"])
            metricRow("I", "интегральная", snapshot?.integratedLUFS,
                      tooltip: Self.tooltips["I"])
            metricRow("LRA", "диапазон громк.", snapshot?.loudnessRangeLU,
                      tooltip: Self.tooltips["LRA"])
            ForEach(extraMetrics, id: \.0) { m in
                metricRow(m.0, m.1, m.2)
            }
        }
        .frame(minWidth: 118, alignment: .leading)
    }

    private var shortTermTooltip: String {
        let seconds = model.rtaSettings.shortTermSeconds
        let duration = seconds.rounded() == seconds ? String(Int(seconds)) : String(format: "%.1f", seconds)
        return LF("S (Short-term), LUFS: K-взвешенная громкость на скользящем окне последних %@ с, без гейтинга. EBU Mode использует 3 с; длительность здесь меняется в настройках Монитора. Дополнительное сглаживание отображаемого M/S задаётся отдельно.", duration)
    }

    private static let momentaryTooltip = "M (Momentary), LUFS: K-взвешенная громкость на скользящем окне последних 400 мс, без гейтинга. При цифровой тишине отображается нижний предел шкалы −120 LUFS. Дополнительное сглаживание отображаемого M/S задаётся отдельно."

    /// Выделенная строка громкости: крупнее и жирнее обычных метрик.
    private func lufsRow(_ name: String, _ hint: String, _ value: Float?, tooltip: String) -> some View {
        MetricInfoRow(name: name, hint: hint, value: value, showHints: showHints,
                      tooltip: tooltip, isPrimary: true)
    }

    /// Словарь подсказок по имени метрики — покрывает и extraMetrics.
    private static let tooltips: [String: String] = [
        "Crest": "Crest factor (дБ) — разность максимального Sample Peak и среднеквадратичного уровня с начала текущего измерения. Для стереошины показывается большее из значений L/R.",
        "Корр.": "Корреляция L/R за текущий аудиоблок (от −1 до +1): +1 — каналы совпадают по фазе, 0 — слабо коррелируют, −1 — противоположны по фазе.",
        "Peak": "Sample Peak (dBFS) — максимальный уровень отдельного цифрового сэмпла с начала текущего измерения. 0 dBFS соответствует полной цифровой шкале.",
        "RMS": "RMS (dBFS) — текущий среднеквадратичный уровень аудиоблока, сглаженный с атакой около 30 мс и спадом около 150 мс. Это же значение используется для заливки метра. Для стерео усредняется энергия L/R.",
        "TruePk": "True Peak (dBTP) — накопленный максимум оценки пика восстановленной волны с начала измерения. Используется 4-кратная передискретизация с 12-отводным windowed-sinc фильтром. Может быть выше Sample Peak. Это оценка, точность не сертифицирована.",
        "I": "Integrated loudness (LUFS) — K-взвешенная интегральная громкость с начала текущего измерения; применяется абсолютный и относительный гейтинг BS.1770. −23 LUFS — целевой уровень EBU R 128, а не универсальная цель для любого материала.",
        "LRA": "Loudness Range (LU) — разность 95-го и 10-го перцентилей распределения Short-term громкости по 3-секундным окнам после гейтинга EBU Tech 3342. Оценка обычно неустойчива в первые 60 с.",
    ]

    private func metricRow(_ name: String, _ hint: String, _ value: Float?, tooltip: String? = nil) -> some View {
        MetricInfoRow(name: name, hint: hint, value: value, showHints: showHints,
                      tooltip: tooltip ?? Self.tooltips[name] ?? "", isPrimary: false)
    }
}

private struct MetricInfoRow: View {
    let name: String
    let hint: String
    let value: Float?
    let showHints: Bool
    let tooltip: String
    let isPrimary: Bool

    @State private var tooltipWorkItem: DispatchWorkItem?
    @State private var isTooltipVisible = false

    private var unit: String {
        switch name {
        case "M", "S", "I": "LUFS"
        case "LRA": "LU"
        case "TruePk": "dBTP"
        case "Peak", "RMS": "dBFS"
        case "Crest": L("дБ")
        default: ""
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            Text(showHints ? "\(L(name)) (\(L(hint)))" : L(name))
                .font(.system(size: isPrimary ? 10 : 9, weight: isPrimary ? .semibold : .regular))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Image(systemName: "info.circle")
                .font(.system(size: 7))
                .foregroundStyle(.tertiary)
            Spacer(minLength: 2)
            if let value, value.isFinite {
                Text(String(format: "%.1f", value))
                    .font(.system(size: isPrimary ? 14 : 10, design: .monospaced)
                        .weight(isPrimary ? .bold : .medium))
            } else {
                Text("--")
                    .font(.system(size: isPrimary ? 14 : 10, design: .monospaced).weight(.medium))
                    .foregroundStyle(.tertiary)
            }
            if !unit.isEmpty {
                Text(unit)
                    .font(.system(size: 7))
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
        }
        .contentShape(Rectangle())
        .onHover(perform: setHovered)
        .overlay(alignment: .bottomLeading) {
            if isTooltipVisible, !tooltip.isEmpty {
                Text(L(tooltip))
                    .font(.system(size: 11))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 7)
                    .frame(maxWidth: 280, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.primary.opacity(0.20)))
                    .offset(y: 22)
                    .allowsHitTesting(false)
            }
        }
        .zIndex(isTooltipVisible ? 50 : 0)
        .accessibilityElement(children: .combine)
        .accessibilityHint(L(tooltip))
        .accessibilityValue(value.map { "\($0) \(unit)" } ?? L("нет данных"))
        .onDisappear {
            tooltipWorkItem?.cancel()
            tooltipWorkItem = nil
            isTooltipVisible = false
        }
    }

    private func setHovered(_ hovering: Bool) {
        tooltipWorkItem?.cancel()
        tooltipWorkItem = nil
        guard hovering else {
            isTooltipVisible = false
            return
        }
        let work = DispatchWorkItem { isTooltipVisible = true }
        tooltipWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
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
                .fill(valueDB > maxDB - 1 ? Color.red : Color.primary.opacity(0.8))
                .frame(height: 2)
                .offset(y: y)
        }
        .allowsHitTesting(false)
    }
}
