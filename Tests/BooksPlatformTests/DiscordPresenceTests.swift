import XCTest
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
}
