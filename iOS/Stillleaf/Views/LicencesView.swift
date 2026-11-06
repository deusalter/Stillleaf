import SwiftUI
import UIKit
import BooksPlatform

/// Settings → About → Open-Source Licences: the notices the reader's libraries and fonts require.
struct LicencesView: View {
    var body: some View {
        NoticesText(text: ThirdPartyNotices.text() ?? "The licence notices are missing from this build.")
            .navigationTitle("Open-Source Licences")
            .navigationBarTitleDisplayMode(.inline)
    }
}

/// A text view rather than SwiftUI `Text`, which lays out the whole document up front.
private struct NoticesText: UIViewRepresentable {
    let text: String

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.font = UIFontMetrics(forTextStyle: .footnote).scaledFont(for: .monospacedSystemFont(ofSize: 12, weight: .regular))
        view.adjustsFontForContentSizeCategory = true
        view.textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        view.text = text
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {}
}
