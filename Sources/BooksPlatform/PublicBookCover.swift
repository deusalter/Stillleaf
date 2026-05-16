import Foundation

/// Produces a Discord activity image reference without reading or uploading any
/// local artwork. Discord retrieves a returned HTTPS URL itself.
public enum PublicBookCover {
    private static let imageExtensions: Set<String> = ["gif", "jpeg", "jpg", "png", "webp"]

    static func assetReference(coverURL: String?, assetKey: String) -> String? {
        if let coverURL, let validated = publicImageURL(coverURL) { return validated }
        return uploadedAssetKey(assetKey)
    }

    public static func publicImageURL(_ candidate: String) -> String? {
        let value = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, let components = URLComponents(string: value) else { return nil }
        let imageExtension = URL(fileURLWithPath: components.path).pathExtension.lowercased()
        guard
              components.scheme?.lowercased() == "https",
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              let host = components.host?.lowercased(),
              isPublicHostname(host),
              imageExtensions.contains(imageExtension),
              let url = components.url else { return nil }
        return url.absoluteString
    }

    static func uploadedAssetKey(_ candidate: String) -> String? {
        let key = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty,
              key.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-" )).contains($0) }) else { return nil }
        return key
    }

    private static func isPublicHostname(_ host: String) -> Bool {
        guard host.count <= 253,
              host.contains("."),
              !host.hasPrefix("."), !host.hasSuffix("."), !host.contains(":"), !host.hasPrefix("0x"),
              host != "localhost", !host.hasSuffix(".localhost"), !host.hasSuffix(".local"), !host.hasSuffix(".internal") else { return false }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2,
              labels.allSatisfy({ label in
                  guard !label.isEmpty, label.utf8.count <= 63,
                        label.first != "-", label.last != "-" else { return false }
                  return label.unicodeScalars.allSatisfy {
                      CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-")).contains($0) && $0.isASCII
                  }
              }),
              !labels.allSatisfy({ $0.allSatisfy(\.isNumber) }) else { return false }
        // Require a well-formed DNS name, rather than allowing literal addresses
        // that could identify loopback or private network resources. This does
        // not resolve the hostname, so validation never fetches a cover.
        return true
    }
}
