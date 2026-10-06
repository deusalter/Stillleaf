import SwiftUI

/// Use only in the pending completion prompt. The owner consumes the saved
/// completion event before returning true; remounting a view cannot replay it.
struct CompletionCelebrationBadge: View {
    var forceReducedMotion = false
    let eventID: String
    let claimCelebration: @MainActor () -> Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var progress: CGFloat = 1
    private var motionDisabled: Bool { reduceMotion || forceReducedMotion }

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
                    ForEach(0..<6, id: \.self) { index in
                        Capsule()
                            .fill(index.isMultiple(of: 2) ? ReadingPalette.accent : ReadingPalette.warning)
                            .frame(width: 2.5, height: 5)
                            .offset(y: -15 - 12 * progress)
                            .rotationEffect(.degrees(Double(index) * 60))
                            .opacity(Double(1 - progress) * 0.65)
                    }
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .readingMotionAccessibility()
            .task(id: eventID) { @MainActor in
                // Consume even with reduced motion: toggling the preference or
                // returning to Today should not re-celebrate the same completion.
                guard claimCelebration(), !motionDisabled else { progress = 1; return }
                progress = 0
                do { try await Task.sleep(nanoseconds: 30_000_000) }
                catch { progress = 1; return }
                guard !Task.isCancelled, !motionDisabled else { progress = 1; return }
                withAnimation(.easeOut(duration: 0.7)) { progress = 1 }
            }
            .onChange(of: motionDisabled) { reduced in
                if reduced { progress = 1 }
            }
            .onDisappear { progress = 1 }
    }
}
