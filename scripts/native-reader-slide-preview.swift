import AppKit
import WebKit

/// Standalone WKWebView fixture using the real built renderer, without the app,
/// its database, tracking, saved preferences, or installed bundle.
final class PreviewResources: NSObject, WKURLSchemeHandler {
    let root: URL
    init(root: URL) { self.root = root }
    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        let file = root.appendingPathComponent(url.path).standardizedFileURL
        guard file.path.hasPrefix(root.path + "/"), let data = try? Data(contentsOf: file) else {
            task.didFailWithError(NSError(domain: "PreviewResource", code: 404)); return
        }
        let mime = ["html": "text/html", "js": "text/javascript", "css": "text/css", "woff2": "font/woff2"][file.pathExtension] ?? "application/octet-stream"
        task.didReceive(URLResponse(url: url, mimeType: mime, expectedContentLength: data.count, textEncodingName: "utf-8"))
        task.didReceive(data); task.didFinish()
    }
    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}

@main struct NativeReaderSlidePreview {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            do { try await run(); exit(0) }
            catch { fputs("native-slide-preview: \(error)\n", stderr); exit(1) }
        }
        app.run()
    }

    @MainActor static func run() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
        let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(PreviewResources(root: root), forURLScheme: "slide-preview")
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 1000, height: 800), configuration: configuration)
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: .aqua)
        window.contentView = view; window.orderFrontRegardless()
        defer { window.contentView = nil; window.close() }
        view.load(URLRequest(url: URL(string: "slide-preview://reader/index.html")!))
        for _ in 0..<100 {
            if (try? await view.evaluateJavaScript("typeof window.StillleafReader?.open === 'function'")) as? Bool == true { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let prose = "The ferry crossed slowly while the gulls kept pace with the wake. She rested the book on her knees and watched the light change on the opposite bank."
        let chapters = (1...2).map { n in
            "<!doctype html><html><head><title>Chapter \(n)</title></head><body><h1>Chapter \(n)</h1>" +
            (0..<40).map { "<p id='c\(n)p\($0)'>\(n).\($0 + 1) — \(prose)</p>" }.joined() + "</body></html>"
        }
        let input: [String: Any] = ["editionId": "native-slide-fixture", "title": "Across the Water", "language": "en",
            "readingOrder": (1...2).map { ["href": "c\($0).html", "type": "text/html", "title": "Chapter \($0)"] },
            "resources": chapters.enumerated().map { ["href": "c\($0.offset + 1).html", "type": "text/html", "dataBase64": Data($0.element.utf8).base64EncodedString()] }]
        let json = String(data: try JSONSerialization.data(withJSONObject: input), encoding: .utf8)!
        _ = try await view.evaluateJavaScript("window.previewReady=false; window.StillleafReader.open(\(json)).then(()=>{window.previewReady=true}); true")
        for _ in 0..<100 {
            if (try await view.evaluateJavaScript("window.previewReady")) as? Bool == true { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        guard (try await view.evaluateJavaScript("window.previewReady")) as? Bool == true else { throw NSError(domain: "RendererNotReady", code: 1) }
        _ = try await view.evaluateJavaScript("window.previewEvents=[]; window.addEventListener('stillleaf-reader-event',e=>{if(e.detail.type==='pageTurn')window.previewEvents.push(e.detail)}); true")
        var captures: [[String: Any]] = []
        let start = Date()
        for index in 0..<100 {
            let script: String?
            switch index {
            case 8: script = "window.StillleafReader.next()"
            case 25: script = "window.StillleafReader.previous()"
            case 40: script = "Promise.all([window.StillleafReader.next(),window.StillleafReader.next(),window.StillleafReader.previous()])"
            case 62: script = "window.StillleafReader.go({href:'c1.html',type:'text/html',locations:{progression:1}})"
            case 72: script = "window.StillleafReader.next()"
            case 87: script = "window.StillleafReader.previous()"
            default: script = nil
            }
            if let script { _ = try await view.evaluateJavaScript("window.previewTurn=\(script); true") }
            try await Task.sleep(nanoseconds: 33_333_333)
            let image: NSImage = try await withCheckedThrowingContinuation { continuation in
                view.takeSnapshot(with: nil) { image, error in
                    if let image { continuation.resume(returning: image) }
                    else { continuation.resume(throwing: error ?? NSError(domain: "Snapshot", code: 1)) }
                }
            }
            guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) else { throw NSError(domain: "PNG", code: 1) }
            let name = String(format: "%03d.png", index)
            try png.write(to: output.appendingPathComponent(name))
            let state = try await view.evaluateJavaScript("JSON.stringify({position:window.StillleafReader.bookmark(),overlays:document.querySelectorAll('.reader-page-slide').length,transform:document.querySelector('.page-slide-track')?getComputedStyle(document.querySelector('.page-slide-track')).transform:null,liveTransform:getComputedStyle(document.querySelector('#reader')).transform})") as? String ?? "{}"
            captures.append(["file": name, "time": Date().timeIntervalSince(start), "state": state])
        }
        let result = try await view.evaluateJavaScript("JSON.stringify({events:window.previewEvents,position:window.StillleafReader.bookmark(),overlays:document.querySelectorAll('.reader-page-slide').length,reducedMotion:matchMedia('(prefers-reduced-motion: reduce)').matches})") as? String ?? "{}"
        try Data(result.utf8).write(to: output.appendingPathComponent("result.json"))
        try JSONSerialization.data(withJSONObject: captures, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("frames.json"))
        // WKWebView.takeSnapshot may freeze compositor-driven motion. A separate,
        // explicitly sampled sequence proves native rendering at known play times;
        // it is not a display refresh or input-latency measurement.
        _ = try await view.evaluateJavaScript("window.previewTurn=window.StillleafReader.next(); true")
        for _ in 0..<100 {
            let ready = try await view.evaluateJavaScript("Boolean(document.querySelector('.page-slide-track')?.getAnimations().length)") as? Bool ?? false
            if ready { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        for (index, time) in stride(from: 0, through: 256, by: 32).enumerated() {
            _ = try await view.evaluateJavaScript("(()=>{const a=document.querySelector('.page-slide-track')?.getAnimations()[0];if(a){a.pause();a.currentTime=\(time)}})(); true")
            try await Task.sleep(nanoseconds: 80_000_000)
            let image: NSImage = try await withCheckedThrowingContinuation { continuation in
                view.takeSnapshot(with: nil) { image, error in
                    if let image { continuation.resume(returning: image) }
                    else { continuation.resume(throwing: error ?? NSError(domain: "Snapshot", code: 1)) }
                }
            }
            let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
            try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(String(format: "sample-%02d.png", index)))
        }
        _ = try await view.evaluateJavaScript("document.querySelector('.page-slide-track')?.getAnimations()[0]?.finish(); true")
        print("Native WKWebView frames: \(output.path)")
        print(result)
    }
}
