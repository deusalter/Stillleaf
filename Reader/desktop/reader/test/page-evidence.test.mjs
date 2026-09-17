import {test} from 'node:test';
import assert from 'node:assert/strict';
import {createServer} from 'node:http';
import {readFile} from 'node:fs/promises';
import path from 'node:path';
import {chromium} from 'playwright';

// Page evidence for reading goals: deliberate turns and full screens scrolled count;
// jumps, restores, reflow and resizes never do, and every layout change is announced.
const root=path.resolve(import.meta.dirname,'../dist');
const prose='The ferry crossed slowly while the gulls kept pace with the wake, and the reader turned another page of the long book on her knees.';
const chapter=n=>`<!doctype html><html lang="en"><head><title>Crossing ${n}</title></head><body><h1>Crossing ${n}</h1>${Array.from({length:60},(_,i)=>`<p id="c${n}p${i}">${prose}</p>`).join('')}</body></html>`;
const book={editionId:'page-evidence',title:'Crossings',creators:['A. Ferry'],language:'en',
 readingOrder:[1,2,3].map(n=>({href:`c${n}.html`,type:'text/html',title:`Crossing ${n}`})),
 resources:[1,2,3].map(n=>({href:`c${n}.html`,type:'text/html',dataBase64:Buffer.from(chapter(n)).toString('base64')}))};

