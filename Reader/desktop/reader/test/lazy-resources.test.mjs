import {test} from 'node:test';
import assert from 'node:assert/strict';
import {createServer} from 'node:http';
import {readFile} from 'node:fs/promises';
import path from 'node:path';
import {chromium} from 'playwright';

// Host-served resources: the reader receives URLs and declared sizes, never the
// publication bytes, and fetches each resource only when a chapter needs it.
// Readium preloads the current chapter and two either side, so the late image
// sits in chapter six.
const root=path.resolve(import.meta.dirname,'../dist');
const pixel=Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==','base64');
const chapter=(title,body,head='')=>`<!doctype html><html lang="en"><head><title>${title}</title>${head}</head><body><h1>${title}</h1>${body}</body></html>`;
const book=[
 {href:'text/one.html',type:'application/xhtml+xml',body:chapter('First light','<p id="styled">Imported styles colour this line.</p><img id="figure" src="../images/one.png" alt="">','<link rel="stylesheet" href="../styles/book.css">')},
 {href:'text/two.html',type:'application/xhtml+xml',body:chapter('Second chapter','<p>Nothing to fetch here.</p>')},
 {href:'text/three.html',type:'application/xhtml+xml',body:chapter('Third chapter','<p>Still near the start.</p>')},
 {href:'text/four.html',type:'application/xhtml+xml',body:chapter('Fourth chapter','<p>Beyond the preload window.</p>')},
 {href:'text/five.html',type:'application/xhtml+xml',body:chapter('Fifth chapter','<p>Further still.</p>')},
 {href:'text/six.html',type:'application/xhtml+xml',body:chapter('','<div id="cover-page"><svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" viewBox="0 0 1 1" preserveAspectRatio="xMidYMid meet"><image width="1" height="1" xlink:href="../images/cover.png"/></svg></div><p>The lantern keeper counted every heron.</p><img id="late" src="../images/three.png" alt="">')},
 {href:'styles/book.css',type:'text/css',body:'@import "base.css"; #styled{background:url(../images/tile.png)}'},
 {href:'styles/base.css',type:'text/css',body:'#styled{border-left:7px solid black}'},
 {href:'images/one.png',type:'image/png',body:pixel},
 {href:'images/three.png',type:'image/png',body:pixel},
 {href:'images/tile.png',type:'image/png',body:pixel},
 {href:'images/unused.png',type:'image/png',body:pixel},
 {href:'images/vector.svg',type:'image/svg+xml',body:'<svg xmlns="http://www.w3.org/2000/svg"/>'},
 {href:'images/cover.png',type:'image/png',body:pixel}
].map((item,index)=>({...item,bytes:Buffer.isBuffer(item.body)?item.body:Buffer.from(item.body),index}));
function input(overrides={}){
 return {editionId:'lazy-fixture',title:'Lanterns',creators:['A. Keeper'],language:'en',
  readingOrder:book.filter(x=>x.href.startsWith('text/')).map(x=>({href:x.href,type:x.type})),
  resources:book.map(x=>({href:x.href,type:x.type,url:`/book/${x.index}`,size:x.bytes.length,...overrides[x.href]}))};
}

