import Foundation
import BooksPlatform

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}

check(InstallLocation.classify(bundlePath: "/Applications/Stillleaf.app", volumeIsReadOnly: false) == .installed, "Applications is installed")
check(InstallLocation.classify(bundlePath: "/private/var/folders/x/T/AppTranslocation/1D/d/Stillleaf.app", volumeIsReadOnly: true) == .translocated, "Translocation is temporary")
check(InstallLocation.classify(bundlePath: "/Volumes/Stillleaf/Stillleaf.app", volumeIsReadOnly: true) == .readOnlyVolume, "The mounted image is temporary")
check(InstallLocation.classify(bundlePath: "/Volumes/External/Applications/Stillleaf.app", volumeIsReadOnly: false) == .installed, "A writable external Applications folder is installed")
check(InstallLocation.classify(bundlePath: "/repo/.build/local/BooksPresence", volumeIsReadOnly: false) == .notBundled, "Bare executables are not bundles")
check(InstallLocation.current() == .notBundled, "This smoke runs as a bare executable")
print("install-location-smoke: passed")
