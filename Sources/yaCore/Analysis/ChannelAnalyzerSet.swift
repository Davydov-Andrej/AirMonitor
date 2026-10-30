import Foundation
import uaDSP

/// Набор DSP-анализаторов для одного канала: VU, пики, LUFS, RTA-спектр, динамика.
public final class ChannelAnalyzerSet {

    public let channelIndex: Int
    public let label: String
    private var sampleRate: Float

    private let vu: VUMeter
    private let dynamics: DynamicsAnalyzer
    private let loudness: LoudnessMeter
    private let rta: RTASpectrumAnalyzer

    public private(set) var lastSpectrum: [SpectrumPoint] = []
    public private(set) var rtaBands: [RTABand] = []
    public private(set) var rtaFineCurve: [SpectrumPoint] = []

    public init(channelIndex: Int, sampleRate: Float, fftLength: Int, windowType: FFT.WindowType = .hann) {
        self.channelIndex = channelIndex
        self.label = "Ch \(channelIndex + 1)"
        self.sampleRate = sampleRate
        self.vu = VUMeter(sampleRate: sampleRate)
        self.dynamics = DynamicsAnalyzer()
        self.loudness = LoudnessMeter(sampleRate: Double(sampleRate))
        self.rta = RTASpectrumAnalyzer(length: fftLength, sampleRate: sampleRate, windowType: windowType)
    }

    public init(channelIndex: Int, label: String, sampleRate: Float, fftLength: Int, windowType: FFT.WindowType = .hann, rtaSettings: RTASettings = .default) {
        self.channelIndex = channelIndex
        self.label = label
        self.sampleRate = sampleRate
        self.vu = VUMeter(sampleRate: sampleRate)
        self.dynamics = DynamicsAnalyzer()
        self.loudness = LoudnessMeter(sampleRate: Double(sampleRate))
        self.rta = RTASpectrumAnalyzer(length: fftLength, sampleRate: sampleRate, settings: rtaSettings, windowType: windowType)
    }

    public func process(_ samples: [Float], sampleRate: Float) {
        self.sampleRate = sampleRate
        vu.process(samples)
        dynamics.process(samples)
        loudness.process(samples)
        rta.process(samples)
        lastSpectrum = rta.spectrumPoints()
        rtaBands = rta.bands
        rtaFineCurve = rta.fineCurve
    }

    /// Применяет новые настройки RTA немедленно (без пересоздания).
    public func applyRTASettings(_ settings: RTASettings) {
        rta.updateSettings(settings)
    }

    public func snapshot() -> ChannelSnapshot {
        snapshot(label: self.label)
    }

    public func snapshot(label: String) -> ChannelSnapshot {
        let reading = loudness.reading()
        let profile = dynamics.profile()
        let history = loudness.history
        return ChannelSnapshot(
            id: channelIndex,
            label: label,
            peakDB: profile.peakDBFS,
            rmsDB: profile.rmsDBFS,
            vuDB: vu.value,
            truePeakDB: profile.truePeakDBTP,
            crestFactorDB: profile.crestFactorDB,
            momentaryLUFS: reading.momentaryLUFS,
            shortTermLUFS: reading.shortTermLUFS,
            spectrum: lastSpectrum,
            rtaBands: rtaBands,
            fineCurve: rtaFineCurve,
            loudnessHistory: history,
            integratedLUFS: reading.integratedLUFS,
            loudnessRangeLU: reading.loudnessRangeLU
        )
    }
}