test('only deliberate page movement is reported as page evidence',{timeout:120000},async t=>{
 const server=createServer(async(req,res)=>{try{const file=path.resolve(root,'.'+new URL(req.url,'http://localhost').pathname);if(!file.startsWith(root+path.sep))throw Error();res.setHeader('Content-Type',{'.html':'text/html','.js':'text/javascript','.css':'text/css'}[path.extname(file)]??'application/octet-stream');res.end(await readFile(file))}catch{res.writeHead(404).end()}});
 await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));const origin=`http://127.0.0.1:${server.address().port}`;
 const browser=await chromium.launch({executablePath:process.env.CHROME_PATH||(process.platform==='darwin'?'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome':undefined),headless:true});
 t.after(async()=>{await browser.close();await new Promise(resolve=>server.close(resolve))});
 const page=await browser.newPage({viewport:{width:1000,height:800},reducedMotion:'reduce'});
 const errors=[];page.on('pageerror',e=>errors.push(e.message));
 await page.goto(origin+'/index.html');await page.waitForFunction(()=>Boolean(window.StillleafReader));
 await page.evaluate(()=>{window.events=[];window.positions=[];window.addEventListener('stillleaf-reader-event',e=>{if(e.detail.type==='position')window.positions.push(e.detail);if(['pageTurn','pageLayout'].includes(e.detail.type))window.events.push(e.detail)})});
 const take=async()=>page.evaluate(()=>window.events.splice(0));
 const settle=()=>page.waitForTimeout(900);
 // Scroll events arrive on the next frame; wait for the turn itself rather than a fixed pause.
 const turned=()=>page.waitForFunction(()=>window.events.some(e=>e.type==='pageTurn'),null,{timeout:5000});
 const frameWith=selector=>page.waitForFunction(selector=>[...document.querySelectorAll('#reader iframe')].some(f=>f.contentDocument?.querySelector(selector)),selector);

 const indexedBook={...book,contentProgress:true,resources:book.resources.map((r,i)=>i===2?{...r,dataBase64:Buffer.from(chapter(3).replace('</body>',prose.repeat(100)+'</body>')).toString('base64')}:r)};
 await page.evaluate(input=>window.StillleafReader.open(input),indexedBook);await frameWith('#c1p0');await settle();
 await page.waitForFunction(()=>window.positions.some(e=>e.position.bookTotal>0));
 const indexCheck=await page.evaluate(resources=>{
  const lengths=resources.map(r=>new DOMParser().parseFromString(atob(r.dataBase64),'text/html').body.textContent.length);
  return {lengths,position:window.positions.at(-1).position};
 },indexedBook.resources);
 assert.equal(indexCheck.position.bookTotal,indexCheck.lengths.reduce((a,b)=>a+b,0));
 assert.ok(indexCheck.lengths[2]>indexCheck.lengths[0]*2,'unequal chapter lengths exercise proportional weighting');
 assert.equal(indexCheck.position.bookOffset,indexCheck.position.upper);

 let events=await take();
 assert.deepEqual(events.map(e=>e.type),['pageLayout'],'opening announces the layout and turns nothing');
 assert.equal(events[0].pages,1);assert.equal(events[0].editionId,'page-evidence');
 const single=events[0].layout;

 for(let i=0;i<3;i++){await page.evaluate(()=>window.StillleafReader.next());await page.waitForTimeout(150)}
 await page.evaluate(()=>window.StillleafReader.previous());await page.waitForTimeout(150);
 events=await take();
 assert.deepEqual(events.map(e=>[e.type,e.direction,e.pages,e.layout]),[
  ['pageTurn','forward',1,single],['pageTurn','forward',1,single],['pageTurn','forward',1,single],['pageTurn','backward',1,single]]);

 const forward=events.filter(e=>e.direction==='forward');
 assert.ok(forward.every(e=>e.departure.href==='c1.html'&&e.departure.upper>e.departure.lower),'turns carry actual departure text');
 assert.deepEqual(forward.map(e=>e.departure.page),[1,2,3],'native coordinates are real chapter pages');
 assert.ok(forward[1].departure.lower>forward[0].departure.lower);
 assert.ok(forward[2].sequence>forward[1].sequence);
 await page.evaluate(()=>window.StillleafReader.next());await page.waitForTimeout(150);
 const revisited=(await take()).find(e=>e.type==='pageTurn');
 assert.deepEqual(revisited.departure,forward[2].departure,'backtracking and turning again names the same content');
 const observed=await page.evaluate(()=>window.positions.at(-1));
 assert.equal(observed.position.page,4);assert.ok(observed.position.totalPages>4);

 // Jumps and restores move the reader but are not reading.
 await page.evaluate(()=>window.StillleafReader.go({href:'c3.html',type:'text/html',locations:{progression:.5}}));await settle();
 await page.evaluate(()=>window.StillleafReader.go({href:'c1.html',type:'text/html',locations:{fragments:['c1p10']}}));await settle();
 assert.deepEqual(await take(),[],'jumps report no page movement');
 const jumped=await page.evaluate(()=>window.positions.at(-1).position);
 assert.equal(jumped.bookTotal,indexCheck.position.bookTotal);
 assert.ok(jumped.page>1,'jump updates actual page position without adding coverage');

 // Reflow starts a new layout, so no turn is compared across it.
 await page.evaluate(()=>window.StillleafReader.setPreferences({fontSize:1.5}));await settle();
 events=await take();
 assert.ok(events.every(e=>e.type==='pageLayout')&&events.length>=1,JSON.stringify(events));
 assert.notEqual(events.at(-1).layout,single);
 assert.equal(await page.evaluate(()=>window.positions.at(-1).position.bookTotal),indexCheck.position.bookTotal,'font reflow keeps the content denominator');

 // Facing pages: a turn moves two pages.
 await page.setViewportSize({width:1300,height:850});await page.evaluate(()=>window.StillleafReader.setPreferences({columns:'two'}));await settle();
 events=await take();assert.ok(events.every(e=>e.type==='pageLayout'),'resizing and switching to facing pages turn nothing');
 const facing=events.at(-1);assert.equal(facing.pages,2);
 await page.evaluate(()=>window.StillleafReader.next());await page.waitForTimeout(150);
 events=await take();assert.deepEqual(events.map(e=>[e.type,e.direction,e.pages,e.layout]),[['pageTurn','forward',2,facing.layout]]);

 // Scroll mode: full screens scrolled by the reader count; scrubbing and jumps do not.
 await page.evaluate(()=>window.StillleafReader.setPreferences({scroll:true}));await settle();
 events=await take();const scroll=events.at(-1);assert.equal(scroll.type,'pageLayout');assert.match(scroll.layout,/^s1-/);
 const scrollFrame=async(dy,steps)=>{for(let i=0;i<steps;i++){await page.evaluate(dy=>{const f=[...document.querySelectorAll('#reader iframe')].find(f=>getComputedStyle(f).visibility!=='hidden');f.contentWindow.scrollBy(0,dy*f.contentWindow.innerHeight)},dy);await page.waitForTimeout(60)}};
 // Mid-chapter, so there is room in both directions; the first scroll after a jump only
 // sets the baseline (tracking undercounts rather than guesses), so prime it first.
 await page.evaluate(()=>window.StillleafReader.go({href:'c2.html',type:'text/html',locations:{progression:.5}}));await settle();
 await take();await scrollFrame(.05,1);assert.deepEqual(await take(),[],'a small scroll is not a page');
 await scrollFrame(.25,5);
 await turned();events=await take();assert.deepEqual(events.map(e=>[e.type,e.direction,e.pages,e.layout]),[['pageTurn','forward',1,scroll.layout]],'1.25 screens scrolled is one page');
 await scrollFrame(-.25,6); // net movement: the 0.25 screen left over from above must be undone too
 await turned();events=await take();assert.deepEqual(events.map(e=>[e.type,e.direction]),[['pageTurn','backward']]);
 await scrollFrame(3,1);
 assert.deepEqual(await take(),[],'a three-screen jump is scrubbing, not reading');
 await page.evaluate(()=>window.StillleafReader.go({href:'c3.html',type:'text/html',locations:{progression:1}}));await settle();
 const endPosition=await page.evaluate(()=>window.positions.at(-1).position);
 assert.equal(endPosition.bookOffset,endPosition.bookTotal,'last screen represents the end of the book including trailing whitespace');
 assert.deepEqual(await take(),[],'seeking to the end still credits no coverage');
 assert.deepEqual(errors,[]);
});

