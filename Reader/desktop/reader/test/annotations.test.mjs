import {test} from 'node:test';
import assert from 'node:assert/strict';
import {createServer} from 'node:http';
import {readFile,mkdir} from 'node:fs/promises';
import path from 'node:path';
import {chromium} from 'playwright';
const root=path.resolve(import.meta.dirname,'../dist'),artifacts=path.resolve(import.meta.dirname,'../artifacts/annotations');
function fixture(){
 const paragraph='A repeated sentence worth keeping. The garden held the last of the rain and she returned to the book.';
 const chapters=Array.from({length:10},(_,i)=>`<html lang="en"><body><h1>Chapter ${i+1}</h1>${Array.from({length:18},(_,j)=>`<p id="p${j}">${i}.${j} ${paragraph}<em> A quiet thought.</em> The end.</p>`).join('')}</body></html>`);
 return {editionId:'annotations-fixture',title:'A garden of notes',experimentalContinuous:true,readingOrder:chapters.map((_,i)=>({href:`ch${i}.html`,type:'text/html'})),resources:chapters.map((text,i)=>({href:`ch${i}.html`,type:'text/html',dataBase64:Buffer.from(text).toString('base64')})),state:{schemaVersion:1,editionId:'annotations-fixture',revision:0,preferences:{scroll:true,theme:'paper',measure:48},bookmarks:[],annotations:[]}};
}
async function select(page,id='p1',href='ch0.html'){
 await page.evaluate(({id,href})=>{
  const frames=[...document.querySelectorAll('#reader iframe')];const frame=frames.find(f=>f.parentElement.dataset.href===href)??frames.find(f=>getComputedStyle(f).visibility!=='hidden');
  const node=frame.contentDocument.getElementById(id),range=frame.contentDocument.createRange();range.setStart(node.firstChild,4);range.setEnd(node.lastChild,5);
  const selection=frame.contentWindow.getSelection();selection.removeAllRanges();selection.addRange(range);frame.contentDocument.dispatchEvent(new frame.contentWindow.PointerEvent('pointerup',{bubbles:true}));frame.contentDocument.dispatchEvent(new frame.contentWindow.KeyboardEvent('keyup',{bubbles:true,key:'Shift'}));
 },{id,href});
 await page.locator('#selection-tools').waitFor({state:'visible'});
}
async function activate(page,id){
 await page.evaluate(id=>{
  const state=window.StillleafReader.exportState(),item=state.annotations.find(x=>x.id===id);const frame=[...document.querySelectorAll('#reader iframe')].find(f=>f.parentElement.dataset.href===item.locator.href);
  frame.contentWindow.getSelection().removeAllRanges();const range=[...frame.contentWindow.CSS.highlights.values()].flatMap(x=>[...x]).find(r=>r.toString()===item.quote),rect=range.getClientRects()[0];
  frame.contentDocument.dispatchEvent(new frame.contentWindow.MouseEvent('click',{bubbles:true,clientX:rect.left+1,clientY:rect.top+1}));
 },id);await page.locator('#selection-tools').waitFor({state:'visible'});
}
test('anchored annotation interaction, autosave, margins, reflow and restart',{timeout:90000},async t=>{
 const server=createServer(async(req,res)=>{try{const file=path.resolve(root,'.'+new URL(req.url,'http://localhost').pathname);if(!file.startsWith(root+path.sep))throw Error();res.setHeader('Content-Type',{'.html':'text/html','.js':'text/javascript','.css':'text/css'}[path.extname(file)]??'application/octet-stream');res.end(await readFile(file))}catch{res.writeHead(404).end()}});
 await new Promise(done=>server.listen(0,'127.0.0.1',done));t.after(()=>new Promise(done=>server.close(done)));
 const browser=await chromium.launch({...(process.env.CHROME_PATH?{executablePath:process.env.CHROME_PATH}:{}),headless:true});t.after(()=>browser.close());
 const page=await browser.newPage({viewport:{width:1420,height:900},reducedMotion:'reduce'}),errors=[];page.on('pageerror',e=>errors.push(e.message));
 const url=`http://127.0.0.1:${server.address().port}/index.html`;await page.goto(url);await page.waitForFunction(()=>window.StillleafReader);const book=fixture();await page.evaluate(book=>window.StillleafReader.open(book),book);
 await select(page);
 const geometry=await page.evaluate(()=>{const popup=document.getElementById('selection-tools').getBoundingClientRect(),frame=document.querySelector('#reader iframe'),r=frame.contentWindow.getSelection().getRangeAt(0).getClientRects()[0],f=frame.getBoundingClientRect();return {top:popup.top,bottom:popup.bottom,passageTop:f.top+r.top,passageBottom:f.top+r.bottom,left:popup.left,right:popup.right}});
 assert.ok(geometry.top>=0&&geometry.right<=1420);assert.ok(Math.abs(geometry.bottom-geometry.passageTop)<100||Math.abs(geometry.top-geometry.passageBottom)<100,'popup is beside the selection');
 await mkdir(artifacts,{recursive:true});await page.screenshot({path:path.join(artifacts,'selection-paper.png')});assert.equal(await page.locator('#selection-tools').evaluate(el=>getComputedStyle(el).animationName),'none');
 await page.getByRole('button',{name:'Sage highlight',exact:true}).click();let saved=await page.evaluate(()=>window.StillleafReader.exportState());assert.equal(saved.annotations.length,1);assert.equal(saved.annotations[0].color,'sage');assert.ok(saved.annotations[0].locator.locations.domRange);assert.ok(saved.annotations[0].locator.text.before);const original=saved.annotations[0];
 await activate(page,original.id);await page.getByRole('button',{name:'Rose highlight',exact:true}).click();saved=await page.evaluate(()=>window.StillleafReader.exportState());assert.equal(saved.annotations[0].id,original.id);assert.deepEqual(saved.annotations[0].locator,original.locator);assert.equal(saved.annotations[0].createdAt,original.createdAt);
 await activate(page,original.id);await page.getByRole('button',{name:'Add note',exact:true}).click();const note='A note with <img src=x onerror="window.injection=true"> & a thought.';await page.getByRole('textbox',{name:'Your note'}).fill(note);
 await page.waitForFunction(note=>window.StillleafReader.exportState().annotations[0].note===note,note);assert.equal(await page.locator('#note-status').textContent(),'Saved automatically');
 const rangesBefore=await page.evaluate(()=>{window.savedRanges=[...document.querySelector('#reader iframe').contentWindow.CSS.highlights.values()].flatMap(x=>[...x]);return window.savedRanges.length});
 await page.getByRole('textbox',{name:'Your note'}).fill(note+' More.');await page.waitForTimeout(300);
 assert.equal(await page.evaluate(()=>{const ranges=[...document.querySelector('#reader iframe').contentWindow.CSS.highlights.values()].flatMap(x=>[...x]);return ranges.length===window.savedRanges.length&&ranges.every((range,i)=>range===window.savedRanges[i])}),true,'note autosave retains every highlight range');assert.ok(rangesBefore>0);
 // Revert before the debounce settles: the already-saved value is still saved.
 await page.getByRole('textbox',{name:'Your note'}).fill(note);await page.waitForTimeout(300);
 await page.getByRole('textbox',{name:'Your note'}).fill(note+' unsaved');await page.getByRole('textbox',{name:'Your note'}).fill(note);await page.waitForTimeout(300);
 assert.equal(await page.locator('#note-status').textContent(),'Saved automatically');
 await page.getByRole('button',{name:'Close note',exact:true}).click();assert.equal(await page.locator('#draft-panel').isVisible(),false);
 await page.locator('.margin-note').waitFor({state:'visible'});assert.equal(await page.locator('.margin-note').textContent(),note);assert.equal(await page.locator('.margin-note img').count(),0);
 const margin=await page.locator('.margin-note').boundingBox(),viewport=await page.locator('#reader').boundingBox();assert.ok(margin.x+margin.width<=viewport.x||margin.x>=viewport.x+viewport.width,'margin does not obscure publication text');await page.screenshot({path:path.join(artifacts,'margin-paper.png')});
 await select(page,'p2');await page.getByRole('button',{name:'Add note',exact:true}).click();await page.getByRole('textbox',{name:'Your note'}).fill('Another thought beside the next passage.');await page.locator('#delete-note').waitFor({state:'visible'});await page.getByRole('button',{name:'Close note',exact:true}).click();await page.waitForFunction(()=>document.querySelectorAll('.margin-note:not([hidden])').length===2);
 const cards=await page.locator('.margin-note').all();const boxes=await Promise.all(cards.map(card=>card.boundingBox()));assert.ok(boxes[0].x+boxes[0].width<=viewport.x);assert.ok(boxes[1].x>=viewport.x+viewport.width);await page.screenshot({path:path.join(artifacts,'both-margins-paper.png')});await cards[1].click();await page.getByRole('button',{name:'Remove highlight & note',exact:true}).click();

 await page.evaluate(()=>window.StillleafReader.setPreferences({theme:'dark',fontSize:1.35}));await page.locator('.margin-note').waitFor({state:'visible'});await page.screenshot({path:path.join(artifacts,'margin-dark.png')});
 await page.setViewportSize({width:430,height:760});await page.waitForTimeout(250);await page.evaluate(()=>window.StillleafReader.setPreferences({}));await page.locator('.compact-notes').waitFor({state:'visible'});assert.equal(await page.locator('.margin-note').isVisible(),false);const compact=await page.locator('.compact-notes').boundingBox(),narrow=await page.locator('#reader').boundingBox();assert.ok(compact.y+compact.height<=narrow.y,'compact fallback stays above text');await page.screenshot({path:path.join(artifacts,'narrow-dark.png')});
 await page.locator('.compact-notes').click();await page.screenshot({path:path.join(artifacts,'saved-notes-narrow-dark.png')});await page.getByRole('button',{name:'Edit note',exact:true}).click();assert.equal(await page.getByRole('textbox',{name:'Your note'}).inputValue(),note);await page.getByRole('textbox',{name:'Your note'}).fill('Edited automatically');await page.keyboard.press('Escape');assert.equal(await page.locator('#note-panel').isVisible(),false);saved=await page.evaluate(()=>window.StillleafReader.exportState());assert.equal(saved.annotations[0].note,'Edited automatically');
 await page.setViewportSize({width:1420,height:900});await page.waitForTimeout(250);await page.evaluate(()=>window.StillleafReader.setPreferences({}));await page.evaluate(()=>window.StillleafReader.go({href:'ch8.html',type:'text/html',locations:{progression:0}}));await page.getByRole('button',{name:'Highlights and notes',exact:true}).click();await page.locator('.saved-link').click();await page.waitForFunction(()=>window.StillleafReader.bookmark()?.href==='ch0.html');
 await page.locator('.margin-note').waitFor({state:'visible'});await select(page);await page.evaluate(()=>{const frame=document.querySelector('#reader iframe');frame.contentDocument.dispatchEvent(new frame.contentWindow.KeyboardEvent('keydown',{key:'Tab',bubbles:true,cancelable:true}))});assert.equal(await page.evaluate(()=>document.activeElement?.id),'highlight-selection');await page.keyboard.press('ArrowRight');assert.equal(await page.evaluate(()=>document.activeElement?.dataset.highlightColor),'sage');await page.keyboard.press('Escape');assert.equal(await page.locator('#selection-tools').isVisible(),false);
 await page.emulateMedia({reducedMotion:'no-preference'});await select(page);assert.equal(await page.locator('#selection-tools').evaluate(el=>getComputedStyle(el).animationDuration),'0.12s');await page.screenshot({path:path.join(artifacts,'selection-dark.png')});await page.locator('#book-title').click();assert.equal(await page.locator('#selection-tools').isVisible(),false);
 // Both paginator and continuous navigator consume the same text locator after reflow.
 await page.evaluate(()=>window.StillleafReader.setPreferences({scroll:false,columns:'two'}));await page.getByRole('button',{name:'Highlights and notes',exact:true}).click();await page.locator('.saved-link').click();saved=await page.evaluate(()=>window.StillleafReader.exportState());assert.deepEqual(saved.annotations[0].locator,original.locator);assert.equal(saved.annotations[0].note,'Edited automatically');await page.screenshot({path:path.join(artifacts,'facing-dark.png')});
 await page.reload();await page.waitForFunction(()=>window.StillleafReader);await page.evaluate(({book,state})=>window.StillleafReader.open({...book,state}),{book,state:saved});assert.deepEqual((await page.evaluate(()=>window.StillleafReader.exportState())).annotations,saved.annotations);
 await page.evaluate(()=>window.StillleafReader.setPreferences({scroll:true}));await page.getByRole('button',{name:'Highlights and notes',exact:true}).click();await page.getByRole('button',{name:'Edit note',exact:true}).click();await page.getByRole('button',{name:'Remove highlight & note',exact:true}).click();assert.equal((await page.evaluate(()=>window.StillleafReader.exportState())).annotations.length,0);assert.deepEqual(errors,[]);
});
