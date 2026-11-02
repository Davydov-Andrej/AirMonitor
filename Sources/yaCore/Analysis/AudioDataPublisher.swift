import Foundation
import CoreAudio
import uaDSP

/// Снимок состояния одного канала для UI (главный поток).
public struct ChannelSnapshot: Identifiable, Sendable {
    public let id: Int
    public let label: String
    public let peakDB: Float
    public let rmsDB: Float
    public let vuDB: Float
    public let truePeakDB: Float
    public let crestFactorDB: Float
    public let momentaryLUFS: Float
    public let shortTermLUFS: Float
    public let integratedLUFS: Float
    public let loudnessRangeLU: Float
    public let spectrum: [SpectrumPoint]
    public let rtaBands: [RTABand]
    public let fineCurve: [SpectrumPoint]
    public let loudnessHistory: [LoudnessMeter.HistoryPoint]

    public init(
        id: Int,
        label: String,
        peakDB: Float,
        rmsDB: Float,
        vuDB: Float,
        truePeakDB: Float,
        crestFactorDB: Float,
        momentaryLUFS: Float,
        shortTermLUFS: Float,
        spectrum: [SpectrumPoint],
        rtaBands: [RTABand] = [],
        fineCurve: [SpectrumPoint] = [],
        loudnessHistory: [LoudnessMeter.HistoryPoint] = [],
        integratedLUFS: Float = -Float.infinity,
        loudnessRangeLU: Float = 0
    ) {
        self.id = id
        self.label = label
        self.peakDB = peakDB
        self.rmsDB = rmsDB
        self.vuDB = vuDB
        self.truePeakDB = truePeakDB
        self.crestFactorDB = crestFactorDB
        self.momentaryLUFS = momentaryLUFS
        self.shortTermLUFS = shortTermLUFS
        self.spectrum = spectrum
        self.rtaBands = rtaBands
        self.fineCurve = fineCurve
        self.loudnessHistory = loudnessHistory
        self.integratedLUFS = integratedLUFS
        self.loudnessRangeLU = loudnessRangeLU
    }

    public static let empty = ChannelSnapshot(
        id: 0,
        label: "",
        peakDB: -Float.infinity,
        rmsDB: -Float.infinity,
        vuDB: -Float.infinity,
        truePeakDB: -Float.infinity,
        crestFactorDB: 0,
        momentaryLUFS: -Float.infinity,
        shortTermLUFS: -Float.infinity,
        spectrum: []
    )
}

/// Публикует снимки всех шин в UI. Управляет захватом устройств.
public final class AudioDataPublisher: @unchecked Sendable {

    public struct Settings {
        public var fftLength: Int = 8192
        public var updateRateHz: Double = 15
        public var windowType: FFT.WindowType = .hann
        public var rta: RTASettings = .default

        public init(
            fftLength: Int = 8192,
            updateRateHz: Double = 15,
            windowType: FFT.WindowType = .hann,
            rta: RTASettings = .default
        ) {
            self.fftLength = fftLength
            self.updateRateHz = updateRateHz
            self.windowType = windowType
            self.rta = rta
        }
    }

    public let deviceEngine = MultiDeviceCapture()

    private let settings: Settings
    /// Serial-очередь: вся DSP-обработка здесь, стабильный темп без гонок.
    private let analysisQueue = DispatchQueue(label: "airmonitor.analysis", qos: .userInteractive)
    private let lock = NSLock()

    private var buses: [BusID: BusRuntime] = [:]
    private var deviceRates: [AudioDeviceID: Double] = [:]
    /// Резолв UID → deviceID из последнего списка устройств.
    private var deviceIDByUID: [String: AudioDeviceID] = [:]

    private var lastPublish = Date.distantPast
    public private(set) var onSnapshot: ((AppSnapshot) -> Void)?

    public init(settings: Settings = Settings()) {
        self.settings = settings
    }

