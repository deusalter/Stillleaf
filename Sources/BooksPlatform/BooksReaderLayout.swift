import Foundation
import BooksCore

/// Books 8.0's WebAreas describe chapter content, not stable reader bounds.
/// Their count and width can change during an ordinary page turn. The enclosing
/// reader host and window define geometry; the footer supplies pagination.
enum BooksReaderLayout {
    static func position(page: Int, totalPages: Int?, windowSize: CGSize, readerSize: CGSize,
                         paneSizes: [CGSize]) -> ReaderPagePosition? {
        guard validSize(windowSize), validSize(readerSize),
              (1...2).contains(paneSizes.count), paneSizes.allSatisfy(validSize) else { return nil }
        // Chapter-container count does not prove how many pages one navigation
        // reveals. Use the conservative capacity; count the actual footer delta.
        return ReaderPagePosition(page: page, visiblePages: 1,
            layoutSignature: "books8-host:\(sizeSignature(windowSize)):\(sizeSignature(readerSize))",
            totalPages: totalPages)
    }

    static func validSize(_ size: CGSize) -> Bool {
        size.width.isFinite && size.height.isFinite && size.width > 0 && size.height > 0
            && size.width < 100_000 && size.height < 100_000
    }

    private static func sizeSignature(_ size: CGSize) -> String {
        "\(Int(size.width.rounded()))x\(Int(size.height.rounded()))"
    }
}
