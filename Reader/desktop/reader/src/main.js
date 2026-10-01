import {EpubNavigator,EpubPreferences,DecorationStyleType} from '@readium/navigator';
import {Manifest,Publication,Locator} from '@readium/shared';
import {PublicationResources,PublicationFetcher} from './resources';
import {ContinuousNavigator,locatorRange} from './continuous';
import {AnnotationUI} from './annotation-ui';
import {annotationLocator,quotePreview,longSelectionRange,MAX_LOCATOR_TEXT} from './annotation-anchor';
import {PageSlide} from './page-slide';
import {visibleTextBounds,firstFullyVisibleOffset} from './visible-text';
import {installPageTurnWheel} from './page-turn-input';
import {NavigationCompletion} from './navigation-completion';
import {screenPages,pageLabel,chapterPagesLeft} from './page-progress';
import {ScreenPaginationIndex} from './screen-pagination-index';
import {continuousTextCandidates} from './content-geometry';
import {syncTypographyChoices} from './appearance-choices';
import {fontCSS,installFont,contrast} from './bundled-fonts';
import {DEFAULT_PREFERENCES,preferences,restoreState,selectorFor,rangePoint} from './state';
import {THEMES,FONTS,MARGINS,resolveTheme,fontStack,fontAvailable,marginMetrics,averageCharacterWidth} from './appearance';

const $=id=>document.getElementById(id);
const pageSlide=new PageSlide($('reader'));
const navigationCompletion=new NavigationCompletion();
const pageTurnGesture={distance:0,sign:0,latched:false,last:0};
const clone=value=>JSON.parse(JSON.stringify(value));
const media=matchMedia('(prefers-color-scheme: dark)');
const widePage=matchMedia('(min-width:1100px)');
const effectiveColumns=()=>state?.preferences.columns==='two'&&widePage.matches&&!state.preferences.scroll?2:1;
const colors={gold:'#e4c778',sage:'#a7cbb0',rose:'#d7a9b4'};
let navigator,pool,input,state,lastLocator,selection,editingNote,activeTab='contents',searchGeneration=0,searchTimer,stateTimer,noticeTimer,lastFocus,opening=false;
let lifecycle=0;let preferenceQueue=Promise.resolve(),preferenceRevision=0,preferenceRestore=false;let jumpHistory=[];let stableAnchor=null,reflowCount=0,resizeTimer,resizing=false;
const frames=new WeakSet();let headingCache=new Map();
const pageLayoutObservers=new WeakMap();
let screenIndex,backgroundQuietUntil=0;
const backgroundActivity=()=>{backgroundQuietUntil=performance.now()+350};
for(const type of ['wheel','scroll','pointerdown','keydown','input'])window.addEventListener(type,backgroundActivity,{capture:true,passive:true});
const delay=ms=>new Promise(resolve=>setTimeout(resolve,ms));
async function paginationIdle(signal){
 // Yield between chapters and pause while the reader scrolls or changes layout.
 await new Promise(requestAnimationFrame);
 while(!signal.aborted&&(opening||reflowCount||resizing||performance.now()<backgroundQuietUntil))await delay(80);
}
function paginationLayout(){
 return JSON.stringify({edition:input.editionId,width:$('reading-viewport').clientWidth,height:$('reader').clientHeight,
  continuous:Boolean(input.experimentalContinuous&&state.preferences.scroll),settings:readiumPreferences(),renderer:'screen-v1'});
}
function assetsSettled(doc){return doc?.body&&doc.fonts.status!=='loading'&&[...doc.images].every(image=>image.complete)}
async function measureChapterScreens(book,owner,chapter,signal,key){
 const layout=JSON.parse(key),link=book.readingOrder[chapter];
 const resourcesController=new AbortController(),resources=owner.fork(resourcesController.signal);
 const host=document.createElement('div');host.className='pagination-probe';host.inert=true;host.setAttribute('aria-hidden','true');
 host.style.width=layout.width+'px';host.style.height=layout.height+'px';
 const container=document.createElement('div');container.style.height='100%';host.append(container);document.body.append(host);
 let probe,timer;
 let rejectAbort;const onAbort=()=>{resourcesController.abort();rejectAbort(new DOMException('Stale pagination','AbortError'))};
 const aborted=new Promise((_,reject)=>{rejectAbort=reject;signal.addEventListener('abort',onAbort,{once:true});timer=setTimeout(()=>{resourcesController.abort();reject(Error('Chapter layout did not settle'))},12000)});
 try{
  if(signal.aborted)throw new DOMException('Stale pagination','AbortError');
  const measuring=(async()=>{
   if(layout.continuous){
    probe=new ContinuousNavigator(container,{...book,readingOrder:[link]},resources,{},null,layout.settings);
   }else{
    const manifest=Manifest.deserialize({metadata:{title:book.title??'Untitled',language:book.languages??book.language??'en',readingProgression:book.readingProgression,conformsTo:['https://readium.org/webpub-manifest/profiles/epub']},readingOrder:[{...link,type:'text/html'}]});
    const publication=new Publication({manifest,fetcher:new PublicationFetcher(resources)});
    const locator=Locator.deserialize({...link,type:'text/html',locations:{position:1,progression:0,totalProgression:0}});
    probe=new EpubNavigator(container,publication,{},[locator],undefined,{preferences:layout.settings,defaults:{}});
   }
   await probe.load();
   if(signal.aborted)return;
   const frame=[...container.querySelectorAll('iframe')].find(f=>getComputedStyle(f).visibility!=='hidden');
   const wnd=frame?.contentWindow,doc=frame?.contentDocument;
   if(!doc?.body)throw Error('Missing chapter layout');
   await doc.fonts.ready;
   // Image load/error both settle geometry. A pending resource leaves the
   // denominator calculating rather than claiming a provisional exact count.
   await Promise.all([...doc.images].filter(image=>!image.complete).map(image=>new Promise(resolve=>{image.addEventListener('load',resolve,{once:true});image.addEventListener('error',resolve,{once:true})})));
   await delay(120);
   if(signal.aborted)return;
   let extent,viewport;
   if(layout.continuous){probe.measure(probe.entries[0]);extent=probe.entries[0].height;viewport=layout.height;}
   else{const root=doc.scrollingElement;extent=layout.settings.scroll?root.scrollHeight:root.scrollWidth;viewport=layout.settings.scroll?wnd.innerHeight:wnd.innerWidth;}
   return screenPages({extent,viewport})?.total;
  })();
  return await Promise.race([measuring,aborted]);
 }finally{
  clearTimeout(timer);
  signal.removeEventListener('abort',onAbort);
  resourcesController.abort();
  // Disconnect resize before the frame handshake, as for live navigators.
  // Readium may await an in-progress frame handshake indefinitely. Its cleanup
  // starts immediately, but cannot hold close hostage. The independent resource
  // view is aborted/closed, so a late continuation cannot access the live owner.
  try{await Promise.race([Promise.resolve(destroyNavigator(probe)).catch(()=>{}),delay(400)])}finally{host.remove();resources.close()}
 }
}
function observeChapterPages(wnd,generation){
 if(navigator?.kind==='continuous')return;
 const href=navigator?.currentLocator?.href??lastLocator?.href;
 const chapter=input.readingOrder.findIndex(link=>link.href===href);
 let previous,previousExtent,pending=0,invalidated=false;const doc=wnd.document;
 const live=()=>generation===lifecycle&&state&&[...$('reader').querySelectorAll('iframe')].some(frame=>frame.contentWindow===wnd);
 const extent=()=>state.preferences.scroll?doc.scrollingElement.scrollHeight:doc.scrollingElement.scrollWidth;
 const invalidate=()=>{if(!live()||invalidated)return;invalidated=true;quietUntil=performance.now()+800;screenIndex?.invalidate(chapter)};
 const measure=()=>{
  pending=0;if(!live()||reflowCount||resizing)return;
  const root=doc.scrollingElement;if(!root)return;
  if(!assetsSettled(doc)){invalidate();return;}
  const count=screenPages(state.preferences.scroll?{extent:root.scrollHeight,viewport:wnd.innerHeight}:{extent:root.scrollWidth,viewport:wnd.innerWidth})?.total;
  if(previous!==undefined&&count!==previous){quietUntil=performance.now()+800;screenIndex?.record(chapter,count);refreshPosition()}
  previous=count;previousExtent=extent();invalidated=false;refreshPosition();
 };
 const schedule=()=>{if(!pending)pending=requestAnimationFrame(measure)};
 const loading=()=>{invalidate();schedule()};
 const resource=event=>{if(['IMG','LINK'].includes(event.target?.tagName))loading()};
 // Readium decoration changes can touch the body; compare the constant-cost
 // screen extent before updating counts, rather than rescanning its text.
 const observer=new MutationObserver(()=>{if(!live())return;if(!assetsSettled(doc)||previousExtent!==extent())invalidate();schedule()});observer.observe(doc.body,{subtree:true,childList:true,attributes:true,characterData:true});
 doc.fonts.addEventListener('loading',loading);doc.fonts.addEventListener('loadingdone',schedule);doc.fonts.addEventListener('loadingerror',schedule);doc.addEventListener('load',resource,true);doc.addEventListener('error',resource,true);schedule();
 pageLayoutObservers.set(wnd,()=>{observer.disconnect();cancelAnimationFrame(pending);doc.fonts.removeEventListener('loading',loading);doc.fonts.removeEventListener('loadingdone',schedule);doc.fonts.removeEventListener('loadingerror',schedule);doc.removeEventListener('load',resource,true);doc.removeEventListener('error',resource,true)});
}
const annotationUI=new AnnotationUI({popup:$('selection-tools'),layer:$('annotation-margins'),viewport:$('reader'),
 frames:()=>navigator?.kind==='continuous'?navigator.entries.filter(e=>e.frame).map(e=>({frame:e.frame,href:e.link.href})):[...$('reader').querySelectorAll('iframe')].filter(f=>getComputedStyle(f).visibility!=='hidden').map(frame=>({frame,href:lastLocator?.href})),
 annotations:()=>state?.annotations??[],continuous:()=>navigator?.kind==='continuous',onDismiss:()=>{selection=null},
 onEdit:id=>{const item=state?.annotations.find(x=>x.id===id);if(item)editNote(item)},onList:openAnnotations});
