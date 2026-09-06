import {test} from 'node:test';
import assert from 'node:assert/strict';
import {createServer} from 'node:http';
import {readFile} from 'node:fs/promises';
import path from 'node:path';
import {chromium} from 'playwright';

const root=path.resolve(import.meta.dirname,'../dist');
const prose='The ferry crossed slowly while the gulls kept pace with the wake. She returned to the sentence she had marked and kept reading.';
const book={editionId:'scroll-performance',title:'Crossings',experimentalContinuous:true,
 readingOrder:Array.from({length:12},(_,i)=>({href:`c${i}.html`,type:'text/html',title:`Crossing ${i}`})),
 resources:Array.from({length:12},(_,i)=>({href:`c${i}.html`,type:'text/html',dataBase64:Buffer.from(`<html><body><h1>Crossing ${i}</h1>${Array.from({length:120},(_,j)=>`<p id="p${j}">${prose}</p>`).join('')}</body></html>`).toString('base64')})),
 state:{schemaVersion:1,editionId:'scroll-performance',revision:0,position:null,preferences:{scroll:true},bookmarks:[],annotations:[]}};

test('settled continuous scrolling does not restore layout or accumulate wheel timers',{timeout:30000},async t=>{
 const server=createServer(async(req,res)=>{try{const file=path.resolve(root,'.'+new URL(req.url,'http://localhost').pathname);if(!file.startsWith(root+path.sep))throw Error();res.setHeader('Content-Type',{'.html':'text/html','.js':'text/javascript','.css':'text/css'}[path.extname(file)]??'application/octet-stream');res.end(await readFile(file))}catch{res.writeHead(404).end()}});
 await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
 const browser=await chromium.launch({executablePath:process.env.CHROME_PATH||(process.platform==='darwin'?'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome':undefined),headless:true});
 t.after(async()=>{await browser.close();await new Promise(resolve=>server.close(resolve))});
 const page=await browser.newPage({viewport:{width:1000,height:800}});
 await page.goto(`http://127.0.0.1:${server.address().port}/index.html`);await page.waitForFunction(()=>window.StillleafReader);
 await page.evaluate(input=>window.StillleafReader.open(input),book);await page.waitForTimeout(1000);
 const initialLabel=await page.locator('#position-label').textContent();
 assert.match(initialLabel,/^Page 1 of \d+$/);
 assert.equal(await page.locator('#chapter-label').textContent(),'in this chapter');
 const result=await page.evaluate(async()=>{
  const flow=document.querySelector('#reader'),frame=flow.querySelector('iframe');
  const descriptor=Object.getOwnPropertyDescriptor(Element.prototype,'scrollTop');
  let corrections=0,timers=0;const originalTimeout=window.setTimeout;
  Object.defineProperty(flow,'scrollTop',{configurable:true,get(){return descriptor.get.call(this)},set(value){corrections++;descriptor.set.call(this,value)}});
  window.setTimeout=function(fn,delay,...args){if(delay===100)timers++;return originalTimeout(fn,delay,...args)};
  const before=flow.scrollTop;
  for(let i=0;i<30;i++){
   // Exercise frame wheel listeners and real native scroll events at the same time.
   frame.contentWindow.dispatchEvent(new frame.contentWindow.WheelEvent('wheel',{deltaY:24}));
   flow.scrollBy(0,24);await new Promise(requestAnimationFrame);
  }
  await new Promise(resolve=>originalTimeout(resolve,200));
  window.setTimeout=originalTimeout;delete flow.scrollTop;
  return {corrections,timers,distance:flow.scrollTop-before,position:window.StillleafReader.bookmark()};
 });
 t.diagnostic(JSON.stringify(result));
 assert.ok(result.distance>650,'scrolling advances through the text');
 assert.equal(result.corrections,0,'ordinary scrolling must not repeatedly restore the layout anchor');
 assert.equal(result.timers,0,'continuous wheel events must not queue delayed text scans');
 assert.ok(result.position.locations.progression>0,'the new reading position is still saved');
 assert.notEqual(await page.locator('#position-label').textContent(),initialLabel,'the footer advances while scrolling');
 // Page totals stay constant across turns, including the last page of a chapter.
 await page.evaluate(()=>window.StillleafReader.setPreferences({scroll:false,columns:'one'}));
 await page.evaluate(()=>window.StillleafReader.go({href:'c0.html',type:'text/html',locations:{fragments:['p0']}}));
 await page.waitForTimeout(200);
 const start=await page.locator('#position-label').textContent(),total=Number(start.match(/of (\d+)/)?.[1]);
 assert.match(start,/^Page 1 of \d+$/);assert.ok(total>2);
 await page.evaluate(()=>window.StillleafReader.next());
 await page.waitForFunction(total=>document.querySelector('#position-label').textContent===`Page 2 of ${total}`,total);
 await page.evaluate(()=>window.StillleafReader.go({href:'c0.html',type:'text/html',locations:{progression:1}}));
 await page.waitForFunction(total=>document.querySelector('#position-label').textContent===`Page ${total} of ${total}`,total);
 await page.setViewportSize({width:1300,height:850});await page.waitForTimeout(500);
 await page.evaluate(()=>window.StillleafReader.setPreferences({columns:'two'}));
 await page.evaluate(()=>window.StillleafReader.go({href:'c0.html',type:'text/html',locations:{fragments:['p0']}}));
 await page.waitForTimeout(250);
 assert.match(await page.locator('#position-label').textContent(),/^Pages 1–2 of \d+$/);
 await page.evaluate(()=>window.StillleafReader.next());
 await page.waitForFunction(()=>/^Pages 3–4 of \d+$/.test(document.querySelector('#position-label').textContent));
});
