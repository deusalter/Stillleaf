import AppKit
import SwiftUI

// The lists in the reader's Contents, Bookmarks, Notes and Search panels. They are a real
// NSOutlineView, so arrow keys, type-to-select, disclosure triangles and VoiceOver's outline
// navigation are the system's own. Only the row drawing is themed, to match the Appearance panel.

/// One row of a reader panel list, decoded from the rows the renderer sends.
final class ReaderRow: NSObject {
    enum Kind { case outline, bookmark, note, result }
    let kind: Kind
    let id: String
    var title = "", detail = "", quote = "", note = "", before = "", match = "", after = "", chapter = ""
    var color: NSColor?
    var current = false
    var openable = true
    var isGroup = false
    var children: [ReaderRow] = []

    init(kind: Kind, id: String) { self.kind = kind; self.id = id }

    /// The kind name the renderer's `go` and `remove` commands use.
    var wireKind: String {
        switch kind {
        case .outline: return "outline"
        case .bookmark: return "bookmark"
        case .note: return "note"
        case .result: return "result"
        }
    }

    static func outline(_ raw: [[String: Any]]) -> [ReaderRow] {
        raw.compactMap { item in
            guard let id = item["id"] as? String else { return nil }
            let row = ReaderRow(kind: .outline, id: id)
            row.title = item["title"] as? String ?? ""
            row.current = item["current"] as? Bool ?? false
            row.openable = item["openable"] as? Bool ?? true
            row.isGroup = item["group"] as? Bool ?? false
            row.children = outline(item["children"] as? [[String: Any]] ?? [])
            return row
        }
    }

    static func bookmarks(_ raw: [[String: Any]]) -> [ReaderRow] {
        raw.compactMap { item in
            guard let id = item["id"] as? String else { return nil }
            let row = ReaderRow(kind: .bookmark, id: id)
            row.title = item["title"] as? String ?? ""
            row.detail = (item["detail"] as? String).flatMap(dateText) ?? ""
            return row
        }
    }

    static func notes(_ raw: [[String: Any]]) -> [ReaderRow] {
        raw.compactMap { item in
            guard let id = item["id"] as? String else { return nil }
            let row = ReaderRow(kind: .note, id: id)
            row.quote = item["quote"] as? String ?? ""
            row.note = item["note"] as? String ?? ""
            row.color = (item["color"] as? String).flatMap(colorFromHex)
            return row
        }
    }

    static func results(_ raw: [[String: Any]]) -> [ReaderRow] {
        raw.compactMap { item in
            guard let id = item["id"] as? String else { return nil }
            let row = ReaderRow(kind: .result, id: id)
            row.before = item["before"] as? String ?? ""
            row.match = item["match"] as? String ?? ""
            row.after = item["after"] as? String ?? ""
            row.chapter = item["chapter"] as? String ?? ""
            return row
        }
    }

    /// The text VoiceOver reads for the whole row.
    var spokenText: String {
        switch kind {
        case .outline: return title
        case .bookmark: return detail.isEmpty ? title : "\(title), \(detail)"
        case .note: return note.isEmpty ? "Highlight: \(quote)" : "Highlight: \(quote). Note: \(note)"
        case .result: return "\(before)\(match)\(after), in \(chapter)"
        }
    }

    private static func dateText(_ iso: String) -> String? {
        let plain = ISO8601DateFormatter(), fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = plain.date(from: iso) ?? fractional.date(from: iso) else { return nil }
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMMd")
        return formatter.string(from: date)
    }

    private static func colorFromHex(_ hex: String) -> NSColor? {
        guard hex.hasPrefix("#"), hex.count == 7, let value = UInt32(hex.dropFirst(), radix: 16) else { return nil }
        return NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255, green: CGFloat((value >> 8) & 255) / 255, blue: CGFloat(value & 255) / 255, alpha: 1)
    }
}

enum ReaderRowMetrics {
    static let outlineHeight: CGFloat = 30
    static let bookmarkHeight: CGFloat = 46
    static let inset: CGFloat = 12
    static let bodyFont = NSFont.systemFont(ofSize: 13)
    static let noteFont = NSFont.systemFont(ofSize: 12)
    static let captionFont = NSFont.systemFont(ofSize: 11)

    static func lineHeight(_ font: NSFont) -> CGFloat { ceil(NSLayoutManager().defaultLineHeight(for: font)) }

