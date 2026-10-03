"use strict";
const {test} = require("node:test"), assert = require("node:assert/strict"), fs = require("node:fs"), os = require("node:os"), path = require("node:path");
const {DatabaseSync} = require("node:sqlite");
const {JournalStore,SCHEMA_VERSION} = require("../store.cjs"), {SessionTracker} = require("../session-tracker.cjs");
const at = "2026-09-24T12:00:00.000Z";
function fixture(t, options) {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(),"stillleaf-tracking-store-")), file = path.join(directory,"journal.sqlite");
  let store = new JournalStore(file, options);
  store.createBook({id:"book",title:"Synthetic",recordedAt:at});
  t.after(()=>{try{store.close()}catch{}fs.rmSync(directory,{recursive:true,force:true});});
  return {directory,file,get store(){return store},restart(){store.close();store=new JournalStore(file,options);return store;}};
}
function interval(id, start, end, extra={}) { return {id,sessionId:"session",bookId:"book",source:"stillleaf-epub",mode:"automatic",timezoneId:"UTC",start,end,duration:(Date.parse(end)-Date.parse(start))/1000,disposition:"credited",...extra}; }
function event(id, extra={}) { return {id,kind:"trackingCheckpoint",bookId:"book",sessionId:"session",source:"stillleaf-epub",mode:"automatic",timezoneId:"UTC",date:at,reason:null,...extra}; }
test("actual SQLite v1 migrates only after validated full backup, retaining source data",t=>{
  const f=fixture(t); f.store.addManualEntry({id:"manual",bookId:"book",day:"2026-09-24",timeZone:"UTC",minutes:7,recordedAt:at});
  // Removing only v2 additions produces the actual original v1 schema.
  f.store.db.exec("DROP TABLE tracking_intervals;PRAGMA user_version=1;");
  const migrated=f.restart();assert.equal(migrated.db.prepare("PRAGMA user_version").get().user_version,SCHEMA_VERSION);
  assert.equal(migrated.dailyProgress("2026-09-24").minutes,7);assert.ok(migrated.migrationBackup);
  const copy=new DatabaseSync(migrated.migrationBackup,{readOnly:true});
  try {assert.equal(copy.prepare("PRAGMA integrity_check").get().integrity_check,"ok");assert.equal(copy.prepare("PRAGMA user_version").get().user_version,1);assert.equal(copy.prepare("SELECT minutes FROM manual_entries").get().minutes,7);assert.equal(copy.prepare("SELECT COUNT(*) AS n FROM sqlite_master WHERE name='tracking_intervals'").get().n,0);}finally{copy.close()}
  assert.equal(f.restart().migrationBackup,null);
});
test("newer schemas reject without mutation or backup",t=>{
  const directory=fs.mkdtempSync(path.join(os.tmpdir(),"stillleaf-future-tracking-"));t.after(()=>fs.rmSync(directory,{recursive:true,force:true}));
  const file=path.join(directory,"future.sqlite"),db=new DatabaseSync(file);db.exec("CREATE TABLE precious(value TEXT); INSERT INTO precious VALUES('preserve'); PRAGMA user_version=99;");db.close();
  const before=fs.readFileSync(file);assert.throws(()=>new JournalStore(file),/Newer/);assert.deepEqual(fs.readFileSync(file),before);assert.deepEqual(fs.readdirSync(directory),["future.sqlite"]);
});
test("atomic tracking sink persists across restart and repeated batch is idempotent",t=>{
  const f=fixture(t), batch={intervals:[interval("interval-a",at,"2026-09-24T12:00:15.000Z")],events:[event("event-a")]};
  assert.equal(f.store.appendTrackingBatch(batch).insertedIntervals,1);
  const reopened=f.restart();assert.equal(reopened.appendTrackingBatch(batch).insertedIntervals,0);assert.equal(reopened.trackingIntervals("book").length,1);assert.equal(reopened.events("trackingCheckpoint","book").length,1);assert.equal(reopened.trackingWatermark(),"2026-09-24T12:00:15.000Z");
  assert.equal(reopened.dailyProgress("2026-09-24").minutes,0.25);
  assert.throws(()=>reopened.appendTrackingBatch({intervals:[{...batch.intervals[0],duration:14}],events:[]}),/identity conflicts/);
});
test("SQL sink failure and event identity conflicts roll back all inserted intervals",t=>{
  const f=fixture(t);f.store.appendTrackingBatch({intervals:[],events:[event("exists")]});
  const batch={intervals:[interval("rollback",at,"2026-09-24T12:00:15.000Z")],events:[event("exists",{reason:"different"})]};
  assert.throws(()=>f.store.appendTrackingBatch(batch),/identity conflicts/);assert.equal(f.store.trackingIntervals().length,0);
  f.store.db.exec("CREATE TRIGGER fail_tracking BEFORE INSERT ON tracking_intervals BEGIN SELECT RAISE(ABORT,'fixture disk error'); END;");
  assert.throws(()=>f.store.appendTrackingBatch({intervals:batch.intervals,events:[event("not-inserted")]}),/fixture disk error/);
  assert.equal(f.store.events("trackingCheckpoint").length,1);assert.equal(f.store.trackingWatermark(),null);
});
test("date boundary splits duration proportionally and credits legacy pending time",t=>{
  const f=fixture(t,{timeZone:"America/Los_Angeles"});
  f.store.addManualEntry({bookId:"book",day:"2026-09-24",timeZone:"America/Los_Angeles",pages:5,minutes:7,recordedAt:"2026-09-25T12:00:00Z"});
  f.store.appendTrackingBatch({intervals:[interval("boundary","2026-09-25T06:59:00Z","2026-09-25T07:01:00Z",{duration:100}),interval("uncertain","2026-09-25T07:01:00Z","2026-09-25T07:02:00Z",{disposition:"uncertain"})],events:[]});
  const before=f.store.dailyProgress("2026-09-24"),after=f.store.dailyProgress("2026-09-25");
  assert.equal(before.creditedSeconds,50);assert.equal(before.minutes,7+50/60);assert.equal(before.pages,5);
  assert.equal(after.creditedSeconds,110);assert.equal(after.uncertainSeconds,undefined);assert.equal(after.minutes,110/60);assert.equal(after.pages,0);
  assert.equal(f.store.dailyProgress("2026-09-25","UTC").creditedSeconds,160);
});
test("DST day uses real 23-hour civil window instead of a fixed 24 hours",t=>{
  const f=fixture(t,{timeZone:"America/Los_Angeles"});
  f.store.appendTrackingBatch({intervals:[interval("spring","2026-03-08T08:00:00Z","2026-03-09T07:00:00Z")],events:[]});
  assert.equal(f.store.dailyProgress("2026-03-08").creditedSeconds,23*3600);assert.equal(f.store.dailyProgress("2026-03-09").creditedSeconds,0);
});
test("overlap and fabricated pages reject, preserving existing manual goals",t=>{
  const f=fixture(t);const saved=interval("saved",at,"2026-09-24T12:00:15Z");f.store.appendTrackingBatch({intervals:[saved],events:[]});
  assert.throws(()=>f.store.appendTrackingBatch({intervals:[{...saved,id:"overlap"}],events:[]}),/overlap/);
  assert.throws(()=>f.store.appendTrackingBatch({intervals:[{...saved,id:"pages",pages:10}],events:[]}),/cannot infer pages/);
  assert.equal(f.store.trackingIntervals().length,1);assert.equal(f.store.dailyProgress("2026-09-24").pages,0);
});
test("SessionTracker uses adapter atomically and recovered watermark holds rollback",t=>{
  const f=fixture(t),tracker=new SessionTracker({persist:batch=>f.store.appendTrackingBatch(batch),timezoneId:"UTC"});
  for(let second=0;second<=20;second++) tracker.sample({date:Date.parse(at)+second*1000,uptime:second,bookId:"book",eligible:true});
  tracker.stop({date:Date.parse(at)+20000,uptime:20});
  assert.equal(f.restart().trackingIntervals().reduce((n,x)=>n+x.duration,0),20);
  const restored=new SessionTracker({persist:batch=>f.store.appendTrackingBatch(batch),durableThrough:Date.parse(f.store.trackingWatermark())});
  assert.equal(restored.sample({date:Date.parse(at),uptime:0,bookId:"book",eligible:true}).phase,"paused");
});

