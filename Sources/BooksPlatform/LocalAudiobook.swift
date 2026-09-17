import Foundation
import AVFoundation
import BooksCore

public enum LocalAudiobook {
    public static let extensions = ["mp3", "m4a", "m4b", "aac", "wav", "aif", "aiff", "caf"]
    public struct Imported {
        public let fileName: String
        public let duration: Double
    }

    /// Copies only an explicitly selected local file. Decoding the copy verifies its
    /// codec and rejects protected/corrupt media before any journal metadata is saved.
    public static func copy(from source: URL, to directory: URL) throws -> Imported {
        guard source.isFileURL, extensions.contains(source.pathExtension.lowercased()) else {
            throw ReadingStoreError.invalidData("Choose a local MP3, M4A, M4B, AAC, WAV, AIFF, or CAF file.")
        }
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        let values = try source.resourceValues(forKeys: [.isRegularFileKey])
        guard values.isRegularFile == true else { throw ReadingStoreError.invalidData("Choose a regular audio file.") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fileName = UUID().uuidString + "." + source.pathExtension.lowercased()
        let destination = directory.appendingPathComponent(fileName)
        do {
            try FileManager.default.copyItem(at: source, to: destination)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            let player = try AVAudioPlayer(contentsOf: destination)
            guard player.duration.isFinite, player.duration > 0, player.prepareToPlay() else {
                throw ReadingStoreError.invalidData("This audio file cannot be decoded. Use an unprotected, supported audio file.")
            }
            return Imported(fileName: fileName, duration: player.duration)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }
}
