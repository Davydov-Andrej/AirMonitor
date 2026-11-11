import SwiftUI
import CoreAudio
import yaCore

/// Режим добавления шины в диалоге.
enum BusDraftMode: String, CaseIterable, Identifiable {
    case stereo = "Стерео-пара (L/R)"
    case mono = "Моно-каналы"

    var id: String { rawValue }
}

/// Сохранённая сцена: набор шин с настройками.
struct MonitorScene: Codable, Identifiable {
    let id: UUID
    var name: String
    var buses: [MonitorBusConfig]
    var createdAt: Date

    init(name: String, buses: [MonitorBusConfig]) {
        self.id = UUID()
        self.name = name
        self.buses = buses
        self.createdAt = Date()
    }
}

enum AppTheme: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "Как в системе"
        case .light: "Светлая"
        case .dark: "Тёмная"
        }
    }

    func resolvedColorScheme(system: ColorScheme) -> ColorScheme {
        switch self {
        case .system: system
        case .light: .light
        case .dark: .dark
        }
    }
}

/// Глобальная модель приложения: управляет шинами мониторинга.
@MainActor
final class AppModel: ObservableObject {

    // Выбираемые устройства и шины
    @Published var devices: [AudioDeviceInfo] = []
    @Published var buses: [MonitorBus] = []
    @Published var dashboardColumns: DashboardColumnLayout {
        didSet { UserDefaults.standard.set(dashboardColumns.rawValue, forKey: "AirMonitor.dashboardColumns") }
    }
    @Published var dashboardCardSize: DashboardCardSize {
        didSet { UserDefaults.standard.set(dashboardCardSize.rawValue, forKey: "AirMonitor.dashboardCardSize") }
    }
    @Published var dashboardAutoWrapModules: Bool {
        didSet { UserDefaults.standard.set(dashboardAutoWrapModules, forKey: "AirMonitor.dashboardAutoWrapModules") }
    }
    @Published var dashboardAutoStretchGraphs: Bool {
        didSet { UserDefaults.standard.set(dashboardAutoStretchGraphs, forKey: "AirMonitor.dashboardAutoStretchGraphs") }
    }
    @Published var appTheme: AppTheme {
        didSet { UserDefaults.standard.set(appTheme.rawValue, forKey: "AirMonitor.appTheme") }
    }

    // Снимки для UI
    @Published var snapshot: AppSnapshot = .empty
    @Published var isCapturing = false
    @Published var errorMessage: String?

    // Черновик новой шины (или редактирование существующей)
    @Published var isPresentingAddBus = false
    @Published var editingBusID: BusID?
    @Published var draftName: String = ""
    @Published var draftDeviceUID: String?
    @Published var draftMode: BusDraftMode = .stereo
    @Published var draftMonoChannels: Set<Int> = []
    @Published var draftLeft: Int = 0
    @Published var draftRight: Int = 1

    // Сцены
    @Published var scenes: [MonitorScene] = []
    @Published var currentSceneName: String?
    @Published var isPresentingSaveScene = false
    @Published var sceneSaveName: String = ""

    // Настройки
    @Published var rtaSettings = RTASettings.default {
        didSet {
            // Мгновенное применение к работающим анализаторам.
            publisher?.applyRTASettings(rtaSettings)
            persistRTASettings()
        }
    }
    /// Частота публикации снимков DSP→UI. Фиксирована 15 Гц: глазу достаточно,
    /// и это вдвое снижает нагрузку против 30 Гц (см. историю оптимизаций).
    let updateRateHz: Double = 15
    /// Показывать русские пояснения к метрикам.
    @Published var showMetricHints: Bool {
        didSet {
            UserDefaults.standard.set(showMetricHints, forKey: "AirMonitor.showMetricHints")
        }
    }
    /// Сглаживание показаний метрик (как в Youlean): цифры не мельтешат.
    /// 0 = выкл, 0.5 = умеренное, 0.9 = сильное. @Published на main для UI,
    /// значение дублируется в nonisolated-хранилище для DSP-потока.


