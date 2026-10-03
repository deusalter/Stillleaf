"use strict";
const { SessionTracker } = require("./session-tracker.cjs");

/** Main-process adapter. The publication has no access to this controller or clock.
 * getReader returns only host-owned {bookId,ready,focused,minimized,destroyed}.
 * No locator, page number or layout callback is treated as activity evidence.
 */
class ReaderSessionHost {
  constructor({ journal, powerMonitor, getReader, clock = () => ({ date: Date.now(), uptime: Number(process.hrtime.bigint()) / 1e9 }),
    timezoneId = Intl.DateTimeFormat().resolvedOptions().timeZone, onError = () => {}, onChanged = () => {},
    setTimer = setInterval, clearTimer = clearInterval, checkpointSeconds = 15 }) {
    this.power = powerMonitor; this.getReader = getReader; this.clock = clock;
    this.onError = onError; this.onChanged = onChanged; this.setTimer = setTimer; this.clearTimer = clearTimer;
    this.blocks = new Set(); this.listeners = []; this.timer = null;
    const durableThrough = journal.trackingWatermark();
    this.tracker = new SessionTracker({ timezoneId, checkpointSeconds,
      durableThrough: durableThrough === null ? null : Date.parse(durableThrough),
      persist: batch => { journal.appendTrackingBatch(batch); try { Promise.resolve(this.onChanged()).catch(this.onError); } catch (error) { this.onError(error); } } });
  }
  get snapshot() { return this.tracker.snapshot; }
  start() {
    if (this.timer !== null) return;
    const changes = [["suspend", "suspend", true], ["resume", "suspend", false],
      ["lock-screen", "lock", true], ["unlock-screen", "lock", false],
      ["user-did-resign-active", "session", true], ["user-did-become-active", "session", false]];
    for (const [name, key, blocked] of changes) {
      const handler = () => { if (blocked) this.blocks.add(key); else this.blocks.delete(key); this.sample(); };
      this.power.on(name, handler); this.listeners.push([name, handler]);
    }
    this.timer = this.setTimer(() => this.sample(), 1000);
    this.timer?.unref?.(); this.sample();
  }
  sample() {
    try {
      const sample = this.clock(), reader = this.getReader();
      const idleState = this.power.getSystemIdleState(1);
      if (!["active", "idle", "locked"].includes(idleState)) throw Error("System lock state is unavailable.");
      const locked = idleState === "locked";
      const eligible = Boolean(reader?.bookId && reader.ready && reader.focused && !reader.minimized && !reader.destroyed && !locked && !this.blocks.size);
      const reason = locked || this.blocks.has("lock") ? "locked" : this.blocks.size ? "suspended" : !reader?.ready ? "noReadingWindow" : "background";
      const result = this.tracker.sample({ ...sample, bookId: reader?.bookId ?? null, eligible,
        source: "stillleaf-epub", mode: "automatic", reason });
      this.lastSample = sample; return result;
    } catch (error) {
      this.onError(error);
      // Stop at the last trustworthy sample; do not fill an unknown observation gap.
      if (this.lastSample) {
        try { this.tracker.stop({ ...this.lastSample, reason: "captureFailure" }); }
        catch (saveError) { this.onError(saveError); }
      }
      return this.snapshot;
    }
  }
  dispose() {
    if (this.timer !== null) { this.clearTimer(this.timer); this.timer = null; }
    for (const [name, handler] of this.listeners) this.power.removeListener(name, handler);
    this.listeners = [];
    this.tracker.stop({ ...this.clock(), reason: "stopped" });
  }
}
module.exports = { ReaderSessionHost };
