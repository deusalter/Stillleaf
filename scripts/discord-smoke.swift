import Foundation
import Darwin
@testable import BooksPlatform
import BooksCore

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("discord-smoke: \(message)\n", stderr)
        exit(1)
    }
}

private func frameParserCheck() {
    let first = DiscordRPCFrame(opcode: .ping, payload: Data("one".utf8))
    let second = DiscordRPCFrame(opcode: .pong, payload: Data("two".utf8))
    let wire = first.encoded() + second.encoded()
    var parser = DiscordRPCFrameParser()
    require(parser.append(wire.prefix(10)).isEmpty, "partial header must not produce a frame")
    require(parser.append(wire.dropFirst(10).prefix(7)) == [first], "first frame was not recovered")
    require(parser.append(wire.dropFirst(17)) == [second], "second frame was not recovered")
}

private func activityPayloadCheck() throws {
    let book = BookRecord(id: "smoke", title: "The Dispossessed", author: "Ursula K. Le Guin")
    let progress = ProgressObservation(bookID: book.id, page: 45, totalPages: 341, source: "smoke", reliable: true)
    let payload = try DiscordActivityPayload.make(book: book, progress: progress, elapsed: 90, applicationID: "123", assetKey: "books")
    let object = try JSONSerialization.jsonObject(with: payload) as! [String: Any]
    let args = object["args"] as! [String: Any]
    let activity = args["activity"] as! [String: Any]
    let timestamp = (activity["timestamps"] as! [String: Int])["start"]!

    require(activity["type"] as? Int == 0, "activity type must be Playing (0)")
    require(activity["state"] as? String == "Ursula K. Le Guin • Page 45 of 341", "reliable progress is missing")
    require((activity["assets"] as? [String: String])?["large_image"] == "books", "configured asset is missing")
    require(Date().timeIntervalSince1970 - Double(timestamp) >= 89, "start timestamp is not seconds")
    require(Date().timeIntervalSince1970 - Double(timestamp) <= 91, "start timestamp excludes credited elapsed incorrectly")
}

private func pausedPayloadCheck() throws {
    let book = BookRecord(id: "paused", title: "The Dispossessed", author: "Ursula K. Le Guin")
    let payload = try DiscordActivityPayload.make(book: book, progress: nil, elapsed: 90, applicationID: "123", assetKey: "books", paused: true)
    let activity = try activityObject(in: payload)

    require(activity["details"] as? String == "Reading The Dispossessed", "paused activity lost the book title")
    require(activity["state"] as? String == "Ursula K. Le Guin • Paused", "paused activity is not clearly marked")
    require(activity["timestamps"] == nil, "paused activity must not include a running timestamp")
}

private func pageActivityPayloadCheck() throws {
    let book = BookRecord(id: "pages", title: "The Dispossessed", author: "Ursula K. Le Guin")
    let activePayload = try DiscordActivityPayload.make(book: book, progress: nil, elapsed: 90, applicationID: "123", assetKey: "books", currentPage: 45, pagesTurned: 0)
    let active = try activityObject(in: activePayload)
    require(active["details"] as? String == "The Dispossessed", "pages mode did not use the title directly")
    require(active["state"] as? String == "Ursula K. Le Guin • Page 45 • 0 pages this session", "pages mode omitted author, page, or zero pages")
    require(active["timestamps"] == nil, "pages mode must not include a running timestamp")

    let pausedPayload = try DiscordActivityPayload.make(book: book, progress: nil, elapsed: 90, applicationID: "123", assetKey: "books", paused: true, currentPage: 45, pagesTurned: 7)
    let paused = try activityObject(in: pausedPayload)
    require(paused["state"] as? String == "Ursula K. Le Guin • Page 45 • 7 pages this session • Paused", "paused pages mode is incomplete")
    require(paused["timestamps"] == nil, "paused pages mode must not include a running timestamp")
}