    /// Калибровочный офсет LUFS (дБ) — подгонка под эталонный метр.
    @Published var lufsOffset: Float {
        didSet {
            UserDefaults.standard.set(Double(lufsOffset), forKey: "AirMonitor.lufsOffset")
            publisher?.applyCalibration(lufsOffset)
        }
    }

    let deviceEngine = MultiDeviceCapture()
    private var publisher: AudioDataPublisher?
    private var deviceListener: AudioDeviceChangeObserver?

    private let scenesKey = "AirMonitor.scenes"
    private let lastSceneKey = "AirMonitor.lastScene"

    init() {
        appTheme = AppTheme(rawValue: UserDefaults.standard.string(forKey: "AirMonitor.appTheme") ?? "") ?? .system
        showMetricHints = UserDefaults.standard.bool(forKey: "AirMonitor.showMetricHints")
        let savedOffset = UserDefaults.standard.float(forKey: "AirMonitor.lufsOffset")
        lufsOffset = savedOffset
        let savedColumns = UserDefaults.standard.integer(forKey: "AirMonitor.dashboardColumns")
        dashboardColumns = DashboardColumnLayout(rawValue: savedColumns) ?? .one
        dashboardCardSize = DashboardCardSize(rawValue: UserDefaults.standard.string(forKey: "AirMonitor.dashboardCardSize") ?? "") ?? .standard
        dashboardAutoWrapModules = UserDefaults.standard.object(forKey: "AirMonitor.dashboardAutoWrapModules") as? Bool ?? true
        dashboardAutoStretchGraphs = UserDefaults.standard.object(forKey: "AirMonitor.dashboardAutoStretchGraphs") as? Bool ?? true

        loadSettings()
        loadScenes()
        if let lastName = UserDefaults.standard.string(forKey: lastSceneKey),
           let scene = scenes.first(where: { $0.name == lastName }) {
            restore(scene: scene)
        }
    }

    private func loadSettings() {
        if let data = UserDefaults.standard.data(forKey: "AirMonitor.rtaSettings"),
           let decoded = try? JSONDecoder().decode(RTASettingsDTO.self, from: data) {
            rtaSettings = decoded.toSettings()
        }
    }

    private func persistRTASettings() {
        if let data = try? JSONEncoder().encode(RTASettingsDTO(from: rtaSettings)) {
            UserDefaults.standard.set(data, forKey: "AirMonitor.rtaSettings")
        }
    }


    // MARK: - Устройства

    func refreshDevices() {
        let all = AudioHAL.audioDevices()
        devices = all.filter { $0.inputChannels > 0 }
        EngineLog.log("refreshDevices: всего \(all.count), с входом \(devices.count)")
        if draftDeviceUID == nil || !devices.contains(where: { $0.uid == draftDeviceUID }) {
            draftDeviceUID = devices.first(where: { $0.isDefaultInput })?.uid
                ?? devices.first?.uid
        }

        // Дисконнект/реконнект: обновляем состояние шин и пробуем автореконнект.
        updateBusConnectionStates()
    }

    /// Помечает шины с отсутствующим устройством и автоматически
    /// переподключает те, чьё устройство вернулось.
    private func updateBusConnectionStates() {
        let availableUIDs = Set(devices.map { $0.uid })

        for index in buses.indices {
            let uid = buses[index].config.deviceUID
            let isConnected = availableUIDs.contains(uid)

            // Дисконнект во время захвата: помечаем и разрываем подписку
            // (иначе шина молча фолбэкается на системный вход).
            if !isConnected && buses[index].isConnected {
                buses[index].needsReconnect = true
                publisher?.removeBus(id: buses[index].id)
                EngineLog.log("Дисконнект устройства шины «\(buses[index].config.name)»")
            }

            // Реконнект: устройство вернулось.
            if isConnected && !buses[index].isConnected && isCapturing {
                EngineLog.log("Реконнект шины «\(buses[index].config.name)»")
                reconnectBus(at: index)
                buses[index].needsReconnect = false
            }

            buses[index].isConnected = isConnected
        }
    }

    private func reconnectBus(at index: Int) {
        guard let publisher else { return }
        let config = buses[index].config
        publisher.updateDeviceMap(devices)
        _ = publisher.addBus(config)
    }

