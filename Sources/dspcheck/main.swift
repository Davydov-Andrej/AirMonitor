import Foundation
import uaDSP

// Самопроверка DSP-модулей без XCTest (доступен и в CommandLineTools).

final class Runner {
    var failures = 0

    func check(_ condition: Bool, _ name: String) {
        if condition {
            print("  ✓ \(name)")
        } else {
            print("  ✗ \(name)")
            failures += 1
        }
    }

    func checkClose(_ a: Float, _ b: Float, tol: Float = 1e-3, _ name: String) {
        check(abs(a - b) < tol, name)
    }

    func runAll() {
        print("== DSPMath ==")
        checkClose(DSPMath.dB(1.0), 0, "dB(1.0) = 0")
        checkClose(DSPMath.dB(0.1), -20, tol: 1e-2, "dB(0.1) = -20")
        check(DSPMath.dB(0) == -120, "dB(0) = -120")
        checkClose(DSPMath.amplitude(-20), 0.1, tol: 1e-3, "amplitude(-20) = 0.1")

        print("== FFT ==")
        let sampleRate: Float = 48000
        let length = 8192
        if let fft = FFT(length: length, sampleRate: sampleRate) {
            let freq: Float = 1000
            var signal = [Float](repeating: 0, count: length)
            for i in 0..<length {
                signal[i] = sinf(2 * Float.pi * freq * Float(i) / sampleRate)
            }
            let magnitudes = fft.magnitudeDB(signal.withUnsafeBufferPointer { $0 })
            let expectedBin = Int(freq * Float(length) / sampleRate)
            print("    expectedBin=\(expectedBin) count=\(magnitudes.count)")
            if expectedBin >= 3 && expectedBin + 3 < magnitudes.count {
                print("    around: \((expectedBin-3...expectedBin+3).map { String(format: "%.1f", magnitudes[$0]) }.joined(separator: " "))")
            }
            if let maxv = magnitudes.enumerated().max(by: { $0.element < $1.element }) {
                print("    max bin: \(maxv.offset)=\(maxv.element)")
            }
            check(magnitudes[expectedBin] > -2, "Пик 1 кГц ≈ 0 dBFS (получено \(magnitudes[expectedBin]))")
            check(magnitudes[expectedBin] > magnitudes[expectedBin + 20], "Пик выше шумового хвоста")
        } else {
            check(false, "FFT init")
        }

        print("== VU ==")
        let vu = VUMeter(sampleRate: 48000)
        vu.process([Float](repeating: 0.5, count: 48000))
        check(vu.value > -10 && vu.value < 0, "VU на 0.5 amplitude ≈ -6 dB (получено \(vu.value))")

        print("== Dynamics ==")
        let dyn = DynamicsAnalyzer()
        var signal = [Float](repeating: 0.01, count: 1000)
        signal[500] = 1.0
        dyn.process(signal)
        let profile = dyn.profile()
        check(profile.peakDBFS > -1, "Peak ≈ 0 dBFS (получено \(profile.peakDBFS))")
        check(profile.crestFactorDB > 0, "Crest > 0 (получено \(profile.crestFactorDB))")

        print("== Loudness (LUFS) ==")
        let meter = LoudnessMeter(sampleRate: 48000)
        let tone = (0..<48000).map { Float(sinf(2 * Float.pi * 440 * Float($0) / 48000)) * 0.1 }
        meter.process(tone)
        let reading = meter.reading()
        check(reading.momentaryLUFS.isFinite && reading.momentaryLUFS > -40 && reading.momentaryLUFS < 0,
              "Momentary LUFS на синусе -20 dBFS (получено \(reading.momentaryLUFS))")

        print("== Instrument bands ==")
        for band in InstrumentBand.allCases {
            check(band.range.upperBound > band.range.lowerBound, "Диапазон \(band.rawName)")
        }

        print("== RTA spectrum ==")
        let rta = RTASpectrumAnalyzer(length: 8192, sampleRate: 48000)
        // Тон 1 кГц
        let tone1k = (0..<48000).map { Float(sinf(2 * Float.pi * 1000 * Float($0) / 48000)) * 0.5 }
        rta.process(tone1k)
        check(!rta.bands.isEmpty, "RTA: есть полосы (\(rta.bands.count))")
        // Тон попадает в конкретную полосу (806 или 1016 Гц) — ищем максимум.
        if let near1k = rta.bands.filter({ $0.centerFrequency > 800 && $0.centerFrequency < 1250 }).max(by: { $0.levelDB < $1.levelDB }) {
            check(near1k.levelDB > -30, "RTA: у 1 кГц уровень \(near1k.levelDB) дБ (ожидали заметный)")
            print("    полоса 1кГц: центр=\(near1k.centerFrequency) level=\(near1k.levelDB)")
        } else {
            check(false, "RTA: нет полосы вблизи 1 кГц")
        }
        // Проверяем пик-холд: после тишины пик остаётся выше уровня.
        let silence = [Float](repeating: 0, count: 48000)
        rta.process(silence)
        if let near1k = rta.bands.filter({ $0.centerFrequency > 800 && $0.centerFrequency < 1250 }).max(by: { $0.peakDB < $1.peakDB }) {
            check(near1k.peakDB > near1k.levelDB, "RTA: peak-hold \(near1k.peakDB) > level \(near1k.levelDB)")
        }

        print("== Instrument balance (форма) ==")
        var balSpectrum: [SpectrumPoint] = []
        let fMin: Float = 20
        var f = fMin
        while f < 20000 {
            balSpectrum.append(SpectrumPoint(id: balSpectrum.count, frequency: f, magnitudeDB: -20))
            f *= powf(2, 0.2)
        }
        let bal = InstrumentBalanceAnalyzer(spectrum: balSpectrum, sampleRate: 48000)
        check(bal.hasSignal, "Balance: есть сигнал")
        let deviations = bal.balances().map { $0.deviationDB }
        check(deviations.contains { abs($0) > 0.1 }, "Balance: форма не константа (\(deviations))")

        print("\nИтог: \(failures == 0 ? "ВСЕ ПРОШЛИ" : "ОШИБОК: \(failures)")")
    }
}

let runner = Runner()
runner.runAll()
exit(runner.failures == 0 ? 0 : 1)
