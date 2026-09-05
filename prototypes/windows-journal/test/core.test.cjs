const {test}=require('node:test');const assert=require('node:assert/strict');const fs=require('node:fs');const os=require('node:os');const path=require('node:path');
const {Journal,summary}=require('../src/journal.cjs');const {parseSettings}=require('../tools/sumatra-probe.cjs');
function fixture(t){const dir=fs.mkdtempSync(path.join(os.tmpdir(),'stillleaf-test-'));t.after(()=>fs.rmSync(dir,{recursive:true,force:true}));const j=new Journal(path.join(dir,'journal.json'));j.mutate('addBook',{title:'A book',author:'',totalPages:200,status:'Reading'});return j;}
function entry(j,overrides={}){return {bookId:j.state.books[0].id,date:'2025-01-02',position:null,pagesRead:null,minutes:null,note:'',...overrides};}
test('position never creates pages read or duration; backward position and rereading remain explicit',t=>{const j=fixture(t);j.mutate('addEntry',entry(j,{position:100}));assert.deepEqual(summary(j.state,j.state.books[0].id),{position:100,pagesRead:0,minutes:0,timedEntries:0});j.mutate('addEntry',entry(j,{position:80,pagesRead:25,minutes:12.5}));assert.deepEqual(summary(j.state,j.state.books[0].id),{position:80,pagesRead:25,minutes:12.5,timedEntries:1});});
test('backdated entry does not replace newer position; same-day insertion breaks ties',t=>{const j=fixture(t);j.mutate('addEntry',entry(j,{position:100}));j.mutate('addEntry',entry(j,{date:'2025-01-01',position:12}));assert.equal(summary(j.state,j.state.books[0].id).position,100);});
test('books, statuses, Unicode notes and entries survive reopening; backup is previous state',t=>{const j=fixture(t);j.mutate('addEntry',entry(j,{note:'A thought — 読書',pagesRead:10}));const previous=JSON.stringify(j.state);j.mutate('setStatus',{id:j.state.books[0].id,status:'Finished'});assert.deepEqual(new Journal(j.file).state,j.state);assert.deepEqual(JSON.parse(fs.readFileSync(j.file+'.bak')),JSON.parse(previous));assert.equal(summary(j.state,j.state.books[0].id).position,null);});
test('validation rejects malformed dates, future dates, invalid numbers and unknown books without disk changes',t=>{const j=fixture(t);const before=fs.readFileSync(j.file,'utf8');for(const overrides of [{date:'2025-02-30',note:'x'},{date:'2999-01-01',note:'x'},{position:201},{pagesRead:-1},{position:NaN},{minutes:Infinity},{pagesRead:1.5},{bookId:'missing',note:'x'},{pagesRead:'10'},{}])assert.throws(()=>j.mutate('addEntry',entry(j,overrides)));assert.equal(fs.readFileSync(j.file,'utf8'),before);});
test('duplicate titles remain distinct identities; removal recalculates position and totals',t=>{const j=fixture(t);j.mutate('addBook',{title:'A book',author:'',totalPages:null,status:'Reading'});assert.notEqual(j.state.books[0].id,j.state.books[1].id);j.mutate('addEntry',entry(j,{position:20,pagesRead:20}));j.mutate('addEntry',entry(j,{position:40,pagesRead:20}));j.mutate('deleteEntry',{id:j.state.entries[1].id});assert.equal(summary(j.state,j.state.books[0].id).position,20);assert.equal(summary(j.state,j.state.books[0].id).pagesRead,20);});
test('corrupt and unknown-version journals are preserved and rejected',t=>{const j=fixture(t);for(const content of ['{broken',JSON.stringify({...j.state,version:999})]){fs.writeFileSync(j.file,content);assert.throws(()=>new Journal(j.file));assert.equal(fs.readFileSync(j.file,'utf8'),content);}});
test('failed commit leaves in-memory state unchanged',t=>{const j=fixture(t);const before=structuredClone(j.state);fs.mkdirSync(j.file+'.bak');assert.throws(()=>j.mutate('addEntry',entry(j,{pagesRead:1})));assert.deepEqual(j.state,before);assert.deepEqual(new Journal(j.file).state,before);});
const settings=String.raw`RememberStatePerDocument = true
FileStates [
 [
 FilePath = C:\Books\My [book].pdf
 Favorites [
 [
 PageNo = 99
 ]
 ]
 PageNo = 12
 UseDefaultState = false
 ]
 [
 FilePath = C:\Books\Novel.epub
 PageNo = 25
 ]
]`;
test('Sumatra probe extracts PDF saved position, ignores nested bookmark page and EPUB',()=>{const data=parseSettings(settings);assert.equal(data.length,1);assert.equal(data[0].position,12);assert.equal(data[0].liveReaderVerified,false);assert.equal(data[0].documentPath,'C:\\Books\\My [book].pdf');});
test('Sumatra probe fails closed on partial/ambiguous syntax, skips disabled or default state',()=>{assert.throws(()=>parseSettings(settings.slice(0,-1)));assert.throws(()=>parseSettings(settings.replace('PageNo = 12','PageNo = 12\nPageNo = 13')));assert.deepEqual(parseSettings(settings.replace('RememberStatePerDocument = true','RememberStatePerDocument = false')),[]);assert.deepEqual(parseSettings(settings.replace('UseDefaultState = false','UseDefaultState = true')),[]);});

test('reopening preserves valid recorded dates after clock or timezone moves backward',t=>{const j=fixture(t);j.mutate('addEntry',entry(j,{note:'Recorded before clock correction'}));const saved=structuredClone(j.state);saved.entries[0].date='2999-01-01';fs.writeFileSync(j.file,JSON.stringify(saved));assert.deepEqual(new Journal(j.file).state,saved);});
