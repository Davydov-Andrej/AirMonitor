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
    private var lastSpectrumDirty = false
    private var lastBalances: [InstrumentBalance] = []

    public init(channelIndex: Int, sampleRate: Float, fftLength: Int, windowType: FFT.WindowType = .hann) {
        self.channelIndex = channelIndex
        self.label = "Ch \(channelIndex + 1)"
        self.sampleRate = sampleRate
        self.vu = VUMeter(sampleRate: sampleRate)
        self.dynamics = DynamicsAnalyzer(sampleRate: sampleRate)
        self.loudness = LoudnessMeter(sampleRate: Double(sampleRate))
        self.rta = RTASpectrumAnalyzer(length: fftLength, sampleRate: sampleRate, windowType: windowType)
        self.loudness.shortTermSeconds = 3.0
        self.loudness.displaySmoothing = 1.0
    }

    public init(channelIndex: Int, label: String, sampleRate: Float, fftLength: Int, windowType: FFT.WindowType = .hann, rtaSettings: RTASettings = .default) {
        self.channelIndex = channelIndex
        self.label = label
        self.sampleRate = sampleRate
        self.vu = VUMeter(sampleRate: sampleRate)
        self.dynamics = DynamicsAnalyzer(sampleRate: sampleRate)
        self.loudness = LoudnessMeter(sampleRate: Double(sampleRate))
        self.rta = RTASpectrumAnalyzer(length: fftLength, sampleRate: sampleRate, settings: rtaSettings, windowType: windowType)
        self.loudness.shortTermSeconds = rtaSettings.shortTermSeconds
        self.loudness.displaySmoothing = rtaSettings.loudnessSmoothing
        self.loudness.numberSmoothing = rtaSettings.numberSmoothing
    }

    public func process(_ samples: [Float], sampleRate: Float) {
        self.sampleRate = sampleRate
        vu.process(samples)
        dynamics.process(samples)
        loudness.process(samples)
        rta.process(samples)
        // Полосы/кривая собираются лениво — в snapshot().
        lastSpectrumDirty = true
    }

    /// Применяет display smoothing громкости немедленно.
    public func applyLoudnessSmoothing(_ alpha: Float) {
        loudness.displaySmoothing = alpha
    }

    /// Калибровочный офсет LUFS (дБ).
    public func applyCalibration(_ offset: Float) {
        loudness.calibrationOffset = offset
    }

    /// Применяет новые настройки RTA немедленно (без пересоздания).
    public func applyRTASettings(_ settings: RTASettings) {
        loudness.shortTermSeconds = settings.shortTermSeconds
        loudness.displaySmoothing = settings.loudnessSmoothing
        loudness.numberSmoothing = settings.numberSmoothing
        rta.updateSettings(settings)
        lastSpectrumDirty = true
    }

    public func snapshot() -> ChannelSnapshot {
        snapshot(label: self.label)
    }

    public func snapshot(label: String) -> ChannelSnapshot {
        if lastSpectrumDirty {
            let data = rta.snapshotData()
            rtaBands = data.bands
            rtaFineCurve = data.fine
            lastSpectrum = data.bands.map {
                SpectrumPoint(id: $0.id, frequency: $0.centerFrequency, magnitudeDB: $0.levelDB)
            }
            // Тональный баланс считается здесь (DSP-поток), а не в UI.
            let analyzer = InstrumentBalanceAnalyzer(spectrum: lastSpectrum, sampleRate: sampleRate)
            lastBalances = analyzer.balances()
            lastSpectrumDirty = false
        }
        let reading = loudness.reading()
        let profile = dynamics.profile()
        let history = loudness.historySnapshot()
        return ChannelSnapshot(
            id: channelIndex,
            label: label,
            peakDB: profile.peakDBFS,
            rmsDB: profile.fastRMS,  // живой RMS для заливки метра
            vuDB: vu.value,
            truePeakDB: profile.truePeakDBTP,
            crestFactorDB: profile.crestFactorDB,
            momentaryLUFS: reading.momentaryLUFS,
            shortTermLUFS: reading.shortTermLUFS,
            spectrum: [],
            rtaBands: rtaBands,
            fineCurve: rtaFineCurve,
            loudnessHistory: history,
            tonalBalances: lastBalances,
            integratedLUFS: reading.integratedLUFS,
            loudnessRangeLU: reading.loudnessRangeLU
        )
    }
}
