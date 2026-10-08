import SwiftUI
import AppKit
import BooksCore

enum OnboardingStep: Int, CaseIterable, Identifiable {
    case welcome, tour, goal, access, appearance, ready
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .welcome: return "Welcome"
        case .tour: return "How it works"
        case .goal: return "Daily goal"
        case .access: return "Read in Stillleaf"
        case .appearance: return "Appearance"
        case .ready: return "Ready"
        }
    }
}

/// Where the reader goes when the welcome tour ends.
enum OnboardingDestination { case menuBar, dashboard, importBooks }

/// Goal choices offered by the tour, kept apart from the main-actor flow so any view can read them.
enum OnboardingGoalLimits {
    static let pagePresets = [10, 20, 30, 50]
    static let minutePresets = [15, 30, 45, 60]
    static let pageRange = ReadingGoalLimits.dailyPages
    static let minuteRange = ReadingGoalLimits.dailyMinutes
    static let annualRange = ReadingGoalLimits.annualBooks
    static func clamp(_ value: Int, to range: ClosedRange<Int>) -> Int { min(max(value, range.lowerBound), range.upperBound) }
}

/// The tour's place and goal drafts live outside the view, so a theme change can
/// re-key every rendered colour without losing either.
@MainActor
final class OnboardingFlow: ObservableObject {
    @Published private(set) var step: OnboardingStep
    /// Direction of the last move; outgoing and incoming steps slide the same way.
    @Published var forward = true
    /// Staggered entrances play once per step, never after a theme change or on return.
    @Published private(set) var animateReveal = true
    @Published var unit: DailyGoalUnit
    @Published var pages: Int
    @Published var minutes: Int
    @Published var annualEnabled: Bool
    @Published var annualBooks: Int
    private var revealed: Set<OnboardingStep> = []

    init(model: AppModel, step: OnboardingStep = .welcome) {
        self.step = step
        unit = model.dailyGoalUnit
        pages = OnboardingGoalLimits.clamp(Int(model.pageGoal.rounded()), to: OnboardingGoalLimits.pageRange)
        minutes = OnboardingGoalLimits.clamp(Int(model.goalMinutes.rounded()), to: OnboardingGoalLimits.minuteRange)
        annualEnabled = model.annualBookGoal != nil
        annualBooks = OnboardingGoalLimits.clamp(model.annualBookGoal ?? 12, to: OnboardingGoalLimits.annualRange)
        revealed = [step]
    }

    var goalValue: Int { unit == .pages ? pages : minutes }
    var presets: [Int] { unit == .pages ? OnboardingGoalLimits.pagePresets : OnboardingGoalLimits.minutePresets }
    var goalSummary: String {
        let noun = unit == .pages ? "page" : "minute"
        return "\(goalValue) \(noun)\(goalValue == 1 ? "" : "s") a day"
    }

    func setGoal(_ value: Int) {
        if unit == .pages { pages = OnboardingGoalLimits.clamp(value, to: OnboardingGoalLimits.pageRange) }
        else { minutes = OnboardingGoalLimits.clamp(value, to: OnboardingGoalLimits.minuteRange) }
    }

    func moveTo(_ target: OnboardingStep) {
        animateReveal = !revealed.contains(target)
        revealed.insert(target)
        step = target
    }

    /// A theme swap re-keys the content; it should appear in place, not replay.
    func holdReveal() { animateReveal = false }
}

private struct OnboardingRevealAnimatedKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    fileprivate var onboardingRevealAnimated: Bool {
        get { self[OnboardingRevealAnimatedKey.self] }
        set { self[OnboardingRevealAnimatedKey.self] = newValue }
    }
}

enum OnboardingMotion {
    static let step = Animation.spring(response: 0.52, dampingFraction: 0.88)
    static let reveal = Animation.spring(response: 0.6, dampingFraction: 0.86)
    static let select = Animation.spring(response: 0.34, dampingFraction: 0.82)
}