    func startObservingDeviceChanges() {
        guard deviceListener == nil else { return }
        deviceListener = AudioDeviceChangeObserver { [weak self] in
            Task { @MainActor in
                self?.refreshDevices()
            }
        }
    }

    func stopObservingDeviceChanges() {
        deviceListener?.cancel()
        deviceListener = nil
    }

    deinit {
        deviceListener?.cancel()
    }

    // MARK: - Шины: добавление и редактирование

    /// Открыть диалог добавления (editingBusID == nil) или редактирования.
    func beginAddBus() {
        editingBusID = nil
        resetDraft()
        isPresentingAddBus = true
    }

    func beginEditBus(id: BusID) {
        guard let bus = buses.first(where: { $0.config.id == id }) else { return }
        editingBusID = id
        draftName = bus.config.name
        draftDeviceUID = bus.config.deviceUID
        draftMode = bus.config.mode.isStereo ? .stereo : .mono
        if case .stereo(let l, let r) = bus.config.mode {
            draftLeft = l
            draftRight = r
        }
        if case .mono(let ch) = bus.config.mode {
            draftMonoChannels = Set(ch)
        }
        isPresentingAddBus = true
    }

    /// Применить черновик: создать новую шину или обновить существующую.
    /// Работает и во время мониторинга — шина подключается на лету.
    func commitDraftBus() {
        guard let device = draftDevice else {
            errorMessage = "Выберите входное устройство"
            return
        }

        let mode: BusMode
        switch draftMode {
        case .stereo:
            guard draftLeft != draftRight else {
                errorMessage = "Для стерео выберите два разных канала"
                return
            }
            mode = .stereo(left: draftLeft, right: draftRight)
        case .mono:
            guard !draftMonoChannels.isEmpty else {
                errorMessage = "Выберите хотя бы один канал"
                return
            }
            mode = .mono(channels: draftMonoChannels.sorted())
        }

        let name = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        let config = MonitorBusConfig(
            name: name.isEmpty ? defaultName(for: device, mode: mode) : name,
            deviceUID: device.uid,
            mode: mode,
            sampleRate: rate(for: device.deviceID)
        )

        if let editingID = editingBusID,
           let index = buses.firstIndex(where: { $0.config.id == editingID }) {
            // Редактирование: замена конфига.
            var updated = config
            updated = MonitorBusConfig(
                id: editingID,
                name: config.name,
                deviceUID: config.deviceUID,
                mode: config.mode,
                sampleRate: config.sampleRate
            )
            buses[index].config = updated
            // Если захват идёт — переподключаем шину на лету.
            if isCapturing, let publisher {
                publisher.removeBus(id: editingID)
                _ = publisher.addBus(updated)
            }
        } else {
            // Новая шина.
            buses.append(MonitorBus(config: config))
            // Если захват идёт — добавляем на лету.
            if isCapturing, let publisher {
                _ = publisher.addBus(config)
            }
        }
        syncBusOrder()

        isPresentingAddBus = false
        editingBusID = nil
        resetDraft()
        autosaveCurrentScene()
        EngineLog.log("Шина «\(config.name)» применена (захват: \(isCapturing))")
    }

    func removeBus(id: BusID) {
        buses.removeAll { $0.config.id == id }
        publisher?.removeBus(id: id)
        holdersLock.lock()
        holders.removeValue(forKey: id)
        holdersLock.unlock()
        syncBusOrder()
        autosaveCurrentScene()
    }

    func renameBus(id: BusID, to newName: String) {
        guard let index = buses.firstIndex(where: { $0.config.id == id }) else { return }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        buses[index].config = buses[index].config.changingName(trimmed)
        if isCapturing {
            publisher?.renameBus(id: id, to: trimmed)
        }
        autosaveCurrentScene()
    }

    /// Переместить шину (порядок отображения).
    func moveBus(from offsets: IndexSet, to destination: Int) {
        buses.move(fromOffsets: offsets, toOffset: destination)
        syncBusOrder()
        autosaveCurrentScene()
    }

    func moveBusUp(id: BusID) {
        guard let index = buses.firstIndex(where: { $0.id == id }), index > 0 else { return }
        buses.swapAt(index, index - 1)
        syncBusOrder()
        autosaveCurrentScene()
    }

