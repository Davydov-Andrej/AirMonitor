import Foundation
import CoreAudio
import uaDSP

/// Уникальный идентификатор шины мониторинга.
public struct BusID: Hashable, Sendable, Codable {
    public let uuid: UUID
    public init() { self.uuid = UUID() }
    public init(uuid: UUID) { self.uuid = uuid }
}

/// Режим выборки каналов для шины.
public enum BusMode: Sendable, Equatable, Codable {
    case mono(channels: [Int])
    case stereo(left: Int, right: Int)

    public var channelIndexes: [Int] {
        switch self {
        case .mono(let ch): return ch
        case .stereo(let l, let r): return [l, r]
        }
    }

    public var isStereo: Bool {
        if case .stereo = self { return true }
        return false
    }
}

/// Конфигурация шины мониторинга (редактируемая).
public struct MonitorBusConfig: Sendable, Identifiable, Codable {
    public let id: BusID
    public var name: String
    /// Стабильный UID устройства (переживает переподключение USB).
    public let deviceUID: String
    public var mode: BusMode
    public let sampleRate: Double
    public let fftLength: Int
    public let windowType: FFT.WindowType
    /// Доля ширины спектра в нижнем ряду (0.25...0.75). Настройка сетки.
    public var spectrumWidthFraction: Double

    enum CodingKeys: String, CodingKey {
        case id, name, deviceUID, mode, sampleRate, fftLength, windowType
        case spectrumWidthFraction
    }

    public init(
        id: BusID = BusID(),
        name: String,
        deviceUID: String,
        mode: BusMode,
        sampleRate: Double = 48000,
        fftLength: Int = 8192,
        windowType: FFT.WindowType = .hann,
        spectrumWidthFraction: Double = 0.5
    ) {
        self.id = id
        self.name = name
        self.deviceUID = deviceUID
        self.mode = mode
        self.sampleRate = sampleRate
        self.fftLength = fftLength
        self.windowType = windowType
        self.spectrumWidthFraction = spectrumWidthFraction
    }

    /// Декод с дефолтом для полей, добавленных позже (обратная совместимость сцен).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decodeIfPresent(BusID.self, forKey: .id) ?? BusID()
        self.name = try c.decode(String.self, forKey: .name)
        self.deviceUID = try c.decode(String.self, forKey: .deviceUID)
        self.mode = try c.decode(BusMode.self, forKey: .mode)
        self.sampleRate = try c.decodeIfPresent(Double.self, forKey: .sampleRate) ?? 48000
        self.fftLength = try c.decodeIfPresent(Int.self, forKey: .fftLength) ?? 8192
        self.windowType = try c.decodeIfPresent(FFT.WindowType.self, forKey: .windowType) ?? .hann
        self.spectrumWidthFraction = try c.decodeIfPresent(Double.self, forKey: .spectrumWidthFraction) ?? 0.5
    }

    public func changingName(_ newName: String) -> MonitorBusConfig {
        var copy = self
        copy.name = newName
        return copy
    }

    /// deviceID для текущей активной сессии (или nil, если устройство не найдено).
    public func resolvedDeviceID(in devices: [AudioDeviceInfo]) -> AudioDeviceID? {
        devices.first { $0.uid == deviceUID }?.deviceID
    }
}

/// Снимок одной шины для UI.
public struct BusSnapshot: Sendable, Identifiable {
    public let id: BusID
    public let name: String
    public let mode: BusMode
    /// В моно-режиме — по одному снапшоту на канал. В стерео — L и R.
    public let channels: [ChannelSnapshot]
    /// Для стерео-режима — сводный mono (mid).
    public let mono: ChannelSnapshot?
    public let correlation: Float?
    public let sampleRate: Double
    public let frameCount: Int
    public let hasSignal: Bool

    public init(
        id: BusID,
        name: String,
        mode: BusMode,
        channels: [ChannelSnapshot],
        mono: ChannelSnapshot?,
        correlation: Float?,
        sampleRate: Double,
        frameCount: Int,
        hasSignal: Bool
    ) {
        self.id = id
        self.name = name
        self.mode = mode
        self.channels = channels
        self.mono = mono
        self.correlation = correlation
        self.sampleRate = sampleRate
        self.frameCount = frameCount
        self.hasSignal = hasSignal
    }

    /// Для отображения: L/R (стерео) или все каналы (моно).
    public var displayChannels: [ChannelSnapshot] {
        if let mono, case .stereo = mode {
            return [mono] + channels
        }
        return channels
    }
}

/// Агрегированный снимок всех шин.
public struct AppSnapshot: Sendable {
    public let buses: [BusSnapshot]
    public let integratedLUFS: Float
    public let loudnessRangeLU: Float
    public let timestamp: Date

    public static let empty = AppSnapshot(
        buses: [],
        integratedLUFS: -Float.infinity,
        loudnessRangeLU: 0,
        timestamp: Date.distantPast
    )

    public init(buses: [BusSnapshot], integratedLUFS: Float, loudnessRangeLU: Float, timestamp: Date) {
        self.buses = buses
        self.integratedLUFS = integratedLUFS
        self.loudnessRangeLU = loudnessRangeLU
        self.timestamp = timestamp
    }

    public func bus(id: BusID) -> BusSnapshot? {
        buses.first { $0.id == id }
    }
}

extension FFT.WindowType: Codable, @unchecked Sendable {
    public enum CodingKeys: String, CodingKey {
        case hann, hamming, blackmanHarris
    }
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw {
        case "hann": self = .hann
        case "hamming": self = .hamming
        case "blackmanHarris": self = .blackmanHarris
        default: self = .hann
        }
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .hann: try container.encode("hann")
        case .hamming: try container.encode("hamming")
        case .blackmanHarris: try container.encode("blackmanHarris")
        }
    }
}