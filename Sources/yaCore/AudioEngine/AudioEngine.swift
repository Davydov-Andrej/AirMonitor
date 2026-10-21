import Foundation
import CoreAudio
import AudioToolbox

/// Подписка на набор каналов устройства. Индексы — физические каналы USB
/// (0-based), например для Yamaha TF: 0..<16.
public struct ChannelSubscription: Hashable {
    public let deviceID: AudioDeviceID
    public let channelIndexes: [Int]
    public let label: String
    public let recommendedSampleRate: Double

    public init(
        deviceID: AudioDeviceID,
        channelIndexes: [Int],
        label: String,
        recommendedSampleRate: Double
    ) {
        self.deviceID = deviceID
        self.channelIndexes = channelIndexes
        self.label = label
        self.recommendedSampleRate = recommendedSampleRate
    }

    public func containsChannel(_ index: Int) -> Bool {
        channelIndexes.contains(index)
    }
}

/// Кадр, захваченный с устройства (по одному буферу на активный канал).
public struct Frame: Sendable {
    public let channelSamples: [ChannelSamples]
    public let frameCount: Int
    public let sampleRate: Double

    public init(channelSamples: [ChannelSamples], frameCount: Int, sampleRate: Double) {
        self.channelSamples = channelSamples
        self.frameCount = frameCount
        self.sampleRate = sampleRate
    }

    public func samples(for channelIndex: Int) -> [Float]? {
        channelSamples.first { $0.channelIndex == channelIndex }?.samples
    }
}

/// Единый движок захвата. v1 поддерживает одну подписку (номер 0).
public final class AudioEngine {

    public private(set) var isRunning = false
    public private(set) var captureSampleRate: Double = 0
    public private(set) var deviceInputChannels = 0
    public private(set) var activeChannels: [Int] = []

    private var capture: AudioCaptureImpl?
    private let lock = NSLock()

    private var subscription: ChannelSubscription?
    private var onFrame: (@Sendable (Frame) -> Void)?

    public init() {}

    @discardableResult
    public func setInput(_ subscription: ChannelSubscription, onFrame: @escaping @Sendable (Frame) -> Void) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        self.subscription = subscription
        self.onFrame = onFrame
        return true
    }

    @discardableResult
    public func start() -> AudioError? {
        lock.lock()
        defer { lock.unlock() }

        guard !isRunning else { return nil }
        guard let subscription else { return nil }

        let inputChannels = AudioHAL.inputChannels(for: subscription.deviceID)
        deviceInputChannels = inputChannels
        EngineLog.log("start(): deviceID=\(subscription.deviceID) '\(subscription.label)' каналов=\(inputChannels), выбранные каналы=\(subscription.channelIndexes)")
        guard inputChannels > 0 else { return .noInputChannels }

        let rate = activeRates(for: subscription.deviceID).max() ?? 48000
        captureSampleRate = rate

        guard channelIndexesAreValid(subscription, totalInput: inputChannels) else {
            return .invalidDevice(channel: subscription.channelIndexes.min() ?? 0)
        }

        let spec = AudioSourceSpec(
            deviceID: subscription.deviceID,
            sampleRate: rate,
            inputChannels: inputChannels
        )
        guard let capture = AudioCaptureImpl(spec: spec) else {
            log("AudioCaptureImpl не создан")
            return .engineNotConfigured
        }

        guard let onFrame else { return .engineNotConfigured }
        let handler = onFrame
        let wanted = subscription.channelIndexes
        capture.onFrame = { frame in
            let filtered = Frame(
                channelSamples: frame.channelSamples.filter { wanted.contains($0.channelIndex) },
                frameCount: frame.frameCount,
                sampleRate: frame.sampleRate
            )
            handler(filtered)
        }
        self.capture = capture

        guard capture.start() else {
            log("AudioCaptureImpl.start() не удался")
            self.capture = nil
            return .engineNotConfigured
        }
        isRunning = true
        activeChannels = subscription.channelIndexes
        return nil
    }

    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard isRunning else { return }
        capture?.stop()
        capture = nil
        isRunning = false
    }

    // MARK: - Private

    private func channelIndexesAreValid(_ subscription: ChannelSubscription, totalInput: Int) -> Bool {
        subscription.channelIndexes.allSatisfy { $0 >= 0 && $0 < totalInput }
    }

    private func activeRates(for deviceID: AudioDeviceID) -> [Double] {
        let current = AudioHAL.sampleRate(for: deviceID)
        return current > 0 ? [current] : [48000]
    }
}
