"use strict";
const {test} = require("node:test"), assert = require("node:assert/strict");
const {SessionTracker} = require("../session-tracker.cjs");
const start = Date.parse("2026-09-24T12:00:00Z");
function fixture(options = {}) {
  const batches = []; let id = 0;
  const tracker = new SessionTracker({persist: batch => batches.push(batch), makeId: () => `fixture-${++id}`, ...options});
  const sample = (seconds, changes = {}) => tracker.sample({date: start + seconds * 1000, uptime: seconds, bookId: "book-a", eligible: true, ...changes});
  return {tracker, batches, sample, intervals: () => batches.flatMap(x => x.intervals), events: () => batches.flatMap(x => x.events)};
}
function total(intervals, disposition) { return intervals.filter(x => !disposition || x.disposition === disposition).reduce((sum,x) => sum + x.duration, 0); }
function noOverlap(intervals) {
  const sorted = intervals.toSorted((a,b) => Date.parse(a.start) - Date.parse(b.start));
  sorted.forEach((interval,i) => { assert.ok(interval.duration > 0); if (i) assert.ok(Date.parse(interval.start) >= Date.parse(sorted[i-1].end)); });
}
test("trusted samples checkpoint exact segments, with identity and no pages", () => {
  const f = fixture({timezoneId:"America/Los_Angeles"});
  for (let t = 0; t <= 20; t++) f.sample(t);
  f.tracker.stop({date:start+20000,uptime:20});
  assert.deepEqual(f.intervals().map(x=>x.duration),[15,5]);
  for (const interval of f.intervals()) {
    assert.equal(interval.bookId,"book-a"); assert.equal(interval.mode,"automatic"); assert.equal(interval.source,"stillleaf-epub"); assert.equal(interval.timezoneId,"America/Los_Angeles"); assert.equal(interval.pages,undefined);
  }
  assert.equal(new Set(f.intervals().map(x=>x.id)).size,2);
  assert.equal(new Set(f.intervals().map(x=>x.sessionId)).size,1);
  noOverlap(f.intervals());
  assert.equal(f.events().find(x=>x.kind==="trackingCheckpoint").date,new Date(start+15000).toISOString());
});
test("book switch creates separate sessions without overlapping credit", () => {
  const f=fixture(); const a=f.sample(0).sessionId; f.sample(4);
  const b=f.sample(5,{bookId:"book-b"}).sessionId; assert.notEqual(a,b);
  f.sample(8,{bookId:"book-b"}); f.tracker.stop({date:start+8000,uptime:8});
  assert.deepEqual(f.intervals().map(x=>[x.bookId,x.duration]),[["book-a",5],["book-b",3]]); noOverlap(f.intervals());
});
test("brief ineligible pause resumes same session without crediting gap", () => {
  const f=fixture(); const first=f.sample(0).sessionId; f.sample(4);
  f.sample(5,{eligible:false,reason:"background"});
  assert.equal(f.sample(100).sessionId,first);
  f.sample(103);f.tracker.stop({date:start+103000,uptime:103});
  assert.equal(total(f.intervals()),8); noOverlap(f.intervals());
});
test("long pause and source changes do not reuse sessions", () => {
  const f=fixture();const a=f.sample(0).sessionId;f.sample(2,{eligible:false});
  const b=f.sample(130).sessionId;assert.notEqual(a,b);
  f.sample(131,{eligible:false});assert.notEqual(f.sample(132,{source:"other-reader"}).sessionId,b);
});
test("sleep or scheduler gap closes at last trusted sample", () => {
  const f=fixture();const first=f.sample(0).sessionId;f.sample(4);
  assert.notEqual(f.sample(20).sessionId,first);f.sample(22);f.tracker.stop({date:start+22000,uptime:22});
  assert.equal(total(f.intervals()),6);assert.ok(f.events().some(x=>x.reason==="captureFailure"));noOverlap(f.intervals());
});
test("rollback closes trusted tail and holds until durable watermark", () => {
  const f=fixture();f.sample(0);f.sample(4);
  const held=f.sample(5,{date:start+2000});assert.equal(held.reason,"clockDiscontinuity");
  assert.equal(total(f.intervals()),4);
  f.sample(6,{date:start+3000});assert.equal(f.events().filter(x=>x.kind==="trackingClockHold").length,1);
  assert.equal(f.sample(7,{date:start+4000}).phase,"reading");
  f.sample(8,{date:start+5000});f.tracker.stop({date:start+5000,uptime:8});noOverlap(f.intervals());
});
test("startup durable watermark rejects replay credit", () => {
  const f=fixture({durableThrough:start+10000});
  assert.equal(f.sample(0).phase,"paused");assert.equal(f.sample(11).phase,"reading");assert.equal(total(f.intervals()),0);
});
test("uninterrupted foreground reading stays credited beyond the former inactivity limit", () => {
  const f=fixture();
  f.sample(0);for(let t=1;t<=1800;t++) f.sample(t,{locator:{progression:t/1801},cause:t%2?"restore":"layout"});
  assert.equal(f.tracker.snapshot.phase,"reading");
  assert.equal(f.tracker.snapshot.creditedSeconds,1800);
  f.tracker.stop({date:start+1800000,uptime:1800});
  assert.equal(total(f.intervals(),"credited"),1800);
  assert.ok(f.intervals().every(row=>row.disposition==="credited" && row.pages===undefined));
  noOverlap(f.intervals());
});
test("persistence failure does not advance internal timing; retry remains nonoverlapping", () => {
  let fail=false; const batches=[];
  const f=fixture({persist:batch=>{if(fail)throw Error("disk failure");batches.push(batch);}});
  f.sample(0);f.sample(4);fail=true;
  assert.throws(()=>f.sample(5,{eligible:false}),/disk failure/);assert.equal(f.tracker.snapshot.phase,"reading");
  fail=false;f.sample(5,{eligible:false});
  const intervals=batches.flatMap(x=>x.intervals);assert.equal(total(intervals),5);noOverlap(intervals);
});
test("invalid explicit clocks and eligibility fail before persistence", () => {
  const f=fixture();
  for(const change of [{uptime:-1},{uptime:NaN},{date:Infinity},{eligible:1}]) assert.throws(()=>f.sample(0,change));
  assert.equal(f.batches.length,0);
});
