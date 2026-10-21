import CoreAudio
import Foundation

public enum AudioError: LocalizedError {
    case osStatus(OSStatus)
    case invalidDevice(channel: Int)
    case noInputChannels
    case renderCallbackMissing
    case engineNotConfigured

    public var errorDescription: String? {
        switch self {
        case .osStatus(let code): return "CoreAudio OSStatus \(code) (\(code))"
        case .invalidDevice(let channel): return "Устройство не имеет входного канала \(channel + 1)"
        case .noInputChannels: return "Устройство не имеет входных каналов"
        case .renderCallbackMissing: return "Render-колбэк не установлен"
        case .engineNotConfigured: return "Движок не сконфигурирован"
        }
    }
}

enum PropertyAddress {
    static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        element: AudioObjectPropertyElement
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: element
        )
    }
}

/// Обёртка над CoreAudio HAL для перечисления и чтения USB-микшеров.
public enum AudioHAL {
    public static func audioDevices() -> [AudioDeviceInfo] {
        var address = PropertyAddress.address(
            kAudioHardwarePropertyDevices,
            scope: kAudioObjectPropertyScopeGlobal,
            element: kAudioObjectPropertyElementMain
        )

        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size
        )
        guard status == noErr else { return [] }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &ids
        )
        guard status == noErr else { return [] }

        let defaultInput = defaultInputDeviceID()
        return ids.map { id in
            deviceInfo(
                deviceID: id,
                isDefault: id == defaultInput
            )
        }
    }

    public static func inputChannels(for deviceID: AudioDeviceID) -> Int {
        propertyCount(
            deviceID: deviceID,
            selector: kAudioDevicePropertyStreamConfiguration,
            scope: kAudioObjectPropertyScopeInput
        )
    }

    public static func outputChannels(for deviceID: AudioDeviceID) -> Int {
        propertyCount(
            deviceID: deviceID,
            selector: kAudioDevicePropertyStreamConfiguration,
            scope: kAudioObjectPropertyScopeOutput
        )
    }

    public static func deviceUID(for deviceID: AudioDeviceID) -> String? {
        stringProperty(
            deviceID: deviceID,
            selector: kAudioDevicePropertyDeviceUID
        )
    }

    public static func deviceName(for deviceID: AudioDeviceID) -> String {
        stringProperty(
            deviceID: deviceID,
            selector: kAudioDevicePropertyDeviceNameCFString
        ) ?? "Device \(deviceID)"
    }

    public static func deviceManufacturer(for deviceID: AudioDeviceID) -> String {
        stringProperty(
            deviceID: deviceID,
            selector: kAudioObjectPropertyManufacturer
        ) ?? ""
    }

    public static func sampleRate(for deviceID: AudioDeviceID) -> Double {
        var address = PropertyAddress.address(
            kAudioDevicePropertyNominalSampleRate,
            scope: kAudioObjectPropertyScopeGlobal,
            element: kAudioObjectPropertyElementMain
        )
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        let status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &size,
            &rate
        )
        return status == noErr ? rate : 0
    }

    // MARK: - Private

    private static func defaultInputDeviceID() -> AudioDeviceID {
        var address = PropertyAddress.address(
            kAudioHardwarePropertyDefaultInputDevice,
            scope: kAudioObjectPropertyScopeGlobal,
            element: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )
        return status == noErr ? deviceID : 0
    }

    private static func deviceInfo(deviceID: AudioDeviceID, isDefault: Bool) -> AudioDeviceInfo {
        AudioDeviceInfo(
            deviceID: deviceID,
            uid: deviceUID(for: deviceID) ?? "",
            name: deviceName(for: deviceID),
            manufacturer: deviceManufacturer(for: deviceID),
            inputChannels: inputChannels(for: deviceID),
            outputChannels: outputChannels(for: deviceID),
            isDefaultInput: isDefault
        )
    }

    private static func propertyCount(deviceID: AudioDeviceID, selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope) -> Int {
        var address = PropertyAddress.address(
            selector,
            scope: scope,
            element: kAudioObjectPropertyElementMain
        )

        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size)
        guard status == noErr else { return 0 }

        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { buffer.deallocate() }

        status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, buffer)
        guard status == noErr else { return 0 }

        let listPointer = buffer.assumingMemoryBound(to: AudioBufferList.self)
        let bufferList = UnsafeMutableAudioBufferListPointer(listPointer)
        var channelCount = 0
        for abl in bufferList {
            channelCount += Int(abl.mNumberChannels)
        }
        return channelCount
    }

    private static func stringProperty(deviceID: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
        var address = PropertyAddress.address(
            selector,
            scope: kAudioObjectPropertyScopeGlobal,
            element: kAudioObjectPropertyElementMain
        )
        var object: CFString?
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &object) { ptr in
            AudioObjectGetPropertyData(
                deviceID,
                &address,
                0,
                nil,
                &size,
                UnsafeMutableRawPointer(ptr)
            )
        }
        guard status == noErr, let cfString = object else { return nil }
        return cfString as String
    }
}