    func moveBusDown(id: BusID) {
        guard let index = buses.firstIndex(where: { $0.id == id }), index < buses.count - 1 else { return }
        buses.swapAt(index, index + 1)
        syncBusOrder()
        autosaveCurrentScene()
    }

    /// Переместить карточку шины до/после другой карточки на дашборде.
    func moveBus(id: BusID, relativeTo targetID: BusID, after: Bool) {
        guard id != targetID,
              let sourceIndex = buses.firstIndex(where: { $0.id == id }),
              let targetIndex = buses.firstIndex(where: { $0.id == targetID }) else { return }
        let bus = buses.remove(at: sourceIndex)
        var destination = targetIndex + (after ? 1 : 0)
        if sourceIndex < destination { destination -= 1 }
        destination = max(0, min(buses.count, destination))
        guard destination != sourceIndex else {
            buses.insert(bus, at: sourceIndex)
            return
        }
        buses.insert(bus, at: destination)
        syncBusOrder()
        autosaveCurrentScene()
    }

    func setDashboardModuleVisible(_ module: DashboardModule, on busID: BusID, visible: Bool) {
        guard let index = buses.firstIndex(where: { $0.id == busID }) else { return }
        var config = buses[index].config
        if visible {
            config.hiddenDashboardModules.remove(module)
            if !config.dashboardModuleOrder.contains(module) {
                config.dashboardModuleOrder.append(module)
            }
        } else {
            config.hiddenDashboardModules.insert(module)
        }
        buses[index].config = config
        autosaveCurrentScene()
    }

    func setDashboardModuleSize(_ module: DashboardModule, on busID: BusID, width: Double, height: Double) {
        guard let index = buses.firstIndex(where: { $0.id == busID }) else { return }
        var config = buses[index].config
        config.dashboardModuleWidths[module.rawValue] = max(module.minimumWidth, min(1_200, width))
        config.dashboardModuleHeights[module.rawValue] = max(module.minimumHeight, min(700, height))
        buses[index].config = config
        autosaveCurrentScene()
    }

    func setDashboardModuleRow(_ module: DashboardModule, on busID: BusID, row: Int) {
        guard let index = buses.firstIndex(where: { $0.id == busID }) else { return }
        var config = buses[index].config
        let newRow = max(0, min(1, row))
        guard config.dashboardModuleRows[module.rawValue] != newRow else { return }
        config.dashboardModuleRows[module.rawValue] = newRow
        buses[index].config = config
        autosaveCurrentScene()
    }

    func clearDashboardModuleRowOverrides(on busID: BusID) {
        guard let index = buses.firstIndex(where: { $0.id == busID }),
              !buses[index].config.dashboardModuleRowOverrides.isEmpty else { return }
        buses[index].config.dashboardModuleRowOverrides = [:]
        autosaveCurrentScene()
    }

    func setDashboardModuleRowOverride(_ module: DashboardModule, on busID: BusID, row: Int) {
        guard let index = buses.firstIndex(where: { $0.id == busID }) else { return }
        let newRow = max(0, min(1, row))
        guard buses[index].config.dashboardModuleRowOverrides[module.rawValue] != newRow else { return }
        buses[index].config.dashboardModuleRowOverrides[module.rawValue] = newRow
        autosaveCurrentScene()
    }

    func setDashboardModuleRows(_ rows: [[DashboardModule]], on busID: BusID) {
        guard let index = buses.firstIndex(where: { $0.id == busID }) else { return }
        var config = buses[index].config
        var changed = false
        for (row, modules) in rows.enumerated() {
            for module in modules {
                let value = min(1, row)
                if config.dashboardModuleRows[module.rawValue] != value {
                    config.dashboardModuleRows[module.rawValue] = value
                    changed = true
                }
            }
        }
        guard changed else { return }
        buses[index].config = config
        autosaveCurrentScene()
    }