    /// Обновляет маппинг UID→ID (вызвать при старте / refreshDevices).
    public func updateDeviceMap(_ devices: [AudioDeviceInfo]) {
        lock.lock()
        defer { lock.unlock() }
        var map: [String: AudioDeviceID] = [:]
        for d in devices {
            map[d.uid] = d.deviceID
        }
        deviceIDByUID = map
    }

    /// Регистрирует обработчик снимков.
    public func setOnSnapshot(_ handler: @escaping (AppSnapshot) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        self.onSnapshot = handler
    }

    /// Добавляет шину, создаёт её анализаторы и запускает захват её устройства.
    @discardableResult
    public func addBus(_ config: MonitorBusConfig) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard buses[config.id] == nil else { return false }
        guard let deviceID = deviceIDByUID[config.deviceUID] else { return false }

        let rate = config.sampleRate > 0 ? config.sampleRate : (deviceRates[deviceID] ?? 48000)
        deviceRates[deviceID] = rate

        guard let runtime = makeRuntime(for: config, deviceID: deviceID, rate: rate) else { return false }
        buses[config.id] = runtime

        guard deviceEngine.ensureCapturing(deviceID: deviceID, rate: rate) else {
            buses[config.id] = nil
            return false
        }
        // Фильтр каналов: копируем только нужные шинам этого устройства.
        var wanted: Set<Int> = []
        for runtime in buses.values where runtime.deviceID == deviceID {
            for ch in runtime.config.mode.channelIndexes {
                wanted.insert(ch)
            }
        }
        deviceEngine.updateWantedChannels(deviceID: deviceID, channels: wanted)
        deviceEngine.setDestination(deviceID: deviceID) { [weak self] frame in
            self?.ingest(frame: frame, from: deviceID)
        }
        return true
    }

    public func removeBus(id: BusID) {
        lock.lock()
        defer { lock.unlock() }
        buses[id] = nil
    }

    public func renameBus(id: BusID, to newName: String) {
        lock.lock()
        defer { lock.unlock() }
        buses[id]?.config.name = newName
    }

    public func start() -> AudioError? {
        deviceEngine.startAll()
    }

    public func stop() {
        deviceEngine.stopAll()
    }

    /// Число активных шин (для UI).
    public var busCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return buses.count
    }

    // MARK: - Private

    private func makeRuntime(for config: MonitorBusConfig, deviceID: AudioDeviceID, rate: Double) -> BusRuntime? {
        let fftLength = config.fftLength > 0 ? config.fftLength : settings.fftLength
        let rta = settings.rta
        switch config.mode {
        case .mono(let channels):
            guard !channels.isEmpty else { return nil }
            var analyzers: [Int: ChannelAnalyzerSet] = [:]
            for ch in channels {
                analyzers[ch] = ChannelAnalyzerSet(
                    channelIndex: ch,
                    label: "\(config.name) · \(ch + 1)",
                    sampleRate: Float(rate),
                    fftLength: fftLength,
                    windowType: config.windowType,
                    rtaSettings: rta
                )
            }
            return BusRuntime(config: config, deviceID: deviceID, monoAnalyzers: analyzers, stereoAnalyzer: nil)
        case .stereo(let l, let r):
            guard l != r else { return nil }
            let stereo = StereoAnalyzerSet(
                left: l,
                right: r,
                label: config.name,
                sampleRate: Float(rate),
                fftLength: fftLength,
                windowType: config.windowType,
                rtaSettings: rta
            )
            return BusRuntime(config: config, deviceID: deviceID, monoAnalyzers: [:], stereoAnalyzer: stereo)
        }
    }

    private func ingest(frame: Frame, from deviceID: AudioDeviceID) {
        // Вся обработка — на одной serial-очереди: стабильный темп, без гонок.
        analysisQueue.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let busCopies = self.buses.values
                .filter { $0.deviceID == deviceID }
                .map { $0 }
            self.lock.unlock()

            let sampleRate = Float(frame.sampleRate)
            for runtime in busCopies {
                runtime.process(frame, sampleRate: sampleRate)
            }

            self.maybePublish()
        }
    }

    private func maybePublish() {
        lock.lock()
        let now = Date()
        let interval = 1.0 / max(settings.updateRateHz, 1)
        guard now.timeIntervalSince(lastPublish) >= interval else {
            lock.unlock()
            return
        }
        lastPublish = now

        var busSnapshots: [BusSnapshot] = []
        var lufs: [Float] = []
        for runtime in buses.values {
            let snap = runtime.snapshot()
            lufs.append(snap.mono?.momentaryLUFS ?? snap.channels.first?.momentaryLUFS ?? -100)
            busSnapshots.append(snap)
        }
        let app = AppSnapshot(
            buses: busSnapshots.sorted { $0.name.lowercased() < $1.name.lowercased() },
            integratedLUFS: lufs.isEmpty ? -Float.infinity : lufs.reduce(0, +) / Float(lufs.count),
            loudnessRangeLU: 0,
            timestamp: now
        )
        let publish = onSnapshot
        lock.unlock()

        publish?(app)
    }

    /// Применяет настройки RTA ко всем работающим анализаторам немедленно.
    public func applyRTASettings(_ newSettings: RTASettings) {
        analysisQueue.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let runtimes = Array(self.buses.values)
            self.lock.unlock()
            for runtime in runtimes {
                runtime.applyRTASettings(newSettings)
            }
        }
    }
}

