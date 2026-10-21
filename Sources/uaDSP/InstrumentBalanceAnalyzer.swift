import Foundation

/// Вычисляет карту энергетических полос (инструментов) из FFT-массива.
/// Отдаёт как отклонение от референсной кривой — для отображения «что
/// перегружено / что утонуло».
///
/// Проблема старой версии: абсолютные дБ сравнивались с фиксированной кривой,
/// поэтому на тихом сигнале все полосы уходили в −120 и шкала «залипала».
/// Здесь сравниваем ФОРМУ спектра: уровень нормализуется по общей громкости
/// сигнала (смещение нейтрализовано), а порог тишины отбрасывает незначащие
/// полосы.
public final class InstrumentBalanceAnalyzer {

    private enum Result {
        case valid([InstrumentBalance])
        case silent
        case noData
    }

    private let result: Result

    /// Инициализируется с последним обновлённым спектром.
    public init(spectrum: [SpectrumPoint], sampleRate: Float) {
        self.result = Self.compute(spectrum: spectrum, sampleRate: sampleRate)
    }

    public init(spectrumDB: [Float], sampleRate: Float, fftLength: Int) {
        let half = spectrumDB.count / 2
        var points: [SpectrumPoint] = []
        for (bin, db) in spectrumDB.enumerated() where bin < half {
            let freq = Float(bin) * sampleRate / Float(fftLength)
            guard freq > 20, freq < sampleRate / 2 else { continue }
            points.append(SpectrumPoint(id: bin, frequency: freq, magnitudeDB: db))
        }
        self.result = Self.compute(spectrum: points, sampleRate: sampleRate)
    }

    public func balances(reference: ReferenceCurve = .defaultMusic) -> [InstrumentBalance] {
        switch result {
        case .valid(let balances):
            return balances
        case .silent, .noData:
            return InstrumentBand.allCases.map { band in
                InstrumentBalance(band: band, energyDB: -120, deviationDB: 0, significance: 0)
            }
        }
    }

    public var hasSignal: Bool {
        if case .valid = result { return true }
        return false
    }

    // MARK: - Private

    private static func compute(spectrum: [SpectrumPoint], sampleRate: Float) -> Result {
        guard !spectrum.isEmpty else { return .noData }

        var sums: [InstrumentBand: Float] = [:]
        var counts: [InstrumentBand: Int] = [:]
        var totalEnergy: Float = 0
        var totalCount = 0

        for point in spectrum {
            for band in InstrumentBand.allCases where band.range.contains(point.frequency) {
                sums[band, default: 0] += point.magnitudeDB
                counts[band, default: 0] += 1
                totalEnergy += point.magnitudeDB
                totalCount += 1
            }
        }

        guard totalCount > 0 else { return .noData }

        // Средний уровень всего спектра — «громкость». Если сигнал тихий
        // (ниже порога −60 дБ RMS в среднем), считаем что звука нет.
        let averageLevel = totalEnergy / Float(totalCount)
        guard averageLevel > -60 else { return .silent }

        var balances: [InstrumentBalance] = []
        let reference = ReferenceCurve.defaultMusic

        for band in InstrumentBand.allCases {
            guard let count = counts[band], count > 0 else { continue }
            let bandLevel = sums[band]! / Float(count)

            // Нормализованная форма: разница «полоса − среднее».
            let shape = bandLevel - averageLevel

            guard let refLevel = reference.bands[band] else { continue }
            let refValues = Array(reference.bands.values)
            let refAverage = refValues.reduce(0, +) / Float(max(refValues.count, 1))
            let refShape = refLevel - refAverage

            let deviation = shape - refShape
            let significance = min(1, max(0, abs(deviation) / 12))

            balances.append(
                InstrumentBalance(
                    band: band,
                    energyDB: bandLevel,
                    deviationDB: deviation,
                    significance: significance
                )
            )
        }

        guard !balances.isEmpty else { return .noData }
        return .valid(balances)
    }
}