/// First-launch welcome: reading in Stillleaf, a daily goal, optional Apple Books setup,
/// a theme, and where the app lives afterwards. Every step is optional.
@MainActor
struct OnboardingView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var flow: OnboardingFlow
    let finish: (OnboardingDestination) -> Void
    var appleBooksSetupExpanded = false
    @ObservedObject private var theme = ThemeStore.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var navigating = false
    /// Card frames for the garden to frost; a class so it never re-renders the steps.
    @State private var frost = FrostRegions()

    static let size = NSSize(width: 780, height: 600)

    /// How much of the garden a step shows: it grows with each one and is complete at the end.
    static func gardenGrowth(for step: OnboardingStep) -> Double {
        Double(step.rawValue + 1) / Double(OnboardingStep.allCases.count)
    }

    var body: some View {
        ZStack {
            OnboardingBackdrop(step: flow.step, frost: frost)
            VStack(spacing: 0) {
                topBar
                ZStack {
                    stepContent
                        .environment(\.onboardingRevealAnimated, flow.animateReveal && !reduceMotion)
                        .id(Self.contentKey(step: flow.step, revision: theme.revision))
                        .transition(stepTransition)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                footer
            }
            // Re-keying the chrome re-resolves theme colours; the flow keeps the reader's place.
            // The garden stays outside it so a theme change recolours it without regrowing.
            .id(theme.revision)
        }
        .coordinateSpace(name: GardenCanvas.space)
        .environment(\.gardenBackdrop, theme.gardenMode != .off)
        .onPreferenceChange(GlassRegionsKey.self) { frost.rects = $0 }
        .frame(width: Self.size.width, height: Self.size.height)
        .background(ReadingPalette.canvas)
        .foregroundStyle(ReadingPalette.ink)
        .tint(ReadingPalette.accent)
        .toggleStyle(.switch)
        .buttonStyle(ReadingButtonStyle())
        .ignoresSafeArea()
        .readingMotionAccessibility()
    }

    static func contentKey(step: OnboardingStep, revision: Int) -> String { "\(step.rawValue)-\(revision)" }

    private var topBar: some View {
        ZStack {
            OnboardingProgress(current: flow.step) { target in
                if target.rawValue < flow.step.rawValue { navigate(to: target) }
            }
            HStack {
                Spacer()
                if flow.step != .ready {
                    Button("Skip") { navigate(to: .ready) }
                        .buttonStyle(.plain)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(ReadingPalette.secondaryInk)
                        .help("Skip to the end. Everything here is also in Settings.")
                        .accessibilityLabel("Skip setup")
                }
            }
        }
        .padding(.horizontal, 24)
        .frame(height: 52)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button {
                if let previous = OnboardingStep(rawValue: flow.step.rawValue - 1) { navigate(to: previous) }
            } label: {
                Label("Back", systemImage: "chevron.left").labelStyle(.titleAndIcon)
            }
            .opacity(flow.step == .welcome ? 0 : 1)
            .disabled(flow.step == .welcome)
            .accessibilityHidden(flow.step == .welcome)
            Spacer()
            footerHint
            Spacer()
            Button(action: primaryAction) {
                HStack(spacing: 7) {
                    Text(primaryTitle)
                    Image(systemName: flow.step == .ready ? "arrow.up.right" : "arrow.right")
                        .font(.system(size: 11, weight: .bold))
                }
                .frame(minWidth: 118)
            }
            .buttonStyle(ReadingButtonStyle(emphasis: .primary))
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 24).padding(.top, 8)
    }

    @ViewBuilder private var footerHint: some View {
        switch flow.step {
        case .goal:
            Text("Changes apply from today. Edit any time in Settings.")
                .font(.caption).foregroundStyle(ReadingPalette.secondaryInk)
        case .access:
            Text("Stillleaf records reading without Accessibility access.")
                .font(.caption).foregroundStyle(ReadingPalette.secondaryInk)
        default:
            EmptyView()
        }
    }

    private var primaryTitle: String {
        switch flow.step {
        case .welcome: return "Get started"
        case .ready: return "Import EPUBs…"
        default: return "Continue"
        }
    }

    private func primaryAction() {
        switch flow.step {
        case .ready:
            finish(.importBooks)
        default:
            if let next = OnboardingStep(rawValue: flow.step.rawValue + 1) { navigate(to: next) }
        }
    }

    private func navigate(to target: OnboardingStep) {
        guard target != flow.step, !navigating else { return }
        let forward = target.rawValue > flow.step.rawValue
        // Leaving the goal step forwards (Continue or Skip) keeps the chosen goal.
        if flow.step == .goal && forward {
            model.applyOnboardingGoals(unit: flow.unit, pages: flow.pages, minutes: flow.minutes,
                                       annualBooks: flow.annualEnabled ? flow.annualBooks : nil)
        }
        // Set the direction a frame early, so the outgoing step renders with the edge it leaves by.
        flow.forward = forward
        navigating = true
        let animation = reduceMotion ? Animation.easeOut(duration: 0.15) : OnboardingMotion.step
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 16_000_000)
            withAnimation(animation) { flow.moveTo(target) }
            navigating = false
        }
    }

    private var stepTransition: AnyTransition {
        if reduceMotion { return .opacity }
        let distance: CGFloat = 56
        let entering = StepMotion(offset: flow.forward ? distance : -distance, blur: 8, opacity: 0, scale: 0.985)
        let leaving = StepMotion(offset: flow.forward ? -distance : distance, blur: 8, opacity: 0, scale: 0.985)
        return .asymmetric(insertion: .modifier(active: entering, identity: StepMotion.identity),
                           removal: .modifier(active: leaving, identity: StepMotion.identity))
    }

    @ViewBuilder private var stepContent: some View {
        switch flow.step {
        case .welcome: OnboardingWelcomeStep()
        case .tour: OnboardingTourStep()
        case .goal: OnboardingGoalStep(flow: flow)
        case .access: OnboardingAccessStep(model: model, appleBooksExpanded: appleBooksSetupExpanded)
        case .appearance: OnboardingAppearanceStep(flow: flow, store: theme)
        case .ready: OnboardingReadyStep(model: model, theme: theme, finish: finish)
        }
    }
}