    /// How many lines `text` takes at `width`, never more than `limit`.
    static func lines(_ text: String, font: NSFont, width: CGFloat, limit: Int) -> Int {
        guard !text.isEmpty, width > 0 else { return 0 }
        let rect = (text as NSString).boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude),
                                                   options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font])
        return min(limit, max(1, Int(ceil(rect.height / lineHeight(font)))))
    }

    /// Row height for the text width left after indentation, disclosure and padding.
    static func height(for row: ReaderRow, textWidth: CGFloat) -> CGFloat {
        switch row.kind {
        case .outline: return row.isGroup ? 34 : outlineHeight
        case .bookmark: return bookmarkHeight
        case .note:
            let width = textWidth - 12
            let quote = lines(row.quote, font: bodyFont, width: width, limit: 3)
            let note = lines(row.note, font: noteFont, width: width, limit: 3)
            return 10 + CGFloat(quote) * lineHeight(bodyFont) + (note > 0 ? 4 + CGFloat(note) * lineHeight(noteFont) : 0) + 6 + 18 + 8
        case .result:
            let lines = lines(row.before + row.match + row.after, font: bodyFont, width: textWidth, limit: 3)
            return 8 + CGFloat(lines) * lineHeight(bodyFont) + 3 + lineHeight(captionFont) + 8
        }
    }
}

// MARK: - Row and cell views

/// Draws a row's hover and selection like the Appearance panel's segmented choices, and the current-chapter bar.
final class ReaderListRowView: NSTableRowView {
    var palette = ReaderPanelPalette(appearance: [:])
    var isCurrent = false
    private var hovered = false { didSet { if hovered != oldValue { needsDisplay = true; refreshAccessories() } } }
    override var isSelected: Bool { didSet { if isSelected != oldValue { refreshAccessories() } } }

    override func drawSelection(in dirtyRect: NSRect) {}
    override func drawBackground(in dirtyRect: NSRect) {
        let area = bounds.insetBy(dx: 6, dy: 1)
        let path = NSBezierPath(roundedRect: area, xRadius: 8, yRadius: 8)
        if isSelected { palette.nsSelected.setFill(); path.fill() }
        else if hovered { palette.nsHover.setFill(); path.fill() }
        if isCurrent {
            palette.nsAccent.setFill()
            NSBezierPath(roundedRect: NSRect(x: area.minX, y: area.minY + 6, width: 3, height: max(0, area.height - 12)), xRadius: 1.5, yRadius: 1.5).fill()
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }

    private func refreshAccessories() { (subviews.first as? ReaderListCell)?.setEmphasis(hovered || isSelected) }
}

final class ReaderListCell: NSTableCellView {
    private let primary = ReaderListCell.label(), secondary = ReaderListCell.label()
    private let bar = NSView()
    private let edit = NSButton(), remove = NSButton()
    private var row: ReaderRow?
    var onEdit: (() -> Void)?
    var onRemove: (() -> Void)?
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        bar.wantsLayer = true
        bar.layer?.cornerRadius = 1.5
        for button in [edit, remove] {
            button.isBordered = false
            button.target = self
            button.setButtonType(.momentaryChange)
        }
        edit.action = #selector(editTapped)
        edit.font = ReaderRowMetrics.captionFont
        edit.alignment = .left
        remove.action = #selector(removeTapped)
        remove.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: nil)
        remove.imagePosition = .imageOnly
        remove.imageScaling = .scaleProportionallyDown
        [bar, primary, secondary, edit, remove].forEach(addSubview)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private static func label() -> NSTextField {
        let field = NSTextField(labelWithString: "")
        field.isEditable = false; field.isSelectable = false; field.drawsBackground = false; field.isBordered = false
        field.lineBreakMode = .byTruncatingTail
        field.cell?.truncatesLastVisibleLine = true
        return field
    }

