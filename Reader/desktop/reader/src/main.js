import {EpubNavigator,EpubPreferences,DecorationStyleType} from '@readium/navigator';
import {Manifest,Publication,Locator} from '@readium/shared';
import {PublicationResources,PublicationFetcher} from './resources';
import {ContinuousNavigator} from './continuous';
import {DEFAULT_PREFERENCES,preferences,restoreState,selectorFor,rangePoint} from './state';
import {THEMES,FONTS,MARGINS,resolveTheme,fontStack,fontAvailable,marginMetrics,averageCharacterWidth} from './appearance';

const $=id=>document.getElementById(id);
const clone=value=>JSON.parse(JSON.stringify(value));
const media=matchMedia('(prefers-color-scheme: dark)');
const widePage=matchMedia('(min-width:1100px)');
const effectiveColumns=()=>state?.preferences.columns==='two'&&widePage.matches&&!state.preferences.scroll?2:1;
const colors={gold:'#e4c778',sage:'#a7cbb0',rose:'#d7a9b4'};
let navigator,pool,input,state,lastLocator,selection,editingNote,activeTab='contents',searchGeneration=0,searchTimer,stateTimer,noticeTimer,lastFocus,opening=false;
let lifecycle=0;let preferenceQueue=Promise.resolve();let jumpHistory=[];let stableAnchor=null,reflowCount=0,resizeTimer,resizing=false;
const frames=new WeakSet();let headingCache=new Map();
const icons={contents:'<path d="M4 5h16M4 12h16M4 19h11"/>',search:'<circle cx="10" cy="10" r="6.5"/><path d="m15 15 5 5"/>',bookmark:'<path d="M6 3h12v18l-6-4-6 4z"/>',previous:'<path d="m14 5-7 7 7 7"/>',next:'<path d="m10 5 7 7-7 7"/>'};
for(const [id,key]of [['contents','contents'],['search','search'],['save-bookmark','bookmark'],['previous','previous'],['next','next']])$(id).innerHTML='<svg viewBox="0 0 24 24" aria-hidden="true">'+icons[key]+'</svg>';
function emit(type,data={}){window.dispatchEvent(new CustomEvent('stillleaf-reader-event',{detail:{version:1,type,editionId:input?.editionId,...data}}))}
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
async function returnFromJump(){
 const target=jumpHistory.at(-1);if(!target)return false;
 if(await go(target,false)){jumpHistory.pop();updateHistory();return true}return false;
}
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
 const index=input.readingOrder.findIndex(x=>x.href===lastLocator.href);
 $('chapter-label').textContent=headingFor(lastLocator.href);$('position-label').textContent=`Section ${index+1} of ${input.readingOrder.length}`;
 const saved=state.bookmarks.some(x=>samePlace(x.locator,lastLocator));
 $('save-bookmark').setAttribute('aria-pressed',String(saved));$('save-bookmark').setAttribute('aria-label',saved?'Remove bookmark':'Add bookmark');$('save-bookmark').title=saved?'Remove bookmark':'Add bookmark';
}
function samePlace(a,b){return a.href===b.href&&Math.abs((a.locations?.progression??0)-(b.locations?.progression??0))<.002}
function currentTheme(){return resolveTheme(state?.preferences.theme??'system',media.matches)}
function theme(){return currentTheme().id}
const compactWindow=()=>innerWidth<640;
function readiumPreferences(){
 const p=state.preferences,t=currentTheme(),{gutter}=marginMetrics(p.margins,compactWindow());
 return {fontSize:p.fontSize,fontFamily:fontStack(p.fontFamily),fontWeight:p.fontWeight,textAlign:p.textAlign==='publisher'?null:p.textAlign,hyphens:p.hyphens,letterSpacing:p.letterSpacing,wordSpacing:p.wordSpacing,scroll:p.scroll,scrollPaddingTop:0,scrollPaddingBottom:0,scrollPaddingLeft:gutter,scrollPaddingRight:gutter,lineHeight:p.lineHeight,optimalLineLength:p.measure,maximalLineLength:Math.min(75,p.measure+5),minimalLineLength:effectiveColumns()===2?Math.min(20,p.measure):Math.min(p.measure,Math.max(20,p.measure-15)),pageGutter:gutter,columnCount:effectiveColumns(),backgroundColor:t.background,textColor:t.text,linkColor:t.link,selectionBackgroundColor:t.selection,darkenFilter:t.dimImages===true};
}
/** Page width for the chosen measure: the chosen typeface's measured advance, or an
 *  average serif estimate when the publisher's own font is in use. */
