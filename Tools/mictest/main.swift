import Foundation
import AVFoundation

// Микро-тест: AVAudioEngine input tap — проверяем, даёт ли система данные
// вообще (TCC-статус). Если даёт — проблема в моём HAL-коде.
// Если нет — это права микрофона.

let engine = AVAudioEngine()
let input = engine.inputNode
let format = input.outputFormat(forBus: 0)

print("Частота: \(format.sampleRate), каналов: \(format.channelCount)")

var count = 0
input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
    count += 1
    if count <= 5 {
        let channels = buffer.floatChannelData
        if let ch = channels {
            let samples = ch.pointee
            var sum: Float = 0
            for i in 0..<min(Int(buffer.frameLength), 1024) {
                sum += samples[i] * samples[i]
            }
            let rms = sqrtf(sum / Float(buffer.frameLength))
            print(String(format: "tap #%d rms=%.4f", count, rms))
        }
    }
}

try engine.start()
print("Запущено, ждём...")
RunLoop.current.run(until: Date().addingTimeInterval(4))
engine.stop()
if count == 0 {
    print("NO DATA — вероятно, нет прав на микрофон (TCC)")
} else {
    print("DATA OK — данных \(count) блоков")
}
