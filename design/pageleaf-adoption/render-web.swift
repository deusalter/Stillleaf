import AppKit
import WebKit
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
final class Renderer: NSObject, WKNavigationDelegate {
    var web: WKWebView!
    let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    func run() {
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 900))
        web.navigationDelegate = self
        web.load(URLRequest(url: URL(string: "http://127.0.0.1:4188")!))
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            let config = WKSnapshotConfiguration()
            config.rect = NSRect(x: 0, y: 0, width: 1280, height: 900)
            webView.takeSnapshot(with: config) { image, error in
                guard let image, let tiff = image.tiffRepresentation,
                      let bitmap = NSBitmapImageRep(data: tiff),
                      let png = bitmap.representation(using: .png, properties: [:]) else {
                    print("Snapshot failed: \(String(describing: error))"); exit(1)
                }
                do { try png.write(to: self.root.appendingPathComponent("website-after.png")) }
                catch { print(error); exit(1) }
                print("Rendered website-after.png (\(bitmap.pixelsWide) × \(bitmap.pixelsHigh))")
                exit(0)
            }
        }
    }
}
let renderer = Renderer()
renderer.run()
app.run()
