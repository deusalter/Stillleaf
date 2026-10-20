import SwiftUI
import UIKit

/// Presents `ReaderViewController` full screen from SwiftUI.
struct ReaderScreen: UIViewControllerRepresentable {
    let edition: Edition
    let journal: Journal
    let onClose: () -> Void

    func makeUIViewController(context: Context) -> ReaderViewController {
        ReaderViewController(edition: edition, journal: journal, onClose: onClose)
    }

    func updateUIViewController(_ controller: ReaderViewController, context: Context) {}

    static func dismantleUIViewController(_ controller: ReaderViewController, coordinator: ()) {
        controller.finish()
    }
}

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
    static var effectiveGardenMode: GardenMode {
        guard gardenMode == .animated else { return gardenMode }
        return UIAccessibility.isReduceMotionEnabled || ProcessInfo.processInfo.isLowPowerModeEnabled ? .still : .animated
    }
}
