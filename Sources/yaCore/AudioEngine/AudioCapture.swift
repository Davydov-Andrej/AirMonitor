import Foundation
import CoreAudio
import AudioToolbox

func log(_ message: String) {
    FileHandle.standardError.write(("[YamahaAir] " + message + "\n").data(using: .utf8)!)
}

/// Захват с выбранного устройства через AUHAL (CoreAudio). В отличие от
/// AVAudioEngine.inputNode (который всегда читает системный вход по умолчанию),
/// AUHAL позволяет явно привязать конкретное устройство через
/// kAudioOutputUnitProperty_CurrentDevice и получить все его входные каналы.
final class AudioCaptureImpl {

    private let spec: AudioSourceSpec
    private let lock = NSLock()
    private var isRunning = false

    private var audioUnit: AudioUnit?
    private var bufferListStorage: UnsafeMutableRawPointer?
    private var channelBuffers: [UnsafeMutableRawPointer] = []
    private var bufferFrames = 0

    /// Вызывается на фоне (не на аудио-потоке) с собранным кадром.
    /// Пишется с main (setDestination), читается на consumerQueue — под локом.
    private var onFrameStorage: (@Sendable (Frame) -> Void)?
    private let onFrameLock = NSLock()

    var onFrame: (@Sendable (Frame) -> Void)? {
        get {
            onFrameLock.lock()
            defer { onFrameLock.unlock() }
            return onFrameStorage
        }
        set {
            onFrameLock.lock()
            onFrameStorage = newValue
            onFrameLock.unlock()
        }
    }

    /// Каналы, которые реально нужны. Пусто = все. Фильтрация происходит
    /// прямо в render-колбэке — лишние каналы не копируются вообще.
    /// Пишется с main (updateWantedChannels), читается на аудио-потоке — под локом.
    private var wantedStorage: Set<Int> = []
    private let wantedLock = NSLock()

    var wantedChannels: Set<Int> {
        get {
            wantedLock.lock()
            defer { wantedLock.unlock() }
            return wantedStorage
        }
        set {
            wantedLock.lock()
            wantedStorage = newValue
            wantedLock.unlock()
        }
    }

    /// Связанные с инстансом данные для render-колбэка (без захвата контекста).
    private var context = CaptureContext()

    init?(spec: AudioSourceSpec) {
        guard spec.inputChannels > 0 else { return nil }
        self.spec = spec
    }

    deinit {
        stop()
    }

    func start() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isRunning else { return false }

        guard let unit = makeInputUnit() else {
            log("AUHAL: не удалось создать input unit")
            return false
        }

        bufferFrames = 1024

        var storage: UnsafeMutableRawPointer?
        var buffers: [UnsafeMutableRawPointer] = []
        guard prepareBuffers(channels: spec.inputChannels, frames: bufferFrames, storage: &storage, buffers: &buffers) else {
            AudioComponentInstanceDispose(unit)
            log("AUHAL: не удалось выделить буферы")
            return false
        }
        bufferListStorage = storage
        channelBuffers = buffers
        context.abl = storage?.assumingMemoryBound(to: AudioBufferList.self)
        context.channelCount = spec.inputChannels
        context.bufferFrames = bufferFrames

        var cbStruct = AURenderCallbackStruct(
            inputProc: { refCon, actionFlags, timeStamp, bus, frames, _ in
                let capture = Unmanaged<AudioCaptureImpl>.fromOpaque(refCon).takeUnretainedValue()
                return capture.captureRenderCallback(actionFlags, timeStamp, bus, frames)
            },
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        let setCb = AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_SetInputCallback,
            kAudioUnitScope_Global,
            0,
            &cbStruct,
            UInt32(MemoryLayout<AURenderCallbackStruct>.size)
        )
        if setCb != noErr {
            teardown(unit: unit)
            log("AUHAL: set input callback \(setCb)")
            return false
        }

        let initStatus = AudioUnitInitialize(unit)
        guard initStatus == noErr else {
            teardown(unit: unit)
            log("AUHAL: AudioUnitInitialize \(initStatus)")
            return false
        }

