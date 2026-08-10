"use strict";
const { SessionTracker } = require("./session-tracker.cjs");

/** Main-process adapter. The publication has no access to this controller or clock.
 * getReader returns only host-owned {bookId,ready,focused,minimized,destroyed}.
 * No locator, page number or layout callback is treated as activity evidence.
 */
class ReaderSessionHost {
  constructor({ journal, powerMonitor, getReader, clock = () => ({ date: Date.now(), uptime: Number(process.hrtime.bigint()) / 1e9 }),
    timezoneId = Intl.DateTimeFormat().resolvedOptions().timeZone, onError = () => {}, onChanged = () => {},
    setTimer = setInterval, clearTimer = clearInterval, uncertaintySeconds = 1200, checkpointSeconds = 15 }) {
    this.power = powerMonitor; this.getReader = getReader; this.clock = clock;
    this.onError = onError; this.onChanged = onChanged; this.setTimer = setTimer; this.clearTimer = clearTimer;
    this.blocks = new Set(); this.listeners = []; this.lastInputUpper = null; this.timer = null;
    const durableThrough = journal.trackingWatermark();
    this.tracker = new SessionTracker({ timezoneId, uncertaintySeconds, checkpointSeconds,
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
      const idle = this.power.getSystemIdleTime();
      if (!Number.isFinite(idle) || idle < 0) throw Error("System input timing is unavailable.");
      const idleState = this.power.getSystemIdleState(1);
      if (!["active", "idle", "locked"].includes(idleState)) throw Error("System lock state is unavailable.");
      const locked = idleState === "locked";
      const eligible = Boolean(reader?.bookId && reader.ready && reader.focused && !reader.minimized && !reader.destroyed && !locked && !this.blocks.size);
      // Electron idle time is quantized to seconds. Overlapping input-time ranges
      // are not fresh activity: fractional timer drift must not reset uncertainty.
      const inputUpper = sample.uptime - idle;
      const freshInput = this.lastInputUpper === null || inputUpper - 1 > this.lastInputUpper;
      const nextInputUpper = freshInput ? inputUpper : Math.min(this.lastInputUpper, inputUpper);
      const activity = eligible && freshInput;
      const reason = locked || this.blocks.has("lock") ? "locked" : this.blocks.size ? "suspended" : !reader?.ready ? "noReadingWindow" : "background";
      const result = this.tracker.sample({ ...sample, bookId: reader?.bookId ?? null, eligible, activity,
        source: "stillleaf-epub", mode: "automatic", reason });
      this.lastInputUpper = nextInputUpper; this.lastSample = sample; return result;
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