    func configure(_ row: ReaderRow, palette: ReaderPanelPalette) {
        self.row = row
        let ink = palette.nsInk, secondaryInk = palette.nsSecondary
        bar.isHidden = true; edit.isHidden = true; remove.isHidden = true; secondary.isHidden = true
        primary.maximumNumberOfLines = 1; primary.lineBreakMode = .byTruncatingTail
        switch row.kind {
        case .outline:
            if row.isGroup {
                primary.attributedStringValue = NSAttributedString(string: row.title.uppercased(), attributes: [
                    .font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: secondaryInk, .kern: 0.8])
            } else {
                primary.attributedStringValue = NSAttributedString(string: row.title, attributes: [
                    .font: row.current ? NSFont.systemFont(ofSize: 13, weight: .semibold) : ReaderRowMetrics.bodyFont, .foregroundColor: ink])
            }
        case .bookmark:
            primary.attributedStringValue = NSAttributedString(string: row.title, attributes: [.font: ReaderRowMetrics.bodyFont, .foregroundColor: ink])
            secondary.attributedStringValue = NSAttributedString(string: row.detail, attributes: [.font: ReaderRowMetrics.captionFont, .foregroundColor: secondaryInk])
            secondary.isHidden = row.detail.isEmpty
            remove.isHidden = false
            style(remove, tint: secondaryInk, label: "Remove bookmark: \(row.title)")
        case .note:
            bar.isHidden = false
            bar.layer?.backgroundColor = (row.color ?? palette.nsAccent).cgColor
            primary.maximumNumberOfLines = 3; primary.lineBreakMode = .byTruncatingTail
            primary.attributedStringValue = NSAttributedString(string: "“\(row.quote)”", attributes: [.font: ReaderRowMetrics.bodyFont, .foregroundColor: ink])
            secondary.maximumNumberOfLines = 3; secondary.lineBreakMode = .byTruncatingTail
            secondary.attributedStringValue = NSAttributedString(string: row.note, attributes: [.font: ReaderRowMetrics.noteFont, .foregroundColor: secondaryInk])
            secondary.isHidden = row.note.isEmpty
            edit.isHidden = false; remove.isHidden = false
            edit.attributedTitle = NSAttributedString(string: row.note.isEmpty ? "Add a note" : "Edit note", attributes: [.font: ReaderRowMetrics.captionFont, .foregroundColor: palette.nsAccent])
            edit.setAccessibilityLabel(row.note.isEmpty ? "Add a note to: \(row.quote)" : "Edit note on: \(row.quote)")
            style(remove, tint: secondaryInk, label: "Remove highlight: \(row.quote)")
        case .result:
            primary.maximumNumberOfLines = 3
            let text = NSMutableAttributedString(string: row.before, attributes: [.font: ReaderRowMetrics.bodyFont, .foregroundColor: ink])
            text.append(NSAttributedString(string: row.match, attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: ink,
                                                                           .backgroundColor: palette.nsAccent.withAlphaComponent(0.28)]))
            text.append(NSAttributedString(string: row.after, attributes: [.font: ReaderRowMetrics.bodyFont, .foregroundColor: ink]))
            primary.attributedStringValue = text
            secondary.attributedStringValue = NSAttributedString(string: row.chapter, attributes: [.font: ReaderRowMetrics.captionFont, .foregroundColor: secondaryInk])
            secondary.isHidden = false
        }
        setEmphasis(false)
        // The row speaks as one element; its buttons stay reachable as children.
        setAccessibilityElement(true)
        setAccessibilityLabel(row.spokenText)
        setAccessibilityChildren([edit, remove].filter { !$0.isHidden })
        needsLayout = true
    }

    private func style(_ button: NSButton, tint: NSColor, label: String) {
        button.contentTintColor = tint
        button.setAccessibilityLabel(label)
        button.toolTip = label
    }

    /// Row actions show on hover or selection, and stay in the accessibility tree.
    func setEmphasis(_ on: Bool) { remove.alphaValue = on ? 1 : 0.45 }

    @objc private func editTapped() { onEdit?() }
    @objc private func removeTapped() { onRemove?() }

    override func layout() {
        super.layout()
        guard let row else { return }
        let width = bounds.width, pad = ReaderRowMetrics.inset
        let bodyHeight = ReaderRowMetrics.lineHeight(ReaderRowMetrics.bodyFont)
        switch row.kind {
        case .outline:
            primary.frame = NSRect(x: 4, y: (bounds.height - bodyHeight) / 2, width: max(0, width - 12), height: bodyHeight)
        case .bookmark:
            primary.frame = NSRect(x: 4, y: 7, width: max(0, width - 40), height: bodyHeight)
            secondary.frame = NSRect(x: 4, y: 7 + bodyHeight + 1, width: max(0, width - 40), height: ReaderRowMetrics.lineHeight(ReaderRowMetrics.captionFont))
            remove.frame = NSRect(x: width - 30, y: (bounds.height - 22) / 2, width: 22, height: 22)
        case .note:
            let textWidth = max(0, width - pad - 8)
            let quoteLines = ReaderRowMetrics.lines(primary.stringValue, font: ReaderRowMetrics.bodyFont, width: textWidth, limit: 3)
            let noteLines = ReaderRowMetrics.lines(row.note, font: ReaderRowMetrics.noteFont, width: textWidth, limit: 3)
            let quoteHeight = CGFloat(quoteLines) * bodyHeight
            primary.frame = NSRect(x: pad, y: 10, width: textWidth, height: quoteHeight)
            var y = 10 + quoteHeight
            if noteLines > 0 {
                let noteHeight = CGFloat(noteLines) * ReaderRowMetrics.lineHeight(ReaderRowMetrics.noteFont)
                secondary.frame = NSRect(x: pad, y: y + 4, width: textWidth, height: noteHeight)
                y += 4 + noteHeight
            }
            edit.frame = NSRect(x: pad, y: y + 6, width: 120, height: 18)
            remove.frame = NSRect(x: width - 30, y: y + 4, width: 22, height: 22)
            bar.frame = NSRect(x: 2, y: 10, width: 3, height: max(0, bounds.height - 20))
        case .result:
            let textWidth = max(0, width - 8)
            let lines = ReaderRowMetrics.lines(row.before + row.match + row.after, font: ReaderRowMetrics.bodyFont, width: textWidth, limit: 3)
            let height = CGFloat(lines) * bodyHeight
            primary.frame = NSRect(x: 4, y: 8, width: textWidth, height: height)
            secondary.frame = NSRect(x: 4, y: 8 + height + 3, width: textWidth, height: ReaderRowMetrics.lineHeight(ReaderRowMetrics.captionFont))
        }
    }
}