function openAnnotations(){if(!state)return;annotationUI.dismiss();renderPanel('notes');showDialog('library-panel','tab-notes')}
function removeAnnotation(id){state.annotations=state.annotations.filter(x=>x.id!==id);applyAnnotations();changed();annotationUI.dismiss();if($('library-panel').open)renderPanel('notes');notice('Highlight and note removed.')}

const icons={contents:'<path d="M4 5h16M4 12h16M4 19h11"/>',search:'<circle cx="10" cy="10" r="6.5"/><path d="m15 15 5 5"/>',bookmark:'<path d="M6 3h12v18l-6-4-6 4z"/>',previous:'<path d="m14 5-7 7 7 7"/>',next:'<path d="m10 5 7 7-7 7"/>'};
for(const [id,key]of [['contents','contents'],['search','search'],['save-bookmark','bookmark'],['previous','previous'],['next','next']])$(id).innerHTML='<svg viewBox="0 0 24 24" aria-hidden="true">'+icons[key]+'</svg>';
let eventSequence=0;
function emit(type,data={}){window.dispatchEvent(new CustomEvent('stillleaf-reader-event',{detail:{version:1,sequence:++eventSequence,observedAt:Date.now(),type,editionId:input?.editionId,...data}}))}
function notice(message){$('notice').textContent=message;$('notice').hidden=false;clearTimeout(noticeTimer);noticeTimer=setTimeout(()=>$('notice').hidden=true,4200)}
function snapshot(){return state?clone(state):null}
function requireSaveBudget(candidate){
 // Leave room for a later locator/revision update inside the hosts' 2 MiB cap.
 if(new TextEncoder().encode(JSON.stringify({...candidate,revision:state.revision+1})).byteLength>2*1024*1024-32768)
  throw Error('This book has reached its note storage limit. Export your notes before removing any to make room.');
}
function changed(immediate=true){
 if(!state)return;
 state.revision++;clearTimeout(stateTimer);
 if(immediate)emit('state',{state:snapshot()});else stateTimer=setTimeout(()=>emit('state',{state:snapshot()}),120);
}
function validLocator(value){
 if(!value||typeof value.href!=='string'||!input?.resources.some(x=>x.href===value.href))return null;
 try{if(JSON.stringify(value).length>524288)return null;return Locator.deserialize(value)?clone(value):null}catch{return null}
}
// Derived spine ordinals belong to the engine adapter, never stored annotations.
function engineLocator(value){
 const locator=validLocator(value);if(!locator)return undefined;
 const index=input.readingOrder.findIndex(link=>link.href===locator.href);if(index<0)return undefined;
 locator.locations={...locator.locations,position:locator.locations?.position??index+1};
 return Locator.deserialize(locator);
}
function linkLocator(link){
 if(typeof link?.href!=='string')return null;
 try{const resolved=pool.resolve('',link.href);const fragment=resolved.fragment?decodeURIComponent(resolved.fragment.slice(1)):undefined;return validLocator({href:resolved.href,type:'text/html',title:link.title,locations:fragment?{fragments:[fragment]}:{progression:0}})}catch{return null}
}
function updateHistory(){$('return-jump').hidden=!jumpHistory.length;}
// Readium drops a go() that arrives while another is in flight, so jumps run one at a time.
// Return reads the history only once the jump ahead of it has recorded its origin.
let navigation=Promise.resolve();
function queueNavigation(task){const generation=lifecycle;const run=navigation.then(()=>generation===lifecycle?task():false);navigation=run.catch(()=>{});return run}
function go(value,recordHistory=true){return queueNavigation(()=>jumpNow(value,recordHistory))}
function returnFromJump(){return queueNavigation(async()=>{
 const target=jumpHistory.at(-1);if(!target)return false;
 if(await jumpNow(target,false)){jumpHistory.pop();updateHistory();return true}return false;
})}
function followPublicationLink(event){
 const anchor=event.target?.closest?.('a[href]');if(!anchor)return;
 event.preventDefault();event.stopImmediatePropagation();
 if(event.type==='click'&&event.detail!==0)return;
 const locator=linkLocator({href:anchor.getAttribute('href')});
 if(locator)void go(locator);else notice('This link cannot be opened in this reader.');
}
function headingFor(href){
 if(headingCache.has(href))return headingCache.get(href);
 const index=input.readingOrder.findIndex(x=>x.href===href),link=input.readingOrder[index];
 if(link?.title){headingCache.set(href,link.title);return link.title;}
 // Chapters load on demand; show the ordinal until the heading is known.
 const fallback=`Chapter ${index+1}`,owner=pool;headingCache.set(href,fallback);
 pool.chapter(href).then(html=>{
  if(pool!==owner)return;
  const title=new DOMParser().parseFromString(html,'text/html').querySelector('h1,h2')?.textContent?.trim().slice(0,200);
  if(title){headingCache.set(href,title);if(lastLocator?.href===href)updatePosition()}
 },()=>{});
 return fallback;
}
function updatePosition(){
 if(!lastLocator)return;
 const heading=headingFor(lastLocator.href);
 let pages,metrics;
 if(navigator?.kind==='continuous'){
  const entry=navigator.entries.find(item=>item.link.href===lastLocator.href);
  if(entry?.frame){const viewport=$('reader');metrics={extent:entry.height,viewport:viewport.clientHeight,offset:viewport.scrollTop-entry.section.offsetTop};pages=screenPages(metrics);}
 }else{
  // Readium's positions are spine entries, not pages. Measure the visible frame;
  // its start/end progressions use different denominators in paginated mode.
  const frame=[...$('reader').querySelectorAll('iframe')].find(f=>getComputedStyle(f).visibility!=='hidden');
  const wnd=frame?.contentWindow,doc=wnd?.document.scrollingElement;
  if(doc){metrics=state.preferences.scroll
   ?{extent:doc.scrollHeight,viewport:wnd.innerHeight,offset:wnd.scrollY}
   :{extent:doc.scrollWidth,viewport:wnd.innerWidth,offset:Math.abs(wnd.scrollX),columns:effectiveColumns()};pages=screenPages(metrics);}
 }
 const left=chapterPagesLeft(metrics??{});
 const chapter=input.readingOrder.findIndex(link=>link.href===lastLocator.href);
 if(screenIndex&&!opening){
  screenIndex.configure(paginationLayout(),input.readingOrder.length);
  if(!reflowCount&&!resizing&&navigator?.kind==='continuous'){
   for(const entry of navigator.entries)if(entry.frame&&!navigator.dirtyEntries.has(entry)&&assetsSettled(entry.frame.contentDocument)){
    screenIndex.record(entry.index,screenPages({extent:entry.height,viewport:$('reader').clientHeight})?.total);
   }
  }else if(!reflowCount&&!resizing){
   const frame=[...$('reader').querySelectorAll('iframe')].find(f=>getComputedStyle(f).visibility!=='hidden');
   if(pages&&assetsSettled(frame?.contentDocument))screenIndex.record(chapter,pages.total);
  }
 }
 if(pages&&!opening){
  nativePosition=contentPosition(pages,left===0);
  emit('position',{position:nativePosition});
 }
 const displayFrame=navigator?.kind==='continuous'?navigator.entries.find(entry=>entry.index===chapter)?.frame:[...$('reader').querySelectorAll('iframe')].find(frame=>getComputedStyle(frame).visibility!=='hidden');
 const bookScreens=!reflowCount&&!resizing&&assetsSettled(displayFrame?.contentDocument)?screenIndex?.pages(chapter,pages):null;
 const label=bookScreens?pageLabel(bookScreens):pages?`${pageLabel(pages)} · Chapter ${chapter+1} · Calculating book pages…`:'Calculating book pages…';
 if($('position-label').textContent!==label)$('position-label').textContent=label;
 $('position-label').title=heading+' · One page is one full reading screen. Whole-book counts update with layout.';
 const remaining=left===null?'':`${left} ${left===1?'page':'pages'} left in chapter`;
 if($('chapter-label').textContent!==remaining)$('chapter-label').textContent=remaining;
 $('chapter-label').title=heading+' · Remaining reading screens in this chapter.';
 const saved=state.bookmarks.some(x=>samePlace(x.locator,lastLocator));
 $('save-bookmark').setAttribute('aria-pressed',String(saved));$('save-bookmark').setAttribute('aria-label',saved?'Remove bookmark':'Add bookmark');$('save-bookmark').title=saved?'Remove bookmark':'Add bookmark';
}
// Text coordinates survive font changes and resizing. Never infer a whole-book
// page total from chapter ordinals. Empty/image-only pages retain position only.
let nativePosition=null,contentIndex=null,contentIndexFailed=false;
const contentIndexes=new Map();
async function indexContent(owner,generation,edition,order){
 try{
  let counts=contentIndexes.get(edition);
  if(!counts){
   counts=[];
   for(const link of order){
    // Yield between chapters. Never block opening on the complete denominator.
    await new Promise(resolve=>setTimeout(resolve,0));
    if(owner!==pool||generation!==lifecycle)return;
    counts.push(await owner.textLength(link.href));
   }
   if(owner!==pool||generation!==lifecycle)return;
   contentIndexes.set(edition,counts);
   while(contentIndexes.size>16)contentIndexes.delete(contentIndexes.keys().next().value);
  }
  if(owner!==pool||generation!==lifecycle)return;
  contentIndex=counts;refreshPosition();
 }catch{if(owner===pool&&generation===lifecycle){contentIndexFailed=true;refreshPosition()}}
}

