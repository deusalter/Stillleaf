import AppKit
import CoreGraphics

public enum SystemEligibility {
    /// A missing console-session description is treated conservatively as locked.
    public static var unlocked: Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any],
              let onConsole = session[kCGSessionOnConsoleKey as String] as? Bool,
              let loggedIn = session[kCGSessionLoginDoneKey as String] as? Bool else { return false }
        return onConsole && loggedIn && !(session["CGSSessionScreenIsLocked"] as? Bool ?? false)
    }
    public static var displayAwake: Bool {
        CGDisplayIsAsleep(CGMainDisplayID()) == 0
    }
    public static var booksForeground: Bool { NSWorkspace.shared.frontmostApplication?.bundleIdentifier == BooksCapture.bundleID }
    /// Reads elapsed input inactivity only, never keys, buttons, pointer coordinates or other app titles.
    public static var secondsSinceInput: TimeInterval { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: UInt32.max)!) }
}
