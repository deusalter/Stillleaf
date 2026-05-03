import XCTest
import Darwin
@testable import BooksPlatform
import BooksCore

final class DiscordPresenceTests: XCTestCase {
    func testFrameParserHandlesPartialHeaderAndPayload() throws {
        let frame = DiscordRPCFrame(opcode: .frame, payload: Data("{\"evt\":\"READY\"}".utf8))
        let encoded = frame.encoded()
        var parser = DiscordRPCFrameParser()

        XCTAssertEqual(parser.append(encoded.prefix(5)), [])
        XCTAssertEqual(parser.append(encoded.dropFirst(5).prefix(6)), [])
        let frames = parser.append(encoded.dropFirst(11))

        XCTAssertEqual(frames, [frame])
    }

    func testFrameParserHandlesPartialChunksContainingMultipleFrames() {
        let first = DiscordRPCFrame(opcode: .ping, payload: Data("one".utf8))
        let second = DiscordRPCFrame(opcode: .pong, payload: Data("two".utf8))
        let wire = first.encoded() + second.encoded()
        var parser = DiscordRPCFrameParser()

        XCTAssertEqual(parser.append(wire.prefix(10)), [])
        XCTAssertEqual(parser.append(wire.dropFirst(10).prefix(7)), [first])
        XCTAssertEqual(parser.append(wire.dropFirst(17)), [second])
    }