/// Рантайм одной шины: анализаторы каналов/стерео.
public final class BusRuntime: @unchecked Sendable {
    public var config: MonitorBusConfig
    public let deviceID: AudioDeviceID
    public let monoAnalyzers: [Int: ChannelAnalyzerSet]
    public let stereoAnalyzer: StereoAnalyzerSet?

    public init(
        config: MonitorBusConfig,
        deviceID: AudioDeviceID,
        monoAnalyzers: [Int: ChannelAnalyzerSet],
        stereoAnalyzer: StereoAnalyzerSet?
    ) {
        self.config = config
        self.deviceID = deviceID
        self.monoAnalyzers = monoAnalyzers
        self.stereoAnalyzer = stereoAnalyzer
    }

    /// Лёгкая копия для работы в фоновом потоке (избегаем гонок по config).
    public func copyForProcessing() -> BusRuntime? {
        BusRuntime(
            config: config,
            deviceID: deviceID,
            monoAnalyzers: monoAnalyzers,
            stereoAnalyzer: stereoAnalyzer
        )
    }

    /// Применяет настройки RTA ко всем анализаторам шины немедленно.
    public func applyRTASettings(_ newSettings: RTASettings) {
        monoAnalyzers.values.forEach { $0.applyRTASettings(newSettings) }
        stereoAnalyzer?.monoAnalyzer.applyRTASettings(newSettings)
        stereoAnalyzer?.leftAnalyzer.applyRTASettings(newSettings)
        stereoAnalyzer?.rightAnalyzer.applyRTASettings(newSettings)
    }

    public func process(_ frame: Frame, sampleRate: Float) {
        if let stereoAnalyzer {
            for cs in frame.channelSamples {
                if cs.channelIndex == stereoAnalyzer.leftChannelIndex
                    || cs.channelIndex == stereoAnalyzer.rightChannelIndex {
                    stereoAnalyzer.push(channel: cs.channelIndex, samples: cs.samples)
                }
            }
            stereoAnalyzer.processFrame(frameCount: frame.frameCount, sampleRate: sampleRate)
        } else {
            for cs in frame.channelSamples {
                guard let analyzer = monoAnalyzers[cs.channelIndex] else { continue }
                analyzer.process(cs.samples, sampleRate: sampleRate)
            }
        }
    }

