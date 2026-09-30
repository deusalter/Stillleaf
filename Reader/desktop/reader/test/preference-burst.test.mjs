import {test} from 'node:test';
import assert from 'node:assert/strict';
import {createServer} from 'node:http';
import {readFile} from 'node:fs/promises';
import path from 'node:path';
import {webkit} from 'playwright';

test('rapid preferences coalesce to the final merged layout and retain the reading anchor',{timeout:60000},async t=>{
 const root=path.resolve(import.meta.dirname,'../dist');
 const server=createServer(async(req,res)=>{try{const file=path.resolve(root,'.'+new URL(req.url,'http://localhost').pathname);if(!file.startsWith(root+path.sep))throw Error();res.setHeader('Content-Type',{'.html':'text/html','.js':'text/javascript','.css':'text/css'}[path.extname(file)]??'application/octet-stream');res.end(await readFile(file))}catch{res.writeHead(404).end()}});
 await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
 // Register server cleanup before browser setup, which can fail on a fresh CI host.
 t.after(()=>new Promise(resolve=>{server.close(resolve);server.closeAllConnections()}));
 const browser=await webkit.launch();
 t.after(()=>browser.close());
 const page=await browser.newPage({viewport:{width:1000,height:800},reducedMotion:'reduce'});
 await page.goto(`http://127.0.0.1:${server.address().port}/index.html`);await page.waitForFunction(()=>window.StillleafReader);
 const html='<html><body>'+Array.from({length:200},(_,i)=>`<p id="p${i}">The river ${i} crossed the valley. She opened the book beneath the shade and began reading.</p>`).join('')+'</body></html>';
 await page.evaluate(input=>StillleafReader.open(input),{editionId:'preferences',title:'The River',experimentalContinuous:true,readingOrder:[{href:'c.html',type:'text/html'}],resources:[{href:'c.html',type:'text/html',dataBase64:Buffer.from(html).toString('base64')}]});
 for(const scroll of [true,false]){
  await page.evaluate(scroll=>StillleafReader.setPreferences({scroll,fontSize:1}),scroll);
  await page.evaluate(()=>StillleafReader.go({href:'c.html',type:'text/html',locations:{fragments:['p80']}}));
  const result=await page.evaluate(async()=>{
   const anchor=StillleafReader.bookmark().locations.cssSelector;
   const anchorVisible=()=>{const flow=document.querySelector('#reader'),view=flow.getBoundingClientRect(),frame=[...flow.querySelectorAll('iframe')].find(f=>getComputedStyle(f).visibility!=='hidden'),bounds=frame.getBoundingClientRect();return [...frame.contentDocument.getElementById('p80').getClientRects()].some(r=>r.bottom+bounds.top>view.top&&r.top+bounds.top<view.bottom&&r.right>0&&r.left<frame.clientWidth)};
   const wasVisible=anchorVisible();
   const timeout=window.setTimeout;let restoreWaits=0,layouts=0;
   window.setTimeout=function(fn,delay,...args){if(delay===120)restoreWaits++;return timeout(fn,delay,...args)};
   const observe=event=>{if(event.detail.type==='pageLayout')layouts++};window.addEventListener('stillleaf-reader-event',observe);
   const began=performance.now();
   // The final theme request must keep both the newest font size and a prior
   // geometry-changing request's anchor restoration requirement.
   await Promise.all([...Array.from({length:20},(_,i)=>StillleafReader.setPreferences({fontSize:1+(i+1)*.02})),StillleafReader.setPreferences({theme:'dark'})]);
   window.setTimeout=timeout;window.removeEventListener('stillleaf-reader-event',observe);
   const frame=[...document.querySelectorAll('#reader iframe')].find(f=>getComputedStyle(f).visibility!=='hidden');
   return{elapsed:performance.now()-began,restoreWaits,layouts,anchor,wasVisible,isVisible:anchorVisible(),after:StillleafReader.bookmark().locations.cssSelector,preferences:StillleafReader.exportState().preferences,zoom:parseFloat(frame.contentWindow.getComputedStyle(frame.contentDocument.body).zoom)};
  });
  t.diagnostic(JSON.stringify({scroll,...result}));
  // State debounce also uses120ms, so layout notifications directly verify
  // batching rather than relying on hardware-sensitive completion timings.
  assert.equal(result.layouts,1,'twenty-one requests commit only the final layout');
  assert.equal(result.preferences.fontSize,1.4);assert.equal(result.preferences.theme,'dark');assert.equal(result.zoom,1.4);
  if(scroll)assert.equal(result.after,result.anchor,'the original text anchor survives the merged reflow');
  assert.equal(result.wasVisible,true);assert.equal(result.isVisible,true,'the requested paragraph stays visible after merged reflow');
 }
 // Burst mode changes must leave a usable final navigator and settle all callers.
 await page.evaluate(()=>Promise.all([StillleafReader.setPreferences({scroll:true}),StillleafReader.setPreferences({scroll:false}),StillleafReader.setPreferences({scroll:true,fontSize:1.1})]));
 assert.equal(await page.locator('#reader.continuous-reader').count(),1);
 assert.equal(await page.evaluate(()=>StillleafReader.exportState().preferences.fontSize),1.1);
});