    func testActivityPayloadUsesSupportedPlayingTypeAndCreditedElapsed() throws {
        let book = BookRecord(id: "book-1", title: "The Left Hand of Darkness", author: "Ursula K. Le Guin")
        let payload = try DiscordActivityPayload.make(
            book: book,
            progress: ProgressObservation(bookID: book.id, page: 12, totalPages: 286, source: "accessibility", reliable: true),
            elapsed: 125,
            applicationID: "123456",
            assetKey: "books"
        )
        let object = try JSONSerialization.jsonObject(with: payload) as! [String: Any]
        let args = object["args"] as! [String: Any]
        let activity = args["activity"] as! [String: Any]
        let timestamps = activity["timestamps"] as! [String: Int]
        let assets = activity["assets"] as! [String: String]

        XCTAssertEqual(object["cmd"] as? String, "SET_ACTIVITY")
        XCTAssertEqual(activity["type"] as? Int, 0)
        XCTAssertEqual(activity["details"] as? String, "Reading The Left Hand of Darkness")
        XCTAssertEqual(activity["state"] as? String, "Ursula K. Le Guin • Page 12 of 286")
        XCTAssertNil(activity["party"])
        XCTAssertEqual(assets["large_image"], "books")
        XCTAssertLessThanOrEqual(Date().timeIntervalSince1970 - Double(timestamps["start"]!), 126)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince1970 - Double(timestamps["start"]!), 124)
    }

    func testActivityPayloadOmitsUnreliableProgressAndEmptyArtwork() throws {
        let book = BookRecord(id: "book-1", title: "A Book")
        let payload = try DiscordActivityPayload.make(
            book: book,
            progress: ProgressObservation(bookID: book.id, page: 12, totalPages: 286, source: "accessibility", reliable: false),
            elapsed: 10,
            applicationID: "123456",
            assetKey: ""
        )
        let object = try JSONSerialization.jsonObject(with: payload) as! [String: Any]
        let activity = ((object["args"] as! [String: Any])["activity"] as! [String: Any])

        XCTAssertNil(activity["assets"])
        XCTAssertNil(activity["state"])
        XCTAssertEqual(activity["details"] as? String, "Reading A Book")
    }

    func testClearPayloadSetsActivityToNull() throws {
        let object = try JSONSerialization.jsonObject(with: DiscordActivityPayload.clear()) as! [String: Any]
        let args = object["args"] as! [String: Any]
        XCTAssertEqual(object["cmd"] as? String, "SET_ACTIVITY")
        XCTAssertTrue(args["activity"] is NSNull)
    }

    func testActivityIsNotSharedUntilMatchingConfirmationArrives() throws {
        let (client, server) = try socketPair()
        defer { Darwin.close(server) }
        var suppliedClient = client
        let presence = DiscordPresence(socketOpener: {
            defer { suppliedClient = -1 }
            return suppliedClient
        })
        let activityReceived = expectation(description: "activity received")
        let serverFinished = expectation(description: "server finished")
        let releaseAcknowledgement = DispatchSemaphore(value: 0)
        var serverError: Error?

        DispatchQueue.global().async {
            defer { serverFinished.fulfill() }
            do {
                _ = try readFrame(from: server)
                try writeFrame(DiscordRPCFrame(opcode: .frame, payload: json(["evt": "READY"])), to: server)
                let activity = try readFrame(from: server)
                let nonce = try nonce(in: activity.payload)
                try writeFrame(DiscordRPCFrame(opcode: .frame, payload: json([
                    "evt": "ERROR",
                    "nonce": "stale-request",
                    "data": ["message": "Old request failed"]
                ])), to: server)
                activityReceived.fulfill()
                guard releaseAcknowledgement.wait(timeout: .now() + 2) == .success else { return }
                try writeFrame(DiscordRPCFrame(opcode: .frame, payload: json(["cmd": "SET_ACTIVITY", "nonce": nonce])), to: server)
            } catch {
                serverError = error
            }
        }

        presence.update(book: BookRecord(id: "book", title: "A Book"), progress: nil, elapsed: 0, enabled: true, applicationID: "123", assetKey: "")
        wait(for: [activityReceived], timeout: 2)
        XCTAssertTrue(waitUntil { presence.status == "Discord activity sent; waiting for confirmation" })

        releaseAcknowledgement.signal()
        wait(for: [serverFinished], timeout: 2)
        XCTAssertNil(serverError)
        XCTAssertTrue(waitUntil { presence.status == "Discord activity shared" })
        presence.shutdown()
    }

    func testErrorAndCloseKeepSafeDiagnosticsUntilTheNextAttempt() throws {
        let (client, server) = try socketPair()
        defer { Darwin.close(server) }
        var suppliedClient = client
        let presence = DiscordPresence(socketOpener: {
            defer { suppliedClient = -1 }
            return suppliedClient
        })
        let activityReceived = expectation(description: "activity received")
        let serverFinished = expectation(description: "server finished")
        let releaseClose = DispatchSemaphore(value: 0)
        var serverError: Error?

        DispatchQueue.global().async {
            defer { serverFinished.fulfill() }
            do {
                _ = try readFrame(from: server)
                try writeFrame(DiscordRPCFrame(opcode: .frame, payload: json(["evt": "READY"])), to: server)
                _ = try readFrame(from: server)
                activityReceived.fulfill()
                try writeFrame(DiscordRPCFrame(opcode: .frame, payload: json(["evt": "ERROR", "data": ["message": "Invalid\tactivity\n"]])), to: server)
                guard releaseClose.wait(timeout: .now() + 2) == .success else { return }
                try writeFrame(DiscordRPCFrame(opcode: .close, payload: json(["message": "Session ended"])), to: server)
            } catch {
                serverError = error
            }
        }

        presence.update(book: BookRecord(id: "book", title: "A Book"), progress: nil, elapsed: 0, enabled: true, applicationID: "123", assetKey: "")
        wait(for: [activityReceived], timeout: 2)
        XCTAssertTrue(waitUntil { presence.status == "Discord rejected activity: Invalidactivity" })

        releaseClose.signal()
        wait(for: [serverFinished], timeout: 2)
        XCTAssertNil(serverError)
        XCTAssertTrue(waitUntil { presence.status == "Discord connection closed: Session ended" })
        presence.shutdown()
    }

    func testDiscordSocketsSuppressSigpipeAndUseNonblockingWrites() throws {
        let (client, server) = try socketPair()
        defer { Darwin.close(client); Darwin.close(server) }

        XCTAssertTrue(configureDiscordSocket(client))
        var noSigPipe: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        XCTAssertEqual(Darwin.getsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, &length), 0)
        XCTAssertEqual(noSigPipe, 1)
        XCTAssertNotEqual(fcntl(client, F_GETFL) & O_NONBLOCK, 0)
    }
}

private enum SyntheticIPCError: Error { case systemCallFailed, unexpectedEOF, malformedFrame }

private func socketPair() throws -> (Int32, Int32) {
    var descriptors = [Int32](repeating: -1, count: 2)
    guard Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else { throw SyntheticIPCError.systemCallFailed }
    return (descriptors[0], descriptors[1])
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
