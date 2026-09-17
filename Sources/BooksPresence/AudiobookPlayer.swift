import AppKit
import AVFoundation
import BooksCore

@MainActor
final class AudiobookPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var bookID: String?
    @Published private(set) var isPlaying = false
    @Published private(set) var position: Double = 0
    @Published private(set) var duration: Double = 0
    @Published var rate: Float = 1 { didSet { player?.rate = rate } }
    @Published var volume: Float = 1 { didSet { player?.volume = volume } }
    @Published private(set) var errorMessage: String?
    var willPlay: (() throws -> Void)?
    var persist: ((ProgressObservation, ReadingInterval?) throws -> Void)?
    var shouldCredit: (String) -> Bool = { _ in true }
    private var pending: (progress: ProgressObservation, interval: ReadingInterval?)?
    var timezoneID: () -> String = { TimeZone.current.identifier }
    private var player: AVAudioPlayer?
    private var timer: Timer?
    private var clock = ListeningClock()
    private var lastCheckpointUptime: Double = 0
    private var sessionID = UUID().uuidString

    func load(book: BookRecord, url: URL, resume: Double) throws {
        try pause()
        let next = try AVAudioPlayer(contentsOf: url)
        next.enableRate = true; next.rate = rate; next.volume = volume
        guard next.duration.isFinite, next.duration > 0, next.prepareToPlay() else {
            throw ReadingStoreError.invalidData("The local audio file could not be opened.")
        }
        next.delegate = self
        next.currentTime = min(max(0, resume), next.duration)
        player = next; bookID = book.id; duration = next.duration; position = next.currentTime
        errorMessage = nil
    }

    func play() {
        guard let player, !isPlaying else { return }
        do {
            try flushPending()
            try willPlay?()
            if position >= duration { player.currentTime = 0; position = 0 }
            guard player.play() else { throw ReadingStoreError.invalidData("Audio playback could not start.") }
            sessionID = UUID().uuidString
            lastCheckpointUptime = ProcessInfo.processInfo.systemUptime
            clock.start(date: Date(), uptime: lastCheckpointUptime)
            isPlaying = true; errorMessage = nil
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in self?.update() }
            }
            self.timer = timer
            RunLoop.main.add(timer, forMode: .common)
        } catch { errorMessage = String(describing: error) }
    }

    func pause() throws {
        try flushPending()
        guard let player, isPlaying else { return }
        let wasPlaying = isPlaying && player.isPlaying
        player.pause(); timer?.invalidate(); timer = nil
        defer { isPlaying = false }
        try checkpoint(credit: wasPlaying)
    }

    func seek(to seconds: Double) {
        guard let player, seconds.isFinite else { return }
        do {
            try checkpoint(credit: isPlaying && player.isPlaying)
            player.currentTime = min(max(0, seconds), duration)
            position = player.currentTime
            try checkpoint(credit: false)
        } catch { fail(error) }
    }

    func close() throws {
        try pause(); player = nil; bookID = nil; position = 0; duration = 0
    }

    func pauseReportingErrors() {
        do { try pause() } catch { fail(error) }
    }

    private func update() {
        if let player { position = min(max(0, player.currentTime), duration) }
        guard ProcessInfo.processInfo.systemUptime - lastCheckpointUptime >= 5 else { return }
        do { try checkpoint(credit: isPlaying && player?.isPlaying == true) }
        catch { fail(error) }
        if player?.isPlaying != true { isPlaying = false; timer?.invalidate(); timer = nil }
    }

    private func checkpoint(credit: Bool, finished: Bool = false) throws {
        try flushPending()
        guard let player, let bookID else { return }
        let now = Date()
        lastCheckpointUptime = ProcessInfo.processInfo.systemUptime
        let elapsed = clock.checkpoint(date: now, uptime: lastCheckpointUptime)
        position = finished ? duration : min(max(0, player.currentTime), duration)
        var interval: ReadingInterval?
        if credit, shouldCredit(bookID), let elapsed {
            interval = ReadingInterval(sessionID: sessionID, bookID: bookID, start: elapsed.start, end: now,
                duration: elapsed.seconds, timezoneID: timezoneID(), mode: .listening, audioSessionID: sessionID)
        }
        let audio = AudiobookProgress(positionSeconds: position, durationSeconds: duration)
        pending = (ProgressObservation(bookID: bookID, observedAt: now, fraction: audio.fraction,
            source: "local-audio", reliable: true, audio: audio, sessionID: interval?.sessionID), interval)
        try flushPending()
    }

    /// Retry exactly the same evidence IDs/date before moving the clock or resuming.
    /// This also makes retry safe when a write committed but acknowledgement failed.
    private func flushPending() throws {
        guard let pending else { return }
        try persist?(pending.progress, pending.interval)
        self.pending = nil
    }

    private func fail(_ error: Error) {
        player?.pause(); isPlaying = false; timer?.invalidate(); timer = nil
        errorMessage = "Playback paused because progress could not be saved: \(error)"
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self, self.player === player else { return }
            do { try self.checkpoint(credit: self.isPlaying && flag, finished: flag) }
            catch { self.fail(error) }
            self.isPlaying = false; self.timer?.invalidate(); self.timer = nil
            if !flag { self.errorMessage = "The audio file stopped before completion." }
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor [weak self] in
            guard let self, self.player === player else { return }
            self.fail(error ?? ReadingStoreError.invalidData("Audio decoding failed."))
        }
    }
}