        let startStatus = AudioOutputUnitStart(unit)
        guard startStatus == noErr else {
            teardown(unit: unit)
            log("AUHAL: AudioOutputUnitStart \(startStatus)")
            return false
        }

        audioUnit = unit
        isRunning = true
        log("AUHAL: запущен, каналов=\(spec.inputChannels), frames=\(bufferFrames)")
        return true
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard isRunning else { return }
        if let unit = audioUnit {
            teardown(unit: unit)
        }
        audioUnit = nil
        isRunning = false
    }

    /// Аудио-поток: копируем каналы из буфера, затем передаём кадр на фон.
    func handleCaptured(frames: Int) {
        guard let abl = context.abl else { return }
        let channelCount = context.channelCount
        guard channelCount > 0, frames > 0 else { return }

        let list = UnsafeMutableAudioBufferListPointer(abl)
        let wanted = wantedChannels  // один снимок под локом
        var channels: [(Int, [Float])] = []
        channels.reserveCapacity(wanted.isEmpty ? channelCount : min(wanted.count, channelCount))

        for c in 0..<channelCount {
            if !wanted.isEmpty && !wanted.contains(c) { continue }
            guard c < list.count else { break }
            let buffer = list[c]
            guard let data = buffer.mData else { continue }
            let src = data.assumingMemoryBound(to: Float.self)
            var samples = [Float](repeating: 0, count: frames)
            for f in 0..<frames {
                samples[f] = src[f]
            }
            channels.append((c, samples))
        }

        guard !channels.isEmpty else { return }

        // Аудио-поток только копирует кадр в очередь (не блокируясь); анализ
        // происходит на отдельной serial-очереди. Если анализ не успевает —
        // старые кадры дропаются (реальное время важнее полноты).
        enqueue(frame: Frame(
            channelSamples: channels.map { ChannelSamples(channelIndex: $0.0, samples: $0.1) },
            frameCount: frames,
            sampleRate: spec.sampleRate
        ))
    }

    /// Неблокирующая очередь кадров с дропом старых (bounded, lock-based,
    /// но критическая секция микроскопическая).
    private var frameQueue: [Frame] = []
    private let frameQueueLock = NSLock()
    private let frameQueueLimit = 8

    private func enqueue(frame: Frame) {
        var dropped = false
        frameQueueLock.lock()
        if frameQueue.count >= frameQueueLimit {
            frameQueue.removeFirst()
            dropped = true
        }
        frameQueue.append(frame)
        frameQueueLock.unlock()

        if !dropped || frameQueue.count == 1 {
            consumerQueue.async { [weak self] in
                self?.drainQueue()
            }
        }
    }

    private func drainQueue() {
        while true {
            frameQueueLock.lock()
            guard !frameQueue.isEmpty else {
                frameQueueLock.unlock()
                return
            }
            let frame = frameQueue.removeFirst()
            frameQueueLock.unlock()
            onFrame?(frame)
        }
    }

    private let consumerQueue = DispatchQueue(label: "airmonitor.capture.consumer", qos: .userInteractive)

    /// Render-колбэк инстанса: вызывается на аудио-потоке.
    private func captureRenderCallback(
        _ actionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>?,
        _ timeStamp: UnsafePointer<AudioTimeStamp>?,
        _ bus: UInt32,
        _ frames: UInt32
    ) -> OSStatus {
        guard let unit = audioUnit, let abl = context.abl else { return noErr }
        guard frames > 0, Int(frames) <= context.bufferFrames else { return noErr }

        let status = AudioUnitRender(unit, actionFlags, timeStamp!, bus, frames, abl)
        if status != noErr {
            // Устройство умерло (отключено) — сообщаем один раз.
            // -10874 = kAudioUnitErr_InvalidElement, -50 params, -10875...
            // Практически: любые повторяющиеся ошибки после отключения.
            if status == -10874 || status == kAudioHardwareBadObjectError || status == -1856 {
                notifyDisconnect()
            } else {
                disconnectErrorCount += 1
                if disconnectErrorCount > 50 {
                    notifyDisconnect()
                }
            }
            return noErr
        }

        handleCaptured(frames: Int(frames))
        return noErr
    }

    var onDisconnect: (() -> Void)?
    private var disconnectNotified = false
    private var disconnectErrorCount = 0

    private func notifyDisconnect() {
        guard !disconnectNotified else { return }
        disconnectNotified = true
        log("AUHAL: устройство отключено (ошибка render)")
        let handler = onDisconnect
        DispatchQueue.global(qos: .userInitiated).async {
            handler?()
        }
    }

    // MARK: - Private

    private func teardown(unit: AudioUnit) {
        AudioOutputUnitStop(unit)
        // После AudioOutputUnitStop колбэков больше не будет — но колбэк,
        // УЖЕ вошедший в captureRenderCallback, мог пройти guard до stop.
        // Асинхронно освобождаем память с запасом 100 мс, чтобы любой
        // «зависший» в колбэке кадр успел дочитаться (иначе use-after-free).
        let storageToFree = bufferListStorage
        let buffersToFree = channelBuffers
        bufferListStorage = nil
        channelBuffers = []
        context.abl = nil
        if storageToFree != nil || !buffersToFree.isEmpty {
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
                if let st = storageToFree { st.deallocate() }
                for b in buffersToFree { b.deallocate() }
            }
        }
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
    }

    private func makeInputUnit() -> AudioUnit? {
        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &desc) else { return nil }
        var unit: AudioUnit?
        guard AudioComponentInstanceNew(component, &unit) == noErr, let unit else { return nil }

        // Только захват: отключаем вывод, включаем вход на элементе 1.
        var enable = UInt32(0)
        AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &enable, UInt32(MemoryLayout<UInt32>.size))
        enable = UInt32(1)
        AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &enable, UInt32(MemoryLayout<UInt32>.size))

        // Явная привязка к выбранному устройству.
        var deviceID = spec.deviceID
        let setDevice = AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard setDevice == noErr else {
            AudioComponentInstanceDispose(unit)
            log("AUHAL: set CurrentDevice \(setDevice)")
            return nil
        }

        // Запрашиваем Float32 non-interleaved с числом каналов устройства.
        var fmt = AudioStreamBasicDescription()
        fmt.mSampleRate = spec.sampleRate
        fmt.mFormatID = kAudioFormatLinearPCM
        fmt.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsNonInterleaved | kAudioFormatFlagIsPacked
        fmt.mChannelsPerFrame = UInt32(spec.inputChannels)
        fmt.mBitsPerChannel = 32
        fmt.mBytesPerFrame = 4
        fmt.mBytesPerPacket = 4
        fmt.mFramesPerPacket = 1
        let setFormat = AudioUnitSetProperty(
            unit,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Output,
            1,
            &fmt,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        )
        guard setFormat == noErr else {
            AudioComponentInstanceDispose(unit)
            log("AUHAL: set StreamFormat \(setFormat)")
            return nil
        }
        return unit
    }

    private func prepareBuffers(
        channels: Int,
        frames: Int,
        storage: inout UnsafeMutableRawPointer?,
        buffers: inout [UnsafeMutableRawPointer]
    ) -> Bool {
        let byteCount = frames * MemoryLayout<Float>.size
        let ablSize = MemoryLayout<AudioBufferList>.size + (channels - 1) * MemoryLayout<AudioBuffer>.size
        let mem = UnsafeMutableRawPointer.allocate(byteCount: ablSize, alignment: MemoryLayout<AudioBuffer>.alignment)
        let abl = mem.assumingMemoryBound(to: AudioBufferList.self)
        abl.pointee.mNumberBuffers = UInt32(channels)
        let list = UnsafeMutableAudioBufferListPointer(abl)
        for c in 0..<channels {
            guard let buf = malloc(byteCount) else {
                return false
            }
            buffers.append(buf)
            list[c].mNumberChannels = 1
            list[c].mDataByteSize = UInt32(byteCount)
            list[c].mData = buf
        }
        storage = mem
        return true
    }
}

/// Данные, доступные render-колбэку.
private final class CaptureContext: @unchecked Sendable {
    var abl: UnsafeMutablePointer<AudioBufferList>?
    var channelCount = 0
    var bufferFrames = 0
}
