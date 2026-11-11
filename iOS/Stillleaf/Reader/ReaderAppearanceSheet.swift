import SwiftUI

/// Themes & Settings: text size, page theme, paging and type. Every control is one the renderer
/// describes, so the choices are the Mac reader's; changes show on the page behind the sheet at once.
/// The appearance chosen here is also what a book opened for the first time starts with.
struct ReaderAppearanceSheet: View {
    @ObservedObject var chrome: ReaderChrome
    /// On a wide screen a half-height sheet is a small card that cuts the themes off; there it opens at full height.
    var wide = false

    private let columns = [GridItem(.adaptive(minimum: 96, maximum: 160), spacing: 12)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    textSize
                    themes
                    reading
                    Button("Reset to Defaults") { chrome.resetAppearance() }
                        .frame(maxWidth: .infinity)
                    Text("Your choices are kept for this book, and new books start with them.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .multilineTextAlignment(.center)
                }
                .padding(20)
            }
            .navigationTitle("Themes & Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { chrome.sheet = nil } }
            }
        }
        .presentationDetents(wide ? [.large] : [.medium, .large])
        .presentationDragIndicator(.visible)
    }

    @ViewBuilder
    private var themes: some View {
        if let options = chrome.control("theme")?.options {
            VStack(alignment: .leading, spacing: 10) {
                heading("Theme")
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(options) { option in
                        ThemeSwatch(option: option, selected: chrome.isSelected(option, for: "theme")) {
                            chrome.choose(option, for: "theme")
                        }
                    }
                }
            }
        }
    }

    private var reading: some View {
        VStack(alignment: .leading, spacing: 10) {
            heading("Reading")
            VStack(spacing: 0) {
                Picker("Page turning", selection: flag("scroll")) {
                    Text("Pages").tag(false)
                    Text("Scroll").tag(true)
                }
                .pickerStyle(.segmented)
                .padding(12)
                if let options = chrome.control("fontFamily")?.options {
                    rule
                    menuRow("Font", options: options, key: "fontFamily")
                }
                if let options = chrome.control("margins")?.options {
                    rule
                    menuRow("Margins", options: options, key: "margins")
                }
                if let spacing = chrome.control("lineHeight"), let low = spacing.min, let high = spacing.max {
                    rule
                    lineSpacing(low: low, high: Swift.max(high, low + 0.05))
                }
                rule
                Toggle("Bold Text", isOn: bold).padding(.horizontal, 16).padding(.vertical, 8)
                rule
                Toggle("Justify Text", isOn: justified).padding(.horizontal, 16).padding(.vertical, 8)
            }
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    private var rule: some View { Divider().padding(.leading, 16) }

    private var bold: Binding<Bool> {
        Binding(get: { (chrome.number("fontWeight") ?? 400) >= 600 },
                set: { chrome.set("fontWeight", $0 ? 700 as Any : NSNull() as Any) })
    }

    private var justified: Binding<Bool> {
        Binding(get: { chrome.preferences["textAlign"] as? String == "justify" },
                set: { chrome.set("textAlign", $0 ? "justify" : "publisher") })
    }

    private func lineSpacing(low: Double, high: Double) -> some View {
        let value = Binding<Double>(get: { chrome.number("lineHeight") ?? low },
                                    set: { chrome.set("lineHeight", ($0 * 20).rounded() / 20) })
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Line Spacing")
                Spacer()
                Text(value.wrappedValue.formatted(.number.precision(.fractionLength(2))))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: low...high).accessibilityLabel("Line Spacing")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    /// A small A, the current size, a large A: the two-button size control readers know from Books.
    private var textSize: some View {
        let size = chrome.number("fontSize") ?? 1
        let control = chrome.control("fontSize")
        return HStack(spacing: 0) {
            Button { chrome.step("fontSize", by: -0.05) } label: {
                Text("A").font(.system(size: 16, weight: .medium, design: .serif)).frame(maxWidth: .infinity, minHeight: 52)
                    .contentShape(Rectangle())
            }
            .disabled(size <= (control?.min ?? 0.5))
            .accessibilityLabel("Smaller Text")
            Divider().frame(height: 24)
            Text("\(Int((size * 100).rounded()))%")
                .font(.subheadline.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 76)
                .accessibilityLabel("Text size \(Int((size * 100).rounded())) percent")
            Divider().frame(height: 24)
            Button { chrome.step("fontSize", by: 0.05) } label: {
                Text("A").font(.system(size: 26, weight: .medium, design: .serif)).frame(maxWidth: .infinity, minHeight: 52)
                    .contentShape(Rectangle())
            }
            .disabled(size >= (control?.max ?? 3))
            .accessibilityLabel("Larger Text")
        }
        .buttonStyle(.plain)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func heading(_ text: String) -> some View {
        Text(text).font(.footnote.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
    }

    private func flag(_ key: String) -> Binding<Bool> {
        Binding(get: { chrome.flag(key) }, set: { chrome.set(key, $0) })
    }

    private func menuRow(_ title: String, options: [ReaderControl.Option], key: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Picker(title, selection: Binding(get: { chrome.encoded(key) }, set: { value in
                if let option = options.first(where: { $0.value == value }) { chrome.choose(option, for: key) }
            })) {
                ForEach(options) { Text($0.label).tag($0.value) }
            }
            .pickerStyle(.menu)
            .labelsHidden()
        }
        .padding(.leading, 16).padding(.trailing, 6).padding(.vertical, 4)
    }
}

/// One page theme, drawn in its own colours. The System theme shows its day and night pages together.
private struct ThemeSwatch: View {
    let option: ReaderControl.Option
    let selected: Bool
    let choose: () -> Void

    var body: some View {
        let page = Color(hex: option.background) ?? Color.white
        let ink = Color(hex: option.text) ?? Color.black
        Button(action: choose) {
            VStack(spacing: 6) {
                ZStack {
                    if let night = Color(hex: option.alternate) {
                        LinearGradient(stops: [.init(color: page, location: 0.5), .init(color: night, location: 0.5)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
                    } else {
                        page
                    }
                    Text("Aa").font(.system(size: 22, weight: .medium, design: .serif)).foregroundStyle(ink)
                }
                .frame(height: 62)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.14), lineWidth: selected ? 2.5 : 1)
                }
                Text(option.label)
                    .font(.caption.weight(selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Color.primary : Color.secondary)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(option.label + " theme")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
