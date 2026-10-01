import {test} from 'node:test';
import assert from 'node:assert/strict';
import {createServer} from 'node:http';
import {readFile} from 'node:fs/promises';
import path from 'node:path';
import {chromium,webkit} from 'playwright';
import {visibleTextBounds} from '../src/visible-text.js';

const root=path.resolve(import.meta.dirname,'../dist');
const prose='The ferry crossed slowly while gulls kept pace with the wake. She returned to the sentence she had marked and kept reading. ';
test('continuous layout converges and measures only dirty chapters, including caret fallback',{timeout:120000},async t=>{
 const server=createServer(async(req,res)=>{try{const file=path.resolve(root,'.'+new URL(req.url,'http://localhost').pathname);if(!file.startsWith(root+path.sep))throw Error();res.setHeader('Content-Type',{'.html':'text/html','.js':'text/javascript','.css':'text/css'}[path.extname(file)]??'application/octet-stream');res.end(await readFile(file))}catch{res.writeHead(404).end()}});
 await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));t.after(()=>new Promise(resolve=>{server.close(resolve);server.closeAllConnections()}));
 const browser=await (process.env.SCROLL_BROWSER==='webkit'?webkit:chromium).launch({headless:true});t.after(()=>browser.close());
 const page=await browser.newPage({viewport:{width:1000,height:800}});
 await page.goto(`http://127.0.0.1:${server.address().port}/index.html`);await page.waitForFunction(()=>window.StillleafReader);
 const book={editionId:'layout-cost',experimentalContinuous:true,contentProgress:true,readingOrder:[0,1,2,3].map(i=>({href:`c${i}.html`,type:'text/html'})),resources:[0,1,2,3].map(i=>({href:`c${i}.html`,type:'text/html',dataBase64:Buffer.from(`<html><body>${Array.from({length:1000},(_,j)=>`<p id="p${j}">${prose.repeat(2)}</p>`).join('')}</body></html>`).toString('base64')})),state:{schemaVersion:1,editionId:'layout-cost',revision:0,position:null,preferences:{scroll:true,fontSize:1},annotations:[],bookmarks:[]}};
 await page.evaluate(b=>StillleafReader.open(b),book);await page.waitForTimeout(1000);
 await page.evaluate(()=>{window.positions=[];window.addEventListener('stillleaf-reader-event',e=>{if(e.detail.type==='position')window.positions.push(e.detail.position)})});
 const metrics=await page.evaluate(async()=>{
  const flow=document.querySelector('#reader'),frames=[...flow.querySelectorAll('iframe')];
  const stats=frames.map(f=>{const w=f.contentWindow,s={elements:0,ranges:0,fragments:0};const e=w.Element.prototype.getBoundingClientRect,r=w.Range.prototype.getBoundingClientRect,c=w.Range.prototype.getClientRects;w.Element.prototype.getBoundingClientRect=function(){s.elements++;return e.call(this)};w.Range.prototype.getBoundingClientRect=function(){s.ranges++;return r.call(this)};w.Range.prototype.getClientRects=function(){s.fragments++;return c.call(this)};return s});
  const snapshot=()=>stats.map(s=>({...s})),reset=()=>stats.forEach(s=>Object.keys(s).forEach(k=>s[k]=0)),wait=ms=>new Promise(r=>setTimeout(r,ms));
  reset();await wait(700);const idle=snapshot();reset();
  const locator=StillleafReader.bookmark();
  let annotation=StillleafReader.annotate({locator,quote:locator.text?.highlight||'The ferry crossed slowly',note:'A margin note',color:'gold'});
  for(let i=0;i<20;i++)annotation=StillleafReader.annotate({...annotation,note:'An autosaved thought '+i,color:i%2?'sage':'rose'});
  await wait(700);const annotations=snapshot();reset();
  frames[1].contentDocument.getElementById('p500').style.height='220px';await wait(700);const dirty=snapshot();reset();
  // Same total height, different internal text geometry. A height-only cache gate is incorrect.
  const doc=frames[0].contentDocument,height=frames[0].clientHeight;
  doc.getElementById('p0').style.transform='translateY(40px)';await wait(700);const sameHeight={before:height,after:frames[0].clientHeight,cost:snapshot()};reset();
  // Force the fallback at a deep location, so scanning from the chapter's first glyph is exposed.
  for(const f of frames){f.contentDocument.caretPositionFromPoint=undefined;f.contentDocument.caretRangeFromPoint=undefined;}
  flow.scrollTop=90000;await wait(200);reset();
  const intervals=[];let last=performance.now();
  for(let i=0;i<60;i++){flow.scrollBy(0,24);await new Promise(requestAnimationFrame);const now=performance.now();intervals.push(now-last);last=now}
  await wait(200);const scroll=snapshot();intervals.sort((a,b)=>a-b);
  return {idle,annotations,dirty,sameHeight,scroll,frames:frames.length,frameMs:{median:intervals[30],p95:intervals[57],max:intervals.at(-1)},label:document.querySelector('#position-label').textContent};
 });
 t.diagnostic(JSON.stringify(metrics));
 if(process.env.READER_BASELINE)return;
 assert.ok(metrics.idle.every(s=>s.elements<10&&s.ranges<10),'settled observers perform no chapter geometry scans');
 assert.ok(metrics.annotations.every(s=>s.elements<100),'highlight and margin note updates do not remeasure publication chapters');
 assert.ok(metrics.dirty.filter(s=>s.elements>100).length===1,'one dirty chapter must not measure every mounted chapter');
 assert.equal(metrics.sameHeight.after,metrics.sameHeight.before,'internal movement can leave chapter height unchanged');
 assert.ok(metrics.sameHeight.cost[0].elements>100&&metrics.sameHeight.cost.slice(1).every(s=>s.elements<10),'same-height mutation invalidates only its chapter');
 assert.ok(metrics.scroll.reduce((sum,s)=>sum+s.fragments,0)<3000,'caret fallback must avoid repeatedly scanning offscreen prefixes');
 assert.match(metrics.label,/^Page \d+ of \d+(?: · Chapter \d+ · Calculating book pages…)?$/);
 const coverage=await page.evaluate(source=>{
  const scan=new Function(source+';return visibleTextBounds')(),flow=document.querySelector('#reader'),frame=flow.querySelector('iframe'),doc=frame.contentDocument,bounds=frame.getBoundingClientRect(),view=flow.getBoundingClientRect();
  const visible=r=>r.width>0&&r.height>0&&r.right>0&&r.left<frame.clientWidth&&r.bottom>view.top-bounds.top&&r.top<view.bottom-bounds.top;
  const walker=doc.createTreeWalker(doc.body,NodeFilter.SHOW_TEXT);let node,offset=0,lower=null,upper=null;
  while((node=walker.nextNode())){if(node.parentElement?.closest('script,style'))continue;const hit=node.textContent.trim()?scan(node,visible):null;if(hit){lower??=offset+hit.first;upper=offset+hit.last}offset+=node.length}
  const actual=window.positions.at(-1);return{expected:{lower,upper},actual:{lower:actual.lower,upper:actual.upper},anchor:StillleafReader.bookmark()};
 },visibleTextBounds.toString());
 assert.deepEqual(coverage.actual,coverage.expected,'fallback/cache retains exact visible content');
 assert.ok(coverage.anchor.locations.domRange,'deep caret fallback still saves a text anchor');
 const image=await page.evaluate(async()=>{
  const flow=document.querySelector('#reader'),frame=flow.querySelector('iframe'),doc=frame.contentDocument,before=StillleafReader.bookmark();
  const anchor=doc.querySelector(before.locations.cssSelector),oldY=anchor.getBoundingClientRect().top+frame.getBoundingClientRect().top;
  const img=doc.createElement('img');doc.getElementById('p10').append(img);
  await new Promise(r=>setTimeout(r,100));
  img.src='data:image/svg+xml,'+encodeURIComponent('<svg xmlns="http://www.w3.org/2000/svg" width="100" height="300"><rect width="100" height="300"/></svg>');
  await img.decode();await new Promise(r=>setTimeout(r,700));
  return {loaded:img.naturalHeight,oldY,newY:anchor.getBoundingClientRect().top+frame.getBoundingClientRect().top,before:before.locations.cssSelector,after:StillleafReader.bookmark().locations.cssSelector};
 });
 assert.equal(image.loaded,300);assert.ok(Math.abs(image.newY-image.oldY)<2,'delayed image preserves the visible anchor');assert.equal(image.after,image.before);

});
