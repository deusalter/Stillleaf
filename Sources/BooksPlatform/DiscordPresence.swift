import Foundation
import Darwin
import BooksCore

enum DiscordRPCOpcode: Int32, Equatable {
    case handshake = 0
    case frame = 1
    case close = 2
    case ping = 3
    case pong = 4
}

struct DiscordRPCFrame: Equatable {
    let opcode: DiscordRPCOpcode
    let payload: Data

    func encoded() -> Data {
        var result = Data()
        result.appendLittleEndian(UInt32(bitPattern: opcode.rawValue))
        result.appendLittleEndian(UInt32(payload.count))
        result.append(payload)
        return result
    }
}

struct DiscordRPCFrameParser {
    private var buffer = Data()
    private static let maximumPayloadBytes = 1_048_576

    mutating func append<S: DataProtocol>(_ data: S) -> [DiscordRPCFrame] {
        buffer.append(contentsOf: data)
        var frames: [DiscordRPCFrame] = []
        while buffer.count >= 8 {
            let opcodeRaw = Int32(bitPattern: buffer.littleEndianUInt32(at: 0))
            let length = Int(buffer.littleEndianUInt32(at: 4))
            guard let opcode = DiscordRPCOpcode(rawValue: opcodeRaw), length <= Self.maximumPayloadBytes else {
                buffer.removeAll(keepingCapacity: false)
                return frames
            }
            guard buffer.count >= 8 + length else { return frames }
            let payloadStart = buffer.index(buffer.startIndex, offsetBy: 8)
            let payloadEnd = buffer.index(payloadStart, offsetBy: length)
            frames.append(DiscordRPCFrame(opcode: opcode, payload: Data(buffer[payloadStart..<payloadEnd])))
            buffer.removeSubrange(buffer.startIndex..<payloadEnd)
        }
        return frames
    }
}

enum DiscordActivityPayload {
    enum Error: Swift.Error { case missingApplicationID }

    static func make(book: BookRecord, progress: ProgressObservation?, elapsed: TimeInterval, applicationID: String, assetKey: String, paused: Bool = false) throws -> Data {
        guard !applicationID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Error.missingApplicationID }
        let state = [book.author?.trimmingCharacters(in: .whitespacesAndNewlines), paused ? "Paused" : reliableProgressText(progress)]
            .compactMap { value -> String? in
                guard let value, !value.isEmpty else { return nil }
                return value
            }
            .joined(separator: " • ")
        var activity: [String: Any] = [
            "type": 0,
            "details": "Reading \(book.title)",
            "instance": false
        ]
        if !paused { activity["timestamps"] = ["start": Int(Date().timeIntervalSince1970 - max(0, elapsed))] }
        if !state.isEmpty { activity["state"] = state }
        if let key = sanitizedAssetKey(assetKey) { activity["assets"] = ["large_image": key] }
        return try json([
            "cmd": "SET_ACTIVITY",
            "args": ["pid": Int(getpid()), "activity": activity] as [String: Any],
            "nonce": UUID().uuidString
        ])
    }

    static func clear() throws -> Data {
        try json([
            "cmd": "SET_ACTIVITY",
            "args": ["pid": Int(getpid()), "activity": NSNull()] as [String: Any],
            "nonce": UUID().uuidString
        ])
    }

    static func handshake(applicationID: String) throws -> Data {
        try json(["v": 1, "client_id": applicationID])
    }

    private static func reliableProgressText(_ progress: ProgressObservation?) -> String? {
        guard let progress, progress.reliable else { return nil }
        if let page = progress.page, let total = progress.totalPages, total > 0 { return "Page \(page) of \(total)" }
        if let fraction = progress.fraction, fraction.isFinite { return "\(Int((min(1, max(0, fraction)) * 100).rounded()))% complete" }
        if let location = progress.location?.trimmingCharacters(in: .whitespacesAndNewlines), !location.isEmpty { return "Location \(location)" }
        return nil
    }

    private static func sanitizedAssetKey(_ candidate: String) -> String? {
        let key = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, key.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-" )).contains($0) }) else { return nil }
        return key
    }

    private static func json(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [])
    }
}

public final class DiscordPresence {
    private struct DesiredActivity {
        let book: BookRecord
        let progress: ProgressObservation?
        let elapsed: TimeInterval
        let applicationID: String
        let assetKey: String
        let paused: Bool
        let publishImmediately: Bool
        let generation: UInt64
    }

