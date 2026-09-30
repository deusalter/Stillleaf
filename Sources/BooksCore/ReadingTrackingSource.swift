/// Accessibility belongs to the Apple Books adapter. Native and manual reading
/// remain eligible even when that optional integration has no permission.
public enum ReadingTrackingSource: Equatable {
    case manual, nativeReader, appleBooks, appleBooksNeedsAccess, idle

    public static func resolve(manualReading: Bool, nativeReaderFocused: Bool,
                               appleBooksForeground: Bool, accessibilityGranted: Bool) -> Self {
        if manualReading { return .manual }
        if nativeReaderFocused { return .nativeReader }
        if !appleBooksForeground { return .idle }
        return accessibilityGranted ? .appleBooks : .appleBooksNeedsAccess
    }
}
