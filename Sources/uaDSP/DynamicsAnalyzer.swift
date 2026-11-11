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

    private var truePeakTail: [Float] = []
    private let truePeakCoefficients = DynamicsAnalyzer.makeTruePeakCoefficients()

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

        // 4x oversampling с нормированным 12-tap windowed-sinc фильтром.
        // Последние 6 сэмплов переносятся на следующий блок, чтобы межсэмпловые
        // пики на границах callback-а считались с контекстом соседнего блока.
        let interp = estimateTruePeak(samples: samples, samplePeak: localPeak)
        if interp > truePeak {
            truePeak = interp
        }

        for sample in samples where abs(sample) > 0.999 {
            clipCount += 1
        }
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
        fastState = 0
        fastRMS = MeterFloor.dB
        truePeakTail.removeAll(keepingCapacity: true)
    }

    private func estimateTruePeak(samples: [Float], samplePeak: Float) -> Float {
        var combined = truePeakTail
        combined.append(contentsOf: samples)
        let coefficients = truePeakCoefficients
        var maximum = samplePeak

        if combined.count >= 12 {
            // Coefficients use offsets -5...+6 around each sample position.
            for center in 5..<(combined.count - 6) {
                for phase in 0..<4 {
                    var value: Float = 0
                    let taps = coefficients[phase]
                    for tap in 0..<12 {
                        value += combined[center + tap - 5] * taps[tap]
                    }
                    maximum = max(maximum, abs(value))
                }
            }
        }

        let tailCount = min(6, combined.count)
        truePeakTail = Array(combined.suffix(tailCount))
        return 20 * log10(max(maximum, 1e-9))
    }

    private static func makeTruePeakCoefficients() -> [[Float]] {
        (0..<4).map { phase in
            let fraction = Float(phase) * 0.25
            var weights = [Float](repeating: 0, count: 12)
            var sum: Float = 0
            for tap in 0..<12 {
                let offset = Float(tap - 5)
                let distance = fraction - offset
                let magnitude = abs(distance)
                guard magnitude < 6 else { continue }
                let sinc = magnitude < 1e-6
                    ? 1
                    : sinf(.pi * distance) / (.pi * distance)
                let window = 0.42 + 0.5 * cosf(.pi * distance / 6)
                    + 0.08 * cosf(2 * .pi * distance / 6)
                let weight = sinc * window
                weights[tap] = weight
                sum += weight
            }
            if abs(sum) > 1e-8 {
                for i in weights.indices { weights[i] /= sum }
            }
            return weights
        }
    }
}
