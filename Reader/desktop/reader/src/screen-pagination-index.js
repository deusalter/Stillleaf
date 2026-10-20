/** Layout-only chapter screen counts. These never create locators or reading evidence. */
const CACHED_LAYOUTS=16;
export class ScreenPaginationIndex {
 /** `completed(key, counts)` hears each layout once it is exact, so the host can keep it for the next opening. */
 constructor({measure,idle=async()=>{},changed=()=>{},completed=()=>{},concurrency=3}){
  this.measure=measure;this.idle=idle;this.changed=changed;this.completed=completed;this.concurrency=concurrency;
  this.cache=new Map();this.reported=new Map();this.saved=new Set();this.generation=0;this.queue=Promise.resolve();this.counts=[];this.previous=[];this.focus=0;
 }
 /** Exact maps saved by the host, most recent first. They are already known to it, so they are not reported back. */
 seed(maps){
  for(const {key,counts}of [...maps].reverse()){if(key===this.key)continue;this.cache.delete(key);this.cache.set(key,counts.slice());this.reported.set(key,counts.join());this.saved.add(key)}
  this.trim();
 }
 configure(key,length,focus=0){
  this.focus=focus;
  if(this.key===key){if(this.controller?.signal.aborted)this.start();return;}
  this.cancel();this.key=key;this.previous=[];
  const cached=this.cache.get(key);
  this.counts=cached?.length===length?cached.slice():Array(length).fill(null);
  this.cache.delete(key);this.cache.set(key,this.counts);this.trim();
  this.start();
 }
 trim(){while(this.cache.size>CACHED_LAYOUTS){const oldest=this.cache.keys().next().value;this.cache.delete(oldest);this.reported.delete(oldest);this.saved.delete(oldest)}}
 /** Complete maps of the book's other layouts, most recent first. */
 references(){return [...this.cache].reverse().filter(([key,counts])=>key!==this.key&&counts.length===this.counts.length&&counts.every(count=>count!==null)).map(([,counts])=>counts)}
 record(chapter,count){
  if(!Number.isSafeInteger(count)||count<1||chapter<0||chapter>=this.counts.length)return;
  if(this.counts[chapter]===count)return;
  // A saved map is trusted until a live chapter disagrees with it: then this Mac lays the book out differently now (a
  // WebKit or font change), so every other chapter is measured again, keeping its saved count meanwhile.
  if(this.saved.delete(this.key)&&this.counts[chapter]!==null){
   for(let other=0;other<this.counts.length;other++)if(other!==chapter){this.previous[other]=this.counts[other];this.counts[other]=null}
   this.counts[chapter]=count;this.cancel();this.changed();this.start();return;
  }
  this.counts[chapter]=count;this.report();this.changed();
 }
 report(){
  if(!this.counts.length||this.counts.some(count=>count===null))return;
  const signature=this.counts.join();if(this.reported.get(this.key)===signature)return;
  this.reported.set(this.key,signature);this.completed(this.key,this.counts.slice());
 }
 invalidate(chapter){
  if(chapter<0||chapter>=this.counts.length)return;
  // The last count stays the best guess while the chapter settles again, so the footer does not move meanwhile.
  this.previous[chapter]=this.counts[chapter]??this.previous[chapter];
  this.counts[chapter]=null;this.cancel();this.changed();this.start();
 }
 pages(chapter,local){
  if(!local||chapter<0||this.counts.some(count=>count===null)||!this.counts.length)return null;
  const before=this.counts.slice(0,chapter).reduce((a,b)=>a+b,0);
  const first=before+Math.min(local.first,this.counts[chapter]);
  return {first,last:first,total:this.counts.reduce((a,b)=>a+b,0)};
 }
 start(){
  const generation=this.generation,key=this.key,controller=new AbortController();this.controller=controller;
  const stale=()=>controller.signal.aborted||generation!==this.generation;
  // Chapters before the reader's place settle its page number, so they go first; later ones only move the total.
  const focus=Math.min(this.focus,this.counts.length);
  const pending=[...Array(focus).keys(),...Array.from({length:this.counts.length-focus},(_,i)=>focus+i)].filter(chapter=>this.counts[chapter]===null);
  // Several chapters lay out at once: most of each one's time is spent waiting on its frame and resources.
  const worker=async()=>{
   while(pending.length){
    const chapter=pending.shift();
    if(stale())return;
    if(this.counts[chapter]!==null)continue;
    await this.idle(controller.signal);
    if(stale())return;
    if(this.counts[chapter]!==null)continue;
    try{
     const count=await this.measure(chapter,controller.signal,key);
     if(stale())return;
     // A live measurement arriving during the probe wins.
     if(this.counts[chapter]===null)this.record(chapter,count);
    }catch{
     // Do not present a fabricated exact total when a chapter cannot settle; its estimate stays in the footer.
     if(!controller.signal.aborted)this.changed();return;
    }
   }
  };
  this.queue=this.queue.catch(()=>{}).then(()=>Promise.all(Array.from({length:Math.max(1,this.concurrency)},worker)));
 }
 cancel(){this.generation++;this.controller?.abort()}
 close(){this.cancel();this.key=null;this.counts=[];this.previous=[];this.cache.clear();this.reported.clear();this.saved.clear()}
}
