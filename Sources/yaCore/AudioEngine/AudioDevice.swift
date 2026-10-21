import CoreAudio
import Foundation

public struct AudioDeviceInfo {
    public let deviceID: AudioDeviceID
    public let uid: String
    public let name: String
    public let manufacturer: String
    public let inputChannels: Int
    public let outputChannels: Int
    public let isDefaultInput: Bool
}

extension AudioDeviceInfo: Identifiable {
    public var id: String { uid }
}
