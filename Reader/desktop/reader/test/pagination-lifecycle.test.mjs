import {test} from 'node:test';
import assert from 'node:assert/strict';
import {createServer} from 'node:http';
import {readFile} from 'node:fs/promises';
import path from 'node:path';
import {chromium,webkit} from 'playwright';
const root=path.resolve(import.meta.dirname,'../dist');
async function setup(t,stalled){
 const server=createServer(async(req,res)=>{
  if(req.url==='/stalled.png'){stalled?.(res);return;}
  try{const file=path.resolve(root,'.'+new URL(req.url,'http://localhost').pathname);if(!file.startsWith(root+path.sep))throw Error();res.setHeader('Content-Type',{'.html':'text/html','.js':'text/javascript','.css':'text/css'}[path.extname(file)]??'application/octet-stream');res.end(await readFile(file))}catch{res.writeHead(404).end()}
 });
 await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
 const browser=await (process.env.READER_TEST_BROWSER==='webkit'?webkit:chromium).launch({headless:true,...(process.env.READER_TEST_BROWSER!=='webkit'&&process.env.CHROME_PATH?{executablePath:process.env.CHROME_PATH}:{})});
 t.after(async()=>{await browser.close();server.closeAllConnections();await new Promise(resolve=>server.close(resolve))});
 const page=await browser.newPage({viewport:{width:1100,height:800},reducedMotion:'reduce'}),origin=`http://127.0.0.1:${server.address().port}`,errors=[];
 page.on('pageerror',error=>errors.push(error.message));await page.goto(origin+'/index.html');await page.waitForFunction(()=>window.StillleafReader);
 return {page,origin,errors};
}
function book(chapters,preferences={}){
 return {editionId:'pagination-lifecycle',experimentalContinuous:true,readingOrder:chapters.map((_,i)=>({href:`c${i}.html`,type:'text/html'})),resources:chapters.map((html,i)=>({href:`c${i}.html`,type:'text/html',dataBase64:Buffer.from(html).toString('base64')})),state:{schemaVersion:1,editionId:'pagination-lifecycle',revision:0,annotations:[],bookmarks:[],preferences}};
}

test('closing and switching abort a probe with a deliberately unresolved resource',{timeout:30000},async t=>{
 let started,aborted=false,requests=0;const pending=new Promise(resolve=>started=resolve);
 const {page,origin,errors}=await setup(t,res=>{requests++;res.on('close',()=>aborted=true);started()});
 const input=book(Array.from({length:5},(_,i)=>`<html><body><p>One reading screen.</p>${i===4?'<img src="stalled.png">':''}</body></html>`));
 input.resources.push({href:'stalled.png',type:'image/png',url:origin+'/stalled.png',size:32});
 await page.evaluate(input=>StillleafReader.open(input),input);await pending;
 const start=Date.now();await page.evaluate(()=>StillleafReader.close());assert.ok(Date.now()-start<1500,'pending resource cannot hold close hostage');
 assert.equal(await page.locator('.pagination-probe').count(),0);
 await page.waitForTimeout(200);assert.equal(aborted,true,'probe transport is aborted');const before=requests;
 await page.evaluate(input=>StillleafReader.open(input),book(['<html><body>Another book.</body></html>']));
 await page.waitForTimeout(300);assert.equal(requests,before,'closed probe makes no late resource requests');
 assert.equal(await page.locator('#position-label').textContent(),'Page 1 of 1');assert.deepEqual(errors,[]);
});

test('pending image geometry withdraws the exact denominator until it settles',{timeout:30000},async t=>{
 const {page,errors}=await setup(t);
 await page.evaluate(input=>StillleafReader.open(input),book(['<html><body>First chapter.</body></html>','<html><body>Second chapter.</body></html>']));
 await page.waitForFunction(()=>document.querySelector('#position-label').textContent==='Page 1 of 2');
 await page.evaluate(()=>{
  window.turns=[];window.positions=[];window.addEventListener('stillleaf-reader-event',event=>{if(event.detail.type==='pageTurn')window.turns.push(event.detail);if(event.detail.type==='position')window.positions.push(event.detail.position)});
  const frame=[...document.querySelectorAll('#reader iframe')].find(frame=>getComputedStyle(frame).visibility!=='hidden'),doc=frame.contentDocument,image=doc.createElement('img');
  // Gate the decoder's completion deterministically; final layout is real.
  window.pendingImage=image;window.imageSettled=false;Object.defineProperty(image,'complete',{get:()=>window.imageSettled});image.style.height='40px';image.style.width='20px';doc.body.append(image);
 });
 await page.waitForTimeout(150);assert.match(await page.locator('#position-label').textContent(),/Calculating book pages/);
 await page.evaluate(()=>{pendingImage.style.height='1800px';const caption=pendingImage.ownerDocument.createElement('p');caption.textContent='The caption wraps onto another reading screen. '.repeat(150);pendingImage.after(caption);window.imageSettled=true;pendingImage.dispatchEvent(new Event('load'))});
 await page.waitForFunction(()=>/^Page \d+ of \d+$/.test(document.querySelector('#position-label').textContent));
 const result=await page.evaluate(()=>({total:Number(document.querySelector('#position-label').textContent.match(/of (\d+)/)[1]),local:window.positions.at(-1).totalPages,turns:window.turns}));
 assert.ok(result.local>1);assert.equal(result.total,result.local+1);assert.deepEqual(result.turns,[]);assert.deepEqual(errors,[]);
});

test('continuous probes share live reserved-scrollbar widths and screen counts',{timeout:30000},async t=>{
 const {page,errors}=await setup(t);
 await page.addStyleTag({content:'.continuous-reader{scrollbar-gutter:stable}.continuous-reader::-webkit-scrollbar{width:18px}'});
 const html='<html><body>'+Array.from({length:20},()=>'<p>'+('The garden held the last of the rain. '.repeat(12))+'</p>').join('')+'</body></html>';
 await page.evaluate(input=>StillleafReader.open(input),book(Array(10).fill(html),{scroll:true,fontSize:1}));
 await page.waitForFunction(()=>document.querySelector('.pagination-probe iframe')?.contentDocument?.body?.textContent.includes('garden'));
 const widths=await page.evaluate(()=>({live:document.querySelector('#reader iframe').contentWindow.innerWidth,probe:document.querySelector('.pagination-probe iframe').contentWindow.innerWidth}));
 assert.equal(widths.probe,widths.live,'non-overlay scrollbar consumes identical width');
 await page.waitForFunction(()=>/^Page \d+ of \d+$/.test(document.querySelector('#position-label').textContent));
 const totals=await page.evaluate(()=>{const flow=document.querySelector('#reader'),frame=flow.querySelector('iframe');return {book:Number(document.querySelector('#position-label').textContent.match(/of (\d+)/)[1]),chapter:Math.ceil(frame.clientHeight/flow.clientHeight-1e-6)}});
 assert.equal(totals.book,10*totals.chapter,'unmounted chapters wrap and count like live chapters');assert.deepEqual(errors,[]);
});