test('continuous view reports full screens the reader scrolls, across chapter boundaries',{timeout:120000},async t=>{
 const server=createServer(async(req,res)=>{try{const file=path.resolve(root,'.'+new URL(req.url,'http://localhost').pathname);if(!file.startsWith(root+path.sep))throw Error();res.setHeader('Content-Type',{'.html':'text/html','.js':'text/javascript','.css':'text/css'}[path.extname(file)]??'application/octet-stream');res.end(await readFile(file))}catch{res.writeHead(404).end()}});
 await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));const origin=`http://127.0.0.1:${server.address().port}`;
 const browser=await chromium.launch({executablePath:process.env.CHROME_PATH||(process.platform==='darwin'?'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome':undefined),headless:true});
 t.after(async()=>{await browser.close();await new Promise(resolve=>server.close(resolve))});
 const page=await browser.newPage({viewport:{width:1000,height:800},reducedMotion:'reduce'});
 const errors=[];page.on('pageerror',e=>errors.push(e.message));
 await page.goto(origin+'/index.html');await page.waitForFunction(()=>Boolean(window.StillleafReader));
 await page.evaluate(()=>{window.events=[];window.addEventListener('stillleaf-reader-event',e=>{if(['pageTurn','pageLayout'].includes(e.detail.type))window.events.push(e.detail)})});
 const take=async()=>page.evaluate(()=>window.events.splice(0));
 const settle=()=>page.waitForTimeout(900);
 const turned=()=>page.waitForFunction(()=>window.events.some(e=>e.type==='pageTurn'),null,{timeout:5000});
 const input={...book,experimentalContinuous:true,state:{schemaVersion:1,editionId:'page-evidence',revision:0,position:null,preferences:{theme:'paper',fontFamily:'publisher',fontSize:1.2,lineHeight:1.6,measure:65,scroll:true},bookmarks:[],annotations:[]}};
 await page.evaluate(input=>window.StillleafReader.open(input),input);
 await page.waitForFunction(()=>document.querySelector('#reader.continuous-reader iframe')?.contentDocument?.querySelector('#c1p0'));await settle();
 let events=await take();
 assert.deepEqual(events.map(e=>e.type),['pageLayout'],'opening announces the layout and turns nothing');
 const layout=events[0].layout;assert.match(layout,/^s1-/);
 const scroll=async(dy,steps)=>{for(let i=0;i<steps;i++){await page.evaluate(dy=>{const flow=document.querySelector('#reader');flow.scrollBy(0,dy*flow.clientHeight)},dy);await page.waitForTimeout(60)}};
 await scroll(.05,1);assert.deepEqual(await take(),[],'a small scroll is not a page');
 await scroll(.25,5);
 await turned();events=await take();assert.deepEqual(events.map(e=>[e.type,e.direction,e.pages,e.layout]),[['pageTurn','forward',1,layout]],'1.25 screens scrolled is one page');
 await scroll(-.25,6);
 await turned();events=await take();assert.deepEqual(events.map(e=>[e.type,e.direction]),[['pageTurn','backward']]);
 // Reading straight through a chapter boundary keeps counting; there is no hand-off.
 const boundary=await page.evaluate(()=>{const flow=document.querySelector('#reader'),second=flow.querySelectorAll('.continuous-chapter')[1];return second.offsetTop-flow.clientHeight*.5});
 await page.evaluate(top=>{document.querySelector('#reader').scrollTop=top},boundary);await settle();await take();
 await scroll(.25,5);await turned();
 events=await take();assert.deepEqual(events.map(e=>[e.type,e.direction]),[['pageTurn','forward']],'scrolling across a chapter boundary is reading');
 assert.ok(await page.evaluate(()=>{const flow=document.querySelector('#reader'),view=flow.getBoundingClientRect();return [...flow.querySelectorAll('.continuous-chapter')].filter(s=>{const r=s.getBoundingClientRect();return r.bottom>view.top&&r.top<view.bottom}).length>=1}));
 // Jumps and scrubbing are not reading.
 await page.evaluate(()=>window.StillleafReader.go({href:'c3.html',type:'text/html',locations:{progression:.5}}));await settle();
 assert.deepEqual(await take(),[],'jumps report no page movement');
 await scroll(3,1);await page.waitForTimeout(300);
 assert.deepEqual(await take(),[],'a three-screen jump is scrubbing, not reading');
 assert.deepEqual(errors,[]);
});
