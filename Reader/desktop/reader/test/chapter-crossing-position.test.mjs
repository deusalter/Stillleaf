import {test} from 'node:test';
import assert from 'node:assert/strict';
import {createServer} from 'node:http';
import {readFile} from 'node:fs/promises';
import path from 'node:path';
import {chromium} from 'playwright';

// Real books open on a cover or title page that is one page long. A forward turn there has no next page
// in its own chapter, so the host must be told about page 1 of the next chapter, and turning back must
// return to the cover. The native smoke relies on this contract.
const root=path.resolve(import.meta.dirname,'../dist');
const prose='The ferry crossed slowly while the gulls kept pace with the wake, and the reader turned another page of the long book on her knees.';
const cover='<!doctype html><html lang="en"><head><title>Cover</title></head><body><h1>Cover</h1></body></html>';
const chapter=`<!doctype html><html lang="en"><head><title>Crossing</title></head><body><h1>Crossing</h1>${Array.from({length:60},(_,i)=>`<p id="p${i}">${prose}</p>`).join('')}</body></html>`;
const book={editionId:'chapter-crossing',title:'Crossings',creators:['A. Ferry'],language:'en',
 readingOrder:[{href:'cover.html',type:'text/html',title:'Cover'},{href:'c1.html',type:'text/html',title:'Crossing'}],
 resources:[['cover.html',cover],['c1.html',chapter]].map(([href,html])=>({href,type:'text/html',dataBase64:Buffer.from(html).toString('base64')}))};

test('a turn from a one-page chapter reaches page 1 of the next chapter and back',{timeout:120000},async t=>{
 const server=createServer(async(req,res)=>{try{const file=path.resolve(root,'.'+new URL(req.url,'http://localhost').pathname);if(!file.startsWith(root+path.sep))throw Error();res.setHeader('Content-Type',{'.html':'text/html','.js':'text/javascript','.css':'text/css'}[path.extname(file)]??'application/octet-stream');res.end(await readFile(file))}catch{res.writeHead(404).end()}});
 await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));const origin=`http://127.0.0.1:${server.address().port}`;
 const browser=await chromium.launch({executablePath:process.env.CHROME_PATH||(process.platform==='darwin'?'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome':undefined),headless:true});
 t.after(async()=>{await browser.close();await new Promise(resolve=>server.close(resolve))});
 const page=await browser.newPage({viewport:{width:1000,height:800},reducedMotion:'reduce'});
 const errors=[];page.on('pageerror',e=>errors.push(e.message));
 await page.goto(origin+'/index.html');await page.waitForFunction(()=>Boolean(window.StillleafReader));
 await page.evaluate(()=>{window.positions=[];window.turns=[];window.addEventListener('stillleaf-reader-event',e=>{if(e.detail.type==='position')window.positions.push(e.detail.position);if(e.detail.type==='pageTurn')window.turns.push(e.detail)})});
 const at=(href,number)=>page.waitForFunction(([href,number])=>{const p=window.positions.at(-1);return p?.href===href&&p.page===number},[href,number],{timeout:8000});
 const settle=()=>page.waitForTimeout(900);
 await page.evaluate(input=>window.StillleafReader.open(input),book);await settle();
 await at('cover.html',1);
 const start=await page.evaluate(()=>window.positions.at(-1));
 assert.equal(start.totalPages,1,'the cover is a single page');

 await page.evaluate(()=>window.StillleafReader.next());
 await at('c1.html',1);
 const crossed=await page.evaluate(()=>({position:window.positions.at(-1),turns:window.turns}));
 assert.equal(crossed.turns.length,1);assert.equal(crossed.turns[0].direction,'forward');
 assert.equal(crossed.turns[0].departure.href,'cover.html','the turn departs from the cover');
 assert.ok(crossed.position.totalPages>1);

 await page.evaluate(()=>window.StillleafReader.previous());
 await at('cover.html',1);
 assert.deepEqual(errors,[]);
});