    private let queue = DispatchQueue(label: "BooksPresence.discord-ipc", qos: .utility)
    private let stateLock = NSLock()
    private let socketOpener: () -> Int32?
    private var statusValue = "Discord sharing is off"
    private var desired: DesiredActivity?
    private var generation: UInt64 = 0
    private var socketFD: Int32 = -1
    private var connectedApplicationID: String?
    private var readSource: DispatchSourceRead?
    private var writeSource: DispatchSourceWrite?
    private var parser = DiscordRPCFrameParser()
    private var outbound = Data()
    private var ready = false
    private var lastPublish = Date.distantPast
    private var reconnectDelay: TimeInterval = 1
    private var reconnectWorkItem: DispatchWorkItem?
    private var publishWorkItem: DispatchWorkItem?
    private var pendingPublishNonce: String?
    private var activityMayBeVisible = false
    private var transportDiagnosticStatus: String?
    private var stopped = false

    public init() {
        socketOpener = openDiscordSocket
    }

    init(socketOpener: @escaping () -> Int32?) {
        self.socketOpener = socketOpener
    }

    public var status: String {
        stateLock.lock(); defer { stateLock.unlock() }
        return statusValue
    }

    public func update(book: BookRecord?, progress: ProgressObservation?, elapsed: TimeInterval, enabled: Bool, applicationID: String, assetKey: String, paused: Bool = false) {
        // Serializing the state change ahead of its work item means a queued, older
        // activity cannot be published after this call disables sharing.
        queue.sync {
            guard !stopped else { return }
            stateLock.lock()
            generation &+= 1
            let currentGeneration = generation
            if enabled, let book, !book.sharingExcluded, !applicationID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let beginsNewSession = desired == nil || desired?.applicationID != applicationID
                let pausedChanged = desired.map { $0.paused != paused } ?? false
                desired = DesiredActivity(book: book, progress: progress, elapsed: elapsed, applicationID: applicationID, assetKey: assetKey, paused: paused, publishImmediately: pausedChanged, generation: currentGeneration)
                // Regular tracker ticks must not mask a useful asynchronous state
                // such as a rejected activity or scheduled reconnect.
                if beginsNewSession { statusValue = "Connecting to Discord…" }
            } else {
                desired = nil
                statusValue = enabled && applicationID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Discord application ID needed" : "Discord sharing is off"
            }
            stateLock.unlock()
        }
        queue.async { [weak self] in self?.applyLatestActivity() }
    }

    public func clear() {
        queue.sync {
            guard !stopped else { return }
            stateLock.lock()
            generation &+= 1
            desired = nil
            statusValue = "Discord activity cleared"
            stateLock.unlock()
        }
        queue.async { [weak self] in self?.clearImmediately() }
    }

    public func shutdown() {
        queue.sync {
            stateLock.lock()
            generation &+= 1
            desired = nil
            statusValue = "Discord sharing is off"
            stateLock.unlock()
            stopped = true
        }
        queue.async { [weak self] in
            guard let self else { return }
            self.reconnectWorkItem?.cancel()
            self.publishWorkItem?.cancel()
            self.clearImmediately()
            self.disconnect(scheduleReconnect: false)
        }
    }

    private func applyLatestActivity() {
        guard !stopped else { return }
        guard let activity = currentDesired() else {
            clearImmediately()
            return
        }
        if socketFD != -1, connectedApplicationID != activity.applicationID {
            // A native IPC connection owns its activity. Closing it clears that
            // activity without ever combining a partial old frame with a new one.
            disconnect(scheduleReconnect: false)
        }
        if socketFD == -1 { connect(applicationID: activity.applicationID) }
        guard ready, isCurrent(activity) else { return }
        let delay = activity.publishImmediately ? 0 : max(0, 15 - Date().timeIntervalSince(lastPublish))
        if delay == 0 {
            publish(activity)
        } else {
            publishWorkItem?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.publishLatestIfCurrent(activity.generation) }
            publishWorkItem = work
            queue.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    private func publishLatestIfCurrent(_ expectedGeneration: UInt64) {
        guard let activity = currentDesired(), activity.generation == expectedGeneration else { return }
        publish(activity)
    }

    private func publish(_ activity: DesiredActivity) {
        guard ready, isCurrent(activity) else { return }
        do {
            let payload = try DiscordActivityPayload.make(book: activity.book, progress: activity.progress, elapsed: activity.elapsed, applicationID: activity.applicationID, assetKey: activity.assetKey, paused: activity.paused)
            guard let nonce = DiscordActivityPayload.nonce(in: payload) else {
                setStatus("Could not prepare Discord activity")
                return
            }
            pendingPublishNonce = nonce
            activityMayBeVisible = true
            transportDiagnosticStatus = nil
            lastPublish = Date()
            setStatus("Discord activity sent; waiting for confirmation")
            enqueue(DiscordRPCFrame(opcode: .frame, payload: payload))
        } catch {
            setStatus("Could not prepare Discord activity")
        }
    }

    private func clearImmediately() {
        publishWorkItem?.cancel()
        pendingPublishNonce = nil
        guard ready, activityMayBeVisible else { return }
        // `outbound` may be the unwritten tail of an already-started activity
        // frame. Replacing it with a clear frame would corrupt the IPC stream.
        // Disconnecting clears the connection-owned activity safely instead.
        guard outbound.isEmpty else {
            disconnect(scheduleReconnect: false)
            return
        }
        // Mark this before enqueueing. Repeated disabled/clear updates can arrive
        // before the write source drains the clear frame, but still need only one.
        do {
            let payload = try DiscordActivityPayload.clear()
            activityMayBeVisible = false
            enqueue(DiscordRPCFrame(opcode: .frame, payload: payload))
        }
        catch { setStatus("Could not clear Discord activity") }
    }

    private func currentDesired() -> DesiredActivity? {
        stateLock.lock(); defer { stateLock.unlock() }
        return desired
    }

    private func isCurrent(_ activity: DesiredActivity) -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return desired?.generation == activity.generation
    }

    private func setStatus(_ newStatus: String) {
        stateLock.lock(); statusValue = newStatus; stateLock.unlock()
    }

    private func connect(applicationID: String) {
        // A scheduled reconnect is the next transport attempt, so it can replace
        // a previous peer diagnostic with its own connection result.
        transportDiagnosticStatus = nil
        guard socketFD == -1, !applicationID.isEmpty, let fd = socketOpener() else {
            scheduleReconnect()
            return
        }
        guard configureDiscordSocket(fd) else {
            Darwin.close(fd)
            scheduleReconnect()
            return
        }
        socketFD = fd
        connectedApplicationID = applicationID
        parser = DiscordRPCFrameParser()
        ready = false
        pendingPublishNonce = nil
        activityMayBeVisible = false
        transportDiagnosticStatus = nil
        configureSources(for: fd)
        do {
            enqueue(DiscordRPCFrame(opcode: .handshake, payload: try DiscordActivityPayload.handshake(applicationID: applicationID)))
            setStatus("Connecting to Discord…")
        } catch {
            disconnect(scheduleReconnect: true)
        }
    }

    private func configureSources(for fd: Int32) {
        let read = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        read.setEventHandler { [weak self] in self?.readAvailable() }
        readSource = read
        let write = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
        write.setEventHandler { [weak self] in self?.flushOutbound() }
        writeSource = write
        read.resume()
        write.resume()
    }

    private func readAvailable() {
        while socketFD != -1 {
            var bytes = [UInt8](repeating: 0, count: 8_192)
            let count = Darwin.read(socketFD, &bytes, bytes.count)
            if count > 0 {
                for frame in parser.append(Data(bytes.prefix(Int(count)))) { handle(frame) }
            } else if count == 0 {
                disconnect(scheduleReconnect: currentDesired() != nil, status: transportDiagnosticStatus ?? "Discord connection closed")
                return
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                return
            } else {
                disconnect(scheduleReconnect: currentDesired() != nil, status: "Discord connection lost")
                return
            }
        }
    }

    private func handle(_ frame: DiscordRPCFrame) {
        switch frame.opcode {
        case .ping:
            enqueue(DiscordRPCFrame(opcode: .pong, payload: frame.payload))
        case .close:
            let status = discordCloseStatus(from: frame.payload) ?? transportDiagnosticStatus ?? "Discord connection closed"
            disconnect(scheduleReconnect: currentDesired() != nil, status: status)
        case .frame:
            guard let object = try? JSONSerialization.jsonObject(with: frame.payload) as? [String: Any] else { return }
            if object["evt"] as? String == "READY" {
                ready = true
                reconnectDelay = 1
                if let activity = currentDesired() { publish(activity) }
            } else if object["evt"] as? String == "ERROR" {
                // Discord can deliver an error for a previous request after a newer
                // activity is already waiting for its acknowledgement. Only a
                // nonce-less connection error or the current request may affect UI.
                if let nonce = object["nonce"] as? String {
                    guard nonce == pendingPublishNonce else { return }
                    pendingPublishNonce = nil
                }
                let status = discordErrorStatus(from: object)
                transportDiagnosticStatus = status
                setStatus(status)
            } else if object["cmd"] as? String == "SET_ACTIVITY",
                      let nonce = object["nonce"] as? String,
                      nonce == pendingPublishNonce {
                pendingPublishNonce = nil
                transportDiagnosticStatus = nil
                setStatus("Discord activity shared")
            }
        case .handshake, .pong: break
        }
    }

    private func enqueue(_ frame: DiscordRPCFrame) {
        outbound.append(frame.encoded())
        flushOutbound()
    }

    private func flushOutbound() {
        while socketFD != -1, !outbound.isEmpty {
            let written = outbound.withUnsafeBytes { bytes -> Int in
                Darwin.write(socketFD, bytes.baseAddress, bytes.count)
            }
            if written > 0 { outbound.removeSubrange(0..<written) }
            else if written == -1 && (errno == EAGAIN || errno == EWOULDBLOCK) { return }
            else { disconnect(scheduleReconnect: currentDesired() != nil, status: "Discord connection lost"); return }
        }
    }

    private func disconnect(scheduleReconnect shouldReconnect: Bool, status: String? = nil) {
        if let status {
            transportDiagnosticStatus = status
            setStatus(status)
        }
        readSource?.cancel(); readSource = nil
        writeSource?.cancel(); writeSource = nil
        if socketFD != -1 { Darwin.close(socketFD); socketFD = -1 }
        connectedApplicationID = nil
        ready = false
        pendingPublishNonce = nil
        activityMayBeVisible = false
        outbound.removeAll(keepingCapacity: false)
        if shouldReconnect && !stopped { scheduleReconnect() }
    }

    private func scheduleReconnect() {
        guard currentDesired() != nil, !stopped,
              (reconnectWorkItem == nil || reconnectWorkItem?.isCancelled == true) else { return }
        let delay = reconnectDelay
        reconnectDelay = min(reconnectDelay * 2, 30)
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.reconnectWorkItem = nil
            self.applyLatestActivity()
        }
        reconnectWorkItem = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
        if transportDiagnosticStatus == nil { setStatus("Discord unavailable; retrying") }
    }
}

