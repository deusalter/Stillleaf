import {test} from 'node:test';
import assert from 'node:assert/strict';
import {createServer} from 'node:http';
import {readFile} from 'node:fs/promises';
import path from 'node:path';
import {webkit} from 'playwright';
import {visibleTextBounds} from '../src/visible-text.js';

const root=path.resolve(import.meta.dirname,'../dist');
const prose='The ferry crossed slowly while gulls kept pace with the wake. She returned to the sentence she had marked and kept reading.';

test('continuous progress measures visible text only and coalesces host updates',{timeout:60000},async t=>{
 const server=createServer(async(req,res)=>{try{const file=path.resolve(root,'.'+new URL(req.url,'http://localhost').pathname);if(!file.startsWith(root+path.sep))throw Error();res.setHeader('Content-Type',{'.html':'text/html','.js':'text/javascript','.css':'text/css'}[path.extname(file)]??'application/octet-stream');res.end(await readFile(file))}catch{res.writeHead(404).end()}});
 await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));const browser=await webkit.launch({headless:true});
 t.after(async()=>{await browser.close();await new Promise(resolve=>server.close(resolve))});
 const page=await browser.newPage({viewport:{width:1000,height:800}});
 await page.goto(`http://127.0.0.1:${server.address().port}/index.html`);await page.waitForFunction(()=>window.StillleafReader);
 await page.evaluate(()=>{window.positions=[];window.addEventListener('stillleaf-reader-event',event=>{if(event.detail.type==='position')window.positions.push(event.detail.position)})});
 const book={editionId:'continuous-geometry',title:'Crossings',experimentalContinuous:true,contentProgress:true,
 readingOrder:[{href:'c.html',type:'text/html',title:'Crossing'}],resources:[{href:'c.html',type:'text/html',dataBase64:Buffer.from(`<html><body>${Array.from({length:1200},(_,i)=>`<p id="p${i}">${prose}</p>`).join('')}</body></html>`).toString('base64')}],
 state:{schemaVersion:1,editionId:'continuous-geometry',revision:0,position:null,preferences:{scroll:true,fontSize:1},bookmarks:[],annotations:[]}};
 await page.evaluate(b=>StillleafReader.open(b),book);await page.waitForTimeout(1100);
 const metrics=await page.evaluate(async()=>{
  const flow=document.querySelector('#reader'),R=flow.querySelector('iframe').contentWindow.Range.prototype,original=R.getClientRects;let calls=0,events=0;
  R.getClientRects=function(){calls++;return original.call(this)};
  const listener=e=>{if(['position','relocated','state'].includes(e.detail.type))events++};window.addEventListener('stillleaf-reader-event',listener);
  for(let i=0;i<90;i++){flow.scrollBy(0,24);await new Promise(requestAnimationFrame)}
  await new Promise(r=>setTimeout(r,200));R.getClientRects=original;window.removeEventListener('stillleaf-reader-event',listener);
  return{calls,events,distance:flow.scrollTop,label:document.querySelector('#position-label').textContent};
 });
 t.diagnostic(JSON.stringify(metrics));assert.ok(metrics.calls<10000,'1200 offscreen paragraphs must not be scanned per scroll');assert.ok(metrics.events<90,'host bookkeeping is batched');assert.ok(metrics.distance>=2160);
 const scanner=visibleTextBounds.toString();
 const compare=async()=>{
  const result=await page.evaluate(source=>{
   const scan=new Function(source+';return visibleTextBounds')();
   const flow=document.querySelector('#reader'),frame=flow.querySelector('iframe'),doc=frame.contentDocument,bounds=frame.getBoundingClientRect(),view=flow.getBoundingClientRect();
   const visible=r=>r.width>0&&r.height>0&&r.right>Math.max(0,view.left-bounds.left)&&r.left<Math.min(frame.clientWidth,view.right-bounds.left)&&r.bottom>Math.max(0,view.top-bounds.top)&&r.top<Math.min(frame.clientHeight,view.bottom-bounds.top);
   const walker=doc.createTreeWalker(doc.body,NodeFilter.SHOW_TEXT);let node,offset=0,lower=null,upper=null;
   while((node=walker.nextNode())){if(node.parentElement?.closest('script,style'))continue;const hit=node.textContent.trim()?scan(node,visible):null;if(hit){lower??=offset+hit.first;upper=offset+hit.last}offset+=node.length}
   return {expected:{lower,upper},actual:{lower:window.positions.at(-1).lower,upper:window.positions.at(-1).upper}};
  },scanner);assert.deepEqual(result.actual,result.expected,'cached candidate selection preserves exact visible offsets');
 };
 await compare();
 const total=Number(metrics.label.match(/of (\d+)/)[1]);
 await page.evaluate(()=>StillleafReader.setPreferences({fontSize:1.3}));await page.waitForTimeout(400);await compare();
 assert.equal(Number((await page.locator('#position-label').textContent()).match(/of (\d+)/)[1]),total,'reference page total survives font reflow');
 await page.setViewportSize({width:850,height:720});await page.waitForTimeout(600);await compare();
 assert.equal(Number((await page.locator('#position-label').textContent()).match(/of (\d+)/)[1]),total,'reference page total survives viewport reflow');
 await page.evaluate(()=>{const flow=document.querySelector('#reader');flow.scrollTop=flow.scrollHeight-flow.clientHeight});await page.waitForTimeout(250);
 assert.equal(await page.locator('#chapter-label').textContent(),'0 pages left in chapter');
 await page.evaluate(()=>StillleafReader.go({href:'c.html',type:'text/html',locations:{progression:0}}));
 const closePosition=await page.evaluate(async()=>{
  let saved;window.addEventListener('stillleaf-reader-event',event=>{if(event.detail.type==='state')saved=event.detail.state.position});
  document.querySelector('#reader').scrollTop+=300;
  await StillleafReader.prepareClose();
  const exported=StillleafReader.exportState().position;
  await StillleafReader.close();return {saved,exported};
 });
 assert.ok(closePosition.exported.locations.progression>0,'native prepareClose/exportState flushes the latest scroll');
 assert.ok(closePosition.saved.locations.progression>0,'closing flushes the latest scroll without waiting for the report timer');
});