test("failed migration rolls back schema and keeps validated original backup",t=>{
  const f=fixture(t);f.store.db.exec("DROP TABLE tracking_intervals; CREATE VIEW tracking_intervals AS SELECT book_id FROM books; PRAGMA user_version=1;");
  assert.throws(()=>f.restart(),/already exists/);
  const original=new DatabaseSync(f.file,{readOnly:true});
  try {assert.equal(original.prepare("PRAGMA user_version").get().user_version,1);assert.equal(original.prepare("SELECT title FROM books WHERE book_id='book'").get().title,"Synthetic");assert.equal(original.prepare("SELECT type FROM sqlite_master WHERE name='tracking_intervals'").get().type,"view");}finally{original.close()}
  const backups=fs.readdirSync(f.directory).filter(x=>x.includes(".pre-v2-"));assert.equal(backups.length,1);
  const saved=new DatabaseSync(path.join(f.directory,backups[0]),{readOnly:true});try{assert.equal(saved.prepare("PRAGMA integrity_check").get().integrity_check,"ok");assert.equal(saved.prepare("PRAGMA user_version").get().user_version,1);}finally{saved.close()}
});
test("one session cannot silently change its book or source",t=>{
  const f=fixture(t);f.store.appendTrackingBatch({intervals:[interval("first",at,"2026-09-24T12:00:15Z")],events:[]});
  assert.throws(()=>f.store.appendTrackingBatch({intervals:[interval("second","2026-09-24T12:00:15Z","2026-09-24T12:00:30Z",{source:"different-source"})],events:[]}),/session identity conflicts/);
  assert.equal(f.store.trackingIntervals().length,1);
});