private struct StepMotion: ViewModifier {
    var offset: CGFloat
    var blur: CGFloat
    var opacity: Double
    var scale: CGFloat
    static let identity = StepMotion(offset: 0, blur: 0, opacity: 1, scale: 1)
    func body(content: Content) -> some View {
        content.offset(x: offset).blur(radius: blur).opacity(opacity).scaleEffect(scale)
    }
}

/// Rises into place in order when a step first appears.
private struct OnboardingReveal: ViewModifier {
    let order: Int
    @Environment(\.onboardingRevealAnimated) private var animated
    @State private var shown = false

    func body(content: Content) -> some View {
        let visible = shown || !animated
        content
            .opacity(visible ? 1 : 0)
            .offset(y: visible ? 0 : 16)
            .blur(radius: visible ? 0 : 5)
            .onAppear {
                guard animated, !shown else { return }
                withAnimation(OnboardingMotion.reveal.delay(0.1 + Double(order) * 0.07)) { shown = true }
            }
    }
}

extension View {
    fileprivate func onboardingReveal(_ order: Int) -> some View { modifier(OnboardingReveal(order: order)) }

    /// A glass surface over the garden: one per step, holding that step's choices.
    fileprivate func onboardingGlass(cornerRadius: CGFloat = 18) -> some View {
        glassSurface(cornerRadius: cornerRadius)
    }
}

private struct OnboardingTitle: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(spacing: 10) {
            Text(title)
                .font(.system(size: 34, weight: .regular, design: .serif)).tracking(-0.5)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
                .onboardingReveal(0)
            Text(subtitle)
                .font(.system(size: 14)).foregroundStyle(ReadingPalette.secondaryInk)
                .multilineTextAlignment(.center).lineSpacing(2)
                .frame(maxWidth: 500)
                .fixedSize(horizontal: false, vertical: true)
                .onboardingReveal(1)
        }
    }
}

// MARK: - Chrome

/// The garden grows a little more with every step, framing the tour's content
/// without crossing it; the last step shows it complete.
private struct OnboardingBackdrop: View {
    let step: OnboardingStep
    let frost: FrostRegions
    @ObservedObject private var theme = ThemeStore.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The centred column where headings, copy and cards sit.
    static let content = CGRect(x: 120, y: 44, width: 540, height: 470)

    var body: some View {
        GardenCanvas(layout: GardenLayout(seed: GardenSeed.daily("onboarding", day: "tour"), roots: 9, pollen: false,
                                          avoid: [Self.content], vigor: 3, growth: OnboardingView.gardenGrowth(for: step)),
                     mode: theme.effectiveGardenMode(reduceMotion: reduceMotion), frost: frost)
            .overlay(
                LinearGradient(colors: [ReadingPalette.canvas.opacity(0), ReadingPalette.canvas.opacity(0.85)],
                               startPoint: .center, endPoint: .bottom)
            )
            .background(ReadingPalette.canvas)
            .ignoresSafeArea()
            .accessibilityHidden(true)
            .allowsHitTesting(false)
    }
}

