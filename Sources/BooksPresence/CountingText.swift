import SwiftUI

/// Remembers what each surface last showed, so numbers count up when a screen first appears and
/// roll when their value really changes, but do not replay every time the user comes back to it.
@MainActor
final class QuietLedger {
    static let shared = QuietLedger()
    /// How long a surface has to be away before its numbers count up again.
    static let freshness: TimeInterval = 600

    enum Start: Equatable {
        /// Already shown recently: no motion.
        case settled
        /// First appearance: count up from zero.
        case fromZero
        /// The value changed while the surface was away: roll from what it last showed.
        case from(String)
    }

    private var seen: [String: (value: String, at: Date)] = [:]
    var now: () -> Date = { Date() }

    func start(_ key: String, value: String) -> Start {
        guard let entry = seen[key] else { return .fromZero }
        if entry.value != value { return .from(entry.value) }
        return now().timeIntervalSince(entry.at) < Self.freshness ? .settled : .fromZero
    }

    func record(_ key: String, value: String) { seen[key] = (value, now()) }

    func forgetAll() { seen.removeAll() }
}

/// A number that counts up the first time it appears and rolls when it changes. Digits keep a
/// fixed width, and the transition runs in SwiftUI's own text animation: nothing is redrawn by
/// a timer. Under Reduce Motion (and in captures) it simply shows the final value.
@MainActor
struct CountingText: View {
    let text: String
    /// Names the number across appearances; see `QuietLedger`.
    let key: String
    @QuietMotionLevel private var motion
    @State private var shown: String?
    @State private var changedAt = Date.distantPast

    static let countUp = Animation.easeOut(duration: 0.8)
    static let roll = Animation.easeOut(duration: 0.45)
    /// Fewest seconds between two rolls, so a number that ticks every second (a timer) rolls once and then just updates.
    static let rollSpacing: TimeInterval = 4

    static func rolls(sinceLastChange seconds: TimeInterval) -> Bool { seconds >= rollSpacing }

    init(_ text: String, key: String) {
        self.text = text
        self.key = key
    }

    var body: some View {
        let current = shown ?? Self.firstText(text, start: QuietLedger.shared.start(key, value: text), motion: motion)
        Text(current)
            .modifier(CountTransition(number: Self.number(in: current)))
            .transaction { if !motion.plays { $0.animation = nil } }
            .onAppear { appear() }
            .onChange(of: text) { change(to: $0) }
    }

    private func appear() {
        let first = Self.firstText(text, start: QuietLedger.shared.start(key, value: text), motion: motion)
        QuietLedger.shared.record(key, value: text)
        guard first != text, shown == nil, motion.plays else { shown = text; return }
        withAnimation(Self.countUp) { shown = text }
    }

    private func change(to value: String) {
        QuietLedger.shared.record(key, value: value)
        let rolls = Self.rolls(sinceLastChange: Date().timeIntervalSince(changedAt))
        changedAt = Date()
        if motion.plays && rolls { withAnimation(Self.roll) { shown = value } } else { shown = value }
    }

    /// What the first frame shows: the final value, or the place the count starts from.
    static func firstText(_ text: String, start: QuietLedger.Start, motion: QuietMotion) -> String {
        guard motion.plays else { return text }
        switch start {
        case .settled: return text
        case .fromZero: return zeroed(text)
        case .from(let old): return old
        }
    }

    /// `text` with every number replaced by a single 0, keeping its shape: "1h 05m" starts at "0h 0m".
    static func zeroed(_ text: String) -> String {
        var result = "", inNumber = false
        let characters = Array(text)
        for (index, character) in characters.enumerated() {
            let digit = character.isASCII && character.isNumber
            let joiner = (character == "," || character == ".") && inNumber
                && index + 1 < characters.count && characters[index + 1].isASCII && characters[index + 1].isNumber
            if digit || joiner {
                if !inNumber { result.append("0"); inNumber = true }
            } else {
                inNumber = false
                result.append(character)
            }
        }
        return result
    }

    /// The first number in `text`, which tells the transition which way the digits roll.
    static func number(in text: String) -> Double {
        var digits = "", started = false
        for character in text {
            if character.isASCII && character.isNumber { digits.append(character); started = true }
            else if started && character == "," { continue }
            else if started { break }
        }
        return Double(digits) ?? 0
    }
}

private struct CountTransition: ViewModifier {
    let number: Double

    func body(content: Content) -> some View {
        #if compiler(>=5.9)
        if #available(macOS 14.0, *) {
            content.contentTransition(.numericText(value: number))
        } else {
            content.contentTransition(.opacity)
        }
        #else
        content.contentTransition(.opacity)
        #endif
    }
}