    func moveDashboardModule(_ module: DashboardModule, on busID: BusID,
                             relativeTo target: DashboardModule, after: Bool, row: Int,
                             autoWrapRowOverride: Bool = false) {
        guard module != target,
              let index = buses.firstIndex(where: { $0.id == busID }) else { return }
        var config = buses[index].config
        var order = config.dashboardModuleOrder
        for item in DashboardModule.allCases where !order.contains(item) { order.append(item) }
        guard let sourceIndex = order.firstIndex(of: module),
              let targetIndex = order.firstIndex(of: target) else { return }
        order.remove(at: sourceIndex)
        var destination = targetIndex + (after ? 1 : 0)
        if sourceIndex < destination { destination -= 1 }
        destination = max(0, min(order.count, destination))
        order.insert(module, at: destination)
        let newRow = max(0, min(1, row))
        let rowChanged = autoWrapRowOverride
            ? config.dashboardModuleRowOverrides[module.rawValue] != newRow
            : config.dashboardModuleRows[module.rawValue] != newRow
        guard order != config.dashboardModuleOrder || rowChanged else { return }
        config.dashboardModuleOrder = order
        if autoWrapRowOverride {
            config.dashboardModuleRowOverrides[module.rawValue] = newRow
        } else {
            config.dashboardModuleRows[module.rawValue] = newRow
        }
        buses[index].config = config
        autosaveCurrentScene()
    }

    func resetDashboardModules(on busID: BusID) {
        guard let index = buses.firstIndex(where: { $0.id == busID }) else { return }
        var config = buses[index].config
        config.dashboardModuleOrder = DashboardModule.allCases
        config.hiddenDashboardModules = [.mixBalance]
        config.dashboardModuleWidths = Dictionary(uniqueKeysWithValues: DashboardModule.allCases.map {
            ($0.rawValue, $0.defaultWidth)
        })
        config.dashboardModuleHeights = Dictionary(uniqueKeysWithValues: DashboardModule.allCases.map {
            ($0.rawValue, $0.defaultHeight)
        })
        config.dashboardModuleRows = [:]
        config.dashboardModuleRowOverrides = [:]
        buses[index].config = config
        autosaveCurrentScene()
    }

    /// Перемещение по снимку (для вкладок, где рендер идёт из snapshot).
    func moveBusSnapshot(id: BusID, delta: Int) {
        if delta < 0 { moveBusUp(id: id) } else { moveBusDown(id: id) }
    }

    /// Настройка сетки: доля ширины спектра в нижнем ряду карточки шины.
    func setBusSpectrumFraction(id: BusID, fraction: Double) {
        guard let index = buses.firstIndex(where: { $0.id == id }) else { return }
        buses[index].config.spectrumWidthFraction = max(0.25, min(0.75, fraction))
        autosaveCurrentScene()
    }

    /// Синхронизирует порядок шин в паблишере — все вкладки показывают
    /// одинаковый порядок.
    private func syncBusOrder() {
        publisher?.setBusOrder(buses.map { $0.id })
    }

    private func defaultName(for device: AudioDeviceInfo, mode: BusMode) -> String {
        switch mode {
        case .stereo(let l, let r):
            return "\(device.name) \(l + 1)/\(r + 1)"
        case .mono(let channels):
            return "\(device.name) " + channels.map { "\($0 + 1)" }.joined(separator: "+")
        }
    }

    private func rate(for deviceID: AudioDeviceID) -> Double {
        let r = AudioHAL.sampleRate(for: deviceID)
        return r > 0 ? r : 48000
    }

    // MARK: - Запуск/стоп