private struct OnboardingProgress: View {
    let current: OnboardingStep
    let select: (OnboardingStep) -> Void
    @Namespace private var indicator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 6) {
            ForEach(OnboardingStep.allCases) { step in
                let isCurrent = step == current
                let done = step.rawValue < current.rawValue
                ZStack {
                    Capsule().fill(done ? ReadingPalette.accent.opacity(0.45) : ReadingPalette.ink.opacity(0.14))
                        .frame(width: 7, height: 7)
                    if isCurrent {
                        Capsule().fill(ReadingPalette.accent)
                            .matchedGeometryEffect(id: "current", in: indicator)
                            .frame(width: 26, height: 7)
                    }
                }
                .frame(width: isCurrent ? 26 : 7, height: 7)
                .contentShape(Rectangle().inset(by: -6))
                .onTapGesture { select(step) }
                .help(step.title)
            }
        }
        .animation(reduceMotion ? nil : OnboardingMotion.select, value: current)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(current.rawValue + 1) of \(OnboardingStep.allCases.count)")
        .accessibilityValue(current.title)
    }
}

// MARK: - Welcome

private struct OnboardingWelcomeStep: View {
    var body: some View {
        VStack(spacing: 26) {
            Spacer(minLength: 0)
            OnboardingMark().onboardingReveal(0)
            VStack(spacing: 12) {
                Text("Welcome to Stillleaf")
                    .font(.system(size: 42, weight: .regular, design: .serif)).tracking(-0.8)
                    .accessibilityAddTraits(.isHeader)
                    .onboardingReveal(1)
                Text("Import EPUBs and read in Stillleaf. Your progress and active reading time\nare recorded automatically, with your place saved for next time.")
                    .font(.system(size: 15)).foregroundStyle(ReadingPalette.secondaryInk)
                    .multilineTextAlignment(.center).lineSpacing(3)
                    .onboardingReveal(2)
            }
            HStack(spacing: 8) {
                Image(systemName: "lock.fill").font(.system(size: 10, weight: .semibold))
                Text("Your reading history stays on this Mac. No account, no cloud.")
            }
            .font(.caption.weight(.medium)).foregroundStyle(ReadingPalette.secondaryInk)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .onboardingGlass(cornerRadius: 20)
            .accessibilityElement(children: .combine)
            .onboardingReveal(3)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 40)
    }
}

/// The leaf mark: a soft bloom of rings around a breathing accent disc.
private struct OnboardingMark: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathe = false

    var body: some View {
        ZStack {
            ForEach(0..<3, id: \.self) { ring in
                Circle()
                    .strokeBorder(ReadingPalette.accent.opacity(0.22 - Double(ring) * 0.06), lineWidth: 1)
                    .frame(width: 104 + CGFloat(ring) * 36, height: 104 + CGFloat(ring) * 36)
                    .scaleEffect(breathe ? 1.04 + CGFloat(ring) * 0.02 : 1)
            }
            Circle()
                .fill(LinearGradient(colors: [ReadingPalette.accent, ReadingPalette.accent.opacity(0.72)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 88, height: 88)
                .shadow(color: ReadingPalette.accent.opacity(0.35), radius: 22, x: 0, y: 10)
                .scaleEffect(breathe ? 1.03 : 1)
            PageleafMark()
                .frame(width: 50, height: 50)
                .foregroundStyle(ReadingPalette.onAccent)
                .rotationEffect(.degrees(breathe ? -4 : 3))
        }
        .frame(width: 180, height: 180)
        .accessibilityHidden(true)
        .onAppear {
            guard !reduceMotion else { return }
            // One slow settle rather than a loop that keeps the window redrawing.
            withAnimation(.easeInOut(duration: 3.2)) { breathe = true }
        }
    }
}

// MARK: - Tour

private struct OnboardingTourStep: View {
    private let features: [(symbol: String, title: String, detail: String)] = [
        ("text.book.closed", "Read inside Stillleaf",
         "Import DRM-free EPUBs. Stillleaf records page coverage and active reading time, and saves your place without extra permissions."),
        ("book.pages", "Apple Books, optionally",
         "Prefer Apple Books? Enable Accessibility access in Settings to track its page turns and reading time."),
        ("flame", "Goals and streaks",
         "Set a daily goal in pages or minutes, add an optional yearly books goal, and watch your streak grow."),
        ("calendar", "A calendar of reading",
         "See each day, week, month and year. Rate finished books and keep private reviews.")
    ]

    var body: some View {
        VStack(spacing: 28) {
            OnboardingTitle(title: "Your reading, quietly kept",
                            subtitle: "Stillleaf sits in your menu bar and does the bookkeeping, so you can simply read.")
            // One surface holds all four features; they are grouped by spacing, not a card each.
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 28), GridItem(.flexible(), spacing: 28)], spacing: 26) {
                ForEach(Array(features.enumerated()), id: \.offset) { index, feature in
                    OnboardingFeatureCard(symbol: feature.symbol, title: feature.title, detail: feature.detail)
                        .onboardingReveal(index + 2)
                }
            }
            .padding(26)
            .frame(maxWidth: 640)
            .onboardingGlass(cornerRadius: 22)
            Text("Reading time is recorded while tracking is active. You can edit saved sessions whenever needed.")
                .font(.caption).foregroundStyle(ReadingPalette.secondaryInk)
                .onboardingReveal(6)
        }
        .padding(.horizontal, 40).padding(.top, 8)
        .frame(maxHeight: .infinity)
    }
}

