import Foundation

/// Where the running app bundle lives, for first-launch decisions that must only happen once
/// Stillleaf is really installed (login startup, the Accessibility entry, Uninstall).
public enum InstallLocation: Equatable, Sendable {
    /// A writable folder such as /Applications or ~/Applications.
    case installed
    /// Gatekeeper App Translocation: a quarantined app opened where it was downloaded or
    /// unpacked runs from a randomized read-only mount until the user moves it.
    case translocated
    /// Opened directly from the mounted release disk image (or another read-only volume).
    case readOnlyVolume
    /// A bare executable, as in development and test runs.
    case notBundled

    public var isTemporary: Bool { self == .translocated || self == .readOnlyVolume }

    public static func classify(bundlePath: String, volumeIsReadOnly: Bool) -> InstallLocation {
        guard bundlePath.hasSuffix(".app") || bundlePath.hasSuffix(".app/") else { return .notBundled }
        if bundlePath.contains("/AppTranslocation/") { return .translocated }
        return volumeIsReadOnly ? .readOnlyVolume : .installed
    }

    public static func current(_ bundle: Bundle = .main) -> InstallLocation {
        let url = bundle.bundleURL
        let readOnly = (try? url.resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly) ?? false
        return classify(bundlePath: url.path, volumeIsReadOnly: readOnly)
    }
}
