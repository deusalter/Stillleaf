import {test} from 'node:test';
import assert from 'node:assert/strict';
import {createServer} from 'node:http';
import {readFile} from 'node:fs/promises';
import path from 'node:path';
import {chromium,webkit} from 'playwright';
const root=path.resolve(import.meta.dirname,'../dist');

// Whole-book page counts are display-only. Whether the footer shows an estimate, an exact count, or a wrong count a host
// handed back, the reader's progress, page evidence and saved state must be identical: they use chapter screens and text.
const prose='The ferry crossed slowly while the gulls kept pace with the wake. She returned to the sentence she had marked and kept reading. ';
const book={editionId:'count-progress',title:'Counts',contentProgress:true,
 readingOrder:[0,1,2,3].map(i=>({href:`c${i}.html`,type:'text/html',title:`Chapter ${i+1}`})),
 resources:[3,9,2,6].map((paragraphs,i)=>({href:`c${i}.html`,type:'text/html',dataBase64:Buffer.from(`<html><body><h1>Chapter ${i+1}</h1>${Array.from({length:paragraphs},(_,j)=>`<p id="p${j}">${prose.repeat(6)}</p>`).join('')}</body></html>`).toString('base64')}))};

test('estimated, exact and stale whole-book counts never reach progress, page evidence or saved state',{timeout:90000},async t=>{
 const server=createServer(async(req,res)=>{try{const file=path.resolve(root,'.'+new URL(req.url,'http://localhost').pathname);if(!file.startsWith(root+path.sep))throw Error();res.setHeader('Content-Type',{'.html':'text/html','.js':'text/javascript','.css':'text/css'}[path.extname(file)]??'application/octet-stream');res.end(await readFile(file))}catch{res.writeHead(404).end()}});
 await new Promise(r=>server.listen(0,'127.0.0.1',r));t.after(()=>new Promise(r=>{server.close(r);server.closeAllConnections()}));
 const browser=await (process.env.READER_TEST_BROWSER==='webkit'?webkit:chromium).launch({headless:true});t.after(()=>browser.close());
 const page=await browser.newPage({viewport:{width:1000,height:760},reducedMotion:'reduce'});
 const errors=[];page.on('pageerror',error=>{if(!/ResizeObserver loop/.test(String(error)))errors.push(String(error))});
 await page.goto(`http://127.0.0.1:${server.address().port}/index.html`);await page.waitForFunction(()=>window.StillleafReader);
 await page.evaluate(()=>{window.log={positions:[],turns:[],maps:[],states:[]};window.addEventListener('stillleaf-reader-event',({detail})=>{
  if(detail.type==='position')window.log.positions.push(detail.position);if(detail.type==='pageTurn')window.log.turns.push(detail);
  if(detail.type==='pageMap')window.log.maps.push(detail.pageMap);if(detail.type==='state')window.log.states.push(detail.state);
 })});
 const reset=()=>page.evaluate(()=>{for(const list of Object.values(window.log))list.splice(0)});
 const footer=()=>page.evaluate(()=>{const label=document.querySelector('#position-label');return {text:label.textContent,status:label.dataset.pages}});
 // Read from the start: three turns, a jump into the long chapter, and two more turns.
 async function read(input){
  await reset();await page.evaluate(input=>StillleafReader.open(input),input);await page.waitForTimeout(150);
  const opened=await footer();
  for(let i=0;i<3;i++){await page.evaluate(()=>StillleafReader.next());await page.waitForTimeout(350)}
  await page.evaluate(()=>StillleafReader.go({href:'c1.html',type:'text/html',locations:{fragments:['p4']}}));await page.waitForTimeout(400);
  for(let i=0;i<2;i++){await page.evaluate(()=>StillleafReader.next());await page.waitForTimeout(350)}
  await page.waitForTimeout(400);
  const log=await page.evaluate(()=>JSON.parse(JSON.stringify(window.log)));
  const state=await page.evaluate(()=>StillleafReader.exportState());
  return {opened,log,state,closing:await footer()};
 }
 const fresh=await read(book);
 assert.ok(/^Page \d+ of \d+$/.test(fresh.opened.text)||fresh.opened.text==='','the footer never shows a calculating notice');
 await page.waitForFunction(()=>window.log.maps.length>0,null,{timeout:20000});
 const exact=await page.evaluate(()=>window.log.maps.at(-1));
 assert.equal(exact.counts.length,4);
 await page.evaluate(()=>StillleafReader.close());

 // The host returns a wrong map for this very layout, as a stale cache could.
 const wrong={key:exact.key,counts:exact.counts.map(count=>count*7+3)};
 const stale=await read({...book,pageMaps:[wrong]});
 // The saved map shows at once; if the live chapter has already settled, its own count replaces the saved one.
 const sum=counts=>counts.reduce((a,b)=>a+b,0);
 assert.ok([sum(wrong.counts),exact.counts[0]+sum(wrong.counts.slice(1))].map(total=>`Page 1 of ${total}`).includes(stale.opened.text),stale.opened.text);

 // Identical evidence and progress, whatever the footer said.
 // `layout` is the evidence's relayout counter, which differs between two openings by design; within one it is constant.
 const evidence=run=>run.log.turns.map(({direction,pages,departure})=>({direction,pages,departure}));
 for(const run of [fresh,stale])assert.equal(new Set(run.log.turns.map(turn=>turn.layout)).size,1);
 assert.equal(fresh.log.turns.length,5,'one page turn per deliberate turn; the jump and any count refinement add none');
 assert.ok(fresh.log.turns.every(turn=>turn.pages===1));
 assert.deepEqual(evidence(stale),evidence(fresh));
 const progress=run=>run.log.positions.map(({href,page,totalPages,visiblePages,pageUnit,bookOffset,bookTotal,lower,upper})=>({href,page,totalPages,visiblePages,pageUnit,bookOffset,bookTotal,lower,upper}));
 assert.deepEqual(progress(stale).at(-1),progress(fresh).at(-1));
 for(const position of [...fresh.log.positions,...stale.log.positions]){
  assert.ok(position.page<=position.totalPages,'positions carry chapter screens');
  assert.ok(position.totalPages<=Math.max(...exact.counts),'never a whole-book count');
  if(position.bookTotal!==undefined)assert.equal(position.bookTotal,fresh.log.positions.at(-1).bookTotal,'the text denominator is independent of layout counts');
 }
 // Saved reading state carries no page counts.
 const fields=state=>Object.keys(state).sort();
 assert.deepEqual(fields(stale.state),fields(fresh.state));
 assert.ok(!JSON.stringify(stale.state).includes(exact.key),'a layout key never enters reading state');
 for(const state of [...fresh.log.states,...stale.log.states])assert.deepEqual(fields(state),fields(fresh.state));
 assert.deepEqual(stale.state.position,fresh.state.position);

 // The live chapters correct the stale map; the corrected map goes back to the host and the footer follows a move.
 await page.waitForFunction(key=>window.log.maps.some(map=>map.key===key),exact.key,{timeout:20000});
 const corrected=await page.evaluate(key=>window.log.maps.filter(map=>map.key===key).at(-1),exact.key);
 assert.deepEqual(corrected.counts,exact.counts,'measured chapters replace every wrong count');
 await page.evaluate(()=>StillleafReader.previous());
 await page.waitForFunction(total=>document.querySelector('#position-label').textContent.endsWith(` of ${total}`),exact.counts.reduce((a,b)=>a+b,0));
 await page.evaluate(()=>StillleafReader.close());

 // A correct saved map: the exact count on first paint, and no chapter is laid out again.
 await page.evaluate(()=>{window.probes=0;new MutationObserver(list=>{for(const m of list)for(const n of m.addedNodes)if(n.classList?.contains('pagination-probe'))window.probes++}).observe(document.body,{childList:true})});
 await page.evaluate(input=>StillleafReader.open(input),{...book,pageMaps:[corrected]});
 await page.waitForFunction(()=>document.querySelector('#position-label').textContent);
 assert.deepEqual(await footer(),{text:`Page 1 of ${sum(exact.counts)}`,status:'exact'});
 for(let i=0;i<2;i++){await page.evaluate(()=>StillleafReader.next());await page.waitForTimeout(300)}
 await page.waitForTimeout(800);
 assert.equal(await page.evaluate(()=>window.probes),0,'reopening never recounts a known layout');
 assert.match((await footer()).text,new RegExp(` of ${sum(exact.counts)}$`));
 assert.deepEqual(errors,[]);
});
