import AppKit
import Darwin
import SwiftUI

/// Deterministic transport delay: reset must follow an in-flight batch and discard a later pending patch.
@MainActor func runNativeReaderQueueSmoke() async throws {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let chrome = NativeReaderChrome(window: window)
    var commands: [String] = [], value = 1.2
    var release: CheckedContinuation<Void, Never>?
    chrome.send = { command, payload in
        commands.append(command)
        if command == "preferences" {
            await withCheckedContinuation { release = $0 }
            value = payload?["fontSize"] as? Double ?? value
        }
        if command == "reset" { value = 1.2 }
        return ["preferences": ["fontSize": value], "definitions": []]
    }
    await chrome.connect()
    chrome.model.change?("fontSize", 1.8)
    let deadline = Date().addingTimeInterval(2)
    while release == nil && Date() < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
    guard let resume = release else { throw NSError(domain: "Stillleaf.ReaderControls", code: 3) }
    chrome.model.change?("fontSize", 2.1)
    chrome.model.reset?()
    resume.resume()
    try await chrome.flush()
    guard commands.filter({ $0 == "preferences" || $0 == "reset" }) == ["preferences", "reset"],
          chrome.model.preferences["fontSize"] as? Double == 1.2 else { throw NSError(domain: "Stillleaf.ReaderControls", code: 4) }
    chrome.accept(["preferences": ["fontSize": 1.2, "immersive": true]])
    guard !chrome.toolbar.isVisible else { throw NSError(domain: "Stillleaf.ReaderControls", code: 6) }
    chrome.accept(["preferences": ["fontSize": 1.2, "immersive": false], "dialogOpen": true])
    guard chrome.toolbar.isVisible, !chrome.canAcceptCommands else { throw NSError(domain: "Stillleaf.ReaderControls", code: 7) }
    chrome.model.accept(["effectiveAppearance": ["backgroundColor": "#1c302d", "textColor": "#e7f3ea"]])
    guard chrome.model.customColor("backgroundColor") == "#1c302d",
          chrome.model.customColor("textColor") == "#e7f3ea" else { throw NSError(domain: "Stillleaf.ReaderControls", code: 16) }
    chrome.model.accept(["preferences": ["theme": "white", "textColor": "#e7f3ea"],
                         "effectiveAppearance": ["backgroundColor": "#ffffff", "textColor": "#242729"]])
    guard chrome.model.customColor("textColor") == "#242729" else { throw NSError(domain: "Stillleaf.ReaderControls", code: 18) }
    let presetModel = ReaderChromeModel()
    var presetChanges: [String: Any] = [:]
    presetModel.change = { key, value in presetChanges[key] = value }
    presetModel.selectChoice("margins", "narrow")
    guard presetChanges["sideMargin"] is NSNull, presetChanges["margins"] as? String == "narrow" else { throw NSError(domain: "Stillleaf.ReaderControls", code: 17) }
    chrome.disconnect()
    print("native-reader-queue: delayed slider, superseded pending patch and Reset ordering passed")
}
