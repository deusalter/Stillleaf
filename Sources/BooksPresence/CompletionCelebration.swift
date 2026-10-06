import SwiftUI

/// Use only in the pending completion prompt. The owner consumes the saved
/// completion event before returning true; remounting a view cannot replay it.
struct CompletionCelebrationBadge: View {
    var forceReducedMotion = false
    let eventID: String
    let claimCelebration: @MainActor () -> Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var progress: CGFloat = 1
    @State private var burstStart: Date?
    @ObservedObject private var theme = ThemeStore.shared
    private var motionDisabled: Bool { reduceMotion || forceReducedMotion }
    private var presentation: VineBurst.Presentation { Self.burstPresentation(theme: theme, reduceMotion: motionDisabled) }

    /// The burst follows the effective garden mode: Still under Reduce Motion or
    /// Low Power, nothing when the garden is off.
    static func burstPresentation(theme: ThemeStore, reduceMotion: Bool) -> VineBurst.Presentation {
        VineBurst.presentation(for: theme.effectiveGardenMode(reduceMotion: reduceMotion))
    }

    var body: some View {
        Image(systemName: "checkmark.circle.fill")
            .font(.title2)
            .foregroundStyle(ReadingPalette.accent)
            .background(Circle().fill(ReadingPalette.canvas).padding(2))
            .scaleEffect(motionDisabled ? 1 : 0.88 + 0.12 * progress)
            .background {
                if !motionDisabled {
                    Circle()
                        .stroke(ReadingPalette.accent.opacity(0.35 * (1 - progress)), lineWidth: 1.5)
                        .frame(width: 28, height: 28)
                        .scaleEffect(1 + progress * 1.15)
                }
                // Vines burst outward around the badge, flower and fade.
                VineBurst(start: burstStart, presentation: presentation)
                    .frame(width: 220, height: 140)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .readingMotionAccessibility()
            .task(id: eventID) { @MainActor in
                // Consume even with reduced motion: toggling the preference or
                // returning to Today should not re-celebrate the same completion.
                guard claimCelebration() else { progress = 1; return }
                let burst = presentation
                if !motionDisabled {
                    progress = 0
                    do { try await Task.sleep(nanoseconds: 30_000_000) }
                    catch { progress = 1; return }
                    guard !Task.isCancelled, !motionDisabled else { progress = 1; return }
                    withAnimation(.easeOut(duration: 0.7)) { progress = 1 }
                } else {
                    progress = 1
                }
                guard burst != .none else { return }
                burstStart = Date()
                // End the burst once it has faded, so nothing runs afterwards.
                try? await Task.sleep(nanoseconds: UInt64((VineBurst.duration(for: burst) + 0.1) * 1_000_000_000))
                burstStart = nil
            }
            .onChange(of: motionDisabled) { reduced in
                if reduced { progress = 1 }
            }
            .onDisappear { progress = 1; burstStart = nil }
    }
}