test("legacy SQLite pending rows normalize without changing IDs or exclusions across reopen and replay",t=>{
  const f=fixture(t);
  const pending=interval("legacy-pending",at,"2026-09-24T12:01:00.000Z",{disposition:"uncertain"});
  const excluded=interval("excluded","2026-09-24T12:01:00.000Z","2026-09-24T12:02:00.000Z",{disposition:"excluded"});
  // Insert actual old column and payload values, bypassing the new write normalizer.
  for(const item of [pending,excluded]) f.store.db.prepare("INSERT INTO tracking_intervals VALUES(?,?,?,?,?,?,?,?,?,?,?)").run(item.id,item.sessionId,item.bookId,item.start,item.end,item.duration,item.timezoneId,item.mode,item.source,item.disposition,JSON.stringify(item));
  f.store.setReview({bookId:"book",text:"Keep this book review.",recordedAt:at});
  const reopened=f.restart();
  assert.deepEqual(reopened.trackingIntervals(),[{...pending,disposition:"credited"},excluded]);
  assert.equal(reopened.dailyProgress("2026-09-24").creditedSeconds,60);
  assert.equal(reopened.dailyProgress("2026-09-24").pages,0);
  assert.equal(reopened.appendTrackingBatch({intervals:[pending,excluded],events:[]}).insertedIntervals,0);
  assert.equal(reopened.appendTrackingBatch({intervals:[{...pending,disposition:"credited"}],events:[]}).insertedIntervals,0);
  assert.throws(()=>reopened.appendTrackingBatch({intervals:[{...excluded,disposition:"credited"}],events:[]}),/identity conflicts/);
  assert.equal(reopened.db.prepare("SELECT payload FROM tracking_intervals WHERE interval_id=?").get(pending.id).payload,JSON.stringify(pending),"read compatibility leaves original evidence intact");
  assert.equal(f.restart().dailyProgress("2026-09-24").creditedSeconds,60);
  assert.equal(f.store.review("book"),"Keep this book review.");
});
