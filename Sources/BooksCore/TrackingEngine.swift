import Foundation

public final class TrackingEngine {
    public private(set) var snapshot = TrackerSnapshot()
    public var timezoneID: String {
        get { configuredTimezoneID }
        set { if TimeZone(identifier: newValue) != nil { configuredTimezoneID = newValue } }
    }
    public var uncertaintyThreshold: TimeInterval {
        get { configuredUncertaintyThreshold }
        set { configuredUncertaintyThreshold = max(0, newValue) }
    }

    private struct ActiveState {
        var book: BookRecord
        var mode: ReadingMode
        var sessionID: String
        var timezoneID: String
        var lastDate: Date
        var lastUptime: TimeInterval
        var lastEvidenceUptime: TimeInterval
        var lastProgressSignature: String?
        var segmentStart: Date
        var segmentEnd: Date
        var segmentDuration: TimeInterval
        var segmentDisposition: IntervalDisposition
        var sessionCreditedSeconds: TimeInterval
    }

    private struct ResumeState {
        var sessionID: String
        var bookID: String
        var mode: ReadingMode
        var date: Date
        var uptime: TimeInterval
    }

    private let store: ReadingStore
    private let checkpointSeconds: TimeInterval
    private let maximumTickGap: TimeInterval = 5
    private let resumablePause: TimeInterval = 120
    private var configuredTimezoneID: String
    private var configuredUncertaintyThreshold: TimeInterval
    private var active: ActiveState?
    private var resume: ResumeState?
    private var lastStoredProgress: [String: String] = [:]
    private var wallClockWatermark: Date?
    private var clockHoldReported = false

    public init(store: ReadingStore, timezoneID: String, uncertaintyThreshold: TimeInterval = 1200, checkpointSeconds: TimeInterval = 15) throws {
        guard TimeZone(identifier: timezoneID) != nil else { throw ReadingStoreError.invalidData("unknown timezone \(timezoneID)") }
        guard uncertaintyThreshold.isFinite, uncertaintyThreshold >= 0, checkpointSeconds.isFinite, checkpointSeconds > 0 else {
            throw ReadingStoreError.invalidData("tracking durations must be finite and nonnegative")
        }
        self.store = store
        self.configuredTimezoneID = timezoneID
        self.configuredUncertaintyThreshold = uncertaintyThreshold
        self.checkpointSeconds = checkpointSeconds
        let storedIntervals = try store.effectiveIntervals()
        self.wallClockWatermark = storedIntervals.map(\.end).max()
        let existingProgress = try store.archive().progress
        for observation in existingProgress { lastStoredProgress[observation.bookID] = storedProgressSignature(observation) }
        try recoverIfNeeded()
    }

    public func process(_ input: TrackingInput) throws {
        if let book = input.book { try store.saveBook(book) }
        if let progress = input.progress {
            let signature = storedProgressSignature(progress)
            if lastStoredProgress[progress.bookID] != signature {
                try store.appendProgress(progress)
                lastStoredProgress[progress.bookID] = signature
            }
        }

        let eligible = input.book != nil && input.pauseReason == nil
        if var current = active {
            let sameReading = eligible && current.book.id == input.book!.id && current.mode == input.mode
            if sameReading {
                let outcome = try advance(&current, to: input.date, uptime: input.uptime, evidence: isEvidence(input, comparedWith: current))
                if outcome == .continued {
                    current.book = input.book!
                    if input.progress?.reliable == true {
                        current.lastProgressSignature = navigationSignature(input.progress) ?? current.lastProgressSignature
                    }
                    active = current
                    updateSnapshot(from: current)
                    return
                }
                // A discontinuous clock or sampling gap closes only at the last trusted sample.
                active = current
                try finishActive(at: current.lastDate, reason: outcome.pauseReason, allowResume: false)
                try start(input, reuseSessionID: nil)
                return
            }

            let evidence = isEvidence(input, comparedWith: current)
            _ = try advance(&current, to: input.date, uptime: input.uptime, evidence: evidence)
            active = current
            let reason = input.pauseReason ?? .stopped
            try finishActive(at: active!.lastDate, reason: reason, allowResume: !eligible)
        }

        if eligible { try start(input, reuseSessionID: resumableSession(for: input)) }
        else {
            snapshot.phase = .paused
            if let book = input.book {
                snapshot.book = book
                snapshot.mode = input.mode
            }
            snapshot.pauseReason = input.pauseReason ?? .stopped
        }
    }

    public func stop(date: Date = Date(), uptime: TimeInterval = ProcessInfo.processInfo.systemUptime, reason: PauseReason = .stopped) throws {
        if var current = active {
            _ = try advance(&current, to: date, uptime: uptime, evidence: false)
            active = current
            try finishActive(at: current.lastDate, reason: reason, allowResume: false)
        }
        resume = nil
        snapshot.phase = .paused
        snapshot.pauseReason = reason
        snapshot.sessionID = nil
    }