function contentPosition(pages,atEnd=false){
 const result={href:lastLocator.href,page:pages.first,totalPages:pages.total,visiblePages:1,pageUnit:'screen'};
 const entry=navigator?.kind==='continuous'?navigator.entries.find(e=>e.link.href===lastLocator.href):null;
 const frame=entry?.frame??[...$('reader').querySelectorAll('iframe')].find(f=>getComputedStyle(f).visibility!=='hidden');
 const doc=frame?.contentDocument;if(!doc?.body)return result;
 const bounds=frame.getBoundingClientRect(),viewport=$('reader').getBoundingClientRect();
 const left=Math.max(0,viewport.left-bounds.left),right=Math.min(frame.clientWidth,viewport.right-bounds.left);
 const top=Math.max(0,viewport.top-bounds.top),bottom=Math.min(frame.clientHeight,viewport.bottom-bounds.top);
 const visible=r=>r.width>0&&r.height>0&&r.right>left&&r.left<right&&r.bottom>top&&r.top<bottom;
 let lower=null,upper=null;
 const candidates=entry?continuousTextCandidates(doc,entry.geometryRevision,top,bottom):(()=>{
  const items=[],walk=doc.createTreeWalker(doc.body,NodeFilter.SHOW_TEXT);let node,offset=0;
  while((node=walk.nextNode())){if(node.parentElement?.closest('script,style'))continue;items.push({node,offset});offset+=node.length;}
  return items;
 })();
 for(const {node,offset}of candidates){
  const bounds=node.textContent.trim()?visibleTextBounds(node,visible):null;
  if(bounds&&bounds.last>bounds.first){lower??=offset+bounds.first;upper=offset+bounds.last;}
 }
 if(lower!==null&&upper>lower){result.lower=lower;result.upper=upper;}
 if(contentIndex){
  const chapter=input.readingOrder.findIndex(link=>link.href===result.href);
  const total=contentIndex.reduce((a,b)=>a+b,0);
  // Position is the trailing visible text boundary, not a claim it was read.
  // Image-only final screens can still display the end of the text coordinate.
  const edge=atEnd?contentIndex[chapter]:upper;
  if(chapter>=0&&total>0&&edge!==null){
   result.bookOffset=Math.min(total,contentIndex.slice(0,chapter).reduce((a,b)=>a+b,0)+Math.min(contentIndex[chapter],edge));
   result.bookTotal=total;
  }
 }
 return result;
}
let positionFrame=0;
function refreshPosition(){
 updatePosition();
 // Readium can announce a jump before committing its scroll offset to the frame.
 // Read the settled geometry on the next paint, coalescing rapid notifications.
 if(navigator?.kind!=='continuous'){cancelAnimationFrame(positionFrame);positionFrame=requestAnimationFrame(updatePosition);}
}
function samePlace(a,b){return a.href===b.href&&Math.abs((a.locations?.progression??0)-(b.locations?.progression??0))<.002}
function currentTheme(){
 const p=state?.preferences,t=resolveTheme(p?.theme??'system',media.matches);
 if(p?.theme!=='custom')return t;
 const background=p.backgroundColor??t.background,text=p.textColor??t.text;
 return {...t,background,text,link:text,chrome:background,panel:background,muted:text};
}
function theme(){return currentTheme().id}
const compactWindow=()=>innerWidth<640;
function readingMargins(){
 const p=state.preferences,m=marginMetrics(p.margins,compactWindow());
 return {...m,gutter:p.sideMargin==null?m.gutter:Math.min(p.sideMargin,Math.max(0,(innerWidth/effectiveColumns()-240)/2))};
}
function readiumPreferences(){
 const p=state.preferences,t=currentTheme(),{gutter}=readingMargins();
 return {fontSize:p.fontSize,fontFamily:fontStack(p.fontFamily),fontWeight:p.fontWeight,textAlign:p.textAlign==='publisher'?null:p.textAlign,hyphens:p.hyphens,letterSpacing:p.letterSpacing,wordSpacing:p.wordSpacing,scroll:p.scroll,scrollPaddingTop:0,scrollPaddingBottom:0,scrollPaddingLeft:gutter,scrollPaddingRight:gutter,lineHeight:p.lineHeight,optimalLineLength:p.measure,maximalLineLength:p.measure+5,minimalLineLength:Math.min(effectiveColumns()===2?Math.min(20,p.measure):Math.min(p.measure,Math.max(20,p.measure-15)),Math.max(1,Math.floor((readingWidth()/effectiveColumns()-2*gutter)/(16*p.fontSize*.55)))),pageGutter:gutter,columnCount:effectiveColumns(),backgroundColor:t.background,textColor:t.text,linkColor:t.link,selectionBackgroundColor:t.selection,darkenFilter:t.dimImages===true};
}
/** Page width for the chosen measure: the chosen typeface's measured advance, or an
 *  average serif estimate when the publisher's own font is in use. */
