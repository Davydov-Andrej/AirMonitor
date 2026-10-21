import SwiftUI
import CoreAudio
import yaCore

/// Режим добавления шины в диалоге.
enum BusDraftMode: String, CaseIterable, Identifiable {
    case stereo = "Стерео-пара (L/R)"
    case mono = "Моно-каналы"

    var id: String { rawValue }
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

    // Черновик новой шины
    @Published var isPresentingAddBus = false
    @Published var draftName: String = ""
    @Published var draftDeviceUID: String?
    @Published var draftMode: BusDraftMode = .stereo
    @Published var draftMonoChannels: Set<Int> = []
    @Published var draftLeft: Int = 0
    @Published var draftRight: Int = 1

    let deviceEngine = MultiDeviceCapture()
    private var publisher: AudioDataPublisher?
    private var deviceListener: AudioDeviceChangeObserver?

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

    // MARK: - Шины

    /// Создаёт шину из черновика.
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

        buses.append(MonitorBus(config: config))

        isPresentingAddBus = false
        resetDraft()
        EngineLog.log("Добавлена шина «\(config.name)»: \(config.mode) на \(device.name)")
    }

    func removeBus(id: BusID) {
        buses.removeAll { $0.config.id == id }
    }

    func renameBus(id: BusID, to newName: String) {
        guard let index = buses.firstIndex(where: { $0.config.id == id }) else { return }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        buses[index].config = buses[index].config.changingName(trimmed)
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

        let publisher = AudioDataPublisher(settings: .init(fftLength: 8192, updateRateHz: 25, windowType: .hann))
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
    }

    private func resetDraft() {
        draftName = ""
        draftMode = .stereo
        draftMonoChannels = []
        draftLeft = 0
        draftRight = 1
        draftDeviceUID = devices.first(where: { $0.isDefaultInput })?.uid ?? devices.first?.uid
    }

    // MARK: - Доступ к устройствам

    var draftDevice: AudioDeviceInfo? {
        guard let uid = draftDeviceUID else { return nil }
        return devices.first { $0.uid == uid }
    }

    var draftChannelCount: Int {
        draftDevice?.inputChannels ?? 0
    }
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