    public func checkpoint(date: Date = Date(), uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) throws {
        guard var current = active else { return }
        let outcome = try advance(&current, to: date, uptime: uptime, evidence: false, automaticCheckpoint: false)
        active = current
        guard outcome == .continued else {
            try finishActive(at: current.lastDate, reason: outcome.pauseReason, allowResume: false)
            return
        }
        try persistSegment(&current, eventKind: "trackingCheckpoint", eventDate: current.lastDate, eventDetail: checkpointDetail(current))
        active = current
        updateSnapshot(from: current)
    }

    private enum AdvanceOutcome: Equatable {
        case continued
        case outage
        case clockDiscontinuity
        var pauseReason: PauseReason {
            switch self {
            case .continued: return .stopped
            case .outage: return .captureFailure
            case .clockDiscontinuity: return .clockDiscontinuity
            }
        }
    }

    private func advance(_ state: inout ActiveState, to date: Date, uptime: TimeInterval, evidence: Bool, automaticCheckpoint: Bool = true) throws -> AdvanceOutcome {
        let monotonicDelta = uptime - state.lastUptime
        let wallDelta = date.timeIntervalSince(state.lastDate)
        guard monotonicDelta >= 0 else { return .clockDiscontinuity }
        guard monotonicDelta <= maximumTickGap else { return .outage }
        guard wallDelta >= 0, !(monotonicDelta > 0 && wallDelta <= 0), abs(wallDelta - monotonicDelta) <= 2 else { return .clockDiscontinuity }

        var remaining = monotonicDelta
        var cursorDate = state.lastDate
        let wallScale = monotonicDelta > 0 ? wallDelta / monotonicDelta : 1
        while remaining > 0 {
            let sinceEvidence = max(0, state.lastUptime - state.lastEvidenceUptime + (monotonicDelta - remaining))
            let creditRemaining = max(0, configuredUncertaintyThreshold - sinceEvidence)
            let disposition: IntervalDisposition = creditRemaining > 0 ? .credited : .uncertain
            let step = disposition == .credited ? min(remaining, creditRemaining) : remaining
            if state.segmentDuration > 0 && state.segmentDisposition != disposition {
                try persistSegment(&state, eventKind: "trackingCheckpoint", eventDate: cursorDate, eventDetail: checkpointDetail(state))
            }
            if state.segmentDuration == 0 {
                state.segmentStart = cursorDate
                state.segmentEnd = cursorDate
                state.segmentDisposition = disposition
            }
            state.segmentDuration += step
            cursorDate = cursorDate.addingTimeInterval(step * wallScale)
            state.segmentEnd = cursorDate
            remaining -= step
            if disposition == .credited { state.sessionCreditedSeconds += step }
            if automaticCheckpoint && state.segmentDuration >= checkpointSeconds {
                try persistSegment(&state, eventKind: "trackingCheckpoint", eventDate: cursorDate, eventDetail: checkpointDetail(state))
            }
        }
        state.lastDate = date
        state.lastUptime = uptime
        if evidence { state.lastEvidenceUptime = uptime }
        return .continued
    }

    private func start(_ input: TrackingInput, reuseSessionID: String?) throws {
        guard let book = input.book else { return }
        if let watermark = wallClockWatermark, input.date < watermark {
            if !clockHoldReported {
                try store.appendEvent(AuditEvent(date: input.date, kind: "trackingClockHold", bookID: book.id,
                                                 detail: "Wall clock is earlier than durable history ending at \(watermark.timeIntervalSince1970); tracking remains paused."))
                clockHoldReported = true
            }
            active = nil
            resume = nil
            snapshot.phase = .paused
            snapshot.book = book
            snapshot.mode = input.mode
            snapshot.sessionID = nil
            snapshot.pauseReason = .clockDiscontinuity
            return
        }
        clockHoldReported = false
        let sessionID = reuseSessionID ?? UUID().uuidString
        let signature = input.progress?.reliable == true ? navigationSignature(input.progress) : nil
        let priorCredited = reuseSessionID == nil ? 0 : try store.effectiveIntervals().filter { $0.sessionID == sessionID && $0.disposition == .credited }.reduce(0) { $0 + $1.duration }
        var state = ActiveState(book: book, mode: input.mode, sessionID: sessionID, timezoneID: configuredTimezoneID,
                                lastDate: input.date, lastUptime: input.uptime, lastEvidenceUptime: input.uptime,
                                lastProgressSignature: signature, segmentStart: input.date, segmentEnd: input.date,
                                segmentDuration: 0, segmentDisposition: .credited, sessionCreditedSeconds: priorCredited)
        let event = AuditEvent(date: input.date, kind: "trackingStarted", bookID: book.id, sessionID: sessionID,
                               detail: checkpointDetail(state))
        try store.appendCheckpoint(interval: nil, event: event)
        active = state
        resume = nil
        snapshot.phase = .reading
        snapshot.book = book
        snapshot.mode = input.mode
        snapshot.sessionID = sessionID
        snapshot.pauseReason = nil
        snapshot.sessionSeconds = priorCredited
        // Silence a Swift warning while retaining var for symmetry with restoration code.
        state.lastProgressSignature = signature
        active = state
    }

