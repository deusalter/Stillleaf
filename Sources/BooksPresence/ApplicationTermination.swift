import AppKit

/// Enter AppKit's termination loop from a run-loop callback, after the signal
/// dispatch callback returns. A terminateLater reply may need the main queue
/// for async reader saves while AppKit runs its nested event loop.
@MainActor
func makeApplicationTerminationSignalSource(application: NSApplication) -> DispatchSourceSignal {
    signal(SIGTERM, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    source.setEventHandler {
        let timer = Timer(timeInterval: 0, target: application,
                          selector: #selector(NSApplication.terminate(_:)), userInfo: nil, repeats: false)
        RunLoop.main.add(timer, forMode: .common)
    }
    source.resume()
    return source
}
