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

private enum SyntheticIPCError: Error { case systemCallFailed, unexpectedEOF, malformedFrame }

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
        } catch {
            serverError = error
        }
    }

    presence.update(book: BookRecord(id: "smoke", title: "The Dispossessed"), progress: nil, elapsed: 0, enabled: true, applicationID: "123", assetKey: "")
    require(activityReceived.wait(timeout: .now() + 2) == .success, "local server did not receive SET_ACTIVITY")
    require(waitUntil { presence.status == "Discord activity sent; waiting for confirmation" }, "a stale Discord error changed the current activity state")
    acknowledge.signal()
    require(serverFinished.wait(timeout: .now() + 2) == .success, "local server did not finish")
    require(serverError == nil, "local server failed: \(String(describing: serverError))")
    require(waitUntil { presence.status == "Discord activity shared" }, "matching SET_ACTIVITY confirmation did not mark activity shared")
    presence.shutdown()
}

frameParserCheck()
do {
    try activityPayloadCheck()
    try localIPCConfirmationCheck()
    print("discord-smoke: passed")
} catch {
    fputs("discord-smoke: \(error)\n", stderr)
    exit(1)
}
