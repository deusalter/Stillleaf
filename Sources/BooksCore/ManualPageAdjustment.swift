import Foundation

/// An explicit additive correction entered by the user. This is kept separate
/// from automatically observed page-turn evidence.
public struct ManualPageAdjustmentEvidence: Codable, Equatable {
    public var pages: Int
    public var recordedAt: Date
    public var reason: String

    public init(pages: Int, recordedAt: Date = Date(), reason: String) {
        self.pages = pages
        self.recordedAt = recordedAt
        self.reason = reason
    }

    func isValid(for eventDate: Date) -> Bool {
        let trimmedReason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        return (1...1_000_000).contains(pages)
            && Self.validDate(eventDate) && Self.validDate(recordedAt) && recordedAt >= eventDate
            && !trimmedReason.isEmpty && reason.count <= 512
            && !reason.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    private static func validDate(_ date: Date) -> Bool {
        let value = date.timeIntervalSince1970
        return value.isFinite && value >= -2_208_988_800 && value <= 7_258_118_400
    }
}
