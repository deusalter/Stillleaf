import Foundation

/// Forgiving readers for the two things people type into the manual-entry form.
public enum ManualEntryParsing {
    public struct Clock: Equatable {
        public var hour: Int
        public var minute: Int
    }

    /// "45", "1h 20m", "1h20", "90 min", "2 hours", "1.5h" and "1:30" (hours:minutes). Bare numbers are minutes.
    public static func duration(_ text: String) -> TimeInterval? {
        let value = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if value.contains(":") {
            let parts = value.split(separator: ":", omittingEmptySubsequences: false)
            guard (2...3).contains(parts.count), parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCIIDigit) }),
                  let hours = Double(parts[0]), let minutes = Double(parts[1]), minutes < 60 else { return nil }
            let seconds = parts.count == 3 ? Double(parts[2]) ?? 60 : 0
            guard seconds < 60 else { return nil }
            return positive(hours * 3_600 + minutes * 60 + seconds)
        }
        guard let pattern = try? NSRegularExpression(pattern: #"(\d+(?:\.\d+)?)\s*([a-z]*)"#) else { return nil }
        let range = NSRange(value.startIndex..., in: value)
        let matches = pattern.matches(in: value, range: range)
        guard !matches.isEmpty else { return nil }
        var rest = value
        var total = 0.0
        for (offset, match) in matches.enumerated().reversed() {
            guard let numberRange = Range(match.range(at: 1), in: value), let unitRange = Range(match.range(at: 2), in: value),
                  let number = Double(value[numberRange]) else { return nil }
            let unit = String(value[unitRange])
            switch unit {
            case "h", "hr", "hrs", "hour", "hours": total += number * 3_600
            case "m", "min", "mins", "minute", "minutes", "": 
                // A unit-less number is minutes, but only as the last number ("1h20").
                if unit.isEmpty && offset != matches.count - 1 { return nil }
                total += number * 60
            default: return nil
            }
            if let all = Range(match.range, in: rest) { rest.removeSubrange(all) }
        }
        guard rest.allSatisfy({ $0.isWhitespace || $0 == "," }) else { return nil }
        return positive(total)
    }

    /// "7:42 pm", "19:42", "742p", "7 pm", "12 am".
    public static func clock(_ text: String) -> Clock? {
        var value = text.lowercased().filter { !$0.isWhitespace && $0 != "." }
        var meridiem: Bool?  // true = pm
        for (suffix, isPM) in [("am", false), ("pm", true), ("a", false), ("p", true)] where value.hasSuffix(suffix) {
            value.removeLast(suffix.count); meridiem = isPM; break
        }
        guard !value.isEmpty, value.allSatisfy({ $0.isASCIIDigit || $0 == ":" }) else { return nil }
        var hour: Int, minute: Int
        if value.contains(":") {
            let parts = value.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]), parts[1].count == 2 else { return nil }
            hour = h; minute = m
        } else {
            guard let number = Int(value) else { return nil }
            switch value.count {
            case 1, 2: hour = number; minute = 0
            case 3, 4: hour = number / 100; minute = number % 100
            default: return nil
            }
        }
        guard (0...59).contains(minute) else { return nil }
        if let isPM = meridiem {
            guard (1...12).contains(hour) else { return nil }
            hour = hour % 12 + (isPM ? 12 : 0)
        }
        guard (0...23).contains(hour) else { return nil }
        return Clock(hour: hour, minute: minute)
    }

    private static func positive(_ seconds: Double) -> TimeInterval? { seconds.isFinite && seconds > 0 ? seconds : nil }
}

private extension Character {
    var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}
