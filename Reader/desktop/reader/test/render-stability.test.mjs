import {test} from 'node:test';
import assert from 'node:assert/strict';
import {createServer} from 'node:http';
import {readFile} from 'node:fs/promises';
import path from 'node:path';
import {chromium, webkit} from 'playwright';
const root=path.resolve(import.meta.dirname,'../dist');
async function setup(t, options={}){
 const server=createServer(async(req,res)=>{try{const file=path.resolve(root,'.'+new URL(req.url,'http://localhost').pathname);if(!file.startsWith(root+path.sep))throw Error();res.setHeader('Content-Type',{'.html':'text/html','.js':'text/javascript','.css':'text/css'}[path.extname(file)]??'application/octet-stream');res.end(await readFile(file))}catch{res.writeHead(404).end()}});
 await new Promise(r=>server.listen(0,'127.0.0.1',r));
 const browser=process.env.READER_TEST_BROWSER==='webkit'?await webkit.launch():await chromium.launch({executablePath:process.env.CHROME_PATH||'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',headless:true});
 t.after(async()=>{await browser.close();await new Promise(r=>server.close(r))});
 const page=await browser.newPage({viewport:{width:options.width??1000,height:800},reducedMotion:'no-preference'});
 await page.goto(`http://127.0.0.1:${server.address().port}/index.html`);
 const prose='The ferry crossed slowly while the gulls kept pace with the wake. She rested the book on her knees and watched the light change on the opposite bank.';
 let html=`<html xmlns="http://www.w3.org/1999/xhtml" dir="${options.rtl?'rtl':'ltr'}"><head><style>a{color:blue;text-decoration:underline}</style></head><body><a id="page-start"/><a name="named"/><h1>Chapter</h1><p id="intro">Ordinary prose.</p>${Array.from({length:50},(_,i)=>`<p id="p${i}">${prose}</p>`).join('')}<p><a id="link" href="#page-start">Return</a></p></body></html>`;
 if(options.html)html=html.replaceAll(/<a (id="page-start"|name="named")\/>/g,'<a $1></a>');
 if(options.malformed)html=html.replace('</body>','').replaceAll(/<a (id="page-start"|name="named")\/>/g,'<a $1></a>');
 if(options.svg)html=html.replace('<h1>', '<svg xmlns="http://www.w3.org/2000/svg"><image xmlns:xlink="http://www.w3.org/1999/xlink" xlink:href="cover.png"/></svg><h1>');
 const book={editionId:'render-stability',title:'Stable pages',contentProgress:true,readingProgression:options.rtl?'rtl':'ltr',readingOrder:[{href:'c.html',type:'text/html'}],resources:[{href:'c.html',type:options.html?'text/html':'application/xhtml+xml',dataBase64:Buffer.from(html).toString('base64')}]};
 if(options.svg)book.resources.push({href:'cover.png',type:'image/png',dataBase64:'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=='});
 await page.evaluate(()=>{window.positions=[];window.addEventListener('stillleaf-reader-event',e=>{if(e.detail.type==='position')window.positions.push(e.detail.position)})});
 await page.evaluate(book=>window.StillleafReader.open(book),book);
 await page.evaluate(options=>window.StillleafReader.setPreferences({theme:'original',fontFamily:'literata',fontSize:1.3,...options}),options);
 await page.waitForTimeout(300);
 return page;
}
for(const options of [{},{html:true},{malformed:true},{svg:true}])
test('destination anchors retain prose styling '+JSON.stringify(options),{timeout:30000},async t=>{
 const page=await setup(t,options);
 if(options.svg)await page.waitForFunction(()=>[...document.querySelectorAll('#reader iframe')].some(f=>f.contentDocument?.querySelector('img')?.naturalWidth===1));
 const result=await page.evaluate(()=>{const f=[...document.querySelectorAll('#reader iframe')].find(f=>getComputedStyle(f).visibility!=='hidden'),d=f.contentDocument,w=f.contentWindow;return Object.fromEntries(['#intro','#link','body'].map(s=>{const c=w.getComputedStyle(d.querySelector(s));return [s,{color:c.color,decoration:c.textDecorationLine}]}))});
 t.diagnostic(JSON.stringify(result));assert.equal(await page.evaluate(()=>[...document.querySelectorAll('#reader iframe')].find(f=>getComputedStyle(f).visibility!=='hidden').contentDocument.querySelector('#intro').closest('a')?.id??null),null,'destination must not wrap prose');assert.equal(result['#intro'].color,result.body.color);assert.equal(result['#intro'].decoration,'none');assert.notEqual(result['#link'].color,result.body.color);assert.equal(result['#link'].decoration,'underline');
 const index=await page.evaluate(()=>{const d=[...document.querySelectorAll('#reader iframe')].find(f=>getComputedStyle(f).visibility!=='hidden').contentDocument;return {length:d.body.textContent.length,total:window.positions.at(-1).bookTotal,named:d.querySelector('a[name="named"]').textContent,target:d.getElementById('page-start').textContent}});assert.equal(index.total,index.length);assert.equal(index.named,'');assert.equal(index.target,'');
 await page.evaluate(()=>window.StillleafReader.go({href:'c.html',type:'text/html',locations:{progression:1}}));
 await page.evaluate(()=>[...document.querySelectorAll('#reader iframe')].find(f=>getComputedStyle(f).visibility!=='hidden').contentDocument.getElementById('link').click());
 await page.waitForFunction(()=>window.positions.at(-1)?.page===1);
 assert.equal(await page.evaluate(()=>window.positions.at(-1).page),1,'internal link reaches named destination');
});
for(const options of [{fontFamily:'sans'},{fontFamily:'literata'},{fontFamily:'literata',width:1300,columns:'two'},{fontFamily:'sans',rtl:true}])
test('incoming slide geometry matches live page '+JSON.stringify(options),{timeout:30000},async t=>{
 const page=await setup(t,options);
 await page.evaluate(()=>{window.turn=window.StillleafReader.next()});
 await page.waitForFunction(()=>document.querySelector('.page-slide-track')?.getAnimations().some(a=>a.playState==='running'));
 const result=await page.evaluate(()=>{
  const a=document.querySelector('.page-slide-track').getAnimations()[0];a.pause();a.currentTime=a.effect.getTiming().duration;
  const live=[...document.querySelectorAll('#reader iframe')].find(f=>getComputedStyle(f).visibility!=='hidden'),copy=[...document.querySelectorAll('.page-slide-snapshot')].at(-1);
  const measure=f=>{const d=f.contentDocument,w=f.contentWindow;const host=f.getBoundingClientRect();return {host:{x:host.x,y:host.y},mode:d.compatMode,width:f.clientWidth,height:f.clientHeight,x:w.scrollX,rects:[...d.querySelectorAll('p')].slice(0,12).map(p=>{const r=p.getBoundingClientRect();return {x:r.x,y:r.y,width:r.width,height:r.height}})}};
  window.stableGeometry=()=>measure(live);return {live:measure(live),copy:measure(copy)};
 });
 t.diagnostic(JSON.stringify({live:result.live.host,copy:result.copy.host,mode:result.copy.mode}));
 await page.evaluate(()=>document.querySelector('.page-slide-track').getAnimations()[0].finish());await page.evaluate(()=>window.turn);
 assert.ok(Math.abs(result.copy.host.x-result.live.host.x)<1&&Math.abs(result.copy.host.y-result.live.host.y)<1,'snapshot lands on the live frame');
 delete result.copy.host;delete result.live.host;assert.deepEqual(result.copy,result.live);
 await page.waitForTimeout(150);const revealed=await page.evaluate(()=>window.stableGeometry());delete revealed.host;assert.deepEqual(revealed,result.live,'text remains stable after revealing live page');
});