function readingWidth(){
 const p=state.preferences,{gutter}=readingMargins(),size=16*p.fontSize,stack=fontStack(p.fontFamily);
 const perCharacter=(stack&&averageCharacterWidth(stack,size))||size*.48;
 return Math.min(innerWidth*p.contentWidth/100,(p.measure*perCharacter+2*gutter)*effectiveColumns());
}
function applyChromeTheme(t){
 const root=document.documentElement.style;root.colorScheme=t.scheme;
 for(const [name,value]of [['chrome',t.chrome],['paper',t.background],['ink',t.text],['muted',t.muted],['accent',t.link],['line',t.text+(t.scheme==='dark'?'20':'1c')],['hover',t.scheme==='dark'?'#ffffff0d':t.text+'0f'],['panel',t.panel]])root.setProperty('--'+name,value);
}
function renderAppearanceControls(){
 const themes=$('theme-options');
 if(!themes.childElementCount){
  const system={id:'system',label:'System'};
  for(const t of [system,...THEMES]){
   const b=document.createElement('button');b.dataset.theme=t.id;b.setAttribute('aria-label',t.label);b.setAttribute('aria-pressed','false');b.title=t.label;
   const swatch=document.createElement('span');swatch.className='swatch';
   if(t.id==='system'){const day=resolveTheme('system',false),night=resolveTheme('system',true);swatch.style.background=`linear-gradient(90deg,${day.background} 50%,${night.background} 50%)`;swatch.style.color=day.link}
   else{swatch.style.background=t.background;swatch.style.color=t.text}
   b.append(swatch,document.createTextNode(t.label));b.onclick=()=>void setPreferences({theme:t.id});themes.append(b);
  }
 }
 const fonts=$('font-options'),chosen=state?.preferences.fontFamily,focused=fonts.contains(document.activeElement)?document.activeElement.dataset.font:null;fonts.replaceChildren();
 for(const f of FONTS){
  // Offer installed typefaces; keep a saved choice visible even if this Mac lacks it.
  if(!fontAvailable(f.id)&&f.id!==chosen)continue;
  const b=document.createElement('button');b.className='font-option';b.dataset.font=f.id;b.setAttribute('role','radio');b.setAttribute('aria-checked',String(f.id===chosen));b.tabIndex=f.id===chosen?0:-1;
  b.textContent=f.label;if(f.stack)b.style.fontFamily=f.stack;if(!fontAvailable(f.id))b.title=f.label+' is not installed on this computer';
  b.onclick=()=>void setPreferences({fontFamily:f.id});fonts.append(b);
 }
 if(focused)fonts.querySelector(`[data-font="${focused}"]`)?.focus();
 const margins=$('margins');
 if(!margins.childElementCount)for(const [id,m]of Object.entries(MARGINS)){const b=document.createElement('button');b.dataset.margins=id;b.setAttribute('role','radio');b.textContent=m.label;b.onclick=()=>void setPreferences({margins:id,sideMargin:null});margins.append(b)}
 for(const b of margins.children){const on=state?.preferences.sideMargin==null&&b.dataset.margins===(state?.preferences.margins??'normal');b.setAttribute('aria-checked',String(on));b.tabIndex=on?0:-1}
}
function syncAppearance(){
 if(!state)return;
 const t=currentTheme();document.documentElement.dataset.theme=t.id;applyChromeTheme(t);
 // Bound the parent Readium measures, rather than clipping its computed frame.
 document.documentElement.style.setProperty('--reading-width',readingWidth()+'px');
 document.documentElement.style.setProperty('--page-inset',marginMetrics(state.preferences.margins,compactWindow()).inset+'px');
 renderAppearanceControls();
 const p=state.preferences,root=document.documentElement;
 root.classList.toggle('immersive',p.immersive);$('immersive').checked=p.immersive;
 $('leave-focus').hidden=!p.immersive;$('focus-reading').setAttribute('aria-pressed',String(p.immersive));
 $('background-color').value=p.backgroundColor??t.background;$('text-color').value=p.textColor??t.text;
 $('contrast-note').textContent='Text contrast: '+contrast(t.background,t.text).toFixed(1)+':1'+(contrast(t.background,t.text)<4.5?' · Low contrast':'');
 $('content-width').value=p.contentWidth;$('content-width-value').textContent=p.contentWidth+'%';
 $('side-margin').value=readingMargins().gutter;$('side-margin-value').textContent=Math.round(readingMargins().gutter)+' px';
 for(const button of document.querySelectorAll('[data-theme]'))button.setAttribute('aria-pressed',String(button.dataset.theme===state.preferences.theme));
 {const mode=state.preferences.scroll?'continuous':state.preferences.columns==='two'?'facing':'single';for(const b of $('reading-mode').querySelectorAll('[role=radio]')){const on=b.dataset.mode===mode;b.setAttribute('aria-checked',String(on));b.tabIndex=on?0:-1}}syncTypographyChoices(state.preferences);
 $('previous').title=state.preferences.scroll?'Previous section':'Previous page';$('next').title=state.preferences.scroll?'Next section':'Next page';
 $('columns-note').textContent=state.preferences.scroll||state.preferences.columns!=='two'?'':widePage.matches?'A narrow window shows one page at a time.':'Widen the window to see both pages.';
 for(const [id,key]of [['letter-spacing','letterSpacing'],['word-spacing','wordSpacing']]){$(id).value=state.preferences[key];$(id+'-value').textContent=Math.round(state.preferences[key]*100)+'%';}
 for(const [id,key]of [['font-size','fontSize'],['line-height','lineHeight'],['measure','measure']])$(id).value=state.preferences[key];
 $('font-size-value').textContent=Math.round(state.preferences.fontSize*100)+'%';$('line-height-value').textContent=state.preferences.lineHeight.toFixed(2).replace(/0$/,'');$('measure-value').textContent='About '+Math.round(state.preferences.measure)+' characters';
}
async function prepareFont(id,generation){
 const css=await fontCSS(id);if(generation!==lifecycle||!pool)return;
 if(pool.trustedFontCSS!==css){pool.trustedFontCSS=css;pool.chapters.clear()}
 await Promise.all([installFont(document,id,css),...[...document.querySelectorAll('#reader iframe')].map(frame=>frame.contentDocument?installFont(frame.contentDocument,id,css):Promise.resolve())]);
}
function visibleAnchor(){
 if(navigator?.kind==='continuous')return navigator.captureLocator();
 if(!lastLocator)return null;
 const frame=[...document.querySelectorAll('#reader iframe')].find(f=>getComputedStyle(f).visibility!=='hidden');
 if(!frame?.contentDocument)return clone(lastLocator);
 const doc=frame.contentDocument,wnd=frame.contentWindow,walk=doc.createTreeWalker(doc.body,NodeFilter.SHOW_TEXT);let node;
 while((node=walk.nextNode())){
  if(!node.textContent.trim()||['STYLE','SCRIPT'].includes(node.parentElement?.tagName))continue;
  const range=doc.createRange();range.selectNodeContents(node);if(![...range.getClientRects()].some(r=>r.right>0&&r.left<wnd.innerWidth&&r.bottom>0&&r.top<wnd.innerHeight))continue;
  const i=firstFullyVisibleOffset(node,{width:wnd.innerWidth,height:wnd.innerHeight});
  if(i!==null)return {...clone(lastLocator),locations:{...lastLocator.locations,cssSelector:selectorFor(node.parentElement)},text:{highlight:node.textContent.slice(i,i+80)}};
 }
 return clone(lastLocator);
}
// Readium's destroy() waits for each frame to ack "unfocus", but a resize-driven CSS commit
// halts hidden frames' comms and drops that ack, leaving destroy() (and open/close) unsettled.
function destroyNavigator(current){
 navigationCompletion.dispose(current);
 if(current&&current.kind!=='continuous'){current.resizeObserver?.disconnect();current.resizeHandler=async()=>{}}
 return current?.destroy();
}
async function setPreferences(value,retained){
 const requestedLifecycle=lifecycle;
 pageSlide.cancel();
 await navigation;
 if(!state||requestedLifecycle!==lifecycle)return;
 screenIndex?.cancel();
 const location=retained??stableAnchor??visibleAnchor();if(location)stableAnchor=clone(location);reflowCount++;
 const restore=Object.keys(value).some(key=>!['theme'].includes(key))||Object.keys(value).length===0;
 state.preferences=preferences({...state.preferences,...value});syncAppearance();changed(false);
 const settings=readiumPreferences(),generation=lifecycle,fontId=state.preferences.fontFamily,request=++preferenceRevision;
 preferenceRestore||=restore;
 preferenceQueue=preferenceQueue.catch(()=>{}).then(async()=>{
  if(generation!==lifecycle||request!==preferenceRevision||!navigator)return;
  relayout();await prepareFont(fontId,generation);
  if(generation!==lifecycle||request!==preferenceRevision||!navigator)return;
  const current=navigator,continuous=Boolean(input.experimentalContinuous&&settings.scroll);
  // Finish an in-flight mode switch even if superseded so the next job always
  // receives a live navigator. Queued jobs have already been coalesced above.
  if((current.kind==='continuous')!==continuous){await destroyNavigator(current);if(generation===lifecycle)await installNavigator(location,settings)}
  else{
   await current.submitPreferences(new EpubPreferences(settings));
   if(preferenceRestore&&location&&current===navigator&&generation===lifecycle&&request===preferenceRevision){
    await new Promise(resolve=>setTimeout(resolve,120));
    if(generation===lifecycle&&request===preferenceRevision)await go(location,false);
   }
  }
  if(generation===lifecycle&&request===preferenceRevision)preferenceRestore=false;
 });
 // Every caller settles after the final coalesced job, including callers whose
 // own intermediate layout was skipped while a slider continued moving.
 try{let pending;do{pending=preferenceQueue;await pending}while(generation===lifecycle&&pending!==preferenceQueue)}finally{reflowCount=Math.max(0,reflowCount-1);if(generation===lifecycle&&state)refreshPosition()}
}
function dismissSelection(){annotationUI.dismiss();for(const f of document.querySelectorAll('#reader iframe'))f.contentWindow?.getSelection()?.removeAllRanges()}
function selected(value){
 if(!value.text?.trim()||!value.locator){$('selection-tools').hidden=true;return}
 const locator=validLocator(value.locator.serialize?.()??value.locator);if(!locator)return;
 let selectedRange;
 for(const {frame,href} of annotationUI.frames()){
  if(href!==locator.href)continue;
  const sel=frame.contentWindow?.getSelection();
  if(sel?.rangeCount&&sel.toString()===value.text){
   const range=sel.getRangeAt(0);selectedRange={frame,range};locator.locations={...locator.locations,domRange:{start:rangePoint(range.startContainer,range.startOffset),end:rangePoint(range.endContainer,range.endOffset)}};
   const before=range.cloneRange(),after=range.cloneRange();before.selectNodeContents(frame.contentDocument.body);before.setEnd(range.startContainer,range.startOffset);after.selectNodeContents(frame.contentDocument.body);after.setStart(range.endContainer,range.endOffset);
   if(value.text.length>MAX_LOCATOR_TEXT){locator.locations.domRange=longSelectionRange(range);locator.locations.domRangeIndexing='text-nodes'}
   locator.text={...locator.text,highlight:value.text,before:before.toString().slice(-80),after:after.toString().slice(0,80)};break;
  }
 }
 locator.text={...locator.text,highlight:value.text};
 try{selection={locator:annotationLocator(locator),quote:quotePreview(value.text)}}catch(error){notice(error.message);return}
 annotationUI.show(selection,selectedRange);
 emit('selection',{selection:{text:selection.quote,locator:selection.locator}});
}
function decorationLocator(item){
 const locator=clone(item.locator);
 // Readium sends decoration locators as JSON. Passing a Locator instance loses
 // locations.otherLocations (a Map), including domRange, on the wire.
 // Convert legacy all-child coordinates only for that wire representation.
 if(locator.locations?.domRange&&locator.locations.domRangeIndexing!=='text-nodes'){
  const frame=annotationUI.frames().find(value=>value.href===locator.href)?.frame;
  const range=frame&&locatorRange(frame.contentDocument,locator);
  if(range){locator.locations.domRange=longSelectionRange(range);locator.locations.domRangeIndexing='text-nodes'}
  else if(locator.text?.highlight)delete locator.locations.domRange;
 }
 return locator;
}
function applyAnnotations(){
 annotationUI.invalidate();
 if(navigator?.decorationsAvailable===false)return;
 navigator?.applyDecorations(state.annotations.filter(item=>input.readingOrder.some(link=>link.href===item.locator.href)).map(item=>({id:item.id,locator:navigator?.kind==='continuous'?clone(item.locator):decorationLocator(item),style:{type:DecorationStyleType.Highlight,tint:colors[item.color]??colors.gold,isActive:true}})),'personal');
}
function annotate(value){
 const prior=state.annotations.find(x=>x.id===value.id);
 const locator=validLocator(prior?.locator??annotationLocator(value.locator));if(!locator||!String(value.quote??'').trim())throw Error('Select a passage to annotate.');
 if(!prior&&state.annotations.length>=1000)throw Error('This book has reached the annotation limit.');
 const now=new Date().toISOString();const item={id:prior?.id??crypto.randomUUID(),locator,quote:prior?.quote??quotePreview(value.quote),note:String(value.note??'').slice(0,65536),color:colors[value.color]?value.color:'gold',createdAt:prior?.createdAt??now,updatedAt:now};
 const annotations=prior?state.annotations.map(existing=>existing===prior?item:existing):[...state.annotations,item];
 requireSaveBudget({...state,annotations});state.annotations=annotations;
 // Notes change the margin cards and stored state, not the highlight ranges.
 // Retain resolved ranges while typing, even across hundreds of highlights.
 if(!prior||prior.color!==item.color)applyAnnotations();else annotationUI.schedule();
 changed();return clone(item);
}
function addBookmark(){
 if(!lastLocator)return;
 const old=state.bookmarks.find(x=>samePlace(x.locator,lastLocator));
 if(old){state.bookmarks=state.bookmarks.filter(x=>x.id!==old.id);notice('Bookmark removed.')}else{
  if(state.bookmarks.length>=1000){notice('This book has reached the bookmark limit.');return}
  const bookmarks=[...state.bookmarks,{id:crypto.randomUUID(),locator:clone(lastLocator),label:headingFor(lastLocator.href),createdAt:new Date().toISOString()}];
  try{requireSaveBudget({...state,bookmarks})}catch(error){notice(error.message);return}
  state.bookmarks=bookmarks;notice('Your place is bookmarked.');
 }
 changed();updatePosition();
}
function showDialog(id,focus){
 annotationUI.dismiss();
 for(const dialog of document.querySelectorAll('dialog[open]'))dialog.close();
 lastFocus=document.activeElement;$(id).showModal();if(focus)$(focus).focus();
}
let draftDecision;
function hasPendingDraft(){return Boolean(editingNote&&$('note-panel').open&&($('note-text').value!==(editingNote.note??'')||document.querySelector('input[name="note-color"]:checked').value!==(colors[editingNote.color]?editingNote.color:'gold')))}
let noteSaveTimer;
function persistNote(){
 clearTimeout(noteSaveTimer);
 if(!editingNote)return true;
 try{
  const color=document.querySelector('input[name="note-color"]:checked').value;
  const note=$('note-text').value;
  if(!(editingNote.id&&note===(editingNote.note??'')&&color===(colors[editingNote.color]?editingNote.color:'gold')))editingNote=annotate({...editingNote,note,color});
  $('delete-note').hidden=!editingNote.id;$('note-error').hidden=true;$('note-status').textContent='Saved automatically';return true;
 }catch(error){$('note-status').textContent='Changes not saved';$('note-error').textContent=(error.message||'The note could not be saved.')+' Your draft is still here.';$('note-error').hidden=false;return false}
}
function saveNote(){
 if(!editingNote)return true;
 try{
  if(!persistNote())return false;
  editingNote=undefined;$('note-error').hidden=true;$('note-panel').close();dismissSelection();notice('Note updated in this reader.');return true;
 }catch(error){
  $('note-error').textContent=(error.message||'The note could not be applied.')+' Your draft is still here. You can keep editing or discard it.';$('note-error').hidden=false;$('note-error').focus();return false;
 }
}
function prepareClose(){
 if(draftDecision)return draftDecision.promise;
 if(hasPendingDraft()&&persistNote())return Promise.resolve(true);
 if(!hasPendingDraft())return Promise.resolve(true);
 const focus=document.activeElement;let resolve;const promise=new Promise(done=>resolve=done);draftDecision={promise,resolve,focus};$('draft-panel').showModal();$('keep-draft').focus();return promise;
}
function decideDraft(choice){
 if(!draftDecision)return;
 const decision=draftDecision;draftDecision=undefined;$('draft-panel').close();
 if(choice==='save'&&!saveNote()){decision.resolve(false);return;}
 if(choice==='discard'){editingNote=undefined;$('note-panel').close();}
 if(choice==='keep'&&decision.focus?.isConnected)decision.focus.focus();
 decision.resolve(choice!=='keep');
}
async function closeDialog(dialog){
 if(dialog.id==='draft-panel'){decideDraft('keep');return false;}
 if(dialog.id==='note-panel'&&!await prepareClose())return false;
 dialog.close();if(dialog.id==='note-panel')editingNote=undefined;if(lastFocus?.isConnected)lastFocus.focus();return true;
}
for(const dialog of document.querySelectorAll('dialog')){
 dialog.addEventListener('click',event=>{if(event.target===dialog){const r=dialog.getBoundingClientRect();if(event.clientX<r.left||event.clientX>r.right||event.clientY<r.top||event.clientY>r.bottom)closeDialog(dialog)}});
 dialog.addEventListener('cancel',event=>{event.preventDefault();closeDialog(dialog)});
 const closeButton=dialog.querySelector('[data-close]');if(closeButton)closeButton.onclick=()=>void closeDialog(dialog);
}
function button(text,cls,action){const node=document.createElement('button');node.type='button';node.className=cls;node.textContent=text;node.onclick=action;return node}
function empty(parent,text){const p=document.createElement('p');p.className='empty-panel';p.textContent=text;parent.append(p)}
function renderPanel(tab=activeTab){
 activeTab=tab;$('panel-title').textContent=tab==='notes'?'Highlights and notes':'Your place in the book';const body=$('panel-body');body.replaceChildren();body.setAttribute('aria-labelledby','tab-'+tab);
 for(const key of ['contents','bookmarks','notes']){$('tab-'+key).setAttribute('aria-selected',String(key===tab));$('tab-'+key).tabIndex=key===tab?0:-1}
 if(tab==='contents'){
  const renderLinks=(links,parent,depth=0)=>{
   if(depth>12)return;
   const list=document.createElement('ol');list.className='contents-tree';parent.append(list);
   for(const link of links.slice(0,2000)){
    const item=document.createElement('li');list.append(item);const locator=linkLocator(link);
    const title=link.title|| (locator?headingFor(locator.href):'Untitled section');
    const row=button(title,'chapter-button',()=>{closeDialog($('library-panel'));if(locator)void go(locator);else notice('This section cannot be opened in this reader.')});
    if(locator?.href===lastLocator?.href)row.setAttribute('aria-current','true');
    if(!locator)row.setAttribute('aria-description','This section has no supported local target.');item.append(row);
    if(Array.isArray(link.children)&&link.children.length)renderLinks(link.children,item,depth+1);
   }
  };
  renderLinks(Array.isArray(input.toc)&&input.toc.length?input.toc:input.readingOrder,body);
  for(const [key,label]of [['landmarks','Landmarks'],['pageList','Printed pages']])if(Array.isArray(input[key])&&input[key].length){const section=document.createElement('details');section.className='navigation-group';const summary=document.createElement('summary');summary.textContent=label;section.append(summary);body.append(section);renderLinks(input[key],section);}

 }else if(tab==='bookmarks'){
  if(!state.bookmarks.length)empty(body,'Keep a place to return to. Use the bookmark button while you read.');
  for(const item of state.bookmarks){const article=document.createElement('article');article.className='saved-item';const jump=button(item.label,'saved-link',()=>{closeDialog($('library-panel'));void go(item.locator)});const date=document.createElement('small');date.textContent=new Date(item.createdAt).toLocaleDateString(undefined,{month:'short',day:'numeric'});jump.append(date);const remove=button('×','remove-saved',()=>{state.bookmarks=state.bookmarks.filter(x=>x.id!==item.id);changed();updatePosition();renderPanel()});remove.setAttribute('aria-label','Remove bookmark: '+item.label);article.append(jump,remove);body.append(article)}
 }else{
  if(!state.annotations.length)empty(body,'Select a passage in the book to highlight it or leave yourself a note.');
  for(const item of state.annotations){const article=document.createElement('article');article.className='saved-item annotation-item';article.style.setProperty('--note-color',colors[item.color]??colors.gold);const jump=button('“'+item.quote+'”','saved-link',()=>{closeDialog($('library-panel'));void go(item.locator)});article.append(jump);if(item.note){const note=document.createElement('p');note.className='note-excerpt';note.textContent=item.note;article.append(note)}article.append(button(item.note?'Edit note':'Add a note','edit-note',()=>editNote(item)));body.append(article)}
 }
}
function editNote(item=selection){
 if(!item)return;clearTimeout(noteSaveTimer);$('note-status').textContent='Saved automatically';$('note-error').hidden=true;editingNote=clone(item);$('note-title').textContent=item.id?'Your note':'A note in the margin';$('note-quote').textContent=item.quote;$('note-text').value=item.note??'';$('delete-note').hidden=!item.id;
 document.querySelector(`input[name="note-color"][value="${colors[item.color]?item.color:'gold'}"]`).checked=true;
 showDialog('note-panel','note-text');persistNote();
}
async function jumpNow(value,recordHistory){
 const locator=validLocator(value);if(!navigator||!locator)return false;quietUntil=performance.now()+800;
 if(!input.readingOrder.some(link=>link.href===locator.href)){notice('This saved passage is outside the supported reading sequence.');return false;}
 const before=lastLocator?clone(lastLocator):null;dismissSelection();
 const current=navigator,generation=lifecycle;
 return navigationCompletion.wait(current,done=>current.go(engineLocator(locator),false,done),ok=>{
  if(generation!==lifecycle||current!==navigator)return;
  if(ok){stableAnchor=clone(locator)}
  if(ok&&recordHistory&&before){jumpHistory.push(before);if(jumpHistory.length>100)jumpHistory.shift();updateHistory();}
 }).catch(()=>{if(generation===lifecycle)notice('This passage could not be opened.');return false});
}
// Page evidence for reading goals. Only deliberate sequential movement is reported:
// page turns in paginated modes and full screens scrolled by the reader. Jumps
// (contents, search, links, bookmarks), restores, reflow and resizes never are. Each
// layout gets its own key; native content identity remains independent of reflow.
let layoutGeneration=0,announcedLayout=null,quietUntil=0,scrollState=new WeakMap(),continuousNet=0,continuousPosition=null;
const pagesPerTurn=()=>1;
const layoutKey=()=>(state?.preferences.scroll?'s':'p')+effectiveColumns()+'-'+layoutGeneration;
function announceLayout(){if(!state||opening)return;const layout=layoutKey();if(layout===announcedLayout)return;announcedLayout=layout;emit('pageLayout',{layout,pages:pagesPerTurn()})}
function relayout(){layoutGeneration++;quietUntil=performance.now()+800;scrollState=new WeakMap();continuousNet=0;continuousPosition=null;announceLayout()}
function pageTurned(direction,departure=nativePosition){if(!state)return;announceLayout();emit('pageTurn',{direction,pages:pagesPerTurn(),layout:layoutKey(),departure})}
/** Scroll mode: one page-equivalent per full screen of net movement by the reader. */
function trackScroll(wnd){
 if(!state?.preferences.scroll||navigator?.kind==='continuous')return;
 const y=wnd.scrollY,height=wnd.innerHeight,now=performance.now(),last=scrollState.get(wnd);
 if(!last||now<quietUntil||boundaryBusy||reflowCount||resizing||!(height>0)){scrollState.set(wnd,{y,net:0,position:nativePosition});return}
 const delta=y-last.y;
 // Scrubbing or programmatic jumps move several screens at once; they are never reading.
 if(Math.abs(delta)>height*1.5){scrollState.set(wnd,{y,net:0,position:nativePosition});return}
 let net=last.net+delta;const crossed=Math.abs(net)>=height;
 while(net>=height){net-=height;pageTurned('forward',last.position)}
 while(net<=-height){net+=height;pageTurned('backward')}
 if(crossed)refreshPosition();
 scrollState.set(wnd,{y,net,position:crossed?nativePosition:last.position});
}
/** Continuous view: the adapter reports only the reader's own movement; its layout corrections never arrive here. */
function trackContinuousScroll(delta,height){
 if(!state?.preferences.scroll||navigator?.kind!=='continuous')return;
 if(performance.now()<quietUntil||reflowCount||resizing||!(height>0)||Math.abs(delta)>height*1.5){continuousNet=0;continuousPosition=nativePosition;return}
 continuousPosition??=nativePosition;
 continuousNet+=delta;const crossed=Math.abs(continuousNet)>=height;
 while(continuousNet>=height){continuousNet-=height;pageTurned('forward',continuousPosition)}
 while(continuousNet<=-height){continuousNet+=height;pageTurned('backward')}
 if(crossed){navigator.report();continuousPosition=nativePosition}
}
// Share the jump queue: Readium must never receive overlapping navigation calls.
// Waiting input accelerates presentation, but every accepted turn still navigates once.
let queuedTurns=0;
function turn(direction){
 queuedTurns++;pageSlide.hurry();
 return queueNavigation(async()=>{
  if(!navigator||reflowCount||resizing)return false;
  dismissSelection();
  refreshPosition();const departure=nativePosition;
  const current=navigator,generation=lifecycle;
  return pageSlide.run(direction,{enabled:!state.preferences.scroll,rtl:input?.readingProgression==='rtl'||current.readingProgression==='rtl',hurried:()=>queuedTurns>1},()=>{
   if(generation!==lifecycle||current!==navigator||reflowCount||resizing)return false;
   return navigationCompletion.wait(current,done=>(direction==='next'?current.goForward.bind(current):current.goBackward.bind(current))(false,done),moved=>{
    if(generation!==lifecycle||current!==navigator)return;
    if(moved===true&&!state?.preferences.scroll)pageTurned(direction==='next'?'forward':'backward',departure);
    stableAnchor=visibleAnchor();
   }).catch(()=>false);
  });
 }).finally(()=>{queuedTurns--});
}
// A crossing stays busy until the next chapter lands plus a short settle, so a momentum wheel
// stream turns one chapter, not several; #reader is aria-busy for exactly that span.
let boundaryBusy=false;
function setBoundaryBusy(busy){boundaryBusy=busy;if(busy)$('reader').setAttribute('aria-busy','true');else $('reader').removeAttribute('aria-busy')}
async function crossScrollBoundary(wnd,delta,event){
 if(navigator?.kind==='continuous'||!state?.preferences.scroll||boundaryBusy||!delta||document.querySelector('dialog[open]'))return;
 const scroller=wnd.document.scrollingElement;const atEdge=delta>0?scroller.scrollTop+wnd.innerHeight>=scroller.scrollHeight-2:scroller.scrollTop<=2;if(!atEdge)return;
 const index=input.readingOrder.findIndex(link=>link.href===lastLocator?.href),next=index+(delta>0?1:-1);if(next<0||next>=input.readingOrder.length)return;
 event.preventDefault();setBoundaryBusy(true);
 try{await go({href:input.readingOrder[next].href,type:'text/html',locations:{progression:delta>0?0:1}},false)}finally{setTimeout(()=>setBoundaryBusy(false),200)}
}
function keyboard(event){
 if(event.defaultPrevented||event.altKey||event.metaKey||event.ctrlKey||event.shiftKey)return;
 const tag=event.target?.tagName;if(['INPUT','TEXTAREA','SELECT'].includes(tag)||event.target?.isContentEditable)return;
 if(event.key==='Escape'){if(! $('selection-tools').hidden){event.preventDefault();annotationUI.dismiss(true);return;}if(state?.preferences.immersive&&!document.querySelector('dialog[open]')){event.preventDefault();void setPreferences({immersive:false})}return}
 if(document.querySelector('dialog[open]'))return;
 if(event.key==='ArrowRight'||event.key==='ArrowLeft'){
  const rtl=input?.readingProgression==='rtl'||navigator?.readingProgression==='rtl';
  event.preventDefault();turn((event.key==='ArrowRight')!==rtl?'next':'previous');
 }
 if(!state?.preferences.scroll&&(event.key==='PageDown'||event.key==='PageUp')){
  event.preventDefault();turn(event.key==='PageDown'?'next':'previous');
 }
}
window.addEventListener('keydown',keyboard);
// WebKit can target the iframe's host surface for a trackpad event; Chromium
// usually targets its inner document. Accept both, confined to the book viewport.
installPageTurnWheel(window,{gesture:pageTurnGesture,enabled:event=>{
 const r=$('reader').getBoundingClientRect();
 return Boolean(state&&!state.preferences.scroll&&!document.querySelector('dialog[open]')&&event.clientX>=r.left&&event.clientX<=r.right&&event.clientY>=r.top&&event.clientY<=r.bottom);
},rtl:()=>input?.readingProgression==='rtl'||navigator?.readingProgression==='rtl',turn});
async function searchBook(){
 const query=$('search-query').value.trim(),generation=++searchGeneration;const results=$('search-results');results.replaceChildren();
 if(query.length<2){$('search-status').textContent='Enter at least two characters.';return}
 $('search-status').textContent='Searching…';let found=0;
 for(const link of input.readingOrder){
  if(generation!==searchGeneration)return;
  let doc;try{doc=new DOMParser().parseFromString(await pool.chapter(link.href),'text/html')}catch{continue}
  if(generation!==searchGeneration)return;
  const candidates=[...doc.querySelectorAll('h1,h2,h3,p,li,blockquote,pre,td,dd,dt')].filter(x=>!x.querySelector('h1,h2,h3,p,li,blockquote,pre,td,dd,dt'));
  for(const element of candidates){
   const text=element.textContent,index=text.toLocaleLowerCase().indexOf(query.toLocaleLowerCase());if(index<0)continue;
   const highlight=text.slice(index,index+query.length);const locator={href:link.href,type:'text/html',locations:{cssSelector:selectorFor(element)},text:{highlight,before:text.slice(Math.max(0,index-60),index),after:text.slice(index+query.length,index+query.length+60)}};
   const row=button('','result-link',()=>{closeDialog($('search-panel'));void go(locator)});row.append(document.createTextNode((index>45?'…':'')+text.slice(Math.max(0,index-45),index)));const mark=document.createElement('mark');mark.textContent=highlight;row.append(mark,document.createTextNode(text.slice(index+query.length,index+query.length+70)+(text.length>index+query.length+70?'…':'')));const chapter=document.createElement('small');chapter.textContent=headingFor(link.href);row.append(chapter);results.append(row);if(++found>=200)break;
  }
  if(found>=200)break;await new Promise(resolve=>setTimeout(resolve,0));
 }
 if(generation===searchGeneration)$('search-status').textContent=found?`${found===200?'First ':''}${found} ${found===1?'matching passage':'matching passages'}`:'No matching passages.';
}
// Route Readium's existing edge taps through the same motion/evidence path.
function pageEdgeTap(event){
 if(state?.preferences.scroll)return false;
 if(event.interactiveElement||document.querySelector('dialog[open]'))return true;
 const frame=[...$('reader').querySelectorAll('iframe')].find(f=>getComputedStyle(f).visibility!=='hidden');
 if(!frame||frame.contentWindow.getSelection()?.toString())return true;
 const width=frame.clientWidth*devicePixelRatio;
 if(event.x<width/4||event.x>width*3/4){
  const rtl=input?.readingProgression==='rtl'||navigator?.readingProgression==='rtl';
  turn((event.x>width/2)!==rtl?'next':'previous');
 }
 return true;
}
async function installNavigator(location,settings=readiumPreferences()){
  const generation=lifecycle;
  const manifest=Manifest.deserialize({metadata:{title:input.title??'Untitled',language:input.languages??input.language??'en',readingProgression:input.readingProgression,conformsTo:['https://readium.org/webpub-manifest/profiles/epub']},readingOrder:input.readingOrder.map(x=>({...x,type:'text/html'}))});
  const publication=new Publication({manifest,fetcher:new PublicationFetcher(pool)});
  const positions=input.readingOrder.map((link,i)=>Locator.deserialize({...link,type:'text/html',locations:{position:i+1,progression:0,totalProgression:i/input.readingOrder.length}}));
  const listeners={
   chapterInvalidated:index=>screenIndex?.invalidate(index),
   click:pageEdgeTap,tap:pageEdgeTap,
   positionChanged:locator=>{if(generation!==lifecycle||!state)return;lastLocator=locator.serialize();if(opening&&state.position){refreshPosition();return;}state.position=clone(lastLocator);refreshPosition();changed(false);emit('relocated',{locator:lastLocator,cause:'unknown',eligibleForProgress:false})},
   frameUnloaded:wnd=>{pageLayoutObservers.get(wnd)?.();pageLayoutObservers.delete(wnd);frames.delete(wnd)},
   readerScrolled:(delta,height)=>{if(generation===lifecycle)trackContinuousScroll(delta,height)},
   readerAnchorChanged:locator=>{if(generation===lifecycle&&performance.now()>=quietUntil&&!reflowCount&&!resizing)stableAnchor=clone(locator)},
   textSelected:value=>{if(generation===lifecycle)selected(value)},
   frameLoaded:wnd=>{if(!wnd.CSS?.highlights&&navigator)navigator.decorationsAvailable=false;if(!frames.has(wnd)){frames.add(wnd);observeChapterPages(wnd,generation);for(const type of ["wheel","scroll","keydown","pointerdown"])wnd.addEventListener(type,backgroundActivity,{capture:true,passive:true});installPageTurnWheel(wnd,{gesture:pageTurnGesture,enabled:()=>Boolean(state&&!state.preferences.scroll&&!document.querySelector('dialog[open]')),rtl:()=>input?.readingProgression==='rtl'||navigator?.readingProgression==='rtl',turn});wnd.document.addEventListener('keydown',keyboard);if(navigator?.kind!=='continuous'){let anchorTimer;wnd.addEventListener('wheel',event=>{void crossScrollBoundary(wnd,event.deltaY,event);clearTimeout(anchorTimer);if(!boundaryBusy)anchorTimer=setTimeout(()=>{if(!reflowCount&&!resizing)stableAnchor=visibleAnchor()},100)},{passive:false});}wnd.document.addEventListener('keydown',event=>{if(navigator?.kind!=='continuous'&&['ArrowDown','PageDown','ArrowUp','PageUp'].includes(event.key)&&!['INPUT','TEXTAREA','SELECT'].includes(event.target?.tagName)){void crossScrollBoundary(wnd,['ArrowDown','PageDown'].includes(event.key)?1:-1,event);setTimeout(()=>{if(!boundaryBusy&&!reflowCount&&!resizing)stableAnchor=visibleAnchor()},100)}});wnd.document.addEventListener('pointerup',followPublicationLink,true);wnd.addEventListener('scroll',()=>trackScroll(wnd),{passive:true});wnd.document.addEventListener('click',followPublicationLink,true);wnd.document.addEventListener('keyup',()=>{const text=wnd.getSelection()?.toString();if(text&&lastLocator&&navigator?.kind!=='continuous')selected({text,locator:Locator.deserialize({...lastLocator,text:{highlight:text}})});});}},
   error:error=>{notice(error.message);emit('error',{message:error.message})}
  };
  navigator=input.experimentalContinuous&&settings.scroll?new ContinuousNavigator($('reader'),input,pool,listeners,location,settings):new EpubNavigator($('reader'),publication,listeners,positions,location?engineLocator(location):undefined,{preferences:settings,defaults:{}});
  navigator.registerDecorationObserver('personal',{onDecorationActivated:event=>{const item=state.annotations.find(x=>x.id===event.decoration.id);if(item){selection=clone(item);annotationUI.show(item,annotationUI.locate(item));}return true}});
  const installed=navigator;
  try{await installed.load()}catch(error){
   if(installed.kind!=='continuous'||generation!==lifecycle)throw error;
   await installed.destroy();state.preferences=preferences({...state.preferences,scroll:false});syncAppearance();
   await installNavigator(location,readiumPreferences());changed();notice(error.message+' Reading in pages instead.');return;
  }
  if(generation===lifecycle&&navigator===installed)applyAnnotations();
}
async function open(value){
 if(!await close())throw Error('The current note is still being edited.');headingCache=new Map();stableAnchor=null;jumpHistory=[];updateHistory();input=value;opening=true;$('error').hidden=true;
 try{
  if(value.fixedLayout===true||['fixed','pre-paginated'].includes(value.layout)||value.rendition?.layout==='pre-paginated')throw Error('This book uses a fixed page layout, which this reader does not support yet. Your imported book is preserved in Library.');
  if(!value.readingOrder?.length)throw Error('This book has no readable chapters.');
  for(const link of value.readingOrder)if(!['application/xhtml+xml','text/html'].includes(link.type))throw Error('This book contains illustrated or fixed-image pages that this reader does not support yet.');
  pool=new PublicationResources(value.resources);state=restoreState(value.state,value.editionId,validLocator);
  const override=validLocator(value.locator);if(override)state.position=override;
  $('reader').replaceChildren();$('book-title').textContent=value.title??'Untitled';$('book-author').textContent=value.creators?.join(', ')??'';document.title=(value.title??'Book')+' · Stillleaf';$('back').hidden=!value.canReturnToLibrary;
  syncAppearance();await prepareFont(state.preferences.fontFamily,lifecycle);
  const owner=pool,book=input;
  screenIndex=new ScreenPaginationIndex({measure:(chapter,signal,key)=>measureChapterScreens(book,owner,chapter,signal,key),idle:paginationIdle,
   changed:()=>{if(owner===pool&&!opening){cancelAnimationFrame(positionFrame);positionFrame=requestAnimationFrame(()=>{if(owner===pool)refreshPosition()})}}});
  await installNavigator(state.position);opening=false;refreshPosition();emit('ready',{warnings:[...pool.warnings]});announcedLayout=null;relayout();changed();
  void indexContent(pool,lifecycle,input.editionId,input.readingOrder);
  if(pool.warnings.size&&$('notice').hidden)notice('Some original styling or illustrations could not be displayed.');
 }catch(error){opening=false;$('error').textContent=error.message;$('error').hidden=false;emit('error',{message:error.message});throw error}
}
async function close(){
 if(!await prepareClose())return false;
 if(navigator?.kind==='continuous')navigator.report();
 clearTimeout(noteSaveTimer);annotationUI.reset();pageSlide.cancel();lifecycle++;searchGeneration++;cancelAnimationFrame(positionFrame);clearTimeout(resizeTimer);resizing=false;clearTimeout(searchTimer);clearTimeout(stateTimer);clearTimeout(noticeTimer);
 const paginationClosed=screenIndex?.queue;screenIndex?.close();screenIndex=undefined;
 nativePosition=null;contentIndex=null;contentIndexFailed=false;preferenceRestore=false;
 if(state)emit('state',{state:snapshot()});
 for(const dialog of document.querySelectorAll('dialog[open]'))dialog.close();
 const current=navigator;navigator=undefined;navigationCompletion.dispose(current);await preferenceQueue.catch(()=>{});await destroyNavigator(current);await paginationClosed?.catch(()=>{});pool?.close();pool=undefined;state=undefined;lastLocator=undefined;selection=undefined;$('selection-tools').hidden=true;$('notice').hidden=true;editingNote=undefined;return true;
}
const api={open,close,prepareClose,hasPendingDraft,returnFromJump,next:()=>turn('next'),previous:()=>turn('previous'),go,setPreferences,bookmark:()=>lastLocator?clone(lastLocator):null,restore:go,exportState:()=>{if(hasPendingDraft())persistNote();if(navigator?.kind==='continuous')navigator.report();return snapshot()},addBookmark,annotate};
window.StillleafReader=Object.freeze(api);
$('return-jump').onclick=()=>void returnFromJump();
$('back').onclick=async()=>{if(await prepareClose())emit('close-request')};$('next').onclick=api.next;$('previous').onclick=api.previous;$('save-bookmark').onclick=addBookmark;
$('saved-passages').onclick=openAnnotations;
$('contents').onclick=()=>{if(!state)return;renderPanel();showDialog('library-panel','tab-'+activeTab)};
$('appearance').onclick=()=>{if(state){syncAppearance();showDialog('appearance-panel')}};
$('search').onclick=()=>{if(state)showDialog('search-panel','search-query')};
for(const tab of ['contents','bookmarks','notes'])$('tab-'+tab).onclick=()=>renderPanel(tab);
document.querySelector('.panel-tabs').addEventListener('keydown',event=>{if(['ArrowRight','ArrowLeft'].includes(event.key)){event.preventDefault();const tabs=['contents','bookmarks','notes'];const next=tabs[(tabs.indexOf(activeTab)+(event.key==='ArrowRight'?1:2))%3];renderPanel(next);$('tab-'+next).focus()}});
// Radio groups: arrow keys move the choice, as in native segmented controls.
for(const group of [$('font-options'),$('margins'),$('reading-mode')])group.addEventListener('keydown',event=>{
 const step={ArrowRight:1,ArrowDown:1,ArrowLeft:-1,ArrowUp:-1}[event.key];if(!step)return;event.preventDefault();
 const items=[...group.querySelectorAll('[role=radio]')],next=items[(items.indexOf(document.activeElement)+step+items.length)%items.length];next?.focus();next?.click();
});
document.fonts?.ready.then(()=>{if(state)renderAppearanceControls()});
for(const [id,key]of [['font-size','fontSize'],['line-height','lineHeight'],['measure','measure']])$(id).oninput=()=>void setPreferences({[key]:Number($(id).value)});
for(const b of $('reading-mode').querySelectorAll('[role=radio]'))b.onclick=()=>{const mode=b.dataset.mode;if(b.getAttribute('aria-checked')==='true')return;void setPreferences({scroll:mode==='continuous',...(mode!=='continuous'?{columns:mode==='facing'?'two':'one'}:{})})};
$('font-weight').onchange=()=>void setPreferences({fontWeight:$('font-weight').value==='publisher'?null:Number($('font-weight').value)});
$('text-align').onchange=()=>void setPreferences({textAlign:$('text-align').value});
$('hyphens').onchange=()=>void setPreferences({hyphens:$('hyphens').value==='publisher'?null:$('hyphens').value==='true'});
for(const [id,key]of [['letter-spacing','letterSpacing'],['word-spacing','wordSpacing']])$(id).oninput=()=>void setPreferences({[key]:Number($(id).value)});
window.addEventListener('resize',()=>{pageSlide.cancel();if(!state)return;screenIndex?.cancel();resizing=true;relayout();const anchor=stableAnchor?clone(stableAnchor):lastLocator?clone(lastLocator):null;clearTimeout(resizeTimer);resizeTimer=setTimeout(()=>{void setPreferences({},anchor).finally(()=>{resizing=false;refreshPosition()})},100)});
$('reset-appearance').onclick=()=>void setPreferences(DEFAULT_PREFERENCES);
$('search-form').onsubmit=event=>{event.preventDefault();void searchBook()};$('search-query').oninput=()=>{clearTimeout(searchTimer);searchTimer=setTimeout(()=>void searchBook(),180)};
for(const b of document.querySelectorAll('[data-highlight-color]'))b.onclick=()=>{
 if(!selection)return;
 try{annotate({...selection,color:b.dataset.highlightColor});dismissSelection();notice('Passage highlighted.')}catch(error){notice(error.message)}
};
$('remove-selection').onclick=()=>{if(selection?.id)removeAnnotation(selection.id)};
$('note-text').oninput=()=>{clearTimeout(noteSaveTimer);$('note-status').textContent='Saving…';noteSaveTimer=setTimeout(persistNote,180)};
for(const radio of document.querySelectorAll('input[name="note-color"]'))radio.onchange=persistNote;
$('note-selection').onclick=()=>editNote();$('dismiss-selection').onclick=dismissSelection;
$('save-note').onclick=saveNote;
$('keep-draft').onclick=()=>decideDraft('keep');$('discard-draft').onclick=()=>decideDraft('discard');$('save-draft').onclick=()=>decideDraft('save');
$('delete-note').onclick=()=>{if(!editingNote?.id)return;clearTimeout(noteSaveTimer);removeAnnotation(editingNote.id);editingNote=undefined;closeDialog($('note-panel'));dismissSelection();notice('Highlight and note removed.');};
media.addEventListener('change',()=>{if(state?.preferences.theme==='system')void setPreferences({})});
emit('available');

for(const id of ['background-color','text-color'])$(id).oninput=()=>void setPreferences({theme:'custom',backgroundColor:$('background-color').value,textColor:$('text-color').value});
for(const [id,key]of [['content-width','contentWidth'],['side-margin','sideMargin']])$(id).oninput=()=>void setPreferences({[key]:Number($(id).value)});
$('smaller-type').onclick=()=>void setPreferences({fontSize:Math.round((state.preferences.fontSize-.01)*100)/100});
$('larger-type').onclick=()=>void setPreferences({fontSize:Math.round((state.preferences.fontSize+.01)*100)/100});
$('immersive').onchange=()=>void setPreferences({immersive:$('immersive').checked});
$('focus-reading').onclick=()=>void setPreferences({immersive:true});
$('leave-focus').onclick=()=>void setPreferences({immersive:false});
