import SwiftUI
import BooksCore

/// The caller supplies saved evidence and a synchronous durable-save operation.
/// No binding to the store is exposed: browsing, Escape and Cancel cannot write.
struct ReadingDatesEditor: View {
    let title: String
    let timezoneID: String
    let save: (ReadingCompletionDates) -> String?
    @Environment(\.dismiss) private var dismiss
    @State private var draft: ReadingCompletionDates
    @State private var saveError: String?
    @State private var expandedField: String?

    init(title: String, dates: ReadingCompletionDates, timezoneID: String, initiallyExpanded: Bool = false,
         save: @escaping (ReadingCompletionDates) -> String?) {
        self.title = title; self.timezoneID = timezoneID; self.save = save
        _draft = State(initialValue: dates)
        _expandedField = State(initialValue: initiallyExpanded ? "finish" : nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            ReadingSheetHeader(title: "Reading dates", subtitle: title, close: { dismiss() })
            Text("Already marked as read. Dates are optional; skip to keep your saved dates. An unknown start stays unknown.")
                .font(.callout).foregroundStyle(ReadingPalette.fadedInk)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(spacing: 12) {
                    ReadingDateField(title: "Started", date: $draft.startedAt, timezoneID: timezoneID,
                        expanded: Binding(get: { expandedField == "start" }, set: { expandedField = $0 ? "start" : nil }))
                    ReadingDateField(title: "Finished", date: $draft.finishedAt, timezoneID: timezoneID,
                        expanded: Binding(get: { expandedField == "finish" }, set: { expandedField = $0 ? "finish" : nil }))
                }.padding(2)
            }.scrollIndicators(.visible)
            .frame(height: expandedField == nil ? 156 : 480)
            Text("Removing a finish date keeps this book read, but leaves it out of yearly totals and the dated timeline. Times are shown in \(timezoneID).")
                .font(.caption).foregroundStyle(ReadingPalette.fadedInk)
                .fixedSize(horizontal: false, vertical: true)
            if let message = saveError ?? draft.validationMessage(now: Date()) {
                Text(message).font(.callout).foregroundStyle(ReadingPalette.ochre)
                    .accessibilityLabel("Dates not saved. \(message)")
            }
            HStack {
                Button("Skip — keep saved dates") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save dates") {
                    if let message = draft.validationMessage(now: Date()) { saveError = message; return }
                    saveError = save(draft)
                    if saveError == nil { dismiss() }
                }.buttonStyle(ReadingButtonStyle(emphasis: .primary))
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.validationMessage(now: Date()) != nil)
            }
        }
        .padding(24).frame(width: 540)
        .background(ReadingPalette.paper).foregroundStyle(ReadingPalette.ink)
        .buttonStyle(ReadingButtonStyle())
        .readingMotionAccessibility()
    }
}

private struct ReadingDateField: View {
    let title: String
    @Binding var date: Date?
    let timezoneID: String
    @Binding var expanded: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: timezoneID) ?? .current
        return value
    }
    private var label: String {
        guard let date else { return "Unknown · optional" }
        let formatter = DateFormatter()
        formatter.timeZone = calendar.timeZone
        formatter.dateStyle = .medium; formatter.timeStyle = .short
        return formatter.string(from: date)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button {
                    withAnimation(reduceMotion ? nil : ReadingMotion.entrance) { expanded.toggle() }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "calendar").foregroundStyle(ReadingPalette.moss)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(title).font(.caption.weight(.semibold))
                            Text(label).font(.callout)
                        }
                        Spacer()
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .accessibilityLabel("\(title): \(label)")
                    .accessibilityValue(expanded ? "Calendar expanded" : "Calendar collapsed")
                    .accessibilityHint("Show or hide the date calendar")
                if date != nil {
                    Button("Clear") { date = nil }
                        .accessibilityLabel("Leave \(title.lowercased()) date unknown")
                }
            }
            if expanded {
                if let value = date {
                    ReadingDatePicker("Time", selection: Binding(get: { date ?? value }, set: { date = $0 }),
                                      includesDate: false)
                        .environment(\.timeZone, calendar.timeZone)
                }
                ReadingDateCalendar(selection: $date, timezoneID: timezoneID)
                    .transition(reduceMotion ? .identity : .opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
                    .onExitCommand {
                        withAnimation(reduceMotion ? nil : ReadingMotion.entrance) { expanded = false }
                    }
            }
        }
        .padding(16)
        .background(ReadingPalette.surface, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(ReadingPalette.border.opacity(0.5)))
    }
}

