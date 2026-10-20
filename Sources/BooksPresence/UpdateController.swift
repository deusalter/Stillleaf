import AppKit
import SwiftUI
import BooksCore
import BooksPlatform

/// "Check for Updates…" against the release feed (docs/DISTRIBUTION.md#updates). Stillleaf
/// never downloads or installs anything itself: it opens the release page, and the notarized
/// disk image is checked by Gatekeeper like any other download.
@MainActor
final class UpdateController: ObservableObject {
    enum Status: Equatable {
        case idle, checking, upToDate
        case available(UpdateRelease)
        case requiresNewerSystem(UpdateRelease)
        case failed(String)
    }

    @Published private(set) var status = Status.idle
    @Published private(set) var lastChecked: Date?
    /// Off by default, like every other Stillleaf feature that contacts a server.
    @Published var automaticChecks: Bool {
        didSet {
            defaults.set(automaticChecks, forKey: Self.automaticKey)
            if automaticChecks { checkIfDue() }
        }
    }

    let checker: UpdateChecker?
    private let defaults: UserDefaults
    private var timer: Timer?
    private var activationObserver: NSObjectProtocol?
    /// An automatic result waiting for the app to come forward, so a check never steals focus.
    private var pendingAnnouncement: UpdateRelease?
    private static let automaticKey = "automaticUpdateChecks", lastCheckKey = "lastUpdateCheck", announcedKey = "announcedUpdateBuild"
    private static let checkInterval: TimeInterval = 24 * 60 * 60

    init(checker: UpdateChecker? = UpdateChecker(bundle: .main), defaults: UserDefaults = .standard) {
        self.checker = checker
        self.defaults = defaults
        automaticChecks = defaults.bool(forKey: Self.automaticKey)
        lastChecked = defaults.object(forKey: Self.lastCheckKey) as? Date
    }

    var isConfigured: Bool { checker != nil }

    var versionDescription: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "development"
        let build = info["CFBundleVersion"] as? String
        return "Stillleaf \(version)" + (build.map { " (\($0))" } ?? "")
    }

    var statusDescription: String {
        guard isConfigured else { return "This build has no update feed. Download releases from the Stillleaf website." }
        switch status {
        case .checking: return "Checking…"
        case .available(let release): return "Stillleaf \(release.version) is available."
        case .requiresNewerSystem(let release): return "Stillleaf \(release.version) needs macOS \(release.minimumSystemVersion) or later."
        case .failed(let message): return message
        case .upToDate, .idle:
            guard let lastChecked else { return "Not checked yet." }
            return "Up to date. Last checked \(lastChecked.formatted(date: .abbreviated, time: .shortened))."
        }
    }

    /// Starts the daily automatic check when the reader opted in. Safe to call once at launch.
    func start() {
        guard isConfigured, timer == nil, !BackgroundUI.isEnabled else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 60 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.checkIfDue() }
        }
        activationObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.announcePending() }
        }
        checkIfDue()
    }

    func checkNow() { check(userInitiated: true) }

    private func checkIfDue() {
        guard automaticChecks, status != .checking else { return }
        if let lastChecked, Date().timeIntervalSince(lastChecked) < Self.checkInterval { return }
        check(userInitiated: false)
    }

    private func check(userInitiated: Bool) {
        guard let checker else {
            if userInitiated { present(title: "Updates are not set up for this build", message: statusDescription) }
            return
        }
        guard status != .checking else { return }
        status = .checking
        Task { [weak self] in
            let result: Result<UpdateAvailability, Error>
            do { result = .success(try await checker.check()) } catch { result = .failure(error) }
            self?.finish(result, userInitiated: userInitiated)
        }
    }

    private func finish(_ result: Result<UpdateAvailability, Error>, userInitiated: Bool) {
        switch result {
        case .success(let availability):
            lastChecked = Date(); defaults.set(lastChecked, forKey: Self.lastCheckKey)
            switch availability {
            case .upToDate:
                status = .upToDate
                if userInitiated { present(title: "Stillleaf is up to date", message: "\(versionDescription) is the latest version.") }
            case .available(let release):
                status = .available(release)
                if userInitiated { offer(release) }
                else if defaults.integer(forKey: Self.announcedKey) != release.build {
                    pendingAnnouncement = release
                    announcePending()
                }
            case .requiresNewerSystem(let release):
                status = .requiresNewerSystem(release)
                if userInitiated { present(title: "A newer Stillleaf needs a newer macOS", message: statusDescription) }
            }
        case .failure(let error):
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            status = .failed(message)
            if userInitiated { present(title: "Could not check for updates", message: message) }
        }
    }

    private func announcePending() {
        guard let release = pendingAnnouncement, NSApp.isActive else { return }
        pendingAnnouncement = nil
        defaults.set(release.build, forKey: Self.announcedKey)
        offer(release)
    }

    private func offer(_ release: UpdateRelease) {
        let alert = NSAlert()
        alert.messageText = "Stillleaf \(release.version) is available"
        alert.informativeText = "You have \(versionDescription). Download the new version from the Stillleaf website, then replace the app in your Applications folder. Your reading history stays where it is."
        alert.addButton(withTitle: "Open Download Page")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(release.pageURL) }
    }

    private func present(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }
}

/// Settings → Data & privacy → Updates.
struct UpdateSettingsSection: View {
    @ObservedObject var updates: UpdateController

    var body: some View {
        ReadingSection("Updates") {
            VStack(spacing: 0) {
                SettingsRow(title: "Check automatically", description: "Once a day, ask the Stillleaf website whether a newer version exists. The request carries only the app version.") {
                    GlassSwitch(label: "Check for updates automatically", isOn: $updates.automaticChecks)
                }.disabled(!updates.isConfigured)
                SettingsDivider()
                SettingsRow(title: updates.versionDescription, description: updates.statusDescription) {
                    HStack(spacing: ReadingMetrics.Space.s) {
                        if case .available(let release) = updates.status {
                            Button("Download…") { NSWorkspace.shared.open(release.pageURL) }.buttonStyle(ReadingButtonStyle(emphasis: .primary))
                        }
                        Button("Check now") { updates.checkNow() }.disabled(!updates.isConfigured || updates.status == .checking)
                    }.controlSize(.small)
                }
            }
        }
    }
}