private extension Data {
    mutating func appendLittleEndian(_ value: UInt32) {
        append(UInt8(value & 0xff)); append(UInt8((value >> 8) & 0xff)); append(UInt8((value >> 16) & 0xff)); append(UInt8((value >> 24) & 0xff))
    }

    func littleEndianUInt32(at offset: Int) -> UInt32 {
        let first = index(startIndex, offsetBy: offset)
        let second = index(first, offsetBy: 1)
        let third = index(first, offsetBy: 2)
        let fourth = index(first, offsetBy: 3)
        return UInt32(self[first]) | UInt32(self[second]) << 8 | UInt32(self[third]) << 16 | UInt32(self[fourth]) << 24
    }
}

private extension DiscordActivityPayload {
    static func nonce(in payload: Data) -> String? {
        (try? JSONSerialization.jsonObject(with: payload) as? [String: Any])?["nonce"] as? String
    }
}

private func discordErrorStatus(from object: [String: Any]) -> String {
    guard let message = discordDiagnosticMessage(from: object) else { return "Discord rejected the activity update" }
    return "Discord rejected activity: \(message)"
}

private func discordCloseStatus(from payload: Data) -> String? {
    guard let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
          let message = discordDiagnosticMessage(from: object) else { return nil }
    return "Discord connection closed: \(message)"
}

