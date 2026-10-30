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

/// Глобальная модель приложения: управляет шинами мониторинга.
@MainActor
final class AppModel: ObservableObject {

    // Выбираемые устройства и шины
    @Published var devices: [AudioDeviceInfo] = []
    @Published var buses: [MonitorBus] = []

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
    @Published var updateRateHz: Double = 25 {
        didSet {
            persistUpdateRate()
        }
    }
    /// Показывать русские пояснения к метрикам.
    @Published var showMetricHints: Bool {
        didSet {
            UserDefaults.standard.set(showMetricHints, forKey: "AirMonitor.showMetricHints")
        }
    }

    let deviceEngine = MultiDeviceCapture()
    private var publisher: AudioDataPublisher?
    private var deviceListener: AudioDeviceChangeObserver?

    private let scenesKey = "AirMonitor.scenes"
    private let lastSceneKey = "AirMonitor.lastScene"

    init() {
        showMetricHints = UserDefaults.standard.bool(forKey: "AirMonitor.showMetricHints")
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
        let rate = UserDefaults.standard.double(forKey: "AirMonitor.updateRate")
        if rate > 0 { updateRateHz = rate }
    }

    private func persistRTASettings() {
        if let data = try? JSONEncoder().encode(RTASettingsDTO(from: rtaSettings)) {
            UserDefaults.standard.set(data, forKey: "AirMonitor.rtaSettings")
        }
    }

    private func persistUpdateRate() {
        UserDefaults.standard.set(updateRateHz, forKey: "AirMonitor.updateRate")
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

        isPresentingAddBus = false
        editingBusID = nil
        resetDraft()
        autosaveCurrentScene()
        EngineLog.log("Шина «\(config.name)» применена (захват: \(isCapturing))")
    }

    func removeBus(id: BusID) {
        buses.removeAll { $0.config.id == id }
        publisher?.removeBus(id: id)
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
        autosaveCurrentScene()
    }

    func moveBusUp(id: BusID) {
        guard let index = buses.firstIndex(where: { $0.id == id }), index > 0 else { return }
        buses.swapAt(index, index - 1)
        autosaveCurrentScene()
    }

    func moveBusDown(id: BusID) {
        guard let index = buses.firstIndex(where: { $0.id == id }), index < buses.count - 1 else { return }
        buses.swapAt(index, index + 1)
        autosaveCurrentScene()
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
            settings: .init(fftLength: 8192, updateRateHz: updateRateHz, windowType: .hann, rta: rtaSettings)
        )
        publisher.updateDeviceMap(devices)
        publisher.setOnSnapshot { [weak self] snapshot in
            Task { @MainActor in
                self?.snapshot = snapshot
            }
        }

        var ok = true
        for bus in buses {
            if !publisher.addBus(bus.config) {
                ok = false
                errorMessage = "Не удалось подключиться к каналам «\(bus.config.name)»"
            }
        }
        guard ok else { return }

        if let error = publisher.start() {
            errorMessage = error.localizedDescription
            return
        }

        self.publisher = publisher
        isCapturing = true
        errorMessage = nil
        EngineLog.log("startCapture: шин \(buses.count)")
    }

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

    var id: BusID { config.id }

    init(config: MonitorBusConfig) {
        self.config = config
    }
}

extension AppModel {
    func busPreview(for bus: MonitorBus) -> BusSnapshot? {
        snapshot.bus(id: bus.id)
    }
}