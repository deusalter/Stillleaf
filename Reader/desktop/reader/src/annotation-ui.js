import {locatorRange} from './continuous';

// Geometry stays in viewport coordinates. Nothing here changes chapter layout,
// progress, or persisted locators; the navigator remains the location authority.
export function popupPosition(rect, width, height, viewport) {
 const pad=8, left=Math.max(pad,Math.min(viewport.width-width-pad,(rect.left+rect.right-width)/2));
 const above=rect.top-height-10;
 return {left,top:Math.max(pad,Math.min(viewport.height-height-pad,above>=pad?above:rect.bottom+10))};
}
export function marginSlots(items,top,bottom,gap=8) {
 const ends=[top,top];return items.map(item=>{
  const side=ends[0]<=ends[1]?0:1,y=Math.max(top,item.top,ends[side]);
  if(y+item.height>bottom)return {...item,compact:true};
  ends[side]=y+item.height+gap;return {...item,side,top:y};
 });
}
function rectInHost(frame,range,viewport){
 const host=frame.getBoundingClientRect();
 const rect=[...range.getClientRects()].find(r=>r.width>0&&r.height>0&&host.top+r.bottom>viewport.top&&host.top+r.top<viewport.bottom&&host.left+r.right>viewport.left&&host.left+r.left<viewport.right);
 return rect?{left:host.left+rect.left,right:host.left+rect.right,top:host.top+rect.top,bottom:host.top+rect.bottom}:null;
}
export class AnnotationUI {
 constructor({popup,layer,viewport,frames,annotations,continuous,onDismiss,onEdit,onList}){
  Object.assign(this,{popup,layer,viewport,frames,annotations,continuous,onDismiss,onEdit,onList});
  this.active=null;this.pending=0;this.bound=new Map();this.cards=new Map();this.rangeCache=new Map();
  this.compact=document.createElement('button');this.compact.className='compact-notes';this.compact.hidden=true;this.compact.onclick=()=>onList();layer.append(this.compact);
  // Pointer controls must not collapse the selection inside another document.
  popup.addEventListener('pointerdown',event=>event.preventDefault());
  popup.addEventListener('keydown',event=>{
   if(event.key==='Escape'){event.preventDefault();event.stopPropagation();this.dismiss(true);return}
   const buttons=[...popup.querySelectorAll('button:not([hidden])')];
   const direction={ArrowRight:1,ArrowLeft:-1}[event.key];
   if(direction){event.preventDefault();event.stopPropagation();buttons[(buttons.indexOf(document.activeElement)+direction+buttons.length)%buttons.length]?.focus();}
   if(event.key==='Tab'){event.preventDefault();this.dismiss(true)}
  });
  this.outside=event=>{if(!popup.contains(event.target))this.dismiss(false)};
  document.addEventListener('pointerdown',this.outside);
  this.schedule=this.schedule.bind(this);
  window.addEventListener('resize',this.schedule);document.addEventListener('scroll',this.schedule,true);
  this.observer=new MutationObserver(this.schedule);this.observer.observe(viewport,{childList:true,subtree:true});
  this.resize=new ResizeObserver(this.schedule);this.resize.observe(viewport);
 }
 bindFrames(){
  const live=new Set(this.frames().map(x=>x.frame));
  for(const [frame,binding]of this.bound)if(!live.has(frame)||binding.doc!==frame.contentDocument){
   binding.doc.removeEventListener('pointerdown',binding.down);binding.doc.removeEventListener('keydown',binding.key,true);binding.doc.removeEventListener('scroll',this.schedule,true);
   this.resize.unobserve(frame);this.resize.unobserve(binding.doc.body);this.bound.delete(frame);this.rangeCache.delete(frame);
  }
  for(const frame of live){const doc=frame.contentDocument;if(!doc?.body||this.bound.has(frame))continue;
   const down=()=>this.dismiss(false),key=event=>{
    if(event.key==='Escape'&&this.active){event.preventDefault();event.stopImmediatePropagation();this.dismiss(true)}
    else if(event.key==='Tab'&&this.active&&!this.popup.hidden&&!event.shiftKey){event.preventDefault();event.stopImmediatePropagation();this.popup.querySelector('button:not([hidden])')?.focus()}
   };
   doc.addEventListener('pointerdown',down);doc.addEventListener('keydown',key,true);doc.addEventListener('scroll',this.schedule,true);this.resize.observe(frame);this.resize.observe(doc.body);
   this.bound.set(frame,{doc,down,key});
  }
 }
 show(item,selectedRange){
  this.bindFrames();
  this.active={item,frame:selectedRange?.frame,range:selectedRange?.range?.cloneRange()};
  for(const b of this.popup.querySelectorAll('[data-highlight-color]'))b.setAttribute('aria-pressed',String(item.color===b.dataset.highlightColor));
  this.popup.querySelector('#remove-selection').hidden=!item.id;
  this.popup.querySelector('#note-selection').textContent=item.note?'Edit note':'Add note';
  // The popup must have its selection geometry before it can paint. A busy
  // host may delay the scheduled frame; never expose the default CSS position.
  this.popup.style.visibility='hidden';this.popup.hidden=false;
  this.layout();this.popup.style.removeProperty('visibility');this.schedule();
 }
 dismiss(restoreFocus=false){
  const frame=this.active?.frame;this.active=null;this.popup.hidden=true;
  if(restoreFocus&&frame?.isConnected){frame.contentWindow.getSelection()?.removeAllRanges();frame.contentWindow.focus();}
  this.onDismiss();
 }
 invalidate(){this.rangeCache.clear();this.schedule()}
 schedule(){if(!this.pending)this.pending=requestAnimationFrame(()=>{this.pending=0;this.layout()})}
 resolve(frame,item){
  let cache=this.rangeCache.get(frame);if(!cache){cache=new Map();this.rangeCache.set(frame,cache)}
  if(!cache.has(item.id))cache.set(item.id,locatorRange(frame.contentDocument,item.locator));return cache.get(item.id);
 }
 locate(item){
  const viewport=this.viewport.getBoundingClientRect();
  for(const {frame,href}of this.frames())if(href===item.locator.href&&frame.contentDocument?.body){
   const range=locatorRange(frame.contentDocument,item.locator);if(!range)continue;
   if(rectInHost(frame,range,viewport))return {frame,range};
  }return null;
 }
 layout(){
  this.bindFrames();const viewport=this.viewport.getBoundingClientRect();
  if(this.active&&!this.popup.hidden){
   const pair=this.active.range?.startContainer?.isConnected?this.active:this.locate(this.active.item);
   const rect=pair&&rectInHost(pair.frame,pair.range,viewport);
   if(!rect){this.dismiss(false)}else{
    this.active.frame=pair.frame;this.active.range=pair.range;
    const p=popupPosition(rect,this.popup.offsetWidth,this.popup.offsetHeight,{width:innerWidth,height:innerHeight});
    this.popup.style.left=p.left+'px';this.popup.style.top=p.top+'px';
   }
  }
  // Margin cards exist only beside a continuous book that has notes. Without any, a scroll frame has nothing to place,
  // and must not touch the layer or the compact button (writing to them invalidates layout even when nothing changed).
  const noted=this.continuous()&&this.annotations().some(item=>item.note);
  if(!noted&&!this.cards.size&&this.compact.hidden)return;
  const visible=[];
  if(noted)for(const {frame,href}of this.frames()){
   const f=frame.getBoundingClientRect();if(f.bottom<=viewport.top||f.top>=viewport.bottom||!frame.contentDocument?.body)continue;
   for(const item of this.annotations())if(item.note&&item.locator.href===href){
    const range=this.resolve(frame,item),rect=range&&rectInHost(frame,range,viewport);if(rect)visible.push({item,rect});
   }
  }
  visible.sort((a,b)=>a.rect.top-b.rect.top);
  const ids=new Set(visible.map(x=>x.item.id));for(const [id,card]of this.cards)if(!ids.has(id)){card.remove();this.cards.delete(id)}
  const room=Math.min(viewport.left,innerWidth-viewport.right)-16,width=Math.min(200,room),wide=width>=150;
  // Every write first, then every read: measuring a card between writes would force a layout per card.
  const placed=[];
  for(const {item,rect}of visible){
   let card=this.cards.get(item.id);if(!card){card=document.createElement('button');card.className='margin-note';card.onclick=()=>this.onEdit(item.id);this.cards.set(item.id,card);this.layer.append(card)}
   const color=item.color==='sage'?'#a7cbb0':item.color==='rose'?'#d7a9b4':'#e4c778',label='Edit note for '+item.quote.slice(0,100);
   if(card.textContent!==item.note)card.textContent=item.note;
   if(card.getAttribute('aria-label')!==label)card.setAttribute('aria-label',label);
   if(card.style.getPropertyValue('--note-color')!==color)card.style.setProperty('--note-color',color);
   if(card.style.width!==width+'px')card.style.width=width+'px';
   if(card.hidden!==!wide)card.hidden=!wide;
   if(wide)placed.push({card,top:rect.top});
  }
  const items=placed.map(({card,top})=>({card,top,height:card.offsetHeight}));
  let overflow=wide?0:visible.length;
  for(const slot of marginSlots(items,viewport.top,viewport.bottom)){
   slot.card.hidden=!!slot.compact;if(slot.compact){overflow++;continue}
   slot.card.style.top=slot.top+'px';slot.card.style.left=(slot.side===0?viewport.left-width-12:viewport.right+12)+'px';
  }
  const text=overflow+' '+(overflow===1?'note':'notes'),label=overflow+' notes beside visible passages. Open highlights and notes',top=Math.max(2,viewport.top-26)+'px',right=Math.max(8,innerWidth-viewport.right)+'px';
  if(this.compact.hidden!==!overflow)this.compact.hidden=!overflow;
  if(this.compact.textContent!==text)this.compact.textContent=text;
  if(this.compact.getAttribute('aria-label')!==label)this.compact.setAttribute('aria-label',label);
  if(this.compact.style.top!==top)this.compact.style.top=top;
  if(this.compact.style.right!==right)this.compact.style.right=right;
 }
 reset(){this.dismiss();this.rangeCache.clear();for(const card of this.cards.values())card.remove();this.cards.clear();this.compact.hidden=true;this.schedule()}
}
