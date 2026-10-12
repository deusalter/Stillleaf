import SwiftUI

/// The running session time, which changes every second while a book is open.
@MainActor
final class LiveSession: ObservableObject {
    @Published var sessionSeconds: Double = 0
}

/// Shows the running session time. It observes only `AppModel.live`, so the once-a-second change
/// re-renders this label and nothing around it.
struct LiveSessionTime<Content: View>: View {
    @ObservedObject var live: LiveSession
    @ViewBuilder let content: (String) -> Content

    var body: some View { content(ReadingFormat.duration(live.sessionSeconds)) }
}
