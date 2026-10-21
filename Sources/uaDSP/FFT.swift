import Foundation
import Accelerate

/// Оконный FFT поверх vDSP. Вход — float[length], выход — линейные мощности
/// (для RTA) или амплитуды в дБFS (для точечных измерений) на бин.
public final class FFT {
    public enum WindowType {
        case hann, hamming, blackmanHarris
    }

    public let length: Int
    public let halfLength: Int
    public let sampleRate: Float

    private let log2n: vDSP_Length
    private let fftSetup: FFTSetup
    private var window: [Float]

    public init?(length: Int, sampleRate: Float, windowType: WindowType = .hann) {
        guard length > 0, (length & (length - 1)) == 0 else { return nil }
        self.length = length
        self.halfLength = length / 2
        self.sampleRate = sampleRate

        self.log2n = vDSP_Length(log2(Float(length)))
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            return nil
        }
        self.fftSetup = setup

        self.window = [Float](repeating: 0, count: length)
        applyWindow(of: windowType, into: &window)
    }

    deinit {
        vDSP_destroy_fftsetup(fftSetup)
    }

    /// Линейный спектр мощности на бины (без дБ). Длина `halfLength`.
    /// Бин i соответствует частоте `i * sampleRate / length`.
    public func powerSpectrum(_ input: UnsafeBufferPointer<Float>) -> [Float] {
        guard input.count >= length else { return [] }

        var windowed = [Float](repeating: 0, count: length)
        for i in 0..<length {
            windowed[i] = input[i] * window[i]
        }

        var real = [Float](repeating: 0, count: halfLength)
        var imag = [Float](repeating: 0, count: halfLength)
        // vDSP_fft_zrip ожидает «packed» формат: realp = чётные отсчёты,
        // imagp = нечётные отсчёты исходного реального сигнала.
        for i in 0..<halfLength {
            real[i] = windowed[i * 2]
            imag[i] = windowed[i * 2 + 1]
        }

        var power = [Float](repeating: 0, count: halfLength)

        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(
                    realp: rp.baseAddress!,
                    imagp: ip.baseAddress!
                )
                vDSP_fft_zrip(
                    fftSetup,
                    &split,
                    1,
                    log2n,
                    FFTDirection(kFFTDirection_Forward)
                )
                let scale = Float(2.0 / Float(length))
                var reCopy = [Float](repeating: 0, count: halfLength)
                var imCopy = [Float](repeating: 0, count: halfLength)
                reCopy.withUnsafeMutableBufferPointer { rcp in
                    rcp.baseAddress!.update(from: split.realp, count: halfLength)
                }
                imCopy.withUnsafeMutableBufferPointer { icp in
                    icp.baseAddress!.update(from: split.imagp, count: halfLength)
                }
                let scale2 = scale * scale
                for bin in 0..<halfLength {
                    let re = reCopy[bin]
                    let im = imCopy[bin]
                    power[bin] = (re * re + im * im) * scale2
                }
            }
        }

        return power
    }

    /// Амплитуды в дБFS по бинам. Массив длины `halfLength`.
    public func magnitudeDB(_ input: UnsafeBufferPointer<Float>) -> [Float] {
        let power = powerSpectrum(input)
        guard power.count == halfLength else { return [] }
        var magnitudes = [Float](repeating: 0, count: halfLength)
        for i in 0..<halfLength {
            magnitudes[i] = DSPMath.clampedDB(sqrtf(power[i]))
        }
        return magnitudes
    }

    /// Частота (Гц) bin-а.
    public func frequency(ofBin bin: Int) -> Float {
        guard bin >= 0 && bin < halfLength else { return 0 }
        return Float(bin) * sampleRate / Float(length)
    }

    private func applyWindow(of type: WindowType, into out: inout [Float]) {
        let n = length
        switch type {
        case .hann:
            vDSP_hann_window(&out, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        case .hamming:
            vDSP_hamm_window(&out, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        case .blackmanHarris:
            for i in 0..<n {
                let x = Float(i) / Float(n - 1)
                let a0: Float = 0.35875
                let a1: Float = 0.48829
                let a2: Float = 0.14128
                let a3: Float = 0.01168
                out[i] = a0
                    - a1 * cosf(2 * .pi * x)
                    + a2 * cosf(4 * .pi * x)
                    - a3 * cosf(6 * .pi * x)
            }
        }
    }
}