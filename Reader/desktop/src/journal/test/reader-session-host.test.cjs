"use strict";
const { test } = require("node:test"), assert = require("node:assert/strict"), { EventEmitter } = require("node:events");
const { ReaderSessionHost } = require("../reader-session-host.cjs");
function fixture(watermark = null) {
  const power = new EventEmitter(), intervals = [], events = [], errors = [];
  let time = 0, lock = "active", timer, reader = null;
  power.getSystemIdleState = () => lock;
  const host = new ReaderSessionHost({ powerMonitor: power, getReader: () => reader,
    clock: () => ({ date: Date.UTC(2026, 8, 24) + time * 1000, uptime: time + 100 }),
    timezoneId: "UTC", checkpointSeconds: 2,
    journal: { trackingWatermark: () => watermark, appendTrackingBatch: batch => { intervals.push(...batch.intervals); events.push(...batch.events); } },
    onError: e => errors.push(e.message), setTimer: callback => { timer = callback; return 1; }, clearTimer: () => { timer = null; } });
  return { host, power, intervals, errors, setReader: value => reader = value, setLock: value => lock = value,
    advance: (seconds = 1) => { time += seconds; timer?.(); }, tick: () => timer?.() };
}
test("host credits only ready focused readers and excludes lock/suspend/gaps without inferring pages", () => {
  const f = fixture(); f.host.start();
  f.advance(1); assert.equal(f.intervals.length, 0, "Library/import never starts reading");
  const reader = { bookId: "book", ready: true, focused: true, minimized: false, destroyed: false };
  f.setReader(reader); f.tick();
  for (let i = 0; i < 5; i++) f.advance();
  f.power.emit("lock-screen");
  assert.equal(f.host.snapshot.phase, "paused");
  assert.equal(f.intervals.filter(x => x.disposition === "credited").reduce((n, x) => n + x.duration, 0), 5);
  assert.ok(f.intervals.every(x => x.disposition === "credited"));
  const before = f.intervals.reduce((n, x) => n + x.duration, 0);
  f.advance(60); f.power.emit("unlock-screen"); f.advance(1);
  reader.focused = false; f.tick(); f.advance(20);
  assert.equal(f.intervals.reduce((n, x) => n + x.duration, 0), before + 1);
  reader.focused = true; f.tick(); f.advance(20);
  f.power.emit("suspend"); f.advance(100); f.power.emit("resume");
  f.host.dispose();
  assert.equal(f.intervals.reduce((n, x) => n + x.duration, 0), before + 1, "outage/sleep never fills missing time");
  assert.ok(f.intervals.every(x => !("pages" in x)), "layout and time do not invent page credits");
  assert.deepEqual(f.errors, []); assert.equal(f.power.listenerCount("lock-screen"), 0);
});
test("unknown lock observation stops at the last trusted sample without filling time", () => {
  const f = fixture(); f.setReader({ bookId: "book", ready: true, focused: true }); f.host.start();
  f.advance(1); f.setLock("unknown"); f.advance(1);
  assert.equal(f.host.snapshot.phase, "paused");
  assert.equal(f.intervals.reduce((n, x) => n + x.duration, 0), 1);
  assert.match(f.errors[0], /lock state/); f.host.dispose();
});
test("restart accepts the journal ISO watermark and never credits already saved time", () => {
  const watermark = "2026-09-24T00:00:02.000Z", f = fixture(watermark);
  f.setReader({ bookId: "book", ready: true, focused: true }); f.host.start();
  f.advance(); f.advance();
  assert.equal(f.intervals.length, 0);
  f.advance(1); f.advance(); f.host.dispose();
  assert.deepEqual(f.errors, []);
  assert.ok(f.intervals.length > 0);
  assert.ok(f.intervals.every(row => Date.parse(row.start) >= Date.parse(watermark)));
});
test("fractional timer jitter preserves all focused reading without input", () => {
  const f = fixture(); f.setLock("idle"); f.setReader({ bookId: "book", ready: true, focused: true }); f.host.start();
  for (let i = 0; i < 5; i++) { f.advance(1.2); f.advance(0.8); }
  f.host.dispose();
  assert.equal(f.intervals.filter(row => row.disposition === "credited").reduce((sum, row) => sum + row.duration, 0), 10);
  assert.ok(f.intervals.every(row => row.disposition === "credited"));
  assert.deepEqual(f.errors, []);
});
