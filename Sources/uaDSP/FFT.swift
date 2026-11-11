import Foundation
import Accelerate

/// Оконный FFT поверх vDSP.
/// `powerSpectrum` возвращает one-sided мощность с нормировкой по энергии окна,
/// а `magnitudeDB` — амплитуду синусоидального компонента с нормировкой по
/// когерентному усилению окна.
public final class FFT {
    public enum WindowType {
        case hann, hamming, blackmanHarris
    }

    public let length: Int
    public let halfLength: Int
    public let sampleRate: Float

    private let log2n: vDSP_Length
    private let fftSetup: FFTSetup
    private let window: [Float]
    private let windowSum: Float
    private let windowPowerSum: Float

    public init?(length: Int, sampleRate: Float, windowType: WindowType = .hann) {
        guard length >= 2,
              (length & (length - 1)) == 0,
              sampleRate.isFinite,
              sampleRate > 0 else { return nil }
        self.length = length
        self.halfLength = length / 2
        self.sampleRate = sampleRate
        self.log2n = vDSP_Length(log2(Float(length)))
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            return nil
        }
        self.fftSetup = setup

        var weights = [Float](repeating: 0, count: length)
        Self.makeWindow(windowType, into: &weights)
        self.window = weights
        self.windowSum = weights.reduce(0, +)
        self.windowPowerSum = weights.reduce(Float(0)) { $0 + $1 * $1 }
    }

    deinit {
        vDSP_destroy_fftsetup(fftSetup)
    }

    /// Линейная one-sided мощность на бины (без дБ), длина `halfLength`.
    /// Сумма мощностей бинов соответствует peak-equivalent уровню сигнала.
    public func powerSpectrum(_ input: UnsafeBufferPointer<Float>) -> [Float] {
        guard input.count >= length else { return [] }
        let (real, imag) = transform(input)
        let denominator = Float(length) * max(windowPowerSum, 1e-20)
        var power = [Float](repeating: 0, count: halfLength)

        // vDSP_fft_zrip хранит DC в realp[0], Nyquist в imagp[0],
        // а forward transform возвращает значения, умноженные на 2.
        // Для DC нет симметричной отрицательной частоты, поэтому поправка
        // отличается от обычных one-sided бинов.
        power[0] = (real[0] / (2 * max(windowSum, 1e-20)))
            * (real[0] / (2 * max(windowSum, 1e-20)))
        if halfLength > 1 {
            for bin in 1..<halfLength {
                let re = real[bin]
                let im = imag[bin]
                power[bin] = (re * re + im * im) / denominator
            }
        }
        return power
    }

    /// Амплитуда синусоидального компонента в дБFS, длина `halfLength`.
    /// Нормировка по сумме окна убирает зависимость от выбора окна.
    public func magnitudeDB(_ input: UnsafeBufferPointer<Float>) -> [Float] {
        guard input.count >= length else { return [] }
        let (real, imag) = transform(input)
        let coherentGain = max(windowSum, 1e-20)
        var magnitudes = [Float](repeating: 0, count: halfLength)
        magnitudes[0] = DSPMath.clampedDB(abs(real[0]) / (2 * coherentGain))
        if halfLength > 1 {
            for bin in 1..<halfLength {
                magnitudes[bin] = DSPMath.clampedDB(hypotf(real[bin], imag[bin]) / coherentGain)
            }
        }
        return magnitudes
    }

    /// Частота (Гц) bin-а.
    public func frequency(ofBin bin: Int) -> Float {
        guard bin >= 0 && bin < halfLength else { return 0 }
        return Float(bin) * sampleRate / Float(length)
    }

    private func transform(_ input: UnsafeBufferPointer<Float>) -> ([Float], [Float]) {
        var real = [Float](repeating: 0, count: halfLength)
        var imag = [Float](repeating: 0, count: halfLength)
        for i in 0..<length {
            let value = input[i] * window[i]
            if i.isMultiple(of: 2) {
                real[i / 2] = value
            } else {
                imag[i / 2] = value
            }
        }

        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
            }
        }
        return (real, imag)
    }

    private static func makeWindow(_ type: WindowType, into output: inout [Float]) {
        let n = output.count
        guard n > 1 else {
            if n == 1 { output[0] = 1 }
            return
        }
        for i in 0..<n {
            let phase = 2 * Float.pi * Float(i) / Float(n)
            switch type {
            case .hann:
                output[i] = 0.5 * (1 - cosf(phase))
            case .hamming:
                output[i] = 0.54 - 0.46 * cosf(phase)
            case .blackmanHarris:
                output[i] = 0.35875
                    - 0.48829 * cosf(phase)
                    + 0.14128 * cosf(2 * phase)
                    - 0.01168 * cosf(3 * phase)
            }
        }
    }
}