private func discordDiagnosticMessage(from object: [String: Any]) -> String? {
    let raw = (object["data"] as? [String: Any])?["message"] as? String ?? object["message"] as? String
    let safe = raw?.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.map(String.init).joined()
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !safe.isEmpty else { return nil }
    return String(safe.prefix(160))
}

private func openDiscordSocket() -> Int32? {
    let environment = ProcessInfo.processInfo.environment
    let roots = [environment["XDG_RUNTIME_DIR"], environment["TMPDIR"], environment["TMP"], environment["TEMP"], "/tmp"].compactMap { $0 }.filter { !$0.isEmpty }
    for root in roots {
        for index in 0...9 {
            let path = URL(fileURLWithPath: root).appendingPathComponent("discord-ipc-\(index)").path
            guard let fd = connectUnixSocket(path: path) else { continue }
            return fd
        }
    }
    return nil
}

private func connectUnixSocket(path: String) -> Int32? {
    let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(path.utf8) + [0]
    guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { Darwin.close(fd); return nil }
    _ = withUnsafeMutableBytes(of: &address.sun_path) { destination in
        pathBytes.withUnsafeBytes { source in memcpy(destination.baseAddress!, source.baseAddress!, pathBytes.count) }
    }
    let result = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard result == 0 else { Darwin.close(fd); return nil }
    return fd
}

@discardableResult
func configureDiscordSocket(_ fd: Int32) -> Bool {
    guard fd >= 0 else { return false }
    var enabled: Int32 = 1
    guard Darwin.setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size)) == 0 else { return false }
    let flags = fcntl(fd, F_GETFL)
    guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { return false }
    return true
}