    public func snapshot() -> BusSnapshot {
        if let stereoAnalyzer {
            let result = stereoAnalyzer.snapshot()
            return BusSnapshot(
                id: config.id,
                name: config.name,
                mode: config.mode,
                channels: [result.left, result.right],
                mono: result.mono,
                correlation: result.correlation,
                sampleRate: config.sampleRate,
                frameCount: 0,
                hasSignal: result.left.peakDB > -90 || result.right.peakDB > -90
            )
        }

        let snapshots = monoAnalyzers
            .sorted { $0.key < $1.key }
            .map { $0.value.snapshot() }
        return BusSnapshot(
            id: config.id,
            name: config.name,
            mode: config.mode,
            channels: snapshots,
            mono: nil,
            correlation: nil,
            sampleRate: config.sampleRate,
            frameCount: 0,
            hasSignal: snapshots.contains { $0.peakDB > -90 }
        )
    }
}

/// Захват с нескольких устройств одновременно: один AUHAL на устройство.
public final class MultiDeviceCapture: @unchecked Sendable {
    private var captures: [AudioDeviceID: AudioCaptureImpl] = [:]
    private let lock = NSLock()
    private var onFrameByDevice: [AudioDeviceID: (@Sendable (Frame) -> Void)] = [:]

    public init() {}

    public func setDestination(
        deviceID: AudioDeviceID,
        handler: @escaping @Sendable (Frame) -> Void
    ) {
        lock.lock()
        defer { lock.unlock() }
        onFrameByDevice[deviceID] = handler
        // Если захват уже работает — обновляем колбэк.
        captures[deviceID]?.onFrame = { [weak self] frame in
            self?.onFrameByDevice[deviceID]?(frame)
        }
    }

    /// Обновляет список нужных каналов устройства (фильтр в render-колбэке).
    public func updateWantedChannels(deviceID: AudioDeviceID, channels: Set<Int>) {
        lock.lock()
        defer { lock.unlock() }
        captures[deviceID]?.wantedChannels = channels
    }

    /// Переподключает захват к устройству (после дисконнекта/реконнекта).
    public func restartCapture(deviceID: AudioDeviceID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let rate = lastRates[deviceID] ?? 48000
        captures[deviceID]?.stop()
        captures[deviceID] = nil

        let inputChannels = AudioHAL.inputChannels(for: deviceID)
        guard inputChannels > 0 else { return false }
        let spec = AudioSourceSpec(
            deviceID: deviceID,
            sampleRate: rate,
            inputChannels: inputChannels
        )
        guard let capture = AudioCaptureImpl(spec: spec) else { return false }
        capture.wantedChannels = wantedByDevice[deviceID] ?? []
        capture.onFrame = { [weak self] frame in
            self?.onFrameByDevice[deviceID]?(frame)
        }
        guard capture.start() else { return false }
        captures[deviceID] = capture
        return true
    }

    private var lastRates: [AudioDeviceID: Double] = [:]
    private var wantedByDevice: [AudioDeviceID: Set<Int>] = [:]

    @discardableResult
    public func ensureCapturing(deviceID: AudioDeviceID, rate: Double) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        lastRates[deviceID] = rate
        if captures[deviceID] != nil { return true }

        let inputChannels = AudioHAL.inputChannels(for: deviceID)
        guard inputChannels > 0 else { return false }
        let spec = AudioSourceSpec(
            deviceID: deviceID,
            sampleRate: rate,
            inputChannels: inputChannels
        )
        guard let capture = AudioCaptureImpl(spec: spec) else { return false }

        capture.onFrame = { [weak self] frame in
            self?.onFrameByDevice[deviceID]?(frame)
        }
        guard capture.start() else { return false }
        captures[deviceID] = capture
        return true
    }

    public func release(deviceID: AudioDeviceID) {
        lock.lock()
        defer { lock.unlock() }
        captures[deviceID]?.stop()
        captures[deviceID] = nil
    }

    public func allDevices() -> [AudioDeviceID] {
        lock.lock()
        defer { lock.unlock() }
        return Array(captures.keys)
    }

    public func startAll() -> AudioError? {
        nil
    }

    public func stopAll() {
        lock.lock()
        defer { lock.unlock() }
        for capture in captures.values {
            capture.stop()
        }
        captures = [:]
        onFrameByDevice = [:]
    }
}