private struct OnboardingFeatureCard: View {
    let symbol: String
    let title: String
    let detail: String
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(ReadingPalette.accent)
                .frame(width: 40, height: 40)
                .background(ReadingPalette.accent.opacity(hovering ? 0.18 : 0.11), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(ReadingPalette.secondaryInk)
                    .lineSpacing(1.5)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 84, alignment: .topLeading)
        .animation(reduceMotion ? nil : ReadingMotion.hover, value: hovering)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Goal

private struct OnboardingGoalStep: View {
    @ObservedObject var flow: OnboardingFlow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var presetHighlight
    @State private var countsDown = false

    var body: some View {
        VStack(spacing: 20) {
            OnboardingTitle(title: "Pick a daily rhythm",
                            subtitle: "Small and steady beats big and abandoned. Choose what a good reading day looks like.")
            ReadingSegmentedControl(label: "Daily goal unit", options: [DailyGoalUnit.pages, .minutes],
                                    selection: unitBinding, title: { $0 == .pages ? "Pages" : "Minutes" },
                                    preservesWalkthroughTreatment: true)
                .frame(width: 260)
                .onboardingReveal(2)
            dial.onboardingReveal(3)
            presets.onboardingReveal(4)
            annual.onboardingReveal(5)
        }
        .padding(.horizontal, 40).padding(.top, 4)
        .frame(maxHeight: .infinity)
    }

    private var unitBinding: Binding<DailyGoalUnit> {
        Binding(get: { flow.unit }, set: { unit in
            withAnimation(reduceMotion ? nil : OnboardingMotion.select) { flow.unit = unit }
        })
    }

    private var arcProgress: Double {
        let ceiling = flow.unit == .pages ? 60.0 : 90.0
        return min(1, Double(flow.goalValue) / ceiling)
    }

    private var dial: some View {
        HStack(spacing: 22) {
            stepButton(symbol: "minus", delta: -1, label: "Decrease goal")
            ZStack {
                DottedReadingArc(progress: arcProgress)
                    .frame(width: 230, height: 128)
                    .animation(reduceMotion ? nil : OnboardingMotion.select, value: arcProgress)
                VStack(spacing: 0) {
                    Text("\(flow.goalValue)")
                        .font(.system(size: 52, weight: .regular, design: .serif)).monospacedDigit()
                        .contentTransition(.numericText(countsDown: countsDown))
                    Text(flow.unit == .pages ? "pages a day" : "minutes a day")
                        .font(.caption.weight(.medium)).foregroundStyle(ReadingPalette.secondaryInk)
                }
                .offset(y: 14)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Daily goal")
            .accessibilityValue(flow.goalSummary)
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: adjust(by: 1)
                case .decrement: adjust(by: -1)
                @unknown default: break
                }
            }
            stepButton(symbol: "plus", delta: 1, label: "Increase goal")
        }
    }

    private func stepButton(symbol: String, delta: Int, label: String) -> some View {
        Button { adjust(by: delta) } label: {
            Image(systemName: symbol).font(.system(size: 13, weight: .semibold)).frame(width: 18, height: 18)
        }
        .buttonStyle(ReadingButtonStyle(iconOnly: true))
        .accessibilityLabel(label)
    }

    /// Moves to the neighbouring multiple of five, never below one.
    private func adjust(by delta: Int) {
        let current = flow.goalValue
        choose(delta > 0 ? (current / 5 + 1) * 5 : max(1, ((current - 1) / 5) * 5))
    }

    private func choose(_ value: Int) {
        countsDown = value < flow.goalValue
        withAnimation(reduceMotion ? nil : OnboardingMotion.select) { flow.setGoal(value) }
    }