    func startCapture() {
        guard !buses.isEmpty else {
            errorMessage = "Добавьте хотя бы одну шину мониторинга"
            return
        }

        let publisher = AudioDataPublisher(
            settings: .init(fftLength: 4096, updateRateHz: updateRateHz, windowType: .hann, rta: rtaSettings)
        )
        publisher.updateDeviceMap(devices)

        // Регистрируем холдеры ДО старта: publish пишет в них напрямую с
        // DSP-очереди (потокобезопасно, без прыжков в MainActor).
        // ВАЖНО: переиспользуем СУЩЕСТВУЮЩИЕ holders — SwiftUI-графики держат
        // ссылку на holder через замыкание versionProvider; пересоздание рвёт
        // связь и версионный гейт блокирует отрисовку навсегда.
        holdersLock.lock()
        for bus in buses {
            if holders[bus.config.id] == nil {
                holders[bus.config.id] = BusSnapshotHolder(id: bus.config.id)
            }
        }
        // Удаляем holders ушедших шин.
        let activeIDs = Set(buses.map { $0.config.id })
        for stale in holders.keys where !activeIDs.contains(stale) {
            holders.removeValue(forKey: stale)
        }
        holdersLock.unlock()

        // Замыкание НЕ изолировано MainActor: вызывается с analysis-очереди 60 раз/с.
        // AppModel — @MainActor, поэтому вся работа вынесена в nonisolated-метод
        // (иначе dispatch_assert_queue крашит при обращении к self из DSP-потока).
        publisher.setOnSnapshot { [weak self] snapshot in
            self?.ingestSnapshot(snapshot)
        }

        // Старт AUHAL блокирует main на ~1-2 с (AudioDeviceCreateIOProcID внутри
        // драйвера устройства синхронный) — вся инициализация на фоновой очереди,
        // UI остаётся живым.
        isCapturing = true  // сразу показываем состояние (кнопка/индикатор)
        errorMessage = nil

        let busesToStart = buses.map { $0.config }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            var ok = true
            var failureMessage: String?
            for config in busesToStart {
                if !publisher.addBus(config) {
                    ok = false
                    failureMessage = "Не удалось подключиться к каналам «\(config.name)»"
                    break
                }
            }
            var startError: AudioError?
            if ok {
                startError = publisher.start()
            }

            Task { @MainActor [weak self] in
                guard let self else { return }
                if let failureMessage {
                    self.errorMessage = failureMessage
                    self.isCapturing = false
                } else if let startError {
                    self.errorMessage = startError.localizedDescription
                    self.isCapturing = false
                } else {
                    self.publisher = publisher
                    self.isCapturing = true
                    self.errorMessage = nil
                    self.syncBusOrder()
                    publisher.applyCalibration(self.lufsOffset)
                    EngineLog.log("startCapture: шин \(busesToStart.count) (фоновый старт)")
                }
            }
        }
    }

    /// Порядок шин последнего снапшота. Пишется из DSP-потока, читается оттуда же;
    /// MainActor читает через syncOrderFromSnapshot — под orderLock.
    nonisolated(unsafe) private var currentOrder: [BusID] = []
    nonisolated private let orderLock = NSLock()
    /// Горячий путь доставки снимков (DSP-поток, nonisolated).
    /// Только lock-защищённые поля — MainActor не трогается.
    nonisolated private func ingestSnapshot(_ snapshot: AppSnapshot) {
        let newOrder = snapshot.buses.map(\.id)
        orderLock.lock()
        let changed = newOrder != currentOrder
        if changed { currentOrder = newOrder }
        orderLock.unlock()
        if changed {
            Task { @MainActor [weak self] in
                self?.syncOrderFromSnapshot(newOrder)
            }
        }
        holdersLock.lock()
        let targets = snapshot.buses.compactMap { bus in
            (bus, holders[bus.id])
        }
        holdersLock.unlock()
        for (busSnapshot, holder) in targets {
            holder?.update(busSnapshot)
        }
    }


    /// Флаг изменения порядка (ставится из DSP-потока, снимается на MainActor).
    private let orderChangedLock = NSLock()
    private var orderChangedPending: [BusID]? = nil

    /// Синхронизирует порядок из снапшота (редко, только при изменении состава).
    @MainActor
    private func syncOrderFromSnapshot(_ order: [BusID]) {
        snapshot = AppSnapshot(
            buses: order.compactMap { holders[$0]?.snapshot },
            integratedLUFS: snapshot.integratedLUFS,
            loudnessRangeLU: snapshot.loudnessRangeLU,
            timestamp: Date()
        )
    }

    nonisolated(unsafe) private var holders: [BusID: BusSnapshotHolder] = [:]
    nonisolated private let holdersLock = NSLock()

    func stopCapture() {
        isCapturing = false
        publisher?.stop()
        publisher = nil
        snapshot = .empty
    }

    // MARK: - Сцены

    func saveScene(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Заменяем существующую сцену с тем же именем.
        scenes.removeAll { $0.name == trimmed }
        let scene = MonitorScene(name: trimmed, buses: buses.map { $0.config })
        scenes.append(scene)
        scenes.sort { $0.createdAt < $1.createdAt }
        currentSceneName = trimmed
        persistScenes()
    }

    func restore(scene: MonitorScene) {
        stopCapture()
        buses = scene.buses.map { MonitorBus(config: $0) }
        currentSceneName = scene.name
        UserDefaults.standard.set(scene.name, forKey: lastSceneKey)
    }

    func restoreScene(named name: String) {
        guard let scene = scenes.first(where: { $0.name == name }) else { return }
        restore(scene: scene)
    }

    func deleteScene(named name: String) {
        scenes.removeAll { $0.name == name }
        if currentSceneName == name {
            currentSceneName = nil
        }
        persistScenes()
    }

    /// Автосохранение рабочей сцены (если сцена активна).
    private func autosaveCurrentScene() {
        guard let name = currentSceneName else { return }
        scenes.removeAll { $0.name == name }
        let scene = MonitorScene(name: name, buses: buses.map { $0.config })
        scenes.append(scene)
        persistScenes()
    }

    private func persistScenes() {
        if let data = try? JSONEncoder().encode(scenes) {
            UserDefaults.standard.set(data, forKey: scenesKey)
        }
    }

    private func loadScenes() {
        if let data = UserDefaults.standard.data(forKey: scenesKey),
           let decoded = try? JSONDecoder().decode([MonitorScene].self, from: data) {
            scenes = decoded.sorted { $0.createdAt < $1.createdAt }
        }
    }

    // MARK: - Черновик

    private func resetDraft() {
        draftName = ""
        draftMode = .stereo
        draftMonoChannels = []
        draftLeft = 0
        draftRight = 1
        draftDeviceUID = devices.first(where: { $0.isDefaultInput })?.uid ?? devices.first?.uid
    }

    // MARK: - Доступ

    var draftDevice: AudioDeviceInfo? {
        guard let uid = draftDeviceUID else { return nil }
        return devices.first { $0.uid == uid }
    }

    var draftChannelCount: Int {
        draftDevice?.inputChannels ?? 0
    }

    var isEditingBus: Bool { editingBusID != nil }
}

