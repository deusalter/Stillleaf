const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs/promises');
const os=require('node:os');
const path=require('node:path');
const {LibraryArchive}=require('../src/library-archive.cjs');
const {JournalStore}=require('../src/journal/store.cjs');
const {emptyState,saveReaderState}=require('../src/reader-state.cjs');
async function fixture(t){
 const temp=await fs.mkdtemp(path.join(os.tmpdir(),'stillleaf-library-archive-'));
 const root=path.join(temp,'library'),journal=new JournalStore(path.join(temp,'journal.sqlite'));
 t.after(async()=>{journal.close();await fs.rm(temp,{recursive:true,force:true})});
 const {epub,zip}=await import('../../packages/publication/test/fixtures.js');
 const {importEPUB}=await import('../../packages/publication/index.js');
 const source=path.join(temp,'original.epub');await fs.writeFile(source,zip(epub()));
 const imported=await importEPUB(source,root);
 journal.attachEdition({editionId:imported.editionId,title:'Archive fixture',creators:[],recordedAt:'2026-09-27T12:00:00Z'});
 const state=emptyState(imported.editionId);state.revision=1;
 state.preferences={...state.preferences,fontFamily:'literata',theme:'custom',backgroundColor:'#162530',textColor:'#F2E6CB',sideMargin:null,contentWidth:100,immersive:false};
 await saveReaderState(root,imported.editionId,imported.publication,state);
 return{temp,root,journal,source,...imported,archive:new LibraryArchive({root,journal})};
}
test('complete Library export preserves EPUB bytes and state, recovery is idempotent and never overwrites',async t=>{
 const f=await fixture(t),file=path.join(f.temp,'complete.zip');
 const result=await f.archive.exportTo(file);assert.equal(result.epubs,1);assert.equal(result.readerStates,1);assert.equal(result.books,1);
 const {token,summary}=await f.archive.preview(file);assert.equal(summary.activation,'preservation-only');assert.equal(summary.missingEPUBs,0);
 const before=f.journal.listBooks();const preserved=await f.archive.preserve(token);assert.equal(preserved.identical,false);
 assert.equal((await f.archive.preserve(token)).identical,true);assert.deepEqual(f.journal.listBooks(),before);
 const copy=path.join(f.temp,'copy.zip');await f.archive.exportPreserved(preserved.id,copy);assert.deepEqual(await fs.readFile(copy),await fs.readFile(file));
 await assert.rejects(f.archive.exportTo(file));await assert.rejects(f.archive.exportPreserved(preserved.id,copy));
 const combined=path.join(f.temp,'combined.zip');assert.equal((await f.archive.exportTo(combined)).preservedArchives,1);
 assert.deepEqual(await fs.readFile(f.source),await fs.readFile(path.join(f.root,'editions',f.editionId,'original.epub')));
});
test('unrecognized state and linked sources fail without a partial archive or changing the journal',async t=>{
 const f=await fixture(t),file=path.join(f.temp,'unsafe.zip'),stateRoot=path.join(f.root,'reader-state');
 const before=f.journal.listBooks();await fs.writeFile(path.join(stateRoot,'unknown.json'),'private');
 await assert.rejects(f.archive.exportTo(file),/Unrecognized reader state/);await assert.rejects(fs.stat(file),{code:'ENOENT'});
 await fs.unlink(path.join(stateRoot,'unknown.json'));
 const original=path.join(f.root,'editions',f.editionId,'original.epub');await fs.unlink(original);await fs.symlink(f.source,original);
 await assert.rejects(f.archive.exportTo(file));await assert.rejects(fs.stat(file),{code:'ENOENT'});assert.deepEqual(f.journal.listBooks(),before);
});
