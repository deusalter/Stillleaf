import SwiftUI
import UniformTypeIdentifiers

struct RootView: View {
    @EnvironmentObject private var journal: Journal
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("welcomeCompleted") private var welcomeCompleted = false
    @StateObject private var router: AppRouter

    @MainActor
    init(router: AppRouter? = nil) {
        let router = router ?? AppRouter()
        _router = StateObject(wrappedValue: router)
    }

    var body: some View {
        TabView(selection: $router.tab) {
            ReadingNowView()
                .tabItem { Label("Reading Now", systemImage: "book") }.tag(AppRouter.Tab.reading)
            LibraryView()
                .tabItem { Label("Library", systemImage: "books.vertical") }.tag(AppRouter.Tab.library)
            JournalView()
                .tabItem { Label("Journal", systemImage: "calendar") }.tag(AppRouter.Tab.journal)
        }
        .overlay(alignment: .bottom) { StatusCapsule(text: journal.importStatus ?? journal.toast, busy: journal.importStatus != nil) }
        .fullScreenCover(item: $router.reading, onDismiss: offerFinish) { edition in
            ReaderScreen(edition: edition, journal: journal) { router.reading = nil }
        }
        .sheet(item: $router.sheet, onDismiss: { journal.closeFinishOffer() }) { sheet in
            switch sheet {
            case .settings: SettingsView(showWelcome: { router.sheet = nil; welcomeCompleted = false })
            case .logReading: LogReadingView()
            case .finish(let book): FinishOfferView(bookID: book)
            }
        }
        .sheet(isPresented: Binding(get: { !welcomeCompleted && router.sheet == nil }, set: { if !$0 { welcomeCompleted = true } })) {
            WelcomeView { welcomeCompleted = true }
        }
        .fileImporter(isPresented: $router.importing, allowedContentTypes: [.epub], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): importBooks(urls, openSingle: false)
            case .failure(let error): journal.notice = JournalNotice(title: "Import", message: error.localizedDescription)
            }
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
            // EPUBs shared from Files, Mail, Safari or AirDrop arrive here as copies. One book opens straight away.
            guard url.isFileURL else { return }
            importBooks([url], openSingle: true)
        }
        .task(id: journal.toast) {
            guard journal.toast != nil else { return }
            try? await Task.sleep(nanoseconds: 2_600_000_000)
            if !Task.isCancelled { journal.toast = nil }
        }
        .task { await journal.loadLibrary() }
        // Outermost, so the reader and every sheet can reach the router too.
        .environmentObject(router)
    }

    /// Once the reader has gone: a book closed on its last pages is offered as finished.
    private func offerFinish() {
        guard let book = journal.finishOffer else { return }
        if router.sheet == nil, router.reading == nil { router.sheet = .finish(book) } else { journal.closeFinishOffer(remember: false) }
    }

    private func importBooks(_ urls: [URL], openSingle: Bool) {
        Task {
            let books = await journal.importEPUBs(urls)
            if openSingle, books.count == 1, let edition = journal.edition(forBook: books[0]) {
                welcomeCompleted = true
                router.sheet = nil
                router.reading = edition
            } else if !books.isEmpty {
                router.tab = .library
            }
        }
    }
}

/// Import progress and short confirmations, floating above the tab bar.
private struct StatusCapsule: View {
    let text: String?
    let busy: Bool

    var body: some View {
        ZStack {
            if let text {
                HStack(spacing: 8) {
                    if busy { ProgressView().controlSize(.small) } else { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor) }
                    Text(text).lineLimit(2)
                }
                .font(.footnote.weight(.medium))
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(.regularMaterial, in: Capsule())
                .shadow(color: .black.opacity(0.12), radius: 10, y: 3)
                .padding(.horizontal, 24)
                .padding(.bottom, 64)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.updatesFrequently)
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: text)
        .allowsHitTesting(false)
    }
}
