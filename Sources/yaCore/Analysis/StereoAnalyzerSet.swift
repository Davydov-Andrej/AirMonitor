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

    public private(set) var monoAnalyzer: ChannelAnalyzerSet
    public private(set) var leftAnalyzer: ChannelAnalyzerSet
    public private(set) var rightAnalyzer: ChannelAnalyzerSet

    public private(set) var correlation: Float = 1.0

    private var pending: [Int: [Float]] = [:]

    public init(left: Int, right: Int, sampleRate: Float, fftLength: Int, windowType: FFT.WindowType = .hann) {
        self.leftChannelIndex = left
        self.rightChannelIndex = right
        self.label = "L \(left + 1) / R \(right + 1)"
        let labelL = "L \(left + 1)"
        let labelR = "R \(right + 1)"
        self.monoAnalyzer = ChannelAnalyzerSet(channelIndex: -1, label: "Стерео (L+R)",
                                               sampleRate: sampleRate, fftLength: fftLength, windowType: windowType)
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
        self.monoAnalyzer = ChannelAnalyzerSet(channelIndex: -1, label: "\(label) (L+R)",
                                               sampleRate: sampleRate, fftLength: fftLength, windowType: windowType, rtaSettings: rtaSettings)
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

        var mid = [Float](repeating: 0, count: n)
        var productSum: Float = 0
        var leftSq: Float = 0
        var rightSq: Float = 0
        for i in 0..<n {
            mid[i] = (left[i] + right[i]) * 0.5
            productSum += left[i] * right[i]
            leftSq += left[i] * left[i]
            rightSq += right[i] * right[i]
        }

        let denom = sqrtf(leftSq * rightSq)
        if denom > 1e-12 {
            correlation = productSum / denom
        }

        monoAnalyzer.process(mid, sampleRate: sampleRate)
        leftAnalyzer.process(left, sampleRate: sampleRate)
        rightAnalyzer.process(right, sampleRate: sampleRate)

        pending = [:]
    }

    public func snapshot() -> (mono: ChannelSnapshot, left: ChannelSnapshot, right: ChannelSnapshot, correlation: Float) {
        let m = monoAnalyzer.snapshot(label: "Стерео (L+R)")
        let l = leftAnalyzer.snapshot(label: "L \(leftChannelIndex + 1)")
        let r = rightAnalyzer.snapshot(label: "R \(rightChannelIndex + 1)")
        return (m, l, r, correlation)
    }
}
