import Foundation
import yaCore

/// Codable-представление RTASettings для UserDefaults.
struct RTASettingsDTO: Codable {
    var bandsPerOctave: Int
    var attack: Float
    var release: Float
    var peakHoldSeconds: Float
    var showFineCurve: Bool
    var shortTermSeconds: Double
    var neighborSmoothing: Float
    var loudnessSmoothing: Float
    var numberSmoothing: Float
    var autoDowngrade: Bool

    init(from s: RTASettings) {
        self.bandsPerOctave = s.bandsPerOctave
        self.attack = s.attack
        self.release = s.release
        self.peakHoldSeconds = s.peakHoldSeconds
        self.showFineCurve = s.showFineCurve
        self.shortTermSeconds = s.shortTermSeconds
        self.neighborSmoothing = s.neighborSmoothing
        self.loudnessSmoothing = s.loudnessSmoothing
        self.numberSmoothing = s.numberSmoothing
        self.autoDowngrade = s.autoDowngrade
    }

    func toSettings() -> RTASettings {
        RTASettings(
            bandsPerOctave: bandsPerOctave,
            attack: attack,
            release: release,
            peakHoldSeconds: peakHoldSeconds,
            showFineCurve: showFineCurve,
            autoDowngrade: autoDowngrade,
            shortTermSeconds: shortTermSeconds,
            neighborSmoothing: neighborSmoothing,
            loudnessSmoothing: loudnessSmoothing
        )
    }
}