private func publicCoverReferenceCheck() throws {
    let publicCover = "https://images.example.com/covers/the-dispossessed.webp"
    require(PublicBookCover.assetReference(coverURL: publicCover, assetKey: "books") == publicCover, "public HTTPS cover URL was rejected")
    require(PublicBookCover.assetReference(coverURL: "file:///Users/me/Covers/book.jpg", assetKey: "books") == "books", "local cover did not fall back to uploaded asset")
    require(PublicBookCover.assetReference(coverURL: "https://127.0.0.1/book.jpg", assetKey: "") == nil, "private image URL was accepted")

    let book = BookRecord(id: "cover", title: "The Dispossessed")
    let publicPayload = try DiscordActivityPayload.make(book: book, progress: nil, elapsed: 0, applicationID: "123", assetKey: "books", coverURL: publicCover)
    let publicActivity = try activityObject(in: publicPayload)
    require((publicActivity["assets"] as? [String: String])?["large_image"] == publicCover, "public cover URL was not sent as large_image")
    let payload = try DiscordActivityPayload.make(book: book, progress: nil, elapsed: 0, applicationID: "123", assetKey: "", coverURL: "file:///Users/me/Covers/book.jpg")
    require(!String(data: payload, encoding: .utf8)!.contains("file:///"), "local cover path reached Discord payload")
}

private func publicCoverResolverFixtureCheck() throws {
    let book = BookRecord(id: "resolver", title: "A Book", author: "An Author")
    let data = try JSONSerialization.data(withJSONObject: ["results": [[
        "kind": "ebook",
        "trackName": "A Book",
        "artistName": "An Author",
        "artworkUrl100": "https://images.example.com/covers/a-book.jpg"
    ]]])
    let source = URL(string: "https://itunes.apple.com/search?media=ebook&entity=ebook&limit=10&term=A%20Book")!
    let match = try PublicCoverResolver.decodeMatch(book: book, data: data, sourceURL: source)
    require(match?.url == "https://images.example.com/covers/a-book.jpg", "resolver rejected an exact public e-book result")
    require(PublicCoverResolver.request(for: BookRecord(id: "no-author", title: "A Book")) == nil, "resolver searched without an author")
}

private enum SyntheticIPCError: Error { case systemCallFailed, unexpectedEOF, malformedFrame, unexpectedFrame }

private func socketPair() throws -> (Int32, Int32) {
    var descriptors = [Int32](repeating: -1, count: 2)
    guard Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else { throw SyntheticIPCError.systemCallFailed }
    return (descriptors[0], descriptors[1])
}

private func readExactly(_ count: Int, from fd: Int32) throws -> Data {
    var result = Data()
    while result.count < count {
        var bytes = [UInt8](repeating: 0, count: count - result.count)
        let readCount = Darwin.read(fd, &bytes, bytes.count)
        if readCount > 0 { result.append(contentsOf: bytes.prefix(Int(readCount))) }
        else if readCount == 0 { throw SyntheticIPCError.unexpectedEOF }
        else if errno != EINTR { throw SyntheticIPCError.systemCallFailed }
    }
    return result
}

private func readFrame(from fd: Int32) throws -> DiscordRPCFrame {
    let header = try readExactly(8, from: fd)
    let opcode = Int32(bitPattern: uint32LE(header, at: 0))
    let length = Int(uint32LE(header, at: 4))
    guard let parsedOpcode = DiscordRPCOpcode(rawValue: opcode), length <= 1_048_576 else { throw SyntheticIPCError.malformedFrame }
    return DiscordRPCFrame(opcode: parsedOpcode, payload: try readExactly(length, from: fd))
}

private func uint32LE(_ data: Data, at offset: Int) -> UInt32 {
    let bytes = Array(data)
    return UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
}

private func writeFrame(_ frame: DiscordRPCFrame, to fd: Int32) throws {
    let data = frame.encoded()
    var offset = 0
    while offset < data.count {
        let written = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!.advanced(by: offset), data.count - offset) }
        if written > 0 { offset += written }
        else if written == -1 && errno == EINTR { continue }
        else { throw SyntheticIPCError.systemCallFailed }
    }
}

private func json(_ object: [String: Any]) throws -> Data {
    try JSONSerialization.data(withJSONObject: object)
}

