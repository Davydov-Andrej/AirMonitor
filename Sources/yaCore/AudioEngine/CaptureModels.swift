import Foundation
import CoreAudio

/// Данные одного канала за один приход render-колбэка.
public struct ChannelSamples: Sendable {
    public let channelIndex: Int
    public let samples: [Float]

    public init(channelIndex: Int, samples: [Float]) {
        self.channelIndex = channelIndex
        self.samples = samples
    }
}

struct AudioSourceSpec {
    let deviceID: AudioDeviceID
    let sampleRate: Double
    let inputChannels: Int
}
