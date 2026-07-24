import {Locator} from '@readium/shared';
import {selectorFor,rangePoint} from './state';

const MAX_FRAMES=8, MAX_CHAPTER_BYTES=8*1024*1024, MAX_CHAPTER_HEIGHT=250000, MAX_BOOK_HEIGHT=8000000;
const clone=value=>JSON.parse(JSON.stringify(value));
const nextPaint=()=>new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve)));
const serial=value=>value?.serialize?.()??value;
function point(doc,value){
 if(!value?.cssSelector)return null;
 try{const element=doc.querySelector(value.cssSelector);if(!element)return null;const node=value.textNodeIndex===undefined?element:element.childNodes[value.textNodeIndex];const offset=value.charOffset??0;if(!node||offset<0||offset>(node.nodeType===Node.TEXT_NODE?node.length:node.childNodes.length))return null;return {node,offset}}catch{return null}
}
function textRange(doc,root,text){
 if(!text?.highlight)return null;
 const nodes=[],walker=doc.createTreeWalker(root,NodeFilter.SHOW_TEXT);let node,all='';
 while((node=walker.nextNode())){if(['STYLE','SCRIPT'].includes(node.parentElement?.tagName))continue;nodes.push({node,start:all.length});all+=node.textContent;if(all.length>2000000)return null;}
 let start=all.indexOf(text.highlight);if(start<0)return null;
 if(text.before||text.after){let cursor=start;start=-1;while(cursor>=0){if((!text.before||all.slice(Math.max(0,cursor-text.before.length),cursor)===text.before)&&(!text.after||all.slice(cursor+text.highlight.length,cursor+text.highlight.length+text.after.length)===text.after)){start=cursor;break}cursor=all.indexOf(text.highlight,cursor+1)}}
 if(start<0)return null;
 const end=start+text.highlight.length,a=nodes.find(n=>start>=n.start&&start<n.start+n.node.length),b=nodes.find(n=>end>n.start&&end<=n.start+n.node.length);if(!a||!b)return null;
 const range=doc.createRange();range.setStart(a.node,start-a.start);range.setEnd(b.node,end-b.start);return range;
}
export function locatorRange(doc,value){
 const locator=serial(value),locations=locator?.locations??{},endpoints=locations.domRange;
 if(endpoints){const a=point(doc,endpoints.start),b=point(doc,endpoints.end);if(a&&b)try{const range=doc.createRange();range.setStart(a.node,a.offset);range.setEnd(b.node,b.offset);if(!range.collapsed)return range}catch{}}
 let root=doc.body;try{if(locations.cssSelector)root=doc.querySelector(locations.cssSelector)||root}catch{}
 if(locator?.text?.highlight)return textRange(doc,root,locator.text);
 for(const fragment of locations.fragments??[]){let id=fragment.replace(/^#/,'');try{id=decodeURIComponent(id)}catch{}const el=doc.getElementById(id);if(el){const range=doc.createRange();range.selectNodeContents(el);return range}}
 if(root!==doc.body){const range=doc.createRange();range.selectNodeContents(root);return range}return null;
}

/** One native scroll surface; chapter documents stay isolated and script-disabled. */
export class ContinuousNavigator {
 kind='continuous';
 constructor(container,input,pool,listeners,initial,settings){
  this.container=container;this.input=input;this.pool=pool;this.listeners=listeners;this.initial=serial(initial);this.settings=settings;this.entries=[];this.destroyed=false;this.epoch=0;this.queue=Promise.resolve();this.suppress=0;this.decorations=[];this.decorationObserver=null;this.current=null;this.lastAnchor=null;this.lastInput=0;this.currentIndex=0;
  this.onScroll=()=>{if(this.destroyed||this.suppress)return;this.lastInput=performance.now();cancelAnimationFrame(this.scrollFrame);this.scrollFrame=requestAnimationFrame(()=>{this.report();void this.updateWindow()})};
  this.onResize=()=>{if(this.destroyed)return;clearTimeout(this.resizeTimer);this.resizeTimer=setTimeout(()=>void this.remeasure(),60)};
 }
 async load(){
  this.container.classList.add('continuous-reader');this.container.style.removeProperty('width');this.container.tabIndex=0;this.container.setAttribute('aria-label','Continuous book');
  for(const [index,link]of this.input.readingOrder.entries()){
   const section=document.createElement('section');section.className='continuous-chapter';section.dataset.href=link.href;section.setAttribute('aria-label',link.title||`Section ${index+1}`);
   const size=this.pool.size(link.href);const height=Math.max(240,Math.min(50000,size*.35));section.style.height=height+'px';this.container.append(section);this.entries.push({index,link,section,height,frame:null,url:null,observer:null,failed:null,ranges:[]});
  }
  this.container.addEventListener('scroll',this.onScroll,{passive:true});this.resizeObserver=new ResizeObserver(this.onResize);this.resizeObserver.observe(this.container);
  const index=Math.max(0,this.entries.findIndex(e=>e.link.href===this.initial?.href));await this.ensureWindow(index);
  if(this.initial)await this.navigate(this.initial);else{this.container.scrollTop=0;this.report()}
 }
 baseCSS(){return 'html{overflow:hidden!important;min-height:0!important;height:auto!important;font-size:16px}body{margin:0!important;min-height:0!important;height:auto!important;box-sizing:border-box;font-family:Georgia,"Times New Roman",serif;font-size:1rem;line-height:1.6}img,video{max-width:100%;height:auto}:where(h1,h2,h3,h4,h5,h6){break-after:avoid}:where(pre){white-space:pre-wrap}';}
 preferenceCSS(){
  const p=this.settings,gutter=p.scrollPaddingLeft??44,weight=p.fontWeight==null?'':`font-weight:${p.fontWeight}!important;`,family=p.fontFamily?`font-family:${p.fontFamily}!important;`:'';
  const align=p.textAlign?`text-align:${p.textAlign}!important;`:'';const hyphens=typeof p.hyphens==='boolean'?`hyphens:${p.hyphens?'auto':'none'}!important;-webkit-hyphens:${p.hyphens?'auto':'none'}!important;`:'';
  return `html{background:${p.backgroundColor};color:${p.textColor}}body{padding:24px ${gutter}px 32px!important;zoom:${p.fontSize};color:${p.textColor}!important;background:${p.backgroundColor}!important;line-height:${p.lineHeight}!important;${weight}${family}}:where(p,li,dd,dt,blockquote){${weight?'font-weight:inherit!important;':''}${family?'font-family:inherit!important;':''}${align}${hyphens}letter-spacing:${p.letterSpacing??0}rem!important;word-spacing:${p.wordSpacing??0}rem!important}a{color:${p.linkColor}!important}::selection{background:${p.selectionBackgroundColor}}${p.darkenFilter?'img,svg,video{filter:brightness(.8)}':''}`;
 }
 async mount(entry){
  if(this.destroyed||entry.frame||entry.failed)return;
  if(this.pool.size(entry.link.href)>MAX_CHAPTER_BYTES)throw Error('This section is too large for continuous view. Use Single page or Facing pages.');
  const generation=this.epoch,html=await this.pool.chapter(entry.link.href);
  if(this.destroyed||entry.frame||generation!==this.epoch)return;
  const doc=new DOMParser().parseFromString(html,'text/html');
  if(!doc.documentElement.lang)doc.documentElement.lang=this.input.languages?.[0]||this.input.language||'en';
  if(!doc.documentElement.hasAttribute('dir')&&this.input.readingProgression==='rtl')doc.documentElement.dir='rtl';
  const base=doc.createElement('style');base.textContent=this.baseCSS();doc.head.prepend(base);
  const policy=doc.createElement('meta');policy.httpEquiv='Content-Security-Policy';policy.content="default-src 'none'; script-src 'none'; style-src 'unsafe-inline' blob:; img-src blob: data:; font-src blob: data:; connect-src 'none'; object-src 'none'; frame-src 'none'; form-action 'none'";doc.head.prepend(policy);
  const appearance=doc.createElement('style');entry.appearance=appearance;appearance.textContent=this.preferenceCSS();doc.head.append(appearance);
  const frame=document.createElement('iframe');frame.title=entry.link.title||`Section ${entry.index+1}`;frame.sandbox='allow-same-origin';frame.style.height='1px';frame.className='continuous-chapter-frame';entry.frame=frame;
  entry.url=URL.createObjectURL(new Blob(['<!doctype html>'+doc.documentElement.outerHTML],{type:'text/html'}));entry.section.replaceChildren(frame);
  await new Promise((resolve,reject)=>{const timer=setTimeout(()=>reject(Error('The section took too long to load.')),8000);frame.onload=()=>{clearTimeout(timer);resolve()};frame.onerror=()=>{clearTimeout(timer);reject(Error('The section could not be displayed.'))};frame.src=entry.url});
  if(this.destroyed||generation!==this.epoch)return;
  entry.appearance=frame.contentDocument.head.lastElementChild;
  await Promise.race([frame.contentDocument.fonts.ready,new Promise(resolve=>setTimeout(resolve,1500))]);
  if(this.destroyed||generation!==this.epoch)return;
  if(!frame.contentWindow.CSS?.highlights||typeof frame.contentWindow.Highlight!=='function')throw Error('Continuous view needs text highlight support unavailable in this browser. Choose Single page or Facing pages.');
  this.measure(entry);this.bindFrame(entry);this.paint(entry);this.listeners.frameLoaded?.(frame.contentWindow);
  entry.observer=new ResizeObserver(this.onResize);entry.observer.observe(frame.contentDocument.body);
  for(const image of frame.contentDocument.images)image.addEventListener('load',this.onResize,{once:true});
 }
 measure(entry){
  const doc=entry.frame?.contentDocument;if(!doc?.body)return;
  // getBoundingClientRect is already in rendered CSS pixels in both WK and Chromium.
  // WK also returns a zoomed scrollHeight; multiplying that by zoom double-counts it.
  let bottom=doc.body.getBoundingClientRect().bottom;
  const walk=doc.createTreeWalker(doc.body,NodeFilter.SHOW_ELEMENT);let element,count=0;
  while((element=walk.nextNode())){if(++count>20000)throw Error('This section is too complex for continuous view. Use a paginated mode.');bottom=Math.max(bottom,element.getBoundingClientRect().bottom)}
  const height=Math.ceil(Math.max(120,bottom));
  if(!Number.isFinite(height)||height>MAX_CHAPTER_HEIGHT)throw Error('This section exceeds continuous-view layout limits. Use a paginated mode.');
  entry.height=height;entry.frame.style.height=height+'px';entry.section.style.height=height+'px';
  if(this.entries.reduce((sum,item)=>sum+item.height,0)>MAX_BOOK_HEIGHT)throw Error('This book exceeds continuous-view layout limits. Use a paginated mode.');
 }
 unmount(entry){
  if(!entry.frame)return;entry.observer?.disconnect();entry.observer=null;
  this.listeners.frameUnloaded?.(entry.frame.contentWindow);
  if(document.activeElement===entry.frame)this.container.focus({preventScroll:true});
  entry.frame.remove();entry.frame=null;entry.appearance=null;entry.highlightStyle=null;entry.ranges=[];if(entry.url)URL.revokeObjectURL(entry.url);entry.url=null;
 }
 async ensureWindow(index){
  const requested=index;if(this.entries[index]?.failed)throw this.entries[index].failed;this.queue=this.queue.catch(()=>{}).then(async()=>{
   if(this.destroyed)return;
   const top=this.container.scrollTop,bottom=top+this.container.clientHeight;let offset=0;
   const visible=this.entries.filter(entry=>{const match=offset+entry.height>top&&offset<bottom;offset+=entry.height;return match});
   const wanted=new Set([requested]);
   for(const entry of visible.sort((a,b)=>Math.abs(a.index-requested)-Math.abs(b.index-requested)))if(wanted.size<MAX_FRAMES)wanted.add(entry.index);
   for(let distance=1;wanted.size<MAX_FRAMES&&distance<=3;distance++)for(const i of [requested-distance,requested+distance])if(i>=0&&i<this.entries.length&&wanted.size<MAX_FRAMES)wanted.add(i);
   // Keep a measured placeholder when releasing a document; never concatenate chapters.
   for(const entry of this.entries)if(!wanted.has(entry.index))this.unmount(entry);
   const anchor=this.captureAnchor();this.suppress++;
   try{for(const i of [...wanted].sort((a,b)=>Math.abs(a-requested)-Math.abs(b-requested))){if(this.destroyed)return;try{await this.mount(this.entries[i])}catch(error){const entry=this.entries[i];this.unmount(entry);entry.failed=error;entry.section.textContent=error.message;if(i===requested)throw error}}if(anchor)this.restoreAnchorNow(anchor)}finally{this.suppress--}
  });return this.queue;
 }
 async updateWindow(){const index=this.indexAt(this.container.scrollTop+this.container.clientHeight*.25);try{await this.ensureWindow(index)}catch(error){this.listeners.error?.(error)}}
 indexAt(offset){let top=0;for(const entry of this.entries){if(top+entry.height>offset)return entry.index;top+=entry.height}return this.entries.length-1;}
 captureAnchor(){
  const viewport=this.container.getBoundingClientRect();
  for(const entry of this.entries){if(!entry.frame)continue;const bounds=entry.frame.getBoundingClientRect();if(bounds.bottom<=viewport.top||bounds.top>=viewport.bottom)continue;
   const doc=entry.frame.contentDocument;
   // Native caret hit-testing avoids traversing thousands of preceding paragraphs on each scroll.
   for(const y of [Math.max(2,viewport.top-bounds.top+3),Math.max(2,viewport.top-bounds.top+24)])for(const x of [44,entry.frame.clientWidth*.25,entry.frame.clientWidth*.5]){
    const caret=doc.caretPositionFromPoint?.(x,y),hit=caret?{node:caret.offsetNode,offset:caret.offset}:null;
    const fallback=!hit&&doc.caretRangeFromPoint?.(x,y),candidate=hit||(fallback?{node:fallback.startContainer,offset:fallback.startOffset}:null);
    if(candidate?.node.nodeType!==Node.TEXT_NODE)continue;
    const {node,offset:i}=candidate;if(i>=node.length||!node.textContent.slice(i).trim())continue;
    const range=doc.createRange();range.setStart(node,i);range.setEnd(node,i+1);const rect=range.getBoundingClientRect(),top=bounds.top+rect.top;
    if(top<viewport.top||top>=viewport.bottom)continue;
    const text=node.textContent.slice(i,i+80);return {locator:{href:entry.link.href,type:'text/html',title:entry.link.title,locations:{position:entry.index+1,progression:Math.max(0,Math.min(1,(viewport.top-bounds.top)/entry.height)),cssSelector:selectorFor(node.parentElement),domRange:{start:rangePoint(node,i),end:rangePoint(node,Math.min(node.length,i+text.length))}},text:{highlight:text}},offset:top-viewport.top};
   }
   const walk=doc.createTreeWalker(doc.body,NodeFilter.SHOW_TEXT);let node,checked=0;
   while((node=walk.nextNode())&&checked++<3000){if(!node.textContent.trim()||['STYLE','SCRIPT'].includes(node.parentElement?.tagName))continue;const range=doc.createRange();range.selectNodeContents(node);if(![...range.getClientRects()].some(r=>r.bottom+bounds.top>viewport.top&&r.top+bounds.top<viewport.bottom))continue;
    for(let i=0;i<node.length&&checked++<30000;i++){range.setStart(node,i);range.setEnd(node,i+1);const r=range.getBoundingClientRect(),y=bounds.top+r.top;if(y>=viewport.top&&r.right>0&&r.left<entry.frame.clientWidth&&node.textContent.slice(i).trim()){
     const text=node.textContent.slice(i,i+80),start=rangePoint(node,i),end=rangePoint(node,Math.min(node.length,i+Math.max(1,text.length)));
     return {locator:{href:entry.link.href,type:'text/html',title:entry.link.title,locations:{position:entry.index+1,progression:Math.max(0,Math.min(1,(viewport.top-bounds.top)/entry.height)),cssSelector:selectorFor(node.parentElement),domRange:{start,end}},text:{highlight:text}},offset:y-viewport.top};
    }}
   }
  }return null;
 }
 captureLocator(){return this.captureAnchor()?.locator??this.current;}
 restoreAnchorNow(anchor){const entry=this.entries.find(e=>e.link.href===anchor.locator.href);if(!entry?.frame)return false;const range=locatorRange(entry.frame.contentDocument,anchor.locator);if(!range)return false;this.container.scrollTop+=entry.frame.getBoundingClientRect().top+range.getBoundingClientRect().top-this.container.getBoundingClientRect().top-anchor.offset;return true;}
 async remeasure(){
  if(this.destroyed)return;const anchor=this.lastAnchor??this.captureAnchor();this.suppress++;
  try{for(const entry of this.entries)if(entry.frame)this.measure(entry);if(anchor&&performance.now()-this.lastInput>140)this.restoreAnchorNow(anchor)}catch(error){this.listeners.error?.(error)}finally{this.suppress--}this.report();
 }
 report(){if(this.destroyed||this.suppress)return;const anchor=this.captureAnchor();if(!anchor)return;this.lastAnchor=anchor;this.current=anchor.locator;this.currentIndex=this.entries.findIndex(e=>e.link.href===this.current.href);this.listeners.positionChanged?.(Locator.deserialize(this.current));}
 async navigate(value){
  const locator=serial(value),index=this.entries.findIndex(e=>e.link.href===locator?.href);if(index<0)return false;
  this.suppress++;
  try{await this.ensureWindow(index);if(this.destroyed)return false;const entry=this.entries[index];if(!entry.frame)return false;
   const range=locatorRange(entry.frame.contentDocument,locator);const viewport=this.container.getBoundingClientRect();const delta=range?range.getBoundingClientRect().top:Math.max(0,Math.min(1,locator.locations?.progression??0))*Math.max(0,entry.height-this.container.clientHeight);
   this.container.scrollTop+=entry.frame.getBoundingClientRect().top-viewport.top+delta;this.currentIndex=index;await nextPaint();
   // A jump is where the reader now is, even if report() is suppressed by other window work;
   // otherwise the next resize restores the chapter the reader just left.
   const landed=this.captureAnchor();this.lastAnchor=landed;this.current=landed?.locator??locator;
  }finally{this.suppress--}await this.ensureWindow(index);this.report();return true;
 }
 go(locator,_animated,callback){this.navigate(locator).then(callback,error=>{this.listeners.error?.(error);callback(false)})}
 goForward(_animated,callback){const entry=this.entries[Math.min(this.entries.length-1,this.currentIndex+1)];this.go({href:entry.link.href,type:'text/html',locations:{progression:0}},false,callback)}
 goBackward(_animated,callback){const entry=this.entries[Math.max(0,this.currentIndex-1)];this.go({href:entry.link.href,type:'text/html',locations:{progression:0}},false,callback)}
 async submitPreferences(settings){
  const anchor=this.captureAnchor();this.suppress++;this.settings=settings;
  try{for(const entry of this.entries)if(entry.frame)entry.appearance.textContent=this.preferenceCSS();await nextPaint();for(const entry of this.entries)if(entry.frame)this.measure(entry);if(anchor)this.restoreAnchorNow(anchor)}finally{this.suppress--}this.report();
 }
 bindFrame(entry){
  const wnd=entry.frame.contentWindow,doc=wnd.document;
  const selected=()=>{const selection=wnd.getSelection();if(!selection?.rangeCount||!selection.toString().trim())return;const range=selection.getRangeAt(0),locator={href:entry.link.href,type:'text/html',locations:{position:entry.index+1,domRange:{start:rangePoint(range.startContainer,range.startOffset),end:rangePoint(range.endContainer,range.endOffset)}},text:{highlight:selection.toString()}};this.listeners.textSelected?.({text:selection.toString(),locator:Locator.deserialize(locator)})};
  doc.addEventListener('pointerup',selected);doc.addEventListener('keyup',selected);
  doc.addEventListener('keydown',event=>{if(event.defaultPrevented||event.altKey||event.ctrlKey||event.metaKey||['INPUT','TEXTAREA','SELECT'].includes(event.target?.tagName))return;let delta=0;if(event.key==='PageDown'||event.key===' ')delta=this.container.clientHeight*.85*(event.shiftKey?-1:1);if(event.key==='PageUp')delta=-this.container.clientHeight*.85;if(event.key==='ArrowDown')delta=44;if(event.key==='ArrowUp')delta=-44;if(delta){event.preventDefault();this.container.scrollBy({top:delta,behavior:'auto'})}});
  doc.addEventListener('click',event=>{if(wnd.getSelection()?.toString())return;for(const hit of entry.ranges)if([...hit.range.getClientRects()].some(r=>event.clientX>=r.left&&event.clientX<=r.right&&event.clientY>=r.top&&event.clientY<=r.bottom)){event.preventDefault();this.decorationObserver?.onDecorationActivated?.({decoration:hit.decoration});break}});
 }
 registerDecorationObserver(_group,observer){this.decorationObserver=observer;}
 applyDecorations(decorations){this.decorations=decorations;for(const entry of this.entries)if(entry.frame)this.paint(entry);}
 paint(entry){
  const wnd=entry.frame.contentWindow,doc=wnd.document;entry.ranges=[];entry.highlightStyle?.remove();if(!wnd.CSS?.highlights)return;
  for(const key of [...wnd.CSS.highlights.keys()])if(key.startsWith('stillleaf-'))wnd.CSS.highlights.delete(key);
  const rules=[];let index=0;for(const decoration of this.decorations){const locator=serial(decoration.locator);if(locator.href!==entry.link.href)continue;const range=locatorRange(doc,locator);if(!range)continue;const name='stillleaf-'+index++;wnd.CSS.highlights.set(name,new wnd.Highlight(range));const tint=/^#[0-9a-f]{6}$/i.test(decoration.style.tint)?decoration.style.tint:'#e4c778';rules.push(`::highlight(${name}){background:${tint};color:#17271f}`);entry.ranges.push({range,decoration});}
  const style=doc.createElement('style');entry.highlightStyle=style;style.textContent=rules.join('\n');doc.head.append(style);
 }
 async destroy(){this.destroyed=true;this.epoch++;clearTimeout(this.resizeTimer);cancelAnimationFrame(this.scrollFrame);this.resizeObserver?.disconnect();this.container.removeEventListener('scroll',this.onScroll);for(const entry of this.entries)this.unmount(entry);this.entries=[];this.container.replaceChildren();this.container.classList.remove('continuous-reader');this.container.removeAttribute('tabindex');}
}