// MARK: - The outline list

final class ReaderOutlineView: NSOutlineView {
    var onActivate: ((ReaderRow) -> Void)?
    var onDelete: ((ReaderRow) -> Void)?
    var selectedItemRow: ReaderRow? { selectedRow >= 0 ? item(atRow: selectedRow) as? ReaderRow : nil }

    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76:   // Return, Enter
            if let row = selectedItemRow { onActivate?(row); return }
        case 51, 117:  // Delete, Forward Delete
            if let row = selectedItemRow, row.kind == .bookmark || row.kind == .note { onDelete?(row); return }
        default: break
        }
        super.keyDown(with: event)
    }
}

struct ReaderRowList: NSViewRepresentable {
    let rows: [ReaderRow]
    /// Bumped whenever `rows` is replaced, so the list reloads once rather than on every redraw.
    let revision: Int
    let palette: ReaderPanelPalette
    let accessibilityTitle: String
    var width: CGFloat = 360
    /// Take keyboard focus whenever the rows are replaced. The search panel leaves focus in its field instead.
    var focusOnLoad = true
    /// Move keyboard focus to the list whenever this changes.
    var focusToken = 0
    let open: (ReaderRow) -> Void
    var remove: ((ReaderRow) -> Void)?
    var edit: ((ReaderRow) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let outline = ReaderOutlineView()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("reader-row"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.backgroundColor = .clear
        outline.selectionHighlightStyle = .none
        outline.focusRingType = .none
        outline.indentationPerLevel = 14
        outline.intercellSpacing = .zero
        outline.rowSizeStyle = .custom
        outline.usesAutomaticRowHeights = false
        outline.autoresizesOutlineColumn = false
        outline.allowsEmptySelection = true
        outline.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        if #available(macOS 11.0, *) { outline.style = .plain }
        outline.dataSource = context.coordinator
        outline.delegate = context.coordinator
        outline.target = context.coordinator
        outline.action = #selector(Coordinator.clicked(_:))
        outline.onActivate = { [weak coordinator = context.coordinator] row in coordinator?.activate(row) }
        outline.onDelete = { [weak coordinator = context.coordinator] row in coordinator?.parent.remove?(row) }
        outline.setAccessibilityLabel(accessibilityTitle)
        context.coordinator.outline = outline

        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.borderType = .noBorder
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 2, left: 0, bottom: 8, right: 0)
        scroll.setAccessibilityLabel(accessibilityTitle)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        guard let outline = coordinator.outline else { return }
        if coordinator.revision != revision {
            coordinator.revision = revision
            outline.reloadData()
            for row in rows where !row.children.isEmpty && !row.isGroup { outline.expandItem(row, expandChildren: true) }
            if let target = coordinator.firstRow(where: { $0.current }) ?? rows.first {
                let index = outline.row(forItem: target)
                if index >= 0 { outline.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false); outline.scrollRowToVisible(index) }
            }
            if focusOnLoad { coordinator.focus() }
        } else if coordinator.focusToken != focusToken {
            coordinator.focus()
        }
        coordinator.focusToken = focusToken
    }

    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
        var parent: ReaderRowList
        weak var outline: ReaderOutlineView?
        var revision = -1
        var focusToken = 0
        init(_ parent: ReaderRowList) { self.parent = parent; focusToken = parent.focusToken }

        func firstRow(where match: (ReaderRow) -> Bool) -> ReaderRow? {
            func walk(_ rows: [ReaderRow]) -> ReaderRow? {
                for row in rows { if match(row) { return row }; if let found = walk(row.children) { return found } }
                return nil
            }
            return walk(parent.rows)
        }

        func focus() {
            DispatchQueue.main.async { [weak self] in
                guard let outline = self?.outline, let window = outline.window else { return }
                window.makeFirstResponder(outline)
            }
        }

        func activate(_ row: ReaderRow) {
            if !row.children.isEmpty && (row.isGroup || !row.openable) {
                guard let outline else { return }
                if outline.isItemExpanded(row) { outline.collapseItem(row) } else { outline.expandItem(row) }
            } else if row.openable {
                parent.open(row)
            }
        }

        @objc func clicked(_ sender: NSOutlineView) {
            guard sender.clickedRow >= 0, let row = sender.item(atRow: sender.clickedRow) as? ReaderRow else { return }
            activate(row)
        }

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int { (item as? ReaderRow)?.children.count ?? parent.rows.count }
        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any { ((item as? ReaderRow)?.children ?? parent.rows)[index] }
        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { !((item as? ReaderRow)?.children.isEmpty ?? true) }

        func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
            guard let row = item as? ReaderRow else { return ReaderRowMetrics.outlineHeight }
            let indent = CGFloat(outlineView.level(forItem: row)) * outlineView.indentationPerLevel + (row.children.isEmpty ? 0 : 16)
            return ReaderRowMetrics.height(for: row, textWidth: parent.width - 20 - indent - ReaderRowMetrics.inset)
        }

        func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
            guard let row = item as? ReaderRow else { return nil }
            let view = ReaderListRowView()
            view.palette = parent.palette
            view.isCurrent = row.current
            return view
        }

        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let row = item as? ReaderRow else { return nil }
            let cell = ReaderListCell()
            cell.configure(row, palette: parent.palette)
            cell.onEdit = { [weak self] in self?.parent.edit?(row) }
            cell.onRemove = { [weak self] in self?.parent.remove?(row) }
            return cell
        }

        func outlineView(_ outlineView: NSOutlineView, typeSelectStringFor tableColumn: NSTableColumn?, item: Any) -> String? {
            guard let row = item as? ReaderRow else { return nil }
            return row.kind == .note ? row.quote : row.kind == .result ? row.before + row.match + row.after : row.title
        }
    }
}

// MARK: - Search field

/// The system search field, with Return, Down Arrow and Escape wired to the panel.
struct ReaderSearchField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let onSubmit: () -> Void
    let onMoveDown: () -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = placeholder
        field.sendsSearchStringImmediately = true
        field.sendsWholeSearchString = false
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.changed(_:))
        field.font = NSFont.systemFont(ofSize: 13)
        field.setAccessibilityLabel(placeholder)
        DispatchQueue.main.async { field.window?.makeFirstResponder(field) }
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: ReaderSearchField
        init(_ parent: ReaderSearchField) { self.parent = parent }

        @objc func changed(_ sender: NSSearchField) { parent.text = sender.stringValue }
        func controlTextDidChange(_ notification: Notification) {
            if let field = notification.object as? NSSearchField { parent.text = field.stringValue }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.cancelOperation(_:)): parent.onCancel(); return true   // Escape closes the panel like the others
            case #selector(NSResponder.insertNewline(_:)): parent.onSubmit(); return true
            case #selector(NSResponder.moveDown(_:)): parent.onMoveDown(); return true
            default: return false
            }
        }
    }
}
