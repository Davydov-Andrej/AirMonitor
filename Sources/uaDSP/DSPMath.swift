import Foundation

public enum DSPMath {
    /// Перевод амплитуды (Peak, RMS) в дБ.
    @inline(__always)
    public static func dB(_ value: Float) -> Float {
        guard value > 0 else { return -120 }
        return 20 * log10(value)
    }

    /// Из децибел в линейную амплитуду.
    @inline(__always)
    public static func amplitude(_ decibels: Float) -> Float {
        pow(10, decibels / 20)
    }

    /// Схлопывание бесконечности/NaN в дБ.
    public static func clampedDB(_ value: Float) -> Float {
        let db = dB(value)
        guard db.isFinite else { return -120 }
        return max(db, -120)
    }
}
