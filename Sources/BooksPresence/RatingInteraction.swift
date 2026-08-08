import SwiftUI

struct QuarterStarRating: View {
    @Binding var rating: Double?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focused: Bool
    @State private var hovered: Double?
    @GestureState private var dragging = false
    private var displayed: Double? { hovered ?? rating }
    private var value: Double { rating ?? 0 }
    private var tracking: Bool { hovered != nil || dragging }
    private var activeStar: Int? {
        guard tracking, let displayed, displayed > 0 else { return nil }
        return min(4, Int(ceil(displayed)) - 1)
    }
    private var response: Animation? {
        reduceMotion ? nil : (tracking ? .easeOut(duration: 0.075) : .interpolatingSpring(stiffness: 380, damping: 30))
    }
    private let starWidth: CGFloat = 42
    private let gap: CGFloat = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: gap) {
                ForEach(0..<5, id: \.self) { index in
                    FractionalStar(fill: min(1, max(0, (displayed ?? 0) - Double(index))), size: 32)
                        .scaleEffect(!reduceMotion && activeStar == index ? (dragging ? 1.10 : 1.06) : 1)
                        .offset(y: !reduceMotion && activeStar == index ? -2 : 0)
                        .frame(width: starWidth, height: 44)
                }
            }
            .contentShape(Rectangle())
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(focused ? ReadingPalette.accent : .clear, lineWidth: 1.5))
            .onContinuousHover { phase in
                guard !dragging else { return }
                switch phase {
                case .active(let location): hovered = RatingSelection.value(at: location.x)
                case .ended: hovered = nil
                }
            }
            .gesture(DragGesture(minimumDistance: 0)
                .updating($dragging) { _, state, _ in state = true }
                .onChanged { gesture in
                    hovered = nil
                    rating = RatingSelection.value(at: gesture.location.x)
                }
                .onEnded { gesture in
                    rating = RatingSelection.value(at: gesture.location.x)
                    hovered = nil
                })
            .focusable().focused($focused)
            .onMoveCommand { direction in
                hovered = nil
                if direction == .left || direction == .down { rating = max(0, value - 0.25) }
                if direction == .right || direction == .up { rating = min(5, value + 0.25) }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Book rating")
            .accessibilityValue(RatingStars.description(for: rating))
            .accessibilityHint("Adjust in quarter-star steps. Zero is a rating; no rating is left blank.")
            .accessibilityAdjustableAction { direction in
                hovered = nil
                switch direction {
                case .increment: rating = min(5, value + 0.25)
                case .decrement: rating = max(0, value - 0.25)
                @unknown default: break
                }
            }
            .animation(response, value: displayed)
            .animation(response, value: tracking)
            .animation(response, value: dragging)
            .onChange(of: focused) { _ in hovered = nil }
            .onDisappear { hovered = nil }
            HStack(spacing: 8) {
                // Only a real rating shows a number, so zero stays distinct from no rating.
                if let displayed {
                    Text(displayed.formatted(.number.precision(.fractionLength(0...2))))
                        .font(ReadingType.numeral(20)).monospacedDigit()
                        .foregroundStyle(ReadingPalette.ink)
                        .accessibilityHidden(true)
                }
                Spacer(minLength: 0)
                Button("0") { hovered = nil; rating = 0 }
                    .accessibilityLabel("Rate zero stars")
                Button { hovered = nil; rating = max(0, value - 0.25) } label: { Image(systemName: "minus") }
                    .disabled(rating == nil || value <= 0).accessibilityLabel("Decrease rating by a quarter star")
                Button { hovered = nil; rating = min(5, value + 0.25) } label: { Image(systemName: "plus") }
                    .disabled(value >= 5).accessibilityLabel("Increase rating by a quarter star")
            }.controlSize(.small).buttonStyle(ReadingButtonStyle())
        }
        .help("Click or drag the stars. Fine-tune by a quarter.")
        .frame(width: 234)
        .readingMotionAccessibility()
    }
}

/// Star gaps belong to the star immediately before them; dragging outside the
/// rail clamps to the endpoints. A dedicated zero button keeps nil distinct.
enum RatingSelection {
    static func value(at x: CGFloat) -> Double {
        guard x.isFinite else { return 0 }
        if x <= 0 { return 0 }
        if x >= 234 { return 5 }
        let index = min(4, Int(x / 48))
        let within = min(42, max(0, x - CGFloat(index) * 48))
        return min(5, Double(index) + ceil(Double(within / 42) * 4) / 4)
    }
}

/// Read-only stars. The stars carry the value; VoiceOver still hears it spelled out.
struct RatingStars: View {
    let rating: Double?
    var size: CGFloat = 15

    var body: some View {
        HStack(spacing: size * 0.18) {
            ForEach(0..<5, id: \.self) { index in
                FractionalStar(fill: min(1, max(0, (rating ?? 0) - Double(index))), size: size)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Rating: \(Self.description(for: rating))")
        .help(Self.description(for: rating))
    }

    static func description(for rating: Double?) -> String {
        guard let rating else { return "No rating yet" }
        let hundredths = Int((rating * 100).rounded())
        if hundredths % 100 == 0 { return "\(hundredths / 100) of 5" }
        return "\(hundredths / 100).\(String(format: "%02d", hundredths % 100)) of 5"
    }
}

private struct FractionalStar: View, Animatable {
    var fill: Double
    var size: CGFloat = 18
    var animatableData: Double { get { fill } set { fill = newValue } }

    var body: some View {
        let round = StrokeStyle(lineWidth: size * 0.1, lineJoin: .round)
        ZStack {
            // Empty star: a soft, rounded track.
            StarShape().fill(ReadingPalette.track)
            StarShape().stroke(ReadingPalette.track, style: round)
            // Filled portion: gold with a gentle top highlight and a crisp edge.
            ZStack {
                StarShape().fill(ReadingPalette.star)
                StarShape().stroke(ReadingPalette.star, style: round)
                StarShape().fill(LinearGradient(colors: [.white.opacity(0.28), .clear], startPoint: .top, endPoint: .center))
                StarShape().stroke(ReadingPalette.starEdge, style: StrokeStyle(lineWidth: max(0.75, size * 0.045), lineJoin: .round))
            }
            .mask(alignment: .leading) {
                GeometryReader { proxy in
                    // Spring interpolation may briefly pass an endpoint.
                    Rectangle().frame(width: proxy.size.width * min(1, max(0, fill)))
                }
            }
        }
        .padding(size * 0.05)
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// A five-point star with a slightly fuller body than the SF symbol; rounded
/// strokes soften its tips.
private struct StarShape: Shape {
    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY + rect.height * 0.04)
        let outer = min(rect.width, rect.height) / 2
        let inner = outer * 0.47
        var path = Path()
        for index in 0..<10 {
            let radius = index.isMultiple(of: 2) ? outer : inner
            let angle = (Double(index) * 36 - 90) * .pi / 180
            let point = CGPoint(x: center.x + CGFloat(cos(angle)) * radius, y: center.y + CGFloat(sin(angle)) * radius)
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }
}
