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
    var neighborSmoothing: Int

    init(from s: RTASettings) {
        self.bandsPerOctave = s.bandsPerOctave
        self.attack = s.attack
        self.release = s.release
        self.peakHoldSeconds = s.peakHoldSeconds
        self.showFineCurve = s.showFineCurve
        self.shortTermSeconds = s.shortTermSeconds
        self.neighborSmoothing = s.neighborSmoothing
    }

    func toSettings() -> RTASettings {
        RTASettings(
            bandsPerOctave: bandsPerOctave,
            attack: attack,
            release: release,
            peakHoldSeconds: peakHoldSeconds,
            showFineCurve: showFineCurve,
            shortTermSeconds: shortTermSeconds,
            neighborSmoothing: neighborSmoothing
        )
    }
}
