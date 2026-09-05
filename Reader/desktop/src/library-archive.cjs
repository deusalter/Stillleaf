"use strict";
const fs = require('node:fs/promises');
const {constants} = require('node:fs');
const path = require('node:path');
const {pathToFileURL} = require('node:url');
const {createHash,randomUUID} = require('node:crypto');
const {readEdition} = require('./library-store.cjs');
const ID=/^[a-f0-9]{64}$/;
const MAX=256*1024*1024;
const digest=bytes=>createHash('sha256').update(bytes).digest('hex');
const moduleURL=name=>pathToFileURL(path.join(__dirname,'../../packages/archive',name)).href;
let modules;
async function archiveModules(){return modules??=Promise.all([import(moduleURL('index.js')),import(moduleURL('node-journal.js'))]);}
async function directory(file,{optional=false}={}) {
  try {const stat=await fs.lstat(file);if(!stat.isDirectory()||stat.isSymbolicLink())throw Error('Archive source directory is unsafe.');return true;}
  catch(error){if(optional&&error.code==='ENOENT')return false;throw error;}
}
async function readBounded(file,max) {
  const stat=await fs.lstat(file);if(!stat.isFile()||stat.isSymbolicLink()||stat.size>max)throw Error('Archive source file is unsafe or exceeds the size limit.');
  const handle=await fs.open(file,constants.O_RDONLY|constants.O_NOFOLLOW);
  try {const before=await handle.stat();if(!before.isFile()||before.size>max)throw Error('Archive source file changed.');const bytes=Buffer.alloc(before.size);let offset=0;
    while(offset<bytes.length){const {bytesRead}=await handle.read(bytes,offset,bytes.length-offset,offset);if(!bytesRead)throw Error('Archive source changed while reading.');offset+=bytesRead;}
    const after=await handle.stat();if(after.size!==before.size||after.mtimeMs!==before.mtimeMs||after.ctimeMs!==before.ctimeMs)throw Error('Archive source changed while reading.');return bytes;
  } finally {await handle.close();}
}
async function relativeFile(root,relative) {
  if(typeof relative!=='string'||relative.split('/').some(x=>!x||x==='.'||x==='..')||/[\\:\0%?#]/.test(relative))throw Error('Unsafe archive source reference.');
  let current=root;for(const part of relative.split('/')){current=path.join(current,part);if((await fs.lstat(current)).isSymbolicLink())throw Error('Linked archive sources are not supported.');}return current;
}
function counts(entries) {return {journals:entries.filter(x=>x.role==='journal').length,readerStates:entries.filter(x=>x.role==='reader-state').length,epubs:entries.filter(x=>x.role==='epub').length,covers:entries.filter(x=>x.role==='cover').length};}
class LibraryArchive {
  constructor({root,journal,producer={host:'stillleaf-desktop',version:'development'}}) {
    if(!path.isAbsolute(root))throw Error('Archive needs an absolute library root.');this.root=root;this.journal=journal;this.producer=producer;this.preservedRoot=path.join(root,'preserved-archives');
  }
  // Caller holds the host operation lock, has flushed reader state and suspended sampling/input.
  async exportTo(destination) {
    const [archive,node]=await archiveModules();if(!(await directory(this.root,{optional:true})))await fs.mkdir(this.root,{recursive:true,mode:0o700});await directory(this.root);
    const staging=await fs.mkdtemp(path.join(this.root,'.archive-export-'));await fs.chmod(staging,0o700);
    const files=[];let total=0;let importedArchives=0;
    const add=async(bytes,descriptor)=>{total+=bytes.length;if(total>MAX)throw Error('This library exceeds the 256 MiB portable archive limit. No partial archive was exported.');
      if(files.length>=9998)throw Error('This library has too many archive files. No partial archive was exported.');
      const target=path.join(staging,descriptor.path);await fs.mkdir(path.dirname(target),{recursive:true,mode:0o700});await fs.writeFile(target,bytes,{flag:'wx',mode:0o600});files.push(descriptor);};
    try {
      const journalBytes=node.exportNodeJournal(this.journal.db);
      await add(journalBytes,{path:'journals/desktop.json',role:'journal',format:'node-journal-json',schemaVersion:1});
      const associations=new Map(this.journal.listBooks().flatMap(b=>b.editionIds.map(id=>[id,b.book_id])));
      const stateRoot=path.join(this.root,'reader-state');
      if(await directory(stateRoot,{optional:true}))for(const name of (await fs.readdir(stateRoot)).sort()) {
        if(!/^[a-f0-9]{64}\.json(?:\.bak|\.recovery-[a-f0-9-]+|\.tmp-[a-f0-9-]+)?$/.test(name))throw Error('Unrecognized reader state file; export stopped to avoid omitting saved data.');
        const id=name.slice(0,64),primary=name===id+'.json';
        await add(await readBounded(path.join(stateRoot,name),2*1024*1024),{path:'reader-state/'+name,role:primary?'reader-state':'provenance',editionId:id,...(associations.has(id)?{bookId:associations.get(id)}:{}),...(primary?{}:{sourceKind:'reader-state-recovery'})});
      }
      const retained=path.join(this.root,'retained');
      if(await directory(retained,{optional:true}))for(const name of (await fs.readdir(retained)).sort()) {
        if(!/^[a-f0-9]{64}\.json(?:\.bak|\.tmp-[a-f0-9-]+)?$/.test(name))throw Error('Unrecognized retained publication record; export stopped.');
        await add(await readBounded(path.join(retained,name),4*1024*1024),{path:'retained/'+name,role:'provenance',editionId:name.slice(0,64),sourceKind:'retained-publication-receipt'});
      }
      const editions=path.join(this.root,'editions');
      if(await directory(editions,{optional:true}))for(const id of (await fs.readdir(editions)).filter(x=>ID.test(x)).sort()) {
        const {publication}=await readEdition(this.root,id),editionRoot=path.join(editions,id);
        await add(await readBounded(path.join(editionRoot,'publication.json'),4*1024*1024),{path:`receipts/${id}.json`,role:'provenance',editionId:id,sourceKind:'publication-receipt-not-authority'});
        const descriptor={editionId:id,...(associations.has(id)?{bookId:associations.get(id)}:{})};
        await add(await readBounded(path.join(editionRoot,'original.epub'),128*1024*1024),{path:`editions/${id}/original.epub`,role:'epub',...descriptor});
        if(publication.cover){const cover=publication.cover;const source=await relativeFile(editionRoot,'resources/'+cover.path);
          await add(await readBounded(source,32*1024*1024),{path:`covers/${id}/embedded-cover`,role:'cover',...descriptor,mediaType:cover.mediaType,provenance:'epub-metadata'});}
      }
      const saved=await this.listPreserved();if(saved.warnings.length)throw Error(saved.warnings.join(' ')+' Export stopped rather than omitting a recovery archive.');
      for(const item of saved.archives) {
        const preview=await archive.inspectArchive(path.join(this.preservedRoot,item.id,'original.stillleaf.zip'));
        if(preview.sha256!==item.id)throw Error('A preserved archive changed; export stopped.');
        const sourceStage=path.join(staging,'.preserved-source-'+item.id);await archive.stageImport(preview,sourceStage);
        for(const entry of preview.manifest.entries) {
          await add(await readBounded(path.join(sourceStage,'payloads',entry.path),128*1024*1024),{...entry,path:`preserved/${item.id}/${entry.path}`,sourceArchive:item.id});
        }
        await add(await readBounded(path.join(sourceStage,'payloads/manifest.json'),2*1024*1024),{path:`preserved/${item.id}/source-manifest.json`,role:'provenance',sourceArchive:item.id,sourceKind:'portable-archive-manifest'});
        importedArchives++;
      }
      const exported=await archive.exportArchive({sourceRoot:staging,files,producer:this.producer},destination);
      return {...exported,...counts(files),preservedArchives:importedArchives,books:this.journal.listBooks().length};
    } finally {await fs.rm(staging,{recursive:true,force:true});}
  }
  async preview(source) {
    const [archive]=await archiveModules();const preview=await archive.inspectArchive(source);
    return {token:preview,summary:{...counts(preview.manifest.entries),bytes:preview.bytes,missingEPUBs:preview.pendingReaderStates.length,foreignJournals:preview.manifest.entries.filter(e=>e.role==='journal'&&e.format==='native-history-json').length,archiveId:preview.manifest.archiveId,sha256:preview.sha256,activation:'preservation-only'}};
  }
  async preserve(preview) {
    const [archive]=await archiveModules();if(!(await directory(this.root,{optional:true})))await fs.mkdir(this.root,{recursive:true,mode:0o700});await directory(this.root);await fs.mkdir(this.preservedRoot,{recursive:true,mode:0o700});await directory(this.preservedRoot);
    const destination=path.join(this.preservedRoot,preview.sha256);
    try {await fs.lstat(destination);await directory(destination);
      const ready=JSON.parse((await readBounded(path.join(destination,'READY.json'),4*1024*1024)).toString('utf8'));
      const existing=await archive.inspectArchive(path.join(destination,'original.stillleaf.zip'));
      if(ready.state==='preserved'&&ready.archiveSha256===preview.sha256&&existing.sha256===preview.sha256)return {preserved:true,identical:true,id:preview.sha256};
      throw Error('An incomplete or changed recovery archive occupies this destination. Existing files were kept.');
    } catch(error){if(error.code!=='ENOENT')throw error;}
    const result=await archive.stageImport(preview,destination);return {preserved:true,identical:false,id:preview.sha256,...counts(result.entries)};
  }
  async listPreserved() {
    const archives=[],warnings=[];if(!(await directory(this.preservedRoot,{optional:true})))return{archives,warnings};
    for(const id of (await fs.readdir(this.preservedRoot)).sort()) {
      if(!ID.test(id)){warnings.push('An unrecognized recovery archive needs attention.');continue;}
      try {const dir=path.join(this.preservedRoot,id);await directory(dir);const ready=JSON.parse((await readBounded(path.join(dir,'READY.json'),4*1024*1024)).toString('utf8'));
        if(ready.version!==1||ready.state!=='preserved'||ready.archiveSha256!==id||!Array.isArray(ready.entries)||ready.entries.length>10000)throw Error('Incomplete recovery archive');
        archives.push({id,...counts(ready.entries)});
      } catch {warnings.push(`Recovery archive ${id.slice(0,8)} is incomplete or unreadable.`);}
    }return{archives,warnings};
  }
  async exportPreserved(id,destination) {
    if(!ID.test(id))throw Error('Invalid recovery archive identity.');await directory(this.preservedRoot);await directory(path.join(this.preservedRoot,id));
    const [archive]=await archiveModules();const preview=await archive.inspectArchive(path.join(this.preservedRoot,id,'original.stillleaf.zip'));
    if(preview.sha256!==id)throw Error('Recovery archive integrity changed.');return archive.exportPreservedArchive(preview,destination);
  }
}
module.exports={LibraryArchive};
