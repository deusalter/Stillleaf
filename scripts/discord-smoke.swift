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

frameParserCheck()
do {
    try activityPayloadCheck()
    print("discord-smoke: passed")
} catch {
    fputs("discord-smoke: \(error)\n", stderr)
    exit(1)
}