function readingWidth(){
 const p=state.preferences,{gutter}=marginMetrics(p.margins,compactWindow()),size=16*p.fontSize,stack=fontStack(p.fontFamily);
 const perCharacter=(stack&&averageCharacterWidth(stack,size))||size*.48;
 return (p.measure*perCharacter+2*gutter)*effectiveColumns();
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
 if(!margins.childElementCount)for(const [id,m]of Object.entries(MARGINS)){const b=document.createElement('button');b.dataset.margins=id;b.setAttribute('role','radio');b.textContent=m.label;b.onclick=()=>void setPreferences({margins:id});margins.append(b)}
 for(const b of margins.children){const on=b.dataset.margins===(state?.preferences.margins??'normal');b.setAttribute('aria-checked',String(on));b.tabIndex=on?0:-1}
}
function syncAppearance(){
 if(!state)return;
 const t=currentTheme();document.documentElement.dataset.theme=t.id;applyChromeTheme(t);
 // Bound the parent Readium measures, rather than clipping its computed frame.
 document.documentElement.style.setProperty('--reading-width',readingWidth()+'px');
 document.documentElement.style.setProperty('--page-inset',marginMetrics(state.preferences.margins,compactWindow()).inset+'px');
 renderAppearanceControls();
 for(const button of document.querySelectorAll('[data-theme]'))button.setAttribute('aria-pressed',String(button.dataset.theme===state.preferences.theme));
 $('reading-mode').value=state.preferences.scroll?'continuous':state.preferences.columns==='two'?'facing':'single';$('font-weight').querySelector('[data-custom]')?.remove();if(state.preferences.fontWeight!==null&&![400,700].includes(state.preferences.fontWeight)){const option=document.createElement('option');option.dataset.custom='true';option.value=String(state.preferences.fontWeight);option.textContent='Custom ('+state.preferences.fontWeight+')';$('font-weight').append(option)}$('font-weight').value=state.preferences.fontWeight==null?'publisher':String(state.preferences.fontWeight);$('text-align').value=state.preferences.textAlign;$('hyphens').value=state.preferences.hyphens==null?'publisher':String(state.preferences.hyphens);
 $('previous').title=state.preferences.scroll?'Previous section':'Previous page';$('next').title=state.preferences.scroll?'Next section':'Next page';
 $('columns-note').textContent=state.preferences.scroll?'Columns apply when reading in pages.':state.preferences.columns==='two'&&!widePage.matches?'Two columns return when the window is wider.':'Two columns use one column in narrow windows.';
 for(const [id,key]of [['letter-spacing','letterSpacing'],['word-spacing','wordSpacing']]){$(id).value=state.preferences[key];$(id+'-value').textContent=Math.round(state.preferences[key]*100)+'%';}
 for(const [id,key]of [['font-size','fontSize'],['line-height','lineHeight'],['measure','measure']])$(id).value=state.preferences[key];
 $('font-size-value').textContent=Math.round(state.preferences.fontSize*100)+'%';$('line-height-value').textContent=state.preferences.lineHeight.toFixed(2).replace(/0$/,'');$('measure-value').textContent='About '+Math.round(state.preferences.measure)+' characters';
}
function visibleAnchor(){
 if(navigator?.kind==='continuous')return navigator.captureLocator();
 if(!lastLocator)return null;
 const frame=[...document.querySelectorAll('#reader iframe')].find(f=>getComputedStyle(f).visibility!=='hidden');
 if(!frame?.contentDocument)return clone(lastLocator);
 const doc=frame.contentDocument,wnd=frame.contentWindow,walk=doc.createTreeWalker(doc.body,NodeFilter.SHOW_TEXT);let node,checked=0;
 while((node=walk.nextNode())&&checked<30000){
  if(!node.textContent.trim()||['STYLE','SCRIPT'].includes(node.parentElement?.tagName))continue;
  const range=doc.createRange();range.selectNodeContents(node);if(![...range.getClientRects()].some(r=>r.right>0&&r.left<wnd.innerWidth&&r.bottom>0&&r.top<wnd.innerHeight))continue;
  for(let i=0;i<node.length&&checked++<30000;i++){range.setStart(node,i);range.setEnd(node,i+1);const r=range.getBoundingClientRect();if(r.left>=0&&r.left<wnd.innerWidth&&r.top>=0&&r.bottom<=wnd.innerHeight&&node.textContent.slice(i).trim())return {...clone(lastLocator),locations:{...lastLocator.locations,cssSelector:selectorFor(node.parentElement)},text:{highlight:node.textContent.slice(i,i+80)}};}
 }
 return clone(lastLocator);
}
async function setPreferences(value,retained){
 if(!state)return;
 const location=retained??(navigator?.kind==='continuous'?visibleAnchor():stableAnchor??visibleAnchor());if(location)stableAnchor=clone(location);reflowCount++;
 const restore=Object.keys(value).some(key=>!['theme'].includes(key))||Object.keys(value).length===0;
 state.preferences=preferences({...state.preferences,...value});syncAppearance();changed();relayout();
 const settings=readiumPreferences(),generation=lifecycle;
 preferenceQueue=preferenceQueue.catch(()=>{}).then(async()=>{if(generation!==lifecycle||!navigator)return;const current=navigator,continuous=Boolean(input.experimentalContinuous&&settings.scroll);if((current.kind==='continuous')!==continuous){await current.destroy();if(generation===lifecycle)await installNavigator(location,settings)}else{await current.submitPreferences(new EpubPreferences(settings));if(restore&&location&&current===navigator&&generation===lifecycle){await new Promise(resolve=>setTimeout(resolve,120));if(generation===lifecycle)await go(location,false)}}});
 try{await preferenceQueue}finally{reflowCount=Math.max(0,reflowCount-1)}
}
function dismissSelection(){selection=null;$('selection-tools').hidden=true;for(const f of document.querySelectorAll('#reader iframe'))f.contentWindow?.getSelection()?.removeAllRanges()}
function selected(value){
 if(!value.text?.trim()||!value.locator){$('selection-tools').hidden=true;return}
 const locator=validLocator(value.locator.serialize?.()??value.locator);if(!locator)return;
 for(const frame of document.querySelectorAll('#reader iframe')){
  const sel=frame.contentWindow?.getSelection();
  if(sel?.rangeCount&&sel.toString()===value.text){
   const range=sel.getRangeAt(0);locator.locations={...locator.locations,domRange:{start:rangePoint(range.startContainer,range.startOffset),end:rangePoint(range.endContainer,range.endOffset)}};break;
  }
 }
 selection={locator,quote:value.text.slice(0,5000)};$('selection-tools').hidden=false;
 emit('selection',{selection:{text:selection.quote,locator}});
}
function applyAnnotations(){
 if(navigator?.decorationsAvailable===false)return;
 navigator?.applyDecorations(state.annotations.filter(item=>input.readingOrder.some(link=>link.href===item.locator.href)).map(item=>({id:item.id,locator:Locator.deserialize(item.locator),style:{type:DecorationStyleType.Highlight,tint:colors[item.color]??colors.gold,isActive:true}})),'personal');
}
function annotate(value){
 const locator=validLocator(value.locator);if(!locator||!String(value.quote??'').trim())throw Error('Select a passage to annotate.');
 const prior=state.annotations.find(x=>x.id===value.id);if(!prior&&state.annotations.length>=1000)throw Error('This book has reached the annotation limit.');
 const now=new Date().toISOString();const item={id:prior?.id??crypto.randomUUID(),locator,quote:String(value.quote).slice(0,32768),note:String(value.note??'').slice(0,65536),color:colors[value.color]?value.color:'gold',createdAt:prior?.createdAt??now,updatedAt:now};
 const annotations=prior?state.annotations.map(existing=>existing===prior?item:existing):[...state.annotations,item];
 requireSaveBudget({...state,annotations});state.annotations=annotations;
 applyAnnotations();changed();return clone(item);
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
 for(const dialog of document.querySelectorAll('dialog[open]'))dialog.close();
 lastFocus=document.activeElement;$(id).showModal();if(focus)$(focus).focus();
}
let draftDecision;
function hasPendingDraft(){return Boolean(editingNote&&$('note-panel').open&&($('note-text').value!==(editingNote.note??'')||document.querySelector('input[name="note-color"]:checked').value!==(colors[editingNote.color]?editingNote.color:'gold')))}
function saveNote(){
 if(!editingNote)return true;
 try{
  annotate({...editingNote,note:$('note-text').value,color:document.querySelector('input[name="note-color"]:checked').value});
  editingNote=undefined;$('note-error').hidden=true;$('note-panel').close();dismissSelection();notice('Note updated in this reader.');return true;
 }catch(error){
  $('note-error').textContent=(error.message||'The note could not be applied.')+' Your draft is still here. You can keep editing or discard it.';$('note-error').hidden=false;$('note-error').focus();return false;
 }
}
function prepareClose(){
 if(draftDecision)return draftDecision.promise;
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
 activeTab=tab;const body=$('panel-body');body.replaceChildren();body.setAttribute('aria-labelledby','tab-'+tab);
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
  for(const item of state.annotations){const article=document.createElement('article');article.className='saved-item';const jump=button('“'+item.quote+'”','saved-link',()=>{closeDialog($('library-panel'));void go(item.locator)});article.append(jump);if(item.note){const note=document.createElement('p');note.className='note-excerpt';note.textContent=item.note;article.append(note)}article.append(button(item.note?'Edit note':'Add a note','edit-note',()=>editNote(item)));body.append(article)}
 }
}
function editNote(item=selection){
 if(!item)return;$('note-error').hidden=true;editingNote=clone(item);$('note-title').textContent=item.id?'Your note':'A note in the margin';$('note-quote').textContent=item.quote;$('note-text').value=item.note??'';$('delete-note').hidden=!item.id;
 document.querySelector(`input[name="note-color"][value="${colors[item.color]?item.color:'gold'}"]`).checked=true;
 showDialog('note-panel','note-text');
}
async function go(value,recordHistory=true){
 const locator=validLocator(value);if(!navigator||!locator)return false;quietUntil=performance.now()+800;
 if(!input.readingOrder.some(link=>link.href===locator.href)){notice('This saved passage is outside the supported reading sequence.');return false;}
 const before=lastLocator?clone(lastLocator):null;dismissSelection();
 return new Promise(resolve=>{const timeout=setTimeout(()=>resolve(false),4000);try{navigator.go(engineLocator(locator),false,ok=>{clearTimeout(timeout);if(ok){stableAnchor=clone(locator)}if(ok&&recordHistory&&before){jumpHistory.push(before);if(jumpHistory.length>100)jumpHistory.shift();updateHistory();}resolve(ok)})}catch(error){clearTimeout(timeout);notice('This passage could not be opened.');resolve(false)}});
}
// Page evidence for reading goals. Only deliberate sequential movement is reported:
// page turns in paginated modes and full screens scrolled by the reader. Jumps
// (contents, search, links, bookmarks), restores, reflow and resizes never are. Each
// layout gets its own key, so the host starts a fresh baseline after any change.
let layoutGeneration=0,announcedLayout=null,quietUntil=0,scrollState=new WeakMap();
const pagesPerTurn=()=>state?.preferences.scroll?1:effectiveColumns();
const layoutKey=()=>(state?.preferences.scroll?'s':'p')+pagesPerTurn()+'-'+layoutGeneration;
function announceLayout(){if(!state||opening||navigator?.kind==='continuous')return;const layout=layoutKey();if(layout===announcedLayout)return;announcedLayout=layout;emit('pageLayout',{layout,pages:pagesPerTurn()})}
function relayout(){layoutGeneration++;quietUntil=performance.now()+800;scrollState=new WeakMap();announceLayout()}
function pageTurned(direction){if(!state||navigator?.kind==='continuous')return;announceLayout();emit('pageTurn',{direction,pages:pagesPerTurn(),layout:layoutKey()})}
/** Scroll mode: one page-equivalent per full screen of net movement by the reader. */
function trackScroll(wnd){
 if(!state?.preferences.scroll||navigator?.kind==='continuous')return;
 const y=wnd.scrollY,height=wnd.innerHeight,now=performance.now(),last=scrollState.get(wnd);
 if(!last||now<quietUntil||boundaryBusy||reflowCount||resizing||!(height>0)){scrollState.set(wnd,{y,net:0});return}
 const delta=y-last.y;
 // Scrubbing or programmatic jumps move several screens at once; they are never reading.
 if(Math.abs(delta)>height*1.5){scrollState.set(wnd,{y,net:0});return}
 let net=last.net+delta;
 while(net>=height){net-=height;pageTurned('forward')}
 while(net<=-height){net+=height;pageTurned('backward')}
 scrollState.set(wnd,{y,net});
}
// One turn at a time: overlapping goForward/goBackward calls across a chapter edge left every frame hidden.
let turning=false,turnWatchdog=0;
function turn(direction){dismissSelection();if(!navigator||turning)return;turning=true;clearTimeout(turnWatchdog);turnWatchdog=setTimeout(()=>turning=false,2000);(direction==='next'?navigator.goForward.bind(navigator):navigator.goBackward.bind(navigator))(false,moved=>{turning=false;clearTimeout(turnWatchdog);if(moved===true&&!state?.preferences.scroll)pageTurned(direction==='next'?'forward':'backward');stableAnchor=visibleAnchor();if(!state?.preferences.scroll&&!matchMedia('(prefers-reduced-motion: reduce)').matches)$('reader').animate([{opacity:.84,transform:`perspective(1600px) rotateY(${direction==='next'?'-':'+'}1.5deg)`},{opacity:1,transform:'none'}],{duration:140,easing:'ease-out'})})}
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
 if(event.defaultPrevented||event.altKey||event.metaKey||event.ctrlKey)return;
 const tag=event.target?.tagName;if(['INPUT','TEXTAREA','SELECT'].includes(tag)||event.target?.isContentEditable)return;
 if(event.key==='Escape'){$('selection-tools').hidden=true;return}
 if(document.querySelector('dialog[open]'))return;
 if(event.key==='ArrowRight'||event.key==='ArrowLeft'){
  const rtl=input?.readingProgression==='rtl'||navigator?.readingProgression==='rtl';
  event.preventDefault();turn((event.key==='ArrowRight')!==rtl?'next':'previous');
 }
}
window.addEventListener('keydown',keyboard);
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
async function installNavigator(location,settings=readiumPreferences()){
  const generation=lifecycle;
  const manifest=Manifest.deserialize({metadata:{title:input.title??'Untitled',language:input.languages??input.language??'en',readingProgression:input.readingProgression,conformsTo:['https://readium.org/webpub-manifest/profiles/epub']},readingOrder:input.readingOrder.map(x=>({...x,type:'text/html'}))});
  const publication=new Publication({manifest,fetcher:new PublicationFetcher(pool)});
  const positions=input.readingOrder.map((link,i)=>Locator.deserialize({...link,type:'text/html',locations:{position:i+1,progression:0,totalProgression:i/input.readingOrder.length}}));
  const listeners={
   positionChanged:locator=>{if(generation!==lifecycle||!state)return;lastLocator=locator.serialize();if(opening&&state.position){updatePosition();return;}state.position=clone(lastLocator);updatePosition();changed(false);emit('relocated',{locator:lastLocator,cause:'unknown',eligibleForProgress:false})},
   frameUnloaded:wnd=>frames.delete(wnd),
   textSelected:value=>{if(generation===lifecycle)selected(value)},
   frameLoaded:wnd=>{if(!wnd.CSS?.highlights&&navigator)navigator.decorationsAvailable=false;if(!frames.has(wnd)){frames.add(wnd);wnd.document.addEventListener('keydown',keyboard);wnd.addEventListener('wheel',event=>{void crossScrollBoundary(wnd,event.deltaY,event);if(!boundaryBusy)setTimeout(()=>{if(!reflowCount&&!resizing)stableAnchor=visibleAnchor()},100)},{passive:false});wnd.document.addEventListener('keydown',event=>{if(['ArrowDown','PageDown','ArrowUp','PageUp'].includes(event.key)&&!['INPUT','TEXTAREA','SELECT'].includes(event.target?.tagName)){void crossScrollBoundary(wnd,['ArrowDown','PageDown'].includes(event.key)?1:-1,event);setTimeout(()=>{if(!boundaryBusy&&!reflowCount&&!resizing)stableAnchor=visibleAnchor()},100)}});wnd.document.addEventListener('pointerup',followPublicationLink,true);wnd.addEventListener('scroll',()=>trackScroll(wnd),{passive:true});wnd.document.addEventListener('click',followPublicationLink,true);wnd.document.addEventListener('keyup',()=>{const text=wnd.getSelection()?.toString();if(text&&lastLocator&&navigator?.kind!=='continuous')selected({text,locator:Locator.deserialize({...lastLocator,text:{highlight:text}})});});}},
   error:error=>{notice(error.message);emit('error',{message:error.message})}
  };
  navigator=input.experimentalContinuous&&settings.scroll?new ContinuousNavigator($('reader'),input,pool,listeners,location,settings):new EpubNavigator($('reader'),publication,listeners,positions,location?engineLocator(location):undefined,{preferences:settings,defaults:{}});
  navigator.registerDecorationObserver('personal',{onDecorationActivated:event=>{const item=state.annotations.find(x=>x.id===event.decoration.id);if(item)editNote(item);return true}});
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
  syncAppearance();
  await installNavigator(state.position);opening=false;emit('ready',{warnings:[...pool.warnings]});announcedLayout=null;relayout();changed();
  if(pool.warnings.size&&$('notice').hidden)notice('Some original styling or illustrations could not be displayed.');
 }catch(error){opening=false;$('error').textContent=error.message;$('error').hidden=false;emit('error',{message:error.message});throw error}
}
async function close(){
 if(!await prepareClose())return false;
 lifecycle++;searchGeneration++;clearTimeout(resizeTimer);clearTimeout(searchTimer);clearTimeout(stateTimer);clearTimeout(noticeTimer);
 if(state)emit('state',{state:snapshot()});
 for(const dialog of document.querySelectorAll('dialog[open]'))dialog.close();
 await navigator?.destroy();navigator=undefined;pool?.close();pool=undefined;state=undefined;lastLocator=undefined;selection=undefined;$('selection-tools').hidden=true;$('notice').hidden=true;editingNote=undefined;return true;
}
const api={open,close,prepareClose,hasPendingDraft,returnFromJump,next:()=>turn('next'),previous:()=>turn('previous'),go,setPreferences,bookmark:()=>lastLocator?clone(lastLocator):null,restore:go,exportState:snapshot,addBookmark,annotate};
window.StillleafReader=Object.freeze(api);
$('return-jump').onclick=()=>void returnFromJump();
$('back').onclick=async()=>{if(await prepareClose())emit('close-request')};$('next').onclick=api.next;$('previous').onclick=api.previous;$('save-bookmark').onclick=addBookmark;
$('contents').onclick=()=>{if(!state)return;renderPanel();showDialog('library-panel','tab-'+activeTab)};
$('appearance').onclick=()=>{if(state){syncAppearance();showDialog('appearance-panel')}};
$('search').onclick=()=>{if(state)showDialog('search-panel','search-query')};
for(const tab of ['contents','bookmarks','notes'])$('tab-'+tab).onclick=()=>renderPanel(tab);
document.querySelector('.panel-tabs').addEventListener('keydown',event=>{if(['ArrowRight','ArrowLeft'].includes(event.key)){event.preventDefault();const tabs=['contents','bookmarks','notes'];const next=tabs[(tabs.indexOf(activeTab)+(event.key==='ArrowRight'?1:2))%3];renderPanel(next);$('tab-'+next).focus()}});
// Radio groups: arrow keys move the choice, as in native segmented controls.
for(const group of [$('font-options'),$('margins')])group.addEventListener('keydown',event=>{
 const step={ArrowRight:1,ArrowDown:1,ArrowLeft:-1,ArrowUp:-1}[event.key];if(!step)return;event.preventDefault();
 const items=[...group.querySelectorAll('[role=radio]')],next=items[(items.indexOf(document.activeElement)+step+items.length)%items.length];next?.focus();next?.click();
});
document.fonts?.ready.then(()=>{if(state)renderAppearanceControls()});
for(const [id,key]of [['font-size','fontSize'],['line-height','lineHeight'],['measure','measure']])$(id).oninput=()=>void setPreferences({[key]:Number($(id).value)});
$('reading-mode').onchange=()=>{const mode=$('reading-mode').value;void setPreferences({scroll:mode==='continuous',...(mode!=='continuous'?{columns:mode==='facing'?'two':'one'}:{})})};
$('font-weight').onchange=()=>void setPreferences({fontWeight:$('font-weight').value==='publisher'?null:Number($('font-weight').value)});
$('text-align').onchange=()=>void setPreferences({textAlign:$('text-align').value});
$('hyphens').onchange=()=>void setPreferences({hyphens:$('hyphens').value==='publisher'?null:$('hyphens').value==='true'});
for(const [id,key]of [['letter-spacing','letterSpacing'],['word-spacing','wordSpacing']])$(id).oninput=()=>void setPreferences({[key]:Number($(id).value)});
window.addEventListener('resize',()=>{if(!state)return;resizing=true;relayout();const anchor=stableAnchor?clone(stableAnchor):lastLocator?clone(lastLocator):null;clearTimeout(resizeTimer);resizeTimer=setTimeout(()=>{void setPreferences({},anchor).finally(()=>{resizing=false})},100)});
$('reset-appearance').onclick=()=>void setPreferences(DEFAULT_PREFERENCES);
$('search-form').onsubmit=event=>{event.preventDefault();void searchBook()};$('search-query').oninput=()=>{clearTimeout(searchTimer);searchTimer=setTimeout(()=>void searchBook(),180)};
$('highlight-selection').onclick=()=>{if(selection){annotate({...selection,color:'gold'});dismissSelection();notice('Passage highlighted.')}};
$('note-selection').onclick=()=>editNote();$('dismiss-selection').onclick=dismissSelection;
$('save-note').onclick=saveNote;
$('keep-draft').onclick=()=>decideDraft('keep');$('discard-draft').onclick=()=>decideDraft('discard');$('save-draft').onclick=()=>decideDraft('save');
$('delete-note').onclick=()=>{if(!editingNote?.id)return;state.annotations=state.annotations.filter(x=>x.id!==editingNote.id);applyAnnotations();changed();editingNote=undefined;closeDialog($('note-panel'));dismissSelection();notice('Highlight and note removed.');};
media.addEventListener('change',()=>{if(state?.preferences.theme==='system')void setPreferences({})});
emit('available');
