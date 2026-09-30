/** Layout-only chapter screen counts. These never create locators or reading evidence. */
export class ScreenPaginationIndex {
 constructor({measure,idle=async()=>{},changed=()=>{}}){
  this.measure=measure;this.idle=idle;this.changed=changed;this.cache=new Map();this.generation=0;this.queue=Promise.resolve();this.counts=[];
 }
 configure(key,length){
  if(this.key===key)return;
  this.cancel();this.key=key;
  this.counts=this.cache.get(key)?.slice()??Array(length).fill(null);
  this.cache.delete(key);this.cache.set(key,this.counts);
  while(this.cache.size>8)this.cache.delete(this.cache.keys().next().value);
  this.start();
 }
 record(chapter,count){
  if(!Number.isSafeInteger(count)||count<1||chapter<0||chapter>=this.counts.length)return;
  if(this.counts[chapter]===count)return;
  this.counts[chapter]=count;this.changed();
 }
 invalidate(chapter){
  if(chapter<0||chapter>=this.counts.length)return;
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
  this.queue=this.queue.catch(()=>{}).then(async()=>{
   for(let chapter=0;chapter<this.counts.length;chapter++){
    if(controller.signal.aborted||generation!==this.generation)return;
    if(this.counts[chapter]!==null)continue;
    await this.idle(controller.signal);
    if(controller.signal.aborted||generation!==this.generation)return;
    if(this.counts[chapter]!==null)continue;
    try{
     const count=await this.measure(chapter,controller.signal,key);
     if(controller.signal.aborted||generation!==this.generation)return;
     // A live measurement arriving during the probe wins.
     if(this.counts[chapter]===null)this.record(chapter,count);
    }catch{
     // Do not present a fabricated exact total when a chapter cannot settle.
     if(!controller.signal.aborted)this.changed();return;
    }
   }
  });
 }
 cancel(){this.generation++;this.controller?.abort()}
 close(){this.cancel();this.key=null;this.counts=[];this.cache.clear()}
}
