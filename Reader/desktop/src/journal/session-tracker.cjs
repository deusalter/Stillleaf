"use strict";
const { randomUUID } = require("node:crypto");

/** Pure host-sampled timing domain; this module observes no clocks, focus, input or network.
 * The host supplies explicit eligibility. Locator/reflow fields are intentionally ignored.
 * persist(batch) MUST synchronously and atomically store the whole batch or throw without mutation.
 * ReaderSessionHost connects this domain to JournalStore's atomic tracking batch API.
 * date is epoch milliseconds (or Date); uptime and durations are seconds.
 * Deviation from native: checkpoints split at exact checkpointSeconds boundaries; native may overshoot
 * by one trusted tick. Resume also requires matching source, and cached prior credited time is retained.
 * Restart recovery belongs to the host: supply durableThrough and never replay an uncheckpointed tail.
 */
class SessionTracker {
  constructor({persist, timezoneId = "UTC", checkpointSeconds = 15, durableThrough = null, makeId = randomUUID} = {}) {
    if (typeof persist !== "function" || typeof makeId !== "function") throw Error("Timing requires a synchronous persistence sink and identity factory");
    new Intl.DateTimeFormat("en", {timeZone: timezoneId});
    if (!Number.isFinite(checkpointSeconds) || checkpointSeconds <= 0) throw Error("Invalid timing limits");
    this.persist = persist; this.makeId = makeId; this.timezoneId = timezoneId;
    this.checkpointSeconds = checkpointSeconds;
    this.state = {active: null, resume: null, watermark: durableThrough === null ? null : dateValue(durableThrough), holdReported: false, snapshot: {phase: "paused", reason: "stopped", sessionId: null, bookId: null, creditedSeconds: 0}};
  }
  get snapshot() { return structuredClone(this.state.snapshot); }
  sample(input) {
    const sample = checkedSample(input);
    return this._transaction((state, batch) => {
      const eligible = sample.eligible && sample.bookId !== null;
      if (state.active) {
        const same = eligible && sameIdentity(state.active, sample);
        const outcome = this._advance(state, batch, sample.date, sample.uptime);
        if (outcome) {
          this._finish(state, batch, outcome, false);
          if (eligible) this._start(state, batch, sample, false);
          return;
        }
        if (same) { this._snapshot(state); return; }
        this._finish(state, batch, sample.reason || "stopped", !eligible);
      }
      if (eligible) this._start(state, batch, sample, true);
      else state.snapshot = {...state.snapshot, phase: "paused", reason: sample.reason || "ineligible"};
    });
  }
  checkpoint({date, uptime}) {
    const wall = dateValue(date); checkedUptime(uptime);
    return this._transaction((state, batch) => {
      if (!state.active) return;
      const failure = this._advance(state, batch, wall, uptime);
      if (failure) this._finish(state, batch, failure, false);
      else { this._flush(state, batch, "trackingCheckpoint"); this._snapshot(state); }
    });
  }
  stop({date, uptime, reason = "stopped"}) {
    const wall = dateValue(date); checkedUptime(uptime);
    return this._transaction((state, batch) => {
      if (state.active) {
        const failure = this._advance(state, batch, wall, uptime);
        this._finish(state, batch, failure || reason, false);
      }
      state.resume = null; state.snapshot = {...state.snapshot, phase: "paused", reason, sessionId: null};
    });
  }
  _transaction(work) {
    const next = structuredClone(this.state), batch = {intervals: [], events: []};
    work(next, batch);
    if (batch.intervals.length || batch.events.length) {
      const result = this.persist(structuredClone(batch));
      if (result && typeof result.then === "function") throw Error("Timing sink must be synchronous");
    }
    this.state = next;
    return this.snapshot;
  }
  _event(state, batch, kind, reason = null) {
    const active = state.active;
    batch.events.push({id: this.makeId(), kind, bookId: active?.bookId ?? state.snapshot.bookId,
      sessionId: active?.sessionId ?? null, date: new Date(active?.segmentEnd ?? state.watermark).toISOString(),
      source: active?.source ?? null, mode: active?.mode ?? null, timezoneId: active?.timezoneId ?? this.timezoneId, reason});
  }
  _flush(state, batch, kind, reason = null) {
    const a = state.active;
    if (a.duration > 0) {
      batch.intervals.push({id: this.makeId(), sessionId: a.sessionId, bookId: a.bookId, source: a.source, mode: a.mode,
        timezoneId: a.timezoneId, start: new Date(a.segmentStart).toISOString(), end: new Date(a.segmentEnd).toISOString(),
        duration: a.duration, disposition: "credited"});
      state.watermark = Math.max(state.watermark ?? a.segmentEnd, a.segmentEnd);
    }
    this._event(state, batch, kind, reason);
    a.segmentStart = a.segmentEnd; a.duration = 0;
  }
  _advance(state, batch, date, uptime) {
    const a = state.active, delta = uptime - a.lastUptime, wallDelta = (date - a.lastDate) / 1000;
    if (delta < 0) return "clockDiscontinuity";
    if (delta > 5) return "captureFailure";
    if (wallDelta < 0 || (delta > 0 && wallDelta <= 0) || Math.abs(wallDelta - delta) > 2) return "clockDiscontinuity";
    let elapsed = 0;
    while (elapsed < delta) {
      if (a.duration === 0) { a.segmentStart = a.lastDate + elapsed * wallDelta / delta * 1000; a.segmentEnd = a.segmentStart; }
      const step = Math.min(delta - elapsed, this.checkpointSeconds - a.duration);
      a.duration += step; elapsed += step;
      a.segmentEnd = a.lastDate + elapsed * wallDelta / delta * 1000;
      a.creditedSeconds += step;
      if (a.duration >= this.checkpointSeconds - 1e-9) this._flush(state, batch, "trackingCheckpoint");
    }
    a.lastDate = date; a.lastUptime = uptime;
    return null;
  }
  _finish(state, batch, reason, resumable) {
    const a = state.active;
    this._flush(state, batch, "trackingPaused", reason);
    state.resume = resumable ? {sessionId: a.sessionId, bookId: a.bookId, source: a.source, mode: a.mode, date: a.lastDate, uptime: a.lastUptime, creditedSeconds: a.creditedSeconds} : null;
    state.snapshot = {phase: "paused", reason, sessionId: resumable ? a.sessionId : null, bookId: a.bookId, source: a.source, mode: a.mode, creditedSeconds: a.creditedSeconds};
    state.active = null;
  }
  _start(state, batch, sample, mayResume) {
    if (state.watermark !== null && sample.date < state.watermark) {
      state.active = null; state.resume = null;
      state.snapshot = {phase: "paused", reason: "clockDiscontinuity", sessionId: null, bookId: sample.bookId, creditedSeconds: 0};
      if (!state.holdReported) { batch.events.push({id: this.makeId(), kind: "trackingClockHold", bookId: sample.bookId, sessionId: null, date: new Date(sample.date).toISOString(), source: sample.source, mode: sample.mode, timezoneId: this.timezoneId, reason: "wall clock predates durable history"}); state.holdReported = true; }
      return;
    }
    state.holdReported = false;
    const prior = state.resume;
    const resumed = mayResume && prior && sameIdentity(prior, sample) && sample.uptime >= prior.uptime && sample.uptime - prior.uptime <= 120 && sample.date >= prior.date;
    state.active = {bookId: sample.bookId, mode: sample.mode, source: sample.source, timezoneId: this.timezoneId,
      sessionId: resumed ? prior.sessionId : this.makeId(), lastDate: sample.date, lastUptime: sample.uptime,
      segmentStart: sample.date, segmentEnd: sample.date, duration: 0, creditedSeconds: resumed ? prior.creditedSeconds : 0};
    state.resume = null;
    this._event(state, batch, "trackingStarted"); this._snapshot(state);
  }
  _snapshot(state) {
    const a = state.active;
    state.snapshot = {phase: "reading", reason: null,
      sessionId: a.sessionId, bookId: a.bookId, source: a.source, mode: a.mode, creditedSeconds: a.creditedSeconds};
  }
}
function sameIdentity(a, b) { return a.bookId === b.bookId && a.mode === b.mode && a.source === b.source; }
function dateValue(value) { const date = value instanceof Date ? value.getTime() : value; if (typeof date !== "number" || !Number.isFinite(date) || !Number.isFinite(new Date(date).getTime())) throw Error("Invalid host date"); return date; }
function checkedUptime(value) { if (typeof value !== "number" || !Number.isFinite(value) || value < 0) throw Error("Invalid host uptime"); }
function checkedSample(value) {
  if (!value || typeof value.eligible !== "boolean") throw Error("Explicit eligibility required");
  checkedUptime(value.uptime);
  const bookId = value.bookId ?? null, mode = value.mode ?? "automatic", source = value.source ?? "stillleaf-epub";
  if ((bookId !== null && (typeof bookId !== "string" || !bookId || bookId.length > 256)) || !["automatic", "manual"].includes(mode) || typeof source !== "string" || !source || source.length > 128) throw Error("Invalid tracking identity");
  return {...value, bookId, mode, source, date: dateValue(value.date)};
}
module.exports = { SessionTracker };
