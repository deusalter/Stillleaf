import Foundation

/// Reader settings that live outside per-book reader state.
enum ReaderPreferences {
    enum GardenMode: String, CaseIterable, Identifiable {
        case animated, still, off
        var id: String { rawValue }
        var label: String {
            switch self {
            case .animated: return "Living"
            case .still: return "Still"
            case .off: return "Off"
            }
        }
    }

    static let gardenKey = "gardenMode"

    static var gardenMode: GardenMode {
        GardenMode(rawValue: UserDefaults.standard.string(forKey: gardenKey) ?? "") ?? .animated
    }

    /// As on the Mac: a living garden falls back to still under Reduce Motion or Low Power Mode.
    static func effectiveGardenMode(reduceMotion: Bool) -> GardenMode {
        guard gardenMode == .animated else { return gardenMode }
        return reduceMotion || ProcessInfo.processInfo.isLowPowerModeEnabled ? .still : .animated
    }
}
