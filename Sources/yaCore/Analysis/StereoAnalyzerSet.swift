import Foundation
import uaDSP

/// Стерео-анализ: пара каналов обрабатывается как единый стерео-микс.
/// Трансляция выполняется в моновход для измерителей, а корреляция L/R
/// (положительная = согласованно, отрицательная = противофаза) сохраняется
/// отдельно.
public final class StereoAnalyzerSet {

    public let leftChannelIndex: Int
    public let rightChannelIndex: Int
    public let label: String

    public private(set) var leftAnalyzer: ChannelAnalyzerSet
    public private(set) var rightAnalyzer: ChannelAnalyzerSet
    private let stereoLoudness: LoudnessMeter

    public private(set) var correlation: Float = 1.0

    private var pending: [Int: [Float]] = [:]

    public init(left: Int, right: Int, sampleRate: Float, fftLength: Int, windowType: FFT.WindowType = .hann) {
        self.leftChannelIndex = left
        self.rightChannelIndex = right
        self.label = "L \(left + 1) / R \(right + 1)"
        let labelL = "L \(left + 1)"
        let labelR = "R \(right + 1)"
        self.stereoLoudness = LoudnessMeter(sampleRate: Double(sampleRate), channelCount: 2)
        self.leftAnalyzer = ChannelAnalyzerSet(channelIndex: left, label: labelL,
                                               sampleRate: sampleRate, fftLength: fftLength, windowType: windowType)
        self.rightAnalyzer = ChannelAnalyzerSet(channelIndex: right, label: labelR,
                                                sampleRate: sampleRate, fftLength: fftLength, windowType: windowType)
    }

    public init(left: Int, right: Int, label: String, sampleRate: Float, fftLength: Int, windowType: FFT.WindowType = .hann, rtaSettings: RTASettings = .default) {
        self.leftChannelIndex = left
        self.rightChannelIndex = right
        self.label = label
        let labelL = "\(label) · L"
        let labelR = "\(label) · R"
        self.stereoLoudness = LoudnessMeter(sampleRate: Double(sampleRate), channelCount: 2)
        self.stereoLoudness.shortTermSeconds = rtaSettings.shortTermSeconds
        self.stereoLoudness.displaySmoothing = rtaSettings.loudnessSmoothing
        self.stereoLoudness.numberSmoothing = rtaSettings.numberSmoothing
        self.leftAnalyzer = ChannelAnalyzerSet(channelIndex: left, label: labelL,
                                               sampleRate: sampleRate, fftLength: fftLength, windowType: windowType, rtaSettings: rtaSettings)
        self.rightAnalyzer = ChannelAnalyzerSet(channelIndex: right, label: labelR,
                                                sampleRate: sampleRate, fftLength: fftLength, windowType: windowType, rtaSettings: rtaSettings)
    }

    public func push(channel: Int, samples: [Float]) {
        pending[channel] = samples
    }

    /// Когда оба канала собраны — считаем mono (mid) и корреляцию за кадр.
    public func processFrame(frameCount: Int, sampleRate: Float) {
        guard let left = pending[leftChannelIndex], let right = pending[rightChannelIndex] else {
            pending = [:]
            return
        }
        let n = min(left.count, right.count)
        guard n > 0 else { return }

        var productSum: Float = 0
        var leftSq: Float = 0
        var rightSq: Float = 0
        for i in 0..<n {
            productSum += left[i] * right[i]
            leftSq += left[i] * left[i]
            rightSq += right[i] * right[i]
        }

        let denom = sqrtf(leftSq * rightSq)
        if denom > 1e-12 {
            correlation = productSum / denom
        }

        // Оптимизация: только 2 FFT (L и R). Суммарные метрики (mono/M/S/I)
        // вычисляются в snapshot() арифметически из L/R — третий FFT не нужен.
        leftAnalyzer.process(left, sampleRate: sampleRate)
        rightAnalyzer.process(right, sampleRate: sampleRate)
        stereoLoudness.processStereo(left: left, right: right)

        pending = [:]
    }

