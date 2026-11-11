import SwiftUI
import BooksCore

/// The controls over the page. A tap in the middle of the page shows them and another hides them, as in
/// Apple Books; turning a page puts them away. Nothing here covers the text while reading.
struct ReaderControls: View {
    @ObservedObject var chrome: ReaderChrome
    @EnvironmentObject private var journal: Journal
    let title: String
    @State private var bookmarkTaps = 0

    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                if chrome.controlsVisible {
                    HStack(spacing: 12) {
                        TodayBadge()
                        Spacer(minLength: 0)
                        Button { chrome.close?() } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 16, weight: .semibold))
                                .frame(width: 44, height: 44)
                                .background(.regularMaterial, in: Circle())
                        }
                        .accessibilityLabel("Close Book")
                        .accessibilityHint(title)
                    }
                    .transition(.opacity)
                    Spacer(minLength: 0)
                    // The renderer keeps a band under the text for the page number (50 pt in the hand, 68 pt on
                    // wider pages). The toolbar sits inside it on the trailing side and the page number moves to
                    // the leading side, so showing the controls never covers a line.
                    HStack(spacing: 0) {
                        Spacer(minLength: 0)
                        // Six buttons on a narrow phone would reach the page number: each gives up a little width.
                        toolbar(buttonWidth: chrome.pinned ? (proxy.size.width < 400 ? 40 : 44) : 48)
                    }
                    // On a device with a home indicator both drop a little into the room under the band, so the
                    // bar sits between the text and the screen's edge instead of against the last line.
                    .padding(.bottom, (proxy.size.width >= 700 ? 10 : 1) - ReaderChrome.footerDrop(bottomInset: proxy.safeAreaInsets.bottom))
                    .transition(.opacity)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .foregroundStyle(.primary)
        .environment(\.colorScheme, chrome.pageIsDark ? .dark : .light)
        .animation(.easeOut(duration: 0.16), value: chrome.controlsVisible)
        .allowsHitTesting(chrome.controlsVisible)
    }

    /// Contents, search, appearance and bookmark, one tap each, beside the page number.
    private func toolbar(buttonWidth: CGFloat) -> some View {
        HStack(spacing: 4) {
            if chrome.pinned {
                // VoiceOver and Switch Control cannot tap a page edge: they get page buttons.
                tool("chevron.left", "Previous Page", buttonWidth) { chrome.turn(forward: false) }
                tool("chevron.right", "Next Page", buttonWidth) { chrome.turn(forward: true) }
            }
            tool("list.bullet", "Contents", buttonWidth) { chrome.open(.contents) }
            tool("magnifyingglass", "Search Book", buttonWidth) { chrome.open(.search) }
            tool("textformat.size", "Themes and Settings", buttonWidth) { chrome.open(.appearance) }
            tool(chrome.bookmarked ? "bookmark.fill" : "bookmark", chrome.bookmarked ? "Remove Bookmark" : "Bookmark This Page", buttonWidth) {
                bookmarkTaps += 1
                chrome.toggleBookmark()
            }
        }
        // A tap on the bookmark is felt; a page that merely has one is not.
        .sensoryFeedback(.impact(weight: .light), trigger: bookmarkTaps)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
    }

    private func tool(_ symbol: String, _ label: String, _ width: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .medium))
                .frame(width: width, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(label)
    }
}

/// Today's goal and streak, kept in view while the controls are up: reading here is what moves them.
struct TodayBadge: View {
    @EnvironmentObject private var journal: Journal

    var body: some View {
        let progress = journal.todayGoal
        let streak = journal.history.dailyGoalStreak.current
        HStack(spacing: 8) {
            GoalRing(fraction: progress.fraction, lineWidth: 3.5).frame(width: 18, height: 18)
            Text(ReadingText.goalSummary(progress)).monospacedDigit()
            if streak > 0 {
                Label("\(streak)", systemImage: "flame.fill")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(Color.accentColor)
                    .monospacedDigit()
            }
        }
        .font(.footnote.weight(.semibold))
        .padding(.horizontal, 14)
        .frame(height: 44)
        .background(.regularMaterial, in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Today")
        .accessibilityValue(ReadingText.goalSummary(progress) + (streak > 0 ? ", \(streak)-day streak" : ""))
    }
}

extension Color {
    /// A colour from the renderer's `#rrggbb` text.
    init?(hex: String?) {
        guard let rgb = hex.flatMap(ReaderChrome.rgb) else { return nil }
        self.init(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }
}
