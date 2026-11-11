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
            let peakDB = magnitudes.max() ?? -120
            check(peakDB > -1 && peakDB <= 0.1, "Пик 1 кГц ≈ 0 dBFS (получено \(peakDB))")
            check(magnitudes[expectedBin] > magnitudes[expectedBin + 20], "Пик выше шумового хвоста")

            let coherentBin = 170
            let coherentFrequency = sampleRate * Float(coherentBin) / Float(length)
            let coherentTone = (0..<length).map {
                sinf(2 * Float.pi * coherentFrequency * Float($0) / sampleRate)
            }
            let coherentMagnitude = fft.magnitudeDB(coherentTone.withUnsafeBufferPointer { $0 })
            check(abs(coherentMagnitude[coherentBin]) < 0.15,
                  "Когерентный full-scale тон нормирован в 0 dBFS (получено \(coherentMagnitude[coherentBin]))")
            let coherentPower = fft.powerSpectrum(coherentTone.withUnsafeBufferPointer { $0 }).reduce(0, +)
            check(abs(10 * log10(max(coherentPower, 1e-12))) < 0.15,
                  "Интеграл спектра full-scale синуса равен 0 dBFS")

            let dc = [Float](repeating: 0.25, count: length)
            let dcMagnitude = fft.magnitudeDB(dc.withUnsafeBufferPointer { $0 })
            check(abs(dcMagnitude[0] - 20 * log10(0.25)) < 0.15,
                  "DC отделён от Nyquist и нормирован по когерентному усилению окна")
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

        let truePeakMeter = DynamicsAnalyzer(sampleRate: 48000)
        let intersampleTone = (0..<4800).map {
            0.9 * sinf(2 * Float.pi * 12000 * Float($0) / 48000 + .pi / 4)
        }
        truePeakMeter.process(intersampleTone)
        let truePeakProfile = truePeakMeter.profile()
        check(truePeakProfile.truePeakDBTP > truePeakProfile.peakDBFS + 2.5
              && truePeakProfile.truePeakDBTP < truePeakProfile.peakDBFS + 3.5,
              "4x oversampling обнаруживает межсэмпловый пик 12 кГц")

        print("== Loudness (LUFS) ==")
        let meter = LoudnessMeter(sampleRate: 48000)
        let tone = (0..<48000).map { Float(sinf(2 * Float.pi * 440 * Float($0) / 48000)) * 0.1 }
        meter.process(tone)
        let reading = meter.reading()
        check(reading.momentaryLUFS.isFinite && reading.momentaryLUFS > -40 && reading.momentaryLUFS < 0,
              "Momentary LUFS на синусе -20 dBFS (получено \(reading.momentaryLUFS))")
        check(!reading.shortTermLUFS.isFinite,
              "S по умолчанию не готов до накопления 3 секунд")
        if let latestHistory = meter.historySnapshot().last {
            check(abs(latestHistory.momentary - reading.momentaryLUFS) < 0.01,
                  "При отключённом smoothing график хранит те же M-значения")
        }
        meter.calibrationOffset = 0.75
        let calibrated = meter.reading()
        let calibratedHistory = meter.historySnapshot().last
        check(abs(calibrated.momentaryLUFS - reading.momentaryLUFS - 0.75) < 0.01
              && abs((calibratedHistory?.momentary ?? -Float.infinity) - (reading.momentaryLUFS + 0.75)) < 0.01,
              "Калибровочный LUFS-офсет применяется и к числам, и к истории графика")

        let pauseMeter = LoudnessMeter(sampleRate: 48000)
        pauseMeter.numberSmoothing = 0.008
        pauseMeter.displaySmoothing = 0.003
        let oneSecondTone = (0..<48000).map { Float(sinf(2 * Float.pi * 440 * Float($0) / 48000)) * 0.1 }
        pauseMeter.process(oneSecondTone)
        for _ in 0..<3 { pauseMeter.process(oneSecondTone) }
        let integratedBeforePause = pauseMeter.reading().integratedLUFS
        pauseMeter.process([Float](repeating: 0, count: 24000))
        let afterHalfSecondSilence = pauseMeter.reading()
        check(afterHalfSecondSilence.momentaryLUFS <= -100,
              "После паузы M падает до цифровой тишины независимо от release smoothing")
        check(afterHalfSecondSilence.shortTermLUFS.isFinite,
              "S сохраняет скользящее окно во время короткой паузы")
        pauseMeter.process([Float](repeating: 0, count: 48000 * 3))
        let afterFullSilence = pauseMeter.reading()
        check(afterFullSilence.shortTermLUFS <= -100,
              "S показывает тишину после выхода звука из полного окна")
        check(abs(afterFullSilence.integratedLUFS - integratedBeforePause) < 0.5,
              "Integrated LUFS сохраняет gated итог при наступлении тишины (\(integratedBeforePause) → \(afterFullSilence.integratedLUFS))")
        check((pauseMeter.historySnapshot().last?.momentary ?? 0) <= -100,
              "История LUFS опускается до тишины вместо зависшей горизонтали")

        print("== Instrument bands ==")
        for band in InstrumentBand.allCases {
            check(band.range.upperBound > band.range.lowerBound, "Диапазон \(band.rawName)")
        }

        print("== RTA spectrum ==")
        let rta = RTASpectrumAnalyzer(length: 8192, sampleRate: 48000)
        // Тон 1 кГц
        let tone1k = (0..<48000).map { Float(sinf(2 * Float.pi * 1000 * Float($0) / 48000)) * 0.5 }
        rta.process(tone1k)
        let bands1k = rta.snapshotData().bands
        check(!bands1k.isEmpty, "RTA: есть полосы (\(bands1k.count))")
        // Тон попадает в конкретную полосу (806 или 1016 Гц) — ищем максимум.
        if let near1k = bands1k.filter({ $0.centerFrequency > 800 && $0.centerFrequency < 1250 }).max(by: { $0.levelDB < $1.levelDB }) {
            check(near1k.levelDB > -30, "RTA: у 1 кГц уровень \(near1k.levelDB) дБ (ожидали заметный)")
            print("    полоса 1кГц: центр=\(near1k.centerFrequency) level=\(near1k.levelDB)")
        } else {
            check(false, "RTA: нет полосы вблизи 1 кГц")
        }
        // Проверяем пик-холд: после тишины пик остаётся выше уровня.
        let silence = [Float](repeating: 0, count: 4800)
        rta.process(silence)
        let bandsAfter = rta.snapshotData().bands
        if let near1k = bandsAfter.filter({ $0.centerFrequency > 800 && $0.centerFrequency < 1250 }).max(by: { $0.peakDB < $1.peakDB }) {
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

        print("== LUFS standard check ==")
        let lm = LoudnessMeter(sampleRate: 48000, channelCount: 2)
        // 10 сек стерео 1 кГц, -20 dBFS: ожидание -20.69 LUFS по BS.1770
        let n = 48000
        for chunk in 0..<10 {
            var left = [Float](repeating: 0, count: n)
            var right = [Float](repeating: 0, count: n)
            for i in 0..<n {
                let t = Float(Double(chunk * n + i) / 48000.0)
                left[i] = sinf(2 * Float.pi * 1000 * t) * 0.1
                right[i] = sinf(2 * Float.pi * 1000 * t) * 0.1
            }
            lm.processStereo(left: left, right: right)
        }
        let r = lm.reading()
        check(abs(r.momentaryLUFS - (-20.04)) < 0.35,
              "Стерео LUFS учитывает энергию L+R и K-взвешивание (получено \(String(format: "%.2f", r.momentaryLUFS)))")
        check(abs(r.integratedLUFS - r.momentaryLUFS) < 0.15,
              "Integrated LUFS совпадает с постоянным тестовым сигналом")
        check(abs(r.shortTermLUFS - r.momentaryLUFS) < 0.15,
              "S соответствует стандартному трёхсекундному окну")

        print("\nИтог: \(failures == 0 ? "ВСЕ ПРОШЛИ" : "ОШИБОК: \(failures)")")
    }
}

let runner = Runner()
runner.runAll()
exit(runner.failures == 0 ? 0 : 1)