test('host-served resources load on demand and render',{timeout:90000},async t=>{
 const requested=[];
 const server=createServer(async(req,res)=>{
  const url=new URL(req.url,'http://localhost');
  const match=/^\/book\/(\d+)$/.exec(url.pathname);
  if(match){const item=book[Number(match[1])];requested.push(item.href);res.setHeader('Content-Type',item.type);return res.end(item.bytes)}
  try{const file=path.resolve(root,'.'+url.pathname);if(!file.startsWith(root+path.sep))throw Error();res.setHeader('Content-Type',{'.html':'text/html','.js':'text/javascript','.css':'text/css'}[path.extname(file)]??'application/octet-stream');res.end(await readFile(file))}catch{res.writeHead(404).end()}
 });
 await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));const origin=`http://127.0.0.1:${server.address().port}`;
 const browser=await chromium.launch({executablePath:process.env.CHROME_PATH||(process.platform==='darwin'?'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome':undefined),headless:true});
 t.after(async()=>{await browser.close();await new Promise(resolve=>server.close(resolve))});
 const page=await browser.newPage({viewport:{width:1000,height:800},reducedMotion:'reduce'});
 const errors=[],outbound=[];page.on('pageerror',e=>errors.push(e.message));
 await page.route('**/*',route=>{if(route.request().url().startsWith(origin+'/'))return route.continue();outbound.push(route.request().url());return route.abort()});
 await page.goto(origin+'/index.html');await page.waitForFunction(()=>Boolean(window.StillleafReader));
 const frameWith=selector=>page.waitForFunction(selector=>[...document.querySelectorAll('#reader iframe')].some(f=>f.contentDocument?.querySelector(selector)),selector);

 await page.evaluate(input=>window.StillleafReader.open(input),input());
 await frameWith('#figure');
 const first=await page.evaluate(()=>{
  const f=[...document.querySelectorAll('#reader iframe')].find(f=>f.contentDocument?.querySelector('#figure'));
  const d=f.contentDocument,styled=d.getElementById('styled'),image=d.getElementById('figure');
  return {src:image.getAttribute('src'),loaded:image.complete&&image.naturalWidth===1,border:f.contentWindow.getComputedStyle(styled).borderLeftWidth,background:f.contentWindow.getComputedStyle(styled).backgroundImage};
 });
 assert.match(first.src,/^blob:/);assert.ok(first.loaded,'chapter image decoded from fetched bytes');
 assert.ok(parseFloat(first.border)>5,'nested @import stylesheet applied: '+first.border);
 assert.match(first.background,/blob:/,'stylesheet url() rewritten to a fetched asset');
 for(const href of ['text/one.html','styles/book.css','styles/base.css','images/one.png','images/tile.png'])assert.ok(requested.includes(href),href+' fetched for the open chapter');
 for(const href of ['text/four.html','text/five.html','text/six.html','images/three.png','images/unused.png','images/vector.svg'])assert.ok(!requested.includes(href),href+' not fetched before it is needed: '+requested.join(', '));
 assert.equal(new Set(requested).size,requested.length,'each resource fetched at most once: '+requested.join(', '));

 await page.evaluate(()=>window.StillleafReader.go({href:'text/six.html',type:'text/html',locations:{progression:0}}));
 await frameWith('#late');
 assert.ok(requested.includes('images/three.png'),'later chapter image fetched on navigation');
 // Calibre-style SVG cover wrapper becomes a plain image instead of being stripped to a blank page.
 const cover=await page.evaluate(()=>{const d=[...document.querySelectorAll('#reader iframe')].map(f=>f.contentDocument).find(d=>d?.getElementById('cover-page'));const box=d.getElementById('cover-page');return {svg:Boolean(box.querySelector('svg')),src:box.querySelector('img')?.getAttribute('src')??''}});
 assert.equal(cover.svg,false);assert.match(cover.src,/^blob:/,'SVG-wrapped cover rendered as an image');
 assert.equal(await page.evaluate(()=>document.getElementById('chapter-label').title),'Chapter 6','untitled chapter falls back while its heading is empty');

 await page.getByRole('button',{name:'Search book',exact:true}).click();
 await page.getByRole('searchbox',{name:'Words or phrase'}).fill('heron');await page.locator('.result-link').waitFor();
 assert.equal(await page.locator('.result-link').count(),1);
 assert.ok(!requested.includes('images/unused.png')&&!requested.includes('images/vector.svg'),'search reads chapters without fetching unreferenced assets');
 assert.deepEqual(outbound,[]);assert.deepEqual(errors,[]);
});

test('a resource whose size changed on disk is refused without breaking the chapter',{timeout:60000},async t=>{
 const server=createServer(async(req,res)=>{
  const url=new URL(req.url,'http://localhost'),match=/^\/book\/(\d+)$/.exec(url.pathname);
  if(match){const item=book[Number(match[1])];res.setHeader('Content-Type',item.type);return res.end(item.bytes)}
  try{const file=path.resolve(root,'.'+url.pathname);if(!file.startsWith(root+path.sep))throw Error();res.setHeader('Content-Type',{'.html':'text/html','.js':'text/javascript','.css':'text/css'}[path.extname(file)]??'application/octet-stream');res.end(await readFile(file))}catch{res.writeHead(404).end()}
 });
 await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));const origin=`http://127.0.0.1:${server.address().port}`;
 const browser=await chromium.launch({executablePath:process.env.CHROME_PATH||(process.platform==='darwin'?'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome':undefined),headless:true});
 t.after(async()=>{await browser.close();await new Promise(resolve=>server.close(resolve))});
 const page=await browser.newPage({viewport:{width:1000,height:800},reducedMotion:'reduce'});
 await page.goto(origin+'/index.html');await page.waitForFunction(()=>Boolean(window.StillleafReader));
 const warnings=await page.evaluate(input=>new Promise(resolve=>{
  window.addEventListener('stillleaf-reader-event',e=>{if(e.detail.type==='ready')resolve(e.detail.warnings)});
  void window.StillleafReader.open(input);
 }),input({'images/one.png':{size:pixel.length+1}}));
 await page.waitForFunction(()=>[...document.querySelectorAll('#reader iframe')].some(f=>f.contentDocument?.getElementById('styled')));
 const image=await page.evaluate(()=>[...document.querySelectorAll('#reader iframe')].map(f=>f.contentDocument?.getElementById('figure')).find(Boolean)?.hasAttribute('src'));
 assert.equal(image,false,'mismatched image dropped');
 assert.ok(warnings.some(w=>w.includes('changed on disk')),JSON.stringify(warnings));
});
