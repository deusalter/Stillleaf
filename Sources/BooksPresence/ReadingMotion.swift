import SwiftUI

/// Short, non-bouncing feedback shared by the reading UI.
enum ReadingMotion {
    static let hover = Animation.easeOut(duration: 0.14)
    static let press = Animation.easeOut(duration: 0.10)
    static let entrance = Animation.easeOut(duration: 0.18)
    /// A non-overshooting spring retargets an in-flight selection without a delay.
    static let selection = Animation.spring(response: 0.24, dampingFraction: 1)
}

private struct ReadingEntrance: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    func body(content: Content) -> some View {
        content
            .opacity(reduceMotion || appeared ? 1 : 0)
            .animation(reduceMotion ? nil : ReadingMotion.entrance, value: appeared)
            .onAppear { appeared = true }
    }
}

private struct ReadingMotionAccessibility: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.transaction { transaction in
            if reduceMotion {
                transaction.animation = nil
                transaction.disablesAnimations = true
            }
        }
    }
}

extension View {
    /// Apply before a destination's `.id` so each new destination fades once.
    /// No outgoing view is retained and no geometry is interpolated.
    func readingEntrance() -> some View { modifier(ReadingEntrance()) }

    /// Also suppresses implicit SwiftUI motion in native disclosure controls.
    func readingMotionAccessibility() -> some View { modifier(ReadingMotionAccessibility()) }
}