/// Шина мониторинга в UI. Хранит конфиг.
final class MonitorBus: ObservableObject, Identifiable {
    @Published var config: MonitorBusConfig
    /// Устройство доступно в системе.
    @Published var isConnected: Bool = true
    /// Захват прерван из-за дисконнекта — требуется переподключение.
    @Published var needsReconnect: Bool = false

    var id: BusID { config.id }

    init(config: MonitorBusConfig) {
        self.config = config
    }
}

extension AppModel {
    func busPreview(for bus: MonitorBus) -> BusSnapshot? {
        snapshot.bus(id: bus.id)
    }

    /// Холдер снимка шины для изолированных обновлений карточки.
    func holder(for bus: MonitorBus) -> BusSnapshotHolder {
        holdersLock.lock()
        defer { holdersLock.unlock() }
        if let h = holders[bus.id] { return h }
        let h = BusSnapshotHolder(id: bus.id)
        holders[bus.id] = h
        return h
    }
}

/// Потокобезопасное хранилище снимка шины. БЕЗ ObservableObject/@Published:
/// UI читает данные по своему таймеру (TimelineView), пуш-инвалидаций SwiftUI
/// нет — publish не дёргает main-поток.
final class BusSnapshotHolder {
    private let lock = NSLock()
    private var storage: BusSnapshot?
    /// Монотонный счётчик обновлений: графики рендерятся только когда данные
    /// изменились (publish 15 Гц против display-link 30 Гц — половина кадров
    /// иначе перерисовывает то же самое впустую).
    private var version = 0
    let id: BusID

    init(id: BusID) {
        self.id = id
    }

    var snapshot: BusSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    /// Текущая версия данных (растёт при каждом update).
    var dataVersion: Int {
        lock.lock()
        defer { lock.unlock() }
        return version
    }

    func update(_ snapshot: BusSnapshot) {
        lock.lock()
        storage = snapshot
        version += 1
        lock.unlock()
    }
}
