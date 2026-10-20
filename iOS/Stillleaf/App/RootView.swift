import SwiftUI

struct RootView: View {
    enum Tab: Hashable { case today, library, history, reviews, settings }

    @EnvironmentObject private var journal: Journal
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("welcomeCompleted") private var welcomeCompleted = false
    @State private var tab: Tab = .today
    @State private var reading: Edition?

    var body: some View {
        TabView(selection: $tab) {
            TodayView(showLibrary: { tab = .library })
                .tabItem { Label("Today", systemImage: "leaf") }.tag(Tab.today)
            LibraryView()
                .tabItem { Label("Library", systemImage: "books.vertical") }.tag(Tab.library)
            HistoryView()
                .tabItem { Label("History", systemImage: "calendar") }.tag(Tab.history)
            ReviewsView()
                .tabItem { Label("Reviews", systemImage: "text.quote") }.tag(Tab.reviews)
            SettingsView(showWelcome: { welcomeCompleted = false })
                .tabItem { Label("Settings", systemImage: "gearshape") }.tag(Tab.settings)
        }
        .environment(\.openBook, OpenBookAction { reading = $0 })
        .fullScreenCover(item: $reading) { edition in
            ReaderScreen(edition: edition, journal: journal) { reading = nil }
                .ignoresSafeArea()
        }
        .sheet(isPresented: Binding(get: { !welcomeCompleted }, set: { if !$0 { welcomeCompleted = true } })) {
            WelcomeView { welcomeCompleted = true; tab = .library }
        }
        .alert(journal.notice?.title ?? "", isPresented: Binding(get: { journal.notice != nil }, set: { if !$0 { journal.notice = nil } }),
               presenting: journal.notice) { _ in
            Button("OK", role: .cancel) {}
        } message: { notice in
            Text(notice.message)
        }
        .onChange(of: scenePhase) { _, phase in
            journal.sceneActivityChanged(active: phase == .active)
        }
        .onOpenURL { url in
            // EPUBs shared from Files, Mail, Safari or AirDrop arrive here as copies.
            guard url.isFileURL else { return }
            tab = .library
            Task { await journal.importEPUBs([url]) }
        }
        .task { await journal.loadLibrary() }
    }
}
