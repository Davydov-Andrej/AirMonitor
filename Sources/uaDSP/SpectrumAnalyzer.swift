import Foundation
import Accelerate

public struct SpectrumPoint: Identifiable, Sendable {
    public let id: Int
    public let frequency: Float
    public let magnitudeDB: Float

    public init(id: Int, frequency: Float, magnitudeDB: Float) {
        self.id = id
        self.frequency = frequency
        self.magnitudeDB = magnitudeDB
    }
}

/// Полоса спектрального анализатора с плавным значением и пик-маркером.
public struct RTABand: Identifiable, Sendable {
    public let id: Int
    public let centerFrequency: Float
    public let lowerFrequency: Float
    public let upperFrequency: Float
    public let levelDB: Float
    public let peakDB: Float

    public init(
        id: Int,
        centerFrequency: Float,
        lowerFrequency: Float,
        upperFrequency: Float,
        levelDB: Float,
        peakDB: Float
    ) {
        self.id = id
        self.centerFrequency = centerFrequency
        self.lowerFrequency = lowerFrequency
        self.upperFrequency = upperFrequency
        self.levelDB = levelDB
        self.peakDB = peakDB
    }
}

/// Real-Time Analyzer: 1/3-октавные полосы (31 полоса, как на микшерных пультах).
/// - Перекрытие FFT 75% → частые обновления (при length=4096 и 48 кГц это ~47 раз/с).
/// - Экспоненциальное сглаживание уровня (time-averaging) — плавная кривая.
/// - Пик-холд на ~1.5 с — видны мгновенные выбросы.
public final class RTASpectrumAnalyzer {

    public static let pointsPerOctave: Float = 3  // 1/3 октавы

    public private(set) var bands: [RTABand] = []

    private let fft: FFT
    private let bandCenterHz: [Float]
    private let bandRange: [Range<Int>]

    // Сглаживание: экспоненциальное скользящее среднее в энергетической области.
    private var energySmooth: [Float]
    private var peakHold: [Float]
    private var peakHoldRemaining: [Float]
    private let energyAttacker: Float = 0.04
    private let peakHoldSeconds: Float = 1.5
    private let peakHoldTicks: Int

    private var ring: [Float] = []

    public init(length: Int, sampleRate: Float, windowType: FFT.WindowType = .hann) {
        self.fft = FFT(length: length, sampleRate: sampleRate, windowType: windowType)
            ?? FFT(length: 16384, sampleRate: sampleRate, windowType: windowType)!

        let half = fft.halfLength
        let nyquist = fft.sampleRate / 2

        // 1/3-октавная сетка от 20 Гц до 20 кГц (ISO 266).
        let fMin: Float = 20
        var centers: [Float] = []
        var f = fMin
        let step = powf(2.0, 1.0 / RTASpectrumAnalyzer.pointsPerOctave)
        while f <= 20000 && f < nyquist {
            centers.append(f)
            f *= step
        }

        var ranges: [Range<Int>] = []
        var smoothed: [Float] = []
        for c in centers {
            let lo = c / powf(2.0, 1.0 / 6.0)
            let hi = c * powf(2.0, 1.0 / 6.0)
            let binLo = max(2, Int(lo / nyquist * Float(half)))
            let binHi = min(half - 1, Int(hi / nyquist * Float(half)))
            guard binHi > binLo else { continue }
            ranges.append(binLo..<binHi)
            smoothed.append(1e-12)
        }

        self.bandCenterHz = centers
        self.bandRange = ranges
        self.energySmooth = smoothed
        self.peakHold = [Float](repeating: -120, count: ranges.count)
        self.peakHoldRemaining = [Float](repeating: 0, count: ranges.count)
        self.peakHoldTicks = Int(Float(peakHoldSeconds) * 60)

        rebuildBands()
    }

    public func process(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        ring.append(contentsOf: samples)

        let length = fft.length
        let hop = max(1, length / 4)
        while ring.count >= length {
            let block = Array(ring[0..<length])
            ring.removeFirst(hop)

            let power = fft.powerSpectrum(block.withUnsafeBufferPointer { $0 })
            guard power.count == fft.halfLength else { continue }
            integrate(power)
        }

        if ring.count > length * 4 {
            ring.removeFirst(ring.count - length)
        }
    }

    private func integrate(_ power: [Float]) {
        for (i, range) in bandRange.enumerated() {
            guard range.upperBound <= power.count else { continue }
            var sum: Float = 0
            var count = 0
            for b in range {
                sum += power[b]
                count += 1
            }
            guard count > 0 else { continue }
            let energy = sum / Float(count)

            energySmooth[i] += energyAttacker * (energy - energySmooth[i])

            let db = dBFromEnergy(energySmooth[i])
            if db > peakHold[i] {
                peakHold[i] = db
                peakHoldRemaining[i] = Float(peakHoldTicks)
            } else {
                peakHoldRemaining[i] -= 1
                if peakHoldRemaining[i] <= 0 {
                    peakHold[i] = max(db, peakHold[i] - 0.35)
                    peakHoldRemaining[i] = Float(peakHoldTicks)
                }
            }
        }
        rebuildBands()
    }

    private func dBFromEnergy(_ e: Float) -> Float {
        guard e > 1e-12 else { return -120 }
        return 10 * log10(e) + 0  // энергия уже в амплитудной шкале? см. note
    }

    private func rebuildBands() {
        var newBands: [RTABand] = []
        newBands.reserveCapacity(bandCenterHz.count)
        for (i, center) in bandCenterHz.enumerated() {
            guard i < energySmooth.count else { break }
            let lo = center / powf(2.0, 1.0 / 6.0)
            let hi = center * powf(2.0, 1.0 / 6.0)
            newBands.append(
                RTABand(
                    id: i,
                    centerFrequency: center,
                    lowerFrequency: lo,
                    upperFrequency: hi,
                    levelDB: dBFromEnergy(energySmooth[i]),
                    peakDB: peakHold[i]
                )
            )
        }
        bands = newBands
    }

    /// Точки для отображения кривой.
    public func spectrumPoints() -> [SpectrumPoint] {
        bands.map { band in
            SpectrumPoint(
                id: band.id,
                frequency: band.centerFrequency,
                magnitudeDB: band.levelDB
            )
        }
    }
}