private func nonce(in payload: Data) throws -> String {
    guard let object = try JSONSerialization.jsonObject(with: payload) as? [String: Any], let nonce = object["nonce"] as? String else {
        throw SyntheticIPCError.malformedFrame
    }
    return nonce
}

private func activityObject(in payload: Data) throws -> [String: Any] {
    guard let object = try JSONSerialization.jsonObject(with: payload) as? [String: Any],
          let args = object["args"] as? [String: Any],
          let activity = args["activity"] as? [String: Any] else { throw SyntheticIPCError.malformedFrame }
    return activity
}

private func isClearActivity(_ payload: Data) throws -> Bool {
    guard let object = try JSONSerialization.jsonObject(with: payload) as? [String: Any],
          let args = object["args"] as? [String: Any] else { throw SyntheticIPCError.malformedFrame }
    return args["activity"] is NSNull
}

private func assertNoFrames(from fd: Int32, within duration: TimeInterval) throws {
    let flags = fcntl(fd, F_GETFL)
    guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { throw SyntheticIPCError.systemCallFailed }
    defer { _ = fcntl(fd, F_SETFL, flags) }
    var parser = DiscordRPCFrameParser()
    let deadline = Date().addingTimeInterval(duration)
    while Date() < deadline {
        var bytes = [UInt8](repeating: 0, count: 4096)
        let count = Darwin.read(fd, &bytes, bytes.count)
        if count > 0 {
            if !parser.append(Data(bytes.prefix(Int(count)))).isEmpty { throw SyntheticIPCError.unexpectedFrame }
        } else if count == -1 && (errno == EAGAIN || errno == EWOULDBLOCK) {
            usleep(10_000)
        } else if count == -1 && errno == EINTR {
            continue
        } else if count == 0 {
            return
        } else {
            throw SyntheticIPCError.systemCallFailed
        }
    }
}

private func waitUntil(_ predicate: @escaping () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(1)
    while Date() < deadline {
        if predicate() { return true }
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
    return predicate()
}

private func localIPCConfirmationCheck() throws {
    let (client, server) = try socketPair()
    defer { Darwin.close(server) }
    var suppliedClient = client
    let presence = DiscordPresence(socketOpener: {
        defer { suppliedClient = -1 }
        return suppliedClient
    })
    let activityReceived = DispatchSemaphore(value: 0)
    let acknowledge = DispatchSemaphore(value: 0)
    let serverFinished = DispatchSemaphore(value: 0)
    var serverError: Error?

    DispatchQueue.global().async {
        defer { serverFinished.signal() }
        do {
            _ = try readFrame(from: server)
            try writeFrame(DiscordRPCFrame(opcode: .frame, payload: json(["evt": "READY"])), to: server)
            let activity = try readFrame(from: server)
            let requestNonce = try nonce(in: activity.payload)
            try writeFrame(DiscordRPCFrame(opcode: .frame, payload: json([
                "evt": "ERROR",
                "nonce": "stale-request",
                "data": ["message": "Old request failed"]
            ])), to: server)
            activityReceived.signal()
            guard acknowledge.wait(timeout: .now() + 2) == .success else { return }
            try writeFrame(DiscordRPCFrame(opcode: .frame, payload: json(["cmd": "SET_ACTIVITY", "nonce": requestNonce])), to: server)
            let paused = try readFrame(from: server)
            let pausedActivity = try activityObject(in: paused.payload)
            guard pausedActivity["state"] as? String == "Ursula K. Le Guin • Paused", pausedActivity["timestamps"] == nil else {
                throw SyntheticIPCError.malformedFrame
            }
            try writeFrame(DiscordRPCFrame(opcode: .frame, payload: json(["cmd": "SET_ACTIVITY", "nonce": nonce(in: paused.payload)])), to: server)
            let resumed = try readFrame(from: server)
            let resumedActivity = try activityObject(in: resumed.payload)
            guard resumedActivity["state"] as? String == "Ursula K. Le Guin", resumedActivity["timestamps"] != nil else {
                throw SyntheticIPCError.malformedFrame
            }
            try writeFrame(DiscordRPCFrame(opcode: .frame, payload: json(["cmd": "SET_ACTIVITY", "nonce": nonce(in: resumed.payload)])), to: server)
        } catch {
            serverError = error
        }
    }

    presence.update(book: BookRecord(id: "smoke", title: "The Dispossessed", author: "Ursula K. Le Guin"), progress: nil, elapsed: 0, enabled: true, applicationID: "123", assetKey: "")
    require(activityReceived.wait(timeout: .now() + 2) == .success, "local server did not receive SET_ACTIVITY")
    require(waitUntil { presence.status == "Discord activity sent; waiting for confirmation" }, "a stale Discord error changed the current activity state")
    acknowledge.signal()
    require(waitUntil { presence.status == "Discord activity shared" }, "matching SET_ACTIVITY confirmation did not mark activity shared")
    presence.update(book: BookRecord(id: "smoke", title: "The Dispossessed", author: "Ursula K. Le Guin"), progress: nil, elapsed: 0, enabled: true, applicationID: "123", assetKey: "", paused: true)
    require(waitUntil { presence.status == "Discord activity shared" }, "paused activity acknowledgement did not restore shared status")
    presence.update(book: BookRecord(id: "smoke", title: "The Dispossessed", author: "Ursula K. Le Guin"), progress: nil, elapsed: 0, enabled: true, applicationID: "123", assetKey: "", paused: false)
    require(serverFinished.wait(timeout: .now() + 2) == .success, "paused or resumed state was throttled instead of sent immediately")
    require(serverError == nil, "local server failed: \(String(describing: serverError))")
    require(waitUntil { presence.status == "Discord activity shared" }, "resumed activity acknowledgement did not restore shared status")
    presence.shutdown()
}

private func repeatedClearCheck() throws {
    let (client, server) = try socketPair()
    defer { Darwin.close(server) }
    var suppliedClient = client
    let presence = DiscordPresence(socketOpener: {
        defer { suppliedClient = -1 }
        return suppliedClient
    })
    let activityReceived = DispatchSemaphore(value: 0)
    let serverFinished = DispatchSemaphore(value: 0)
    var serverError: Error?

    DispatchQueue.global().async {
        defer { serverFinished.signal() }
        do {
            _ = try readFrame(from: server)
            try writeFrame(DiscordRPCFrame(opcode: .frame, payload: json(["evt": "READY"])), to: server)
            let activity = try readFrame(from: server)
            try writeFrame(DiscordRPCFrame(opcode: .frame, payload: json(["cmd": "SET_ACTIVITY", "nonce": nonce(in: activity.payload)])), to: server)
            activityReceived.signal()
            let clear = try readFrame(from: server)
            guard try isClearActivity(clear.payload) else { throw SyntheticIPCError.malformedFrame }
            try assertNoFrames(from: server, within: 0.3)
        } catch {
            serverError = error
        }
    }

    presence.update(book: BookRecord(id: "clear", title: "Clear Fixture"), progress: nil, elapsed: 0, enabled: true, applicationID: "123", assetKey: "")
    require(activityReceived.wait(timeout: .now() + 2) == .success, "local server did not receive initial activity")
    require(waitUntil { presence.status == "Discord activity shared" }, "initial activity was not confirmed")
    for _ in 0..<3 {
        presence.update(book: nil, progress: nil, elapsed: 0, enabled: false, applicationID: "123", assetKey: "")
    }
    presence.clear()
    presence.clear()
    require(serverFinished.wait(timeout: .now() + 2) == .success, "local server did not receive the deduplicated clear")
    require(serverError == nil, "repeated clear check failed: \(String(describing: serverError))")
    presence.shutdown()
}

frameParserCheck()
do {
    try activityPayloadCheck()
    try pausedPayloadCheck()
    try pageActivityPayloadCheck()
    try publicCoverReferenceCheck()
    try publicCoverResolverFixtureCheck()
    try localIPCConfirmationCheck()
    try repeatedClearCheck()
    print("discord-smoke: passed")
} catch {
    fputs("discord-smoke: \(error)\n", stderr)
    exit(1)
}