    public func snapshot() -> (mono: ChannelSnapshot, left: ChannelSnapshot, right: ChannelSnapshot, correlation: Float) {
        let l = leftAnalyzer.snapshot(label: "L \(leftChannelIndex + 1)")
        let r = rightAnalyzer.snapshot(label: "R \(rightChannelIndex + 1)")
        let m = Self.monoSnapshot(from: l, r, loudness: stereoLoudness.reading(),
                                  history: stereoLoudness.historySnapshot())
        return (m, l, r, correlation)
    }

    public func applyCalibration(_ offset: Float) {
        stereoLoudness.calibrationOffset = offset
    }

    public func applyLoudnessSmoothing(_ alpha: Float) {
        stereoLoudness.displaySmoothing = alpha
    }

    public func applyRTASettings(_ settings: RTASettings) {
        stereoLoudness.shortTermSeconds = settings.shortTermSeconds
        stereoLoudness.displaySmoothing = settings.loudnessSmoothing
        stereoLoudness.numberSmoothing = settings.numberSmoothing
    }

    /// Суммарный (stereo) снимок: громкости по энергетическому среднему L/R,
    /// спектр — суммарная энергия полос. Без третьего FFT.
    private static func monoSnapshot(
        from l: ChannelSnapshot,
        _ r: ChannelSnapshot,
        loudness: LoudnessMeter.Reading,
        history: [LoudnessMeter.HistoryPoint]
    ) -> ChannelSnapshot {
        // Спектральные полосы: среднее энергии каналов (сумма удвоила бы уровень полосы).
        func energyAvg(_ a: Float, _ b: Float) -> Float {
            guard a.isFinite, b.isFinite else { return max(a.isFinite ? a : b, b.isFinite ? b : -Float.infinity) }
            return 10 * log10((powf(10, a / 10) + powf(10, b / 10)) / 2)
        }
        func ampAvg(_ a: Float, _ b: Float) -> Float {
            guard a.isFinite, b.isFinite else { return max(a.isFinite ? a : b, b.isFinite ? b : -Float.infinity) }
            return 20 * log10((powf(10, a / 20) + powf(10, b / 20)) / 2)
        }

        // Спектр: энергия полос L+R.
        var bands: [RTABand] = []
        for (lb, rb) in zip(l.rtaBands, r.rtaBands) {
            let level = energyAvg(lb.levelDB, rb.levelDB)
            let peak = max(lb.peakDB, rb.peakDB)
            bands.append(RTABand(
                id: lb.id,
                centerFrequency: lb.centerFrequency,
                lowerFrequency: lb.lowerFrequency,
                upperFrequency: lb.upperFrequency,
                levelDB: level,
                peakDB: peak
            ))
        }
        var fine: [SpectrumPoint] = []
        for (lf, rf) in zip(l.fineCurve, r.fineCurve) {
            fine.append(SpectrumPoint(id: lf.id, frequency: lf.frequency, magnitudeDB: energyAvg(lf.magnitudeDB, rf.magnitudeDB)))
        }
        // Спектр для баланса: энергия полос L+R.
        var balanceSpectrum: [SpectrumPoint] = []
        for (ls, rs) in zip(l.spectrum, r.spectrum) {
            balanceSpectrum.append(SpectrumPoint(id: ls.id, frequency: ls.frequency, magnitudeDB: energyAvg(ls.magnitudeDB, rs.magnitudeDB)))
        }

        return ChannelSnapshot(
            id: -1,
            label: "Стерео",
            peakDB: max(l.peakDB, r.peakDB),
            rmsDB: energyAvg(l.rmsDB, r.rmsDB),
            vuDB: ampAvg(l.vuDB, r.vuDB),
            truePeakDB: max(l.truePeakDB, r.truePeakDB),
            crestFactorDB: max(l.crestFactorDB, r.crestFactorDB),
            momentaryLUFS: loudness.momentaryLUFS,
            shortTermLUFS: loudness.shortTermLUFS,
            spectrum: balanceSpectrum,
            rtaBands: bands,
            fineCurve: fine,
            loudnessHistory: history,
            integratedLUFS: loudness.integratedLUFS,
            loudnessRangeLU: loudness.loudnessRangeLU
        )
    }
}