    private var presets: some View {
        HStack(spacing: 8) {
            ForEach(Array(flow.presets.enumerated()), id: \.element) { index, value in
                let selected = flow.goalValue == value
                Button { choose(value) } label: {
                    VStack(spacing: 2) {
                        Text("\(value)").font(.system(size: 15, weight: .semibold)).monospacedDigit()
                        Text(["Gentle", "Steady", "Keen", "Devoted"][index])
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(selected ? ReadingPalette.onAccent.opacity(0.85) : ReadingPalette.secondaryInk)
                    }
                    .foregroundStyle(selected ? ReadingPalette.onAccent : ReadingPalette.ink)
                    .frame(width: 78, height: 46)
                    .background {
                        if selected {
                            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(ReadingPalette.accent)
                                .matchedGeometryEffect(id: "preset", in: presetHighlight)
                                .shadow(color: ReadingPalette.accent.opacity(0.3), radius: 8, x: 0, y: 4)
                        } else {
                            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(ReadingPalette.surface.opacity(0.7))
                        }
                    }
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(selected ? Color.clear : ReadingPalette.border, lineWidth: 1))
                    .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(value) \(flow.unit == .pages ? "pages" : "minutes")")
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }

    private var annual: some View {
        HStack(spacing: 14) {
            Image(systemName: "books.vertical").foregroundStyle(ReadingPalette.accent).frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text("Yearly books goal").font(.system(size: 13, weight: .semibold))
                Text("Optional. Counts books you finish this year.").font(.caption).foregroundStyle(ReadingPalette.secondaryInk)
            }
            Spacer(minLength: 8)
            if flow.annualEnabled {
                HStack(spacing: 8) {
                    Text("\(flow.annualBooks) \(flow.annualBooks == 1 ? "book" : "books")").font(.system(size: 13, weight: .medium)).monospacedDigit()
                        .contentTransition(.numericText())
                    Stepper("Yearly books goal", value: $flow.annualBooks, in: OnboardingGoalLimits.annualRange)
                        .labelsHidden()
                }
                .transition(.opacity.combined(with: .move(edge: .trailing)))
            }
            Toggle("Set a yearly books goal", isOn: annualBinding).labelsHidden()
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .frame(width: 480)
        .onboardingGlass(cornerRadius: 14)
    }

    private var annualBinding: Binding<Bool> {
        Binding(get: { flow.annualEnabled }, set: { enabled in
            withAnimation(reduceMotion ? nil : OnboardingMotion.select) { flow.annualEnabled = enabled }
        })
    }
}

// MARK: - Access

private struct OnboardingAccessStep: View {
    @ObservedObject var model: AppModel
    @State private var requested = false
    @State private var showingAppleBooks: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(model: AppModel, appleBooksExpanded: Bool = false) {
        self.model = model
        _showingAppleBooks = State(initialValue: appleBooksExpanded)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                OnboardingTitle(title: "Read inside Stillleaf",
                                subtitle: "Import a DRM-free EPUB and start reading. Stillleaf keeps your place and records page coverage and active reading time automatically.")
                // One surface holds the three choices, told apart by spacing and a faint rule.
                VStack(alignment: .leading, spacing: 18) {
                    Label("No Accessibility permission needed", systemImage: "book.pages")
                        .font(.callout.weight(.medium)).foregroundStyle(ReadingPalette.accent)
                        .onboardingReveal(2)
                    Hairline().opacity(0.6)
                    DisclosureGroup(isExpanded: $showingAppleBooks) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Accessibility access is required only to track reading in Apple Books. It lets Stillleaf read the open book’s title and page number, without reading its page text or other apps.")
                                .font(.caption).foregroundStyle(ReadingPalette.secondaryInk)
                                .fixedSize(horizontal: false, vertical: true)
                            statusCard
                        }.padding(.top, 12)
                    } label: {
                        Text("Optional Apple Books integration").font(.callout.weight(.medium))
                    }
                    .onboardingReveal(3)
                    Hairline().opacity(0.6)
                    loginRow.onboardingReveal(4)
                }
                .padding(20).frame(width: 560)
                .onboardingGlass()
            }
            .padding(.horizontal, 40).padding(.vertical, 12)
        }
        .task(id: showingAppleBooks) { @MainActor in
            guard showingAppleBooks else { return }
            // Poll only while the optional permission setup is disclosed.
            while !Task.isCancelled {
                withAnimation(reduceMotion ? nil : OnboardingMotion.reveal) { model.refreshAccessibilityStatus() }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private var granted: Bool { model.accessibilityGranted }

    private var statusCard: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle().fill(granted ? ReadingPalette.accent : ReadingPalette.accent.opacity(0.12))
                    .frame(width: 50, height: 50)
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(ReadingPalette.accent)
                    .opacity(granted ? 0 : 1)
                    .scaleEffect(granted ? 0.5 : 1)
                DrawnCheck()
                    .trim(from: 0, to: granted ? 1 : 0)
                    .stroke(ReadingPalette.onAccent, style: StrokeStyle(lineWidth: 3.2, lineCap: .round, lineJoin: .round))
                    .frame(width: 22, height: 22)
            }
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("Apple Books tracking access").font(.system(size: 15, weight: .semibold))
                Text(statusDetail)
                    .font(.caption).foregroundStyle(ReadingPalette.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if !granted {
                Button(requested ? "Open Settings" : "Allow access") {
                    if requested { model.openAccessibilitySettings() } else { requested = true; model.requestAccessibility() }
                }
                .buttonStyle(ReadingButtonStyle(emphasis: .primary))
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            } else {
                Label("Allowed", systemImage: "checkmark")
                    .font(.callout.weight(.semibold)).foregroundStyle(ReadingPalette.accent)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        .padding(14)
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(ReadingPalette.accent.opacity(granted ? 1 : 0), lineWidth: 1.5))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Accessibility access for Apple Books tracking")
        .accessibilityValue(granted ? "Allowed" : "Not allowed")
    }

    private var statusDetail: String {
        if granted { return "Allowed. Open a book in Apple Books and Stillleaf starts keeping time." }
        if requested { return "In System Settings → Privacy & Security → Accessibility, switch on Stillleaf. This page updates on its own; if it doesn’t, reopen Stillleaf." }
        return "Optional. Allow access to record page turns and time while reading in Apple Books."
    }

    private var loginRow: some View {
        HStack(spacing: 14) {
            Image(systemName: "power").foregroundStyle(ReadingPalette.accent).frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text("Open at login").font(.system(size: 13, weight: .semibold))
                Text("Keep Stillleaf ready in your menu bar after a restart.").font(.caption).foregroundStyle(ReadingPalette.secondaryInk)
            }
            Spacer()
            Toggle("Open at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                .labelsHidden()
        }
    }
}

