import Foundation
import Accelerate

/// Динамические метрики канала/полного микса в реальном времени.
public struct DynamicProfile {
    public let peakDBFS: Float
    public let rmsDBFS: Float
    /// Живой короткий RMS (~100 мс) — для заливки метра.
    public let fastRMS: Float
    public let crestFactorDB: Float
    public let truePeakDBTP: Float
    public let peakCount: Int
}

/// Постоянные характеристики динамики:
/// - пиковый/средний уровень
/// - crest factor (динамический запас)
/// - количество клипов (сэмплов > полной шкалы по модулю)
public final class DynamicsAnalyzer {

    public private(set) var peak: Float = MeterFloor.dB
    public private(set) var rmsLevel: Float = MeterFloor.dB
    public private(set) var truePeak: Float = MeterFloor.dB
    public private(set) var clipCount: Int = 0

    /// Короткий RMS (для заливки метра): ~100 мс интеграция.
    public private(set) var fastRMS: Float = MeterFloor.dB
    private var fastState: Float = 0

    private var runningSumSquares: Double = 0
    private var runningCount: Int = 0

    private var sampleRate: Float = 48000

    public init(sampleRate: Float = 48000) { self.sampleRate = sampleRate }

    public func process(_ samples: [Float]) {
        guard !samples.isEmpty else { return }

        var sumSquares: Float = 0
        vDSP_svesq(samples, 1, &sumSquares, vDSP_Length(samples.count))
        runningSumSquares += Double(sumSquares)
        runningCount += samples.count

        // Быстрый RMS с атакой/спадом ~100 мс — живой уровень метра.
        let rms = sqrtf(sumSquares / Float(samples.count))
        let dt = Float(samples.count) / sampleRate
        let alpha = rms > fastState ? expf(-dt / 0.03) : expf(-dt / 0.15)
        fastState = alpha * fastState + (1 - alpha) * rms
        fastRMS = 20 * log10(max(fastState, 1e-9))

        var localPeak: Float = 0
        vDSP_maxmgv(samples, 1, &localPeak, vDSP_Length(samples.count))
        let peakDB = 20 * log10(max(localPeak, 1e-9))
        if peakDB > peak {
            peak = peakDB
        }

        if runningCount > 0 {
            let rms = sqrtf(Float(runningSumSquares) / Float(runningCount))
            rmsLevel = 20 * log10(max(rms, 1e-9))
        }

        // Истинный пик: эвристика через 4x интерполяцию в окрестности максимума.
        let interp = interpolatePeak(samples: samples)
        if interp > truePeak {
            truePeak = interp
        }

        clipCount += samples.filter { abs($0) > 0.999 }.count
    }

    public func profile() -> DynamicProfile {
        DynamicProfile(
            peakDBFS: peak,
            rmsDBFS: rmsLevel,
            fastRMS: fastRMS,
            crestFactorDB: peak.isFinite && rmsLevel.isFinite ? peak - rmsLevel : 0,
            truePeakDBTP: truePeak,
            peakCount: clipCount
        )
    }

    public func reset() {
        peak = MeterFloor.dB
        rmsLevel = MeterFloor.dB
        truePeak = MeterFloor.dB
        clipCount = 0
        runningSumSquares = 0
        runningCount = 0
    }

    private func interpolatePeak(samples: [Float]) -> Float {
        guard !samples.isEmpty else { return MeterFloor.dB }
        var maxIndex = 0
        var maxValue: Float = 0
        for (idx, value) in samples.enumerated() {
            let abs = abs(value)
            if abs > maxValue {
                maxValue = abs
                maxIndex = idx
            }
        }
        guard maxIndex > 0, maxIndex < samples.count - 1 else {
            return 20 * log10(max(maxValue, 1e-9))
        }
        let x0 = abs(samples[maxIndex - 1])
        let x1 = abs(samples[maxIndex])
        let x2 = abs(samples[maxIndex + 1])
        // Параболическая интерполяция пика между сэмплами.
        let d = (x0 - x2) / (2 * (x0 - 2 * x1 + x2))
        let t = max(0, min(1, 0.5 + d * 0.5))
        let p1 = fmaxf(x0, x1)
        let estimated = p1 / cosf(Float.pi * t / 2 - Float.pi / 2) * 1.01
        return 20 * log10(max(estimated, 1e-9))
    }
}