    private func finishActive(at date: Date, reason: PauseReason, allowResume: Bool) throws {
        guard var state = active else { return }
        let detail = "reason=\(reason.rawValue);lastTrusted=\(state.lastDate.timeIntervalSince1970)"
        try persistSegment(&state, eventKind: "trackingPaused", eventDate: date, eventDetail: detail)
        if allowResume {
            resume = ResumeState(sessionID: state.sessionID, bookID: state.book.id, mode: state.mode, date: state.lastDate, uptime: state.lastUptime)
        } else { resume = nil }
        active = nil
        snapshot.phase = .paused
        snapshot.book = state.book
        snapshot.mode = state.mode
        snapshot.sessionID = allowResume ? state.sessionID : nil
        snapshot.pauseReason = reason
    }

    private func persistSegment(_ state: inout ActiveState, eventKind: String, eventDate: Date, eventDetail: String) throws {
        let interval: ReadingInterval?
        if state.segmentDuration > 0 {
            interval = ReadingInterval(sessionID: state.sessionID, bookID: state.book.id, start: state.segmentStart,
                                       end: state.segmentEnd, duration: state.segmentDuration, timezoneID: state.timezoneID,
                                       mode: state.mode, disposition: state.segmentDisposition)
        } else { interval = nil }
        let event = AuditEvent(date: eventDate, kind: eventKind, bookID: state.book.id, sessionID: state.sessionID, detail: eventDetail)
        try store.appendCheckpoint(interval: interval, event: event)
        if let interval { wallClockWatermark = max(wallClockWatermark ?? interval.end, interval.end) }
        state.segmentStart = state.segmentEnd
        state.segmentDuration = 0
    }

    private func resumableSession(for input: TrackingInput) -> String? {
        guard let prior = resume, let book = input.book,
              prior.bookID == book.id, prior.mode == input.mode,
              input.uptime >= prior.uptime, input.uptime - prior.uptime <= resumablePause,
              input.date >= prior.date else { return nil }
        return prior.sessionID
    }

    private func isEvidence(_ input: TrackingInput, comparedWith state: ActiveState) -> Bool {
        if input.relevantActivity { return true }
        // Native relocation includes restore, jump and reflow. It is position only.
        guard input.progress?.source != "stillleaf-epub-location",
              input.progress?.reliable == true, let signature = navigationSignature(input.progress) else { return false }
        return signature != state.lastProgressSignature
    }

    private func navigationSignature(_ progress: ProgressObservation?) -> String? {
        guard let progress else { return nil }
        return "\(progress.page.map { String($0) } ?? "")|\(progress.totalPages.map { String($0) } ?? "")|\(progress.fraction.map { String($0) } ?? "")|\(progress.location ?? "")"
    }

    private func storedProgressSignature(_ progress: ProgressObservation) -> String {
        "\(navigationSignature(progress) ?? "")|\(progress.source)|\(progress.reliable)"
    }

    private func checkpointDetail(_ state: ActiveState) -> String {
        "book=\(state.book.id);mode=\(state.mode.rawValue);lastTrusted=\(state.lastDate.timeIntervalSince1970);uptime=\(state.lastUptime)"
    }

    private func updateSnapshot(from state: ActiveState) {
        snapshot.phase = state.segmentDisposition == .uncertain ? .uncertain : .reading
        snapshot.book = state.book
        snapshot.mode = state.mode
        snapshot.sessionID = state.sessionID
        snapshot.pauseReason = nil
        snapshot.sessionSeconds = state.sessionCreditedSeconds
    }

    private func recoverIfNeeded() throws {
        let lifecycleKinds: Set<String> = ["trackingStarted", "trackingCheckpoint", "trackingPaused", "trackingRecovery"]
        let events = try store.archive().events.filter { lifecycleKinds.contains($0.kind) }
        guard let last = events.last, last.kind == "trackingStarted" || last.kind == "trackingCheckpoint" else { return }
        try store.appendEvent(AuditEvent(kind: "trackingRecovery", bookID: last.bookID, sessionID: last.sessionID,
                                         detail: "Previous tracking state ended without a stop marker; uncheckpointed tail duration is unknown and no downtime was credited."))
        snapshot.phase = .paused
        snapshot.pauseReason = .recovery
    }
}
