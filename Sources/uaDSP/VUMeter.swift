import Foundation
import Accelerate

public enum MeterFloor {
    public static let dB: Float = -120
}

/// Потоковое вычисление VU (RMS) по стандартной VU-характеристике
/// (attack 300 мс, интеграция RMS 300 мс). Отдаёт значение в дБFS
/// (0 дБFS = полная шкала).
public final class VUMeter {
    public private(set) var value: Float = MeterFloor.dB
    public private(set) var peak: Float = MeterFloor.dB
    public private(set) var peakHold: Float = MeterFloor.dB
    public private(set) var peakLastSeen: TimeInterval = 0

    private let sampleRate: Float
    private var state: Float = 0
    private var statePeak: Float = 0

    public init(sampleRate: Float) {
        self.sampleRate = sampleRate
    }

    public func process(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        var sumSquares: Float = 0
        vDSP_svesq(samples, 1, &sumSquares, vDSP_Length(samples.count))
        let rms = sqrtf(sumSquares / Float(samples.count))

        let n = samples.count
        let dt = Float(n) / sampleRate
        let attack: Float = 0.300
        let release: Float = 0.300

        let alphaAttack = expf(-dt / attack)
        let alphaRelease = expf(-dt / release)
        let alpha = rms > state ? alphaAttack : alphaRelease
        state = alpha * state + (1 - alpha) * rms

        value = 20 * log10(max(state, 1e-9))

        if rms > statePeak {
            statePeak = rms
            peakLastSeen = Date().timeIntervalSinceReferenceDate
        }
        peak = 20 * log10(max(statePeak, 1e-9))

        // Пик-холд с затуханием: после 1.5 с простоя плавно опускается.
        let elapsed = Date().timeIntervalSinceReferenceDate - peakLastSeen
        if elapsed > 1.5 && statePeak > 0 {
            statePeak *= 0.985  // ~-0.13 дБ/тик при 10-15 Гц обновления
        }
    }

    public func resetHold() {
        statePeak = 0
        peakHold = MeterFloor.dB
    }

    public func decayHold(after seconds: TimeInterval = 3.0) {
        let elapsed = Date().timeIntervalSinceReferenceDate - peakLastSeen
        if elapsed > seconds {
            statePeak *= 0.9
            peakHold = 20 * log10(max(statePeak, 1e-9))
        }
    }
}