/// App-owned calendar surface, also usable in synthetic previews without an AppModel.
struct ReadingDateCalendar: View {
    @Binding var selection: Date?
    @State private var navigation: CalendarNavigation
    @FocusState private var focusedDay: Date?
    let now: Date

    init(selection: Binding<Date?>, timezoneID: String, now: Date = Date()) {
        _selection = selection; self.now = now
        _navigation = State(initialValue: CalendarNavigation(timezoneID: timezoneID,
                              anchor: selection.wrappedValue ?? now))
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Button { moveMonth(-1) } label: { Image(systemName: "chevron.left") }
                    .accessibilityLabel("Previous month")
                Text(navigation.title).font(.system(size: 18, weight: .medium, design: .serif))
                    .frame(maxWidth: .infinity)
                Button { moveMonth(1) } label: { Image(systemName: "chevron.right") }
                    .accessibilityLabel("Next month")
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 4) {
                ForEach(0..<7) { index in
                    Text(navigation.calendar.shortWeekdaySymbols[(navigation.calendar.firstWeekday - 1 + index) % 7])
                        .font(.caption.weight(.medium)).foregroundStyle(ReadingPalette.fadedInk)
                        .accessibilityHidden(true)
                }
                ForEach(navigation.monthCells) { cell in
                    let selected = selection.map { navigation.isSameDay($0, cell.date) } ?? false
                    Button {
                        selection = ReadingCompletionDates.selecting(day: cell.date, preserving: selection,
                                                                     calendar: navigation.calendar, now: now)
                    } label: {
                        Text(String(navigation.calendar.component(.day, from: cell.date)))
                            .font(.system(size: 13, weight: selected ? .bold : .regular, design: .rounded))
                            .frame(maxWidth: .infinity).frame(height: 32)
                            .background(selected ? ReadingPalette.moss.opacity(0.2) : .clear,
                                        in: RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(selected ? ReadingPalette.moss : .clear))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(cell.isInMonth ? ReadingPalette.ink : ReadingPalette.fadedInk)
                    .disabled(!isAllowed(cell.date))
                    .focused($focusedDay, equals: cell.date)
                    .accessibilityLabel(dayLabel(cell.date))
                    .accessibilityAddTraits(selected ? [.isSelected] : [])
                }
            }
            // Reserve six weeks so February and six-row months don't move the
            // editor footer. Month changes replace dates without shuffling
            // shared edge dates across rows or moving keyboard focus targets.
            .frame(minHeight: 230, alignment: .top)
            .transaction { $0.animation = nil }
            .onMoveCommand { direction in
                let offset: Int
                switch direction { case .left: offset = -1; case .right: offset = 1; case .up: offset = -7; case .down: offset = 7; default: return }
                guard let day = focusedDay,
                      let next = navigation.calendar.date(byAdding: .day, value: offset, to: day), isAllowed(next) else { return }
                navigation.select(next)
                focusedDay = next
            }
            HStack {
                Button("Today") {
                    navigation.goToToday(now)
                    focusedDay = navigation.calendar.startOfDay(for: now)
                }
                Spacer()
                Text("Arrow keys to browse · Space to choose")
                    .font(.caption2).foregroundStyle(ReadingPalette.fadedInk)
            }
        }
        .buttonStyle(ReadingButtonStyle()).controlSize(.small)
        .padding(12)
        .background(ReadingPalette.elevated.opacity(0.55), in: RoundedRectangle(cornerRadius: 16))
    }
    private func isAllowed(_ day: Date) -> Bool {
        day >= ReadingCompletionDates.earliestDate && day <= now && day <= ReadingCompletionDates.latestDate
    }
    private func moveMonth(_ amount: Int) {
        navigation.move(by: amount)
    }
    private func dayLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = navigation.calendar.timeZone
        formatter.dateStyle = .full
        return formatter.string(from: date)
    }
}
