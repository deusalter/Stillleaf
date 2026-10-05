import AppKit

@MainActor
private final class TerminationDelegate: NSObject, NSApplicationDelegate {
    private var source: DispatchSourceSignal?
    private var requests = 0
    private var completedSaves = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        source = makeApplicationTerminationSignalSource(application: NSApplication.shared)
        sendSignal()
    }

    private func sendSignal() {
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { kill(getpid(), SIGTERM) }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        requests += 1
        let request = requests
        Task { @MainActor in
            // Exercise a real suspension, as reader close/save does.
            try? await Task.sleep(nanoseconds: 10_000_000)
            completedSaves += 1
            sender.reply(toApplicationShouldTerminate: request == 2)
            if request == 1 { sendSignal() }
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        precondition(requests == 2 && completedSaves == 2,
                     "SIGTERM must allow async saves, cancellation, and a subsequent successful quit")
        print("application-termination: PASS async save / cancelled quit / subsequent SIGTERM quit")
    }
}

@main private struct TerminationSmoke {
    @MainActor static func main() {
        // Fail even when AppKit's nested loop stalls the main queue.
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
            fputs("application-termination: FAIL async quit stalled\n", stderr)
            _exit(1)
        }
        let application = NSApplication.shared
        let delegate = TerminationDelegate()
        application.setActivationPolicy(.prohibited)
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}
