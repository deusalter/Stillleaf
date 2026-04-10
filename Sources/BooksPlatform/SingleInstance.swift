import Foundation
import Darwin

public final class SingleInstance {
    private let fileDescriptor: Int32

    public init(lockURL: URL) throws {
        let parent = lockURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let descriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EWOULDBLOCK)
            Darwin.close(descriptor)
            throw error
        }
        fileDescriptor = descriptor
    }

    deinit { Darwin.close(fileDescriptor) }
}
