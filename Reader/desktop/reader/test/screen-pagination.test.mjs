import {test} from 'node:test';
import assert from 'node:assert/strict';
import {createServer} from 'node:http';
import {readFile} from 'node:fs/promises';
import path from 'node:path';
import {chromium,webkit} from 'playwright';
const root=path.resolve(import.meta.dirname,'../dist');

test('one screen per page survives facing switches, odd final spreads, and chapter jumps',{timeout:90000},async t=>{
 const server=createServer(async(req,res)=>{try{const file=path.resolve(root,'.'+new URL(req.url,'http://localhost').pathname);if(!file.startsWith(root+path.sep))throw Error();res.setHeader('Content-Type',{'.html':'text/html','.js':'text/javascript','.css':'text/css'}[path.extname(file)]??'application/octet-stream');res.end(await readFile(file))}catch{res.writeHead(404).end()}});
 await new Promise(r=>server.listen(0,'127.0.0.1',r));t.after(()=>new Promise(r=>{server.close(r);server.closeAllConnections()}));
 const browser=await (process.env.READER_TEST_BROWSER==='webkit'?webkit:chromium).launch({headless:true});t.after(()=>browser.close());
 const page=await browser.newPage({viewport:{width:1400,height:850},reducedMotion:'reduce'});
 await page.goto(`http://127.0.0.1:${server.address().port}/index.html`);await page.waitForFunction(()=>window.StillleafReader);
 await page.evaluate(()=>{window.turns=[];window.positions=[];window.addEventListener('stillleaf-reader-event',e=>{if(e.detail.type==='pageTurn')window.turns.push(e.detail);if(e.detail.type==='position')window.positions.push(e.detail.position)})});
 const book={editionId:'screen-units',title:'Screens',contentProgress:true,readingOrder:[0,1].map(i=>({href:`c${i}.html`,type:'text/html',title:`Chapter ${i+1}`})),resources:[0,1].map(i=>({href:`c${i}.html`,type:'text/html',dataBase64:Buffer.from(`<html><body>${Array.from({length:7},(_,j)=>`<p id="p${j}" style="${j<6?'break-after:column;':''}">${i}.${j} The ferry crossed slowly. ${'She turned the page and kept reading. '.repeat(8)}</p>`).join('')}</body></html>`).toString('base64')}))};
 await page.evaluate(b=>StillleafReader.open(b),book);await page.waitForTimeout(900);
 const position=()=>page.evaluate(()=>window.positions.at(-1));
 const clear=()=>page.evaluate(()=>window.turns.splice(0));
 const settled=()=>page.waitForTimeout(950);
 const single=await position();assert.equal(single.totalPages,7);
 await page.locator('#contents').focus();
 await page.waitForFunction(()=>document.querySelector('#position-label').textContent==='Page 1 of 14');
 assert.equal(await page.evaluate(()=>document.activeElement.id),'contents','background renderer cannot steal keyboard focus');
 await page.evaluate(()=>StillleafReader.next());await settled();assert.equal((await position()).page,2);assert.equal((await clear())[0].pages,1);
 const saved=await page.evaluate(()=>StillleafReader.bookmark());
 await page.evaluate(()=>StillleafReader.setPreferences({columns:'two'}));await settled();
 const facing=await position();assert.equal(facing.totalPages,4,'seven leaves require four full-screen spreads');assert.equal(facing.visiblePages,1);assert.equal(facing.pageUnit,'screen');assert.deepEqual(await clear(),[]);
 await page.waitForFunction(()=>/^Page \d+ of 8$/.test(document.querySelector('#position-label').textContent));
 assert.equal(await page.evaluate(()=>StillleafReader.bookmark().href),saved.href);
 await page.evaluate(()=>StillleafReader.go({href:'c0.html',type:'text/html',locations:{progression:1}}));await settled();
 const end=await position();assert.equal(end.page,end.totalPages,'odd final spread has one screen number');assert.equal(end.visiblePages,1);assert.deepEqual(await clear(),[]);
 assert.equal(await page.locator('#position-label').textContent(),'Page 4 of 8');
 await page.evaluate(()=>StillleafReader.next());await settled();
 assert.equal((await position()).href,'c1.html');assert.equal((await clear())[0].pages,1,'chapter boundary is one accepted screen turn');
 assert.equal(await page.locator('#position-label').textContent(),'Page 5 of 8','preceding chapters contribute to displayed page');
 await page.evaluate(()=>StillleafReader.previous());await settled();assert.equal((await position()).href,'c0.html');assert.equal((await clear())[0].pages,1);
 // TOC uses this same go path; jumps and reflow generate position only.
 await page.evaluate(()=>StillleafReader.go({href:'c1.html',type:'text/html',locations:{fragments:['p3']}}));await settled();assert.deepEqual(await clear(),[]);
 await page.evaluate(()=>StillleafReader.setPreferences({columns:'one',fontSize:1.5,contentWidth:80}));await settled();assert.deepEqual(await clear(),[]);assert.equal((await position()).visiblePages,1);
 await page.setViewportSize({width:520,height:700});await page.evaluate(()=>StillleafReader.setPreferences({columns:'two'}));await settled();assert.deepEqual(await clear(),[]);
 const narrow=await page.evaluate(()=>{const frame=[...document.querySelectorAll('#reader iframe')].find(f=>getComputedStyle(f).visibility!=='hidden');return {columns:frame.contentWindow.getComputedStyle(frame.contentDocument.documentElement).columnCount,position:window.positions.at(-1),label:document.querySelector('#position-label').textContent}});
 assert.equal(narrow.columns,'1');assert.equal(narrow.position.visiblePages,1);assert.match(narrow.label,/^Page \d+ of \d+(?: · Chapter \d+ · Calculating book pages…)?$/);
 await page.waitForFunction(()=>/^Page \d+ of \d+$/.test(document.querySelector('#position-label').textContent));
 const final=await position();assert.equal(Number((await page.locator('#position-label').textContent()).match(/of (\d+)/)[1]),2*final.totalPages,'both chapters recalculated after font and narrow facing fallback');
 assert.deepEqual(await clear(),[],'background completion generates no reading turns');
 assert.equal(await page.locator('.pagination-probe').count(),0,'completed probe is disposed');
 // Continuous totals use measured screen heights, never estimated placeholders.
 await page.evaluate(b=>StillleafReader.open({...b,experimentalContinuous:true,state:{schemaVersion:1,editionId:b.editionId,revision:0,annotations:[],bookmarks:[],preferences:{scroll:true}}}),book);
 await page.waitForFunction(()=>/^Page \d+ of \d+$/.test(document.querySelector('#position-label').textContent));
 const continuous=await page.evaluate(()=>{const flow=document.querySelector('#reader');return {total:[...flow.querySelectorAll('.continuous-chapter')].reduce((sum,entry)=>sum+Math.ceil(entry.clientHeight/flow.clientHeight-1e-6),0),label:document.querySelector('#position-label').textContent}});
 assert.equal(Number(continuous.label.match(/of (\d+)/)[1]),continuous.total);
 const nextBook={...book,editionId:'other-book',readingOrder:book.readingOrder.slice(0,1)};
 // Close a book with pending unseen chapters; its probe and generation must
 // disappear before resource URLs close or the next book receives its totals.
 const many={...book,readingOrder:Array.from({length:10},(_,i)=>({href:`many${i}.html`,type:'text/html'})),resources:Array.from({length:10},(_,i)=>({...book.resources[i%2],href:`many${i}.html`}))};
 await page.evaluate(b=>StillleafReader.open(b),many);
 await page.waitForFunction(()=>document.querySelector('.pagination-probe'));
 await page.evaluate(()=>StillleafReader.close());assert.equal(await page.locator('.pagination-probe').count(),0);
 await page.evaluate(b=>StillleafReader.open(b),nextBook);
 await page.waitForFunction(()=>document.querySelector('#position-label').textContent==='Page 1 of 7');
 await page.waitForTimeout(300);assert.equal(await page.locator('.pagination-probe').count(),0);
});
