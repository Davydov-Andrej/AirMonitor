import Foundation
import CoreAudio
import yaCore

// CLI-утилита: проверка мультиустройств.
//   air-aio --list
//   air-aio "Имя устройства" ch 0 1 2  — захват указанных каналов с устройства
//   air-aio "Имя устройства" L 0 R 1   — стерео-пара (0=L, 1=R)
//   air-aio "DevA" 0 1 + "DevB" 0 1   — одновременный захват двух устройств

final class RealtimeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var callback: (@Sendable (Int) -> Void)?
    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        let current = value
        if let callback {
            let cb = callback
            DispatchQueue.global().async { cb(current) }
        }
        return current
    }
}

let args = Array(CommandLine.arguments.dropFirst())

if args.isEmpty || args.contains("--list") {
    print("Доступные входные аудиоустройства:")
    let devices = AudioHAL.audioDevices().filter { $0.inputChannels > 0 }
    for device in devices {
        let marker = device.isDefaultInput ? " (default)" : ""
        let rate = AudioHAL.sampleRate(for: device.deviceID)
        print(String(format: "  [%@] %@ — in: %d, out: %d, rate: %.0f%@",
                     device.uid, device.name, device.inputChannels, device.outputChannels, rate, marker))
    }
    if devices.isEmpty {
        print("  (нет устройств)")
    }
    exit(0)
}

func stderr(_ message: String) {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
}

// Интерпретация аргументов: разделитель "+" означает несколько устройств.
var deviceGroups: [[String]] = []
var current: [String] = []
for arg in args {
    if arg == "+" {
        deviceGroups.append(current)
        current = []
    } else {
        current.append(arg)
    }
}
if !current.isEmpty {
    deviceGroups.append(current)
}

struct DeviceRequest {
    let device: AudioDeviceInfo
    var channels: [Int] = []
    var stereo: (Int, Int)?
}

func parseGroup(_ tokens: [String]) -> DeviceRequest? {
    guard let nameToken = tokens.first else { return nil }
    guard let device = AudioHAL.audioDevices().first(where: {
        $0.inputChannels > 0 && ($0.name.localizedCaseInsensitiveContains(nameToken) || $0.uid.localizedCaseInsensitiveContains(nameToken))
    }) else {
        stderr("Устройство '\(nameToken)' не найдено")
        return nil
    }
    var req = DeviceRequest(device: device)

    let rest = tokens.dropFirst()
    if rest.first?.lowercased() == "ch" {
        let indices = rest.dropFirst()
        for token in indices {
            guard let i = Int(token), i >= 0, i < device.inputChannels else {
                stderr("Неверный канал: \(token)")
                return nil
            }
            req.channels.append(i)
        }
    } else if rest.first?.lowercased() == "l" && rest.count >= 4 {
        guard let l = Int(rest[1]), let r = Int(rest[3]),
              l >= 0 && l < device.inputChannels, r >= 0 && r < device.inputChannels, l != r else {
            stderr("Неверная пара L/R")
            return nil
        }
        req.stereo = (l, r)
    } else {
        // по умолчанию — все каналы (до 8)
        req.channels = Array(0..<min(device.inputChannels, 8))
    }
    return req
}

let requests = deviceGroups.compactMap(parseGroup)
guard requests.count == deviceGroups.count else {
    stderr("Не удалось распарсить аргументы")
    stderr("Примеры: air-aio \"Мой микшер\" ch 0 1  ·  air-aio \"Мой микшер\" L 0 R 1  ·  air-aio \"DevA\" L 0 R 1 + \"DevB\" ch 0 1")
    exit(1)
}

let multi = MultiDeviceCapture()

// Подключаем общий приёмник для каждого устройства.
let counter = RealtimeCounter()
var expectedDevices = Set<AudioDeviceID>()
for req in requests {
    expectedDevices.insert(req.device.deviceID)
    let channels = req.stereo.map { [$0.0, $0.1] } ?? req.channels
    let wanted = Set(channels)
    let deviceID = req.device.deviceID
    let deviceName = req.device.name

    multi.setDestination(deviceID: deviceID) { frame in
        let n = counter.next()
        // Из фрейма берём только нужные каналы
        for cs in frame.channelSamples where wanted.contains(cs.channelIndex) {
            var acc: Float = 0
            for s in cs.samples {
                acc += s * s
            }
            let rms = sqrtf(acc / Float(max(cs.samples.count, 1)))
            let db = 20 * log10(max(rms, 1e-9))
            stderr(String(format: "[%@] ch=%d FRAME %d n=%d db=%.1f",
                          deviceName, cs.channelIndex + 1, n, cs.samples.count, db))
        }
    }
}

// Запуск захвата по всем устройствам.
for req in requests {
    let rate = AudioHAL.sampleRate(for: req.device.deviceID) > 0
        ? AudioHAL.sampleRate(for: req.device.deviceID) : 48000
    let added = multi.ensureCapturing(deviceID: req.device.deviceID, rate: rate)
    stderr("Захват \(req.device.name): \(added ? "OK" : "FAIL")")
    if !added { exit(1) }
}

stderr("Активно устройств: \(requests.count). Ctrl+C для выхода...")
CFRunLoopRun()