private struct DrawnCheck: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + rect.width * 0.14, y: rect.minY + rect.height * 0.54))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.4, y: rect.minY + rect.height * 0.8))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.88, y: rect.minY + rect.height * 0.22))
        return path
    }
}

// MARK: - Appearance

private struct OnboardingAppearanceStep: View {
    @ObservedObject var flow: OnboardingFlow
    @ObservedObject var store: ThemeStore
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 22) {
            OnboardingTitle(title: "Make it yours",
                            subtitle: "Pick a palette. Every theme has light and dark versions and follows your Mac’s appearance.")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 16, alignment: .top), count: 3), spacing: 16) {
                ForEach(ReadingTheme.all) { theme in
                    ThemeSwatch(theme: theme, dark: colorScheme == .dark, selected: store.themeID == theme.id) {
                        flow.holdReveal()
                        store.select(theme: theme.id)
                    }
                }
            }
            .frame(width: 600)
            .onboardingReveal(2)
            HStack(spacing: 10) {
                Text("Accent").font(.system(size: 12, weight: .semibold)).foregroundStyle(ReadingPalette.secondaryInk)
                AccentDot(name: "Theme default",
                          color: ReadingPalette.fixed(store.theme.colors(dark: colorScheme == .dark, accent: nil).accent),
                          selected: store.accentID == nil, showsDefaultMark: true) {
                    flow.holdReveal(); store.select(accent: nil)
                }
                ForEach(AccentPreset.all) { accent in
                    AccentDot(name: accent.name, color: ReadingPalette.fixed(colorScheme == .dark ? accent.dark : accent.light),
                              selected: store.accentID == accent.id) {
                        flow.holdReveal(); store.select(accent: accent.id)
                    }
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            .onboardingGlass(cornerRadius: 22)
            .onboardingReveal(3)
        }
        .padding(.horizontal, 40).padding(.top, 4)
        .frame(maxHeight: .infinity)
    }
}

// MARK: - Ready

private struct OnboardingReadyStep: View {
    @ObservedObject var model: AppModel
    @ObservedObject var theme: ThemeStore
    let finish: (OnboardingDestination) -> Void
    @Environment(\.onboardingRevealAnimated) private var animated

    var body: some View {
        VStack(spacing: 22) {
            Spacer(minLength: 0)
            OnboardingBurst(play: animated)
            OnboardingTitle(title: "You’re all set",
                            subtitle: "Import an EPUB to begin reading. Stillleaf records your progress and active time, and saves your place. Your journal is always available from the menu bar.")
            // The menu bar and the summary of your choices share one surface.
            VStack(spacing: 14) {
                MenuBarHint().onboardingReveal(2)
                HStack(spacing: 18) {
                    summaryItem(symbol: "target", text: goalText)
                    summaryItem(symbol: "book.pages", text: "Stillleaf reader ready")
                    summaryItem(symbol: "paintpalette", text: theme.theme.name)
                }
                .onboardingReveal(3)
            }
            .padding(.horizontal, 22).padding(.vertical, 16)
            .onboardingGlass(cornerRadius: 18)
            HStack(spacing: 10) {
                Button { finish(.dashboard) } label: { Label("Open dashboard", systemImage: "rectangle.grid.2x2") }
            }
            .onboardingReveal(4)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 40)
    }

    private var goalText: String {
        let unit = model.dailyGoalUnit
        let value = Int((unit == .pages ? model.pageGoal : model.goalMinutes).rounded())
        return "\(value) \(unit == .pages ? "pages" : "minutes") a day"
    }

    private func summaryItem(symbol: String, text: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.system(size: 12, weight: .medium))
    }
}

/// A mock of the menu bar with Stillleaf's icon gently pulsing.
private struct MenuBarHint: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 16) {
            ForEach(["wifi", "battery.75", "magnifyingglass"], id: \.self) { symbol in
                Image(systemName: symbol).foregroundStyle(ReadingPalette.secondaryInk.opacity(0.7))
            }
            ZStack {
                Circle().stroke(ReadingPalette.accent.opacity(pulse ? 0 : 0.5), lineWidth: 2)
                    .frame(width: 30, height: 30)
                    .scaleEffect(pulse ? 1.5 : 0.8)
                RoundedRectangle(cornerRadius: 6, style: .continuous).fill(ReadingPalette.accent.opacity(0.16))
                    .frame(width: 28, height: 22)
                PageleafMark().frame(width: 18, height: 18).foregroundStyle(ReadingPalette.accent)
            }
            Text(Date.now.formatted(.dateTime.weekday(.abbreviated).hour().minute()))
                .foregroundStyle(ReadingPalette.secondaryInk)
        }
        .font(.system(size: 13, weight: .medium))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("The Stillleaf icon in the menu bar")
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeOut(duration: 1.6).repeatCount(3, autoreverses: false)) { pulse = true }
        }
    }
}

/// Leaves scatter once from the mark when the tour completes.
private struct OnboardingBurst: View {
    let play: Bool
    @State private var progress: CGFloat = 0
    @State private var settled = false

    var body: some View {
        ZStack {
            ForEach(0..<12, id: \.self) { index in
                let angle = Double(index) / 12 * 2 * Double.pi
                let travel = 26 + 58 * Double(progress)
                PageleafMark()
                    .frame(width: index.isMultiple(of: 3) ? 18 : 13, height: index.isMultiple(of: 3) ? 18 : 13)
                    .foregroundStyle(index.isMultiple(of: 2) ? ReadingPalette.accent : ReadingPalette.chart(1))
                    .rotationEffect(.radians(angle + Double(progress) * 1.6))
                    .offset(x: cos(angle) * travel, y: sin(angle) * travel)
                    .opacity(play ? Double(1 - progress) : 0)
            }
            Circle()
                .fill(LinearGradient(colors: [ReadingPalette.accent, ReadingPalette.accent.opacity(0.72)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 72, height: 72)
                .shadow(color: ReadingPalette.accent.opacity(0.35), radius: 18, x: 0, y: 8)
                .scaleEffect(settled || !play ? 1 : 0.6)
            Image(systemName: "checkmark")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(ReadingPalette.onAccent)
                .scaleEffect(settled || !play ? 1 : 0.3)
        }
        .frame(width: 150, height: 110)
        .accessibilityHidden(true)
        .onAppear {
            guard play else { return }
            withAnimation(.spring(response: 0.5, dampingFraction: 1).delay(0.1)) { settled = true }
            withAnimation(.easeOut(duration: 1.1).delay(0.16)) { progress = 1 }
        }
    }
}
