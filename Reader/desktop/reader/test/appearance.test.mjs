import {test} from 'node:test';
import assert from 'node:assert/strict';
import {createServer} from 'node:http';
import {readFile,mkdir} from 'node:fs/promises';
import path from 'node:path';
import {chromium} from 'playwright';
import {THEMES} from '../src/appearance.js';

// Page themes, typefaces and margins, measured inside the rendered book frame.
const root=path.resolve(import.meta.dirname,'../dist');
const artifacts=path.resolve(import.meta.dirname,'../artifacts');
const pixel='iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';
const prose='The lamps were lit along the harbour wall, and the boats came in one by one with the evening tide.';
const chapter=`<!doctype html><html lang="en"><head><title>Harbour</title></head><body><h1>The harbour at dusk</h1><p id="first">${prose}</p><img id="plate" src="plate.png" alt="" style="width:40px;height:40px">${Array.from({length:20},()=>`<p>${prose}</p>`).join('')}</body></html>`;
const book={editionId:'appearance-fixture',title:'Harbour Lights',creators:['M. Tide'],language:'en',
 readingOrder:[{href:'one.html',type:'text/html'}],
 resources:[{href:'one.html',type:'text/html',dataBase64:Buffer.from(chapter).toString('base64')},{href:'plate.png',type:'image/png',dataBase64:pixel}]};
const themes={original:'rgb(255, 255, 255)',paper:'rgb(240, 247, 243)',sepia:'rgb(246, 241, 227)',calm:'rgb(238, 226, 204)',focus:'rgb(255, 251, 239)',quiet:'rgb(74, 74, 78)',dark:'rgb(28, 48, 45)',night:'rgb(13, 13, 14)'};
const labels={original:'Original',paper:'Stillleaf',sepia:'Warm',calm:'Calm',focus:'Focus',quiet:'Quiet',dark:'Dark',night:'Night'};

test('themes, typefaces and margins apply to the page and persist',{timeout:120000},async t=>{
 const server=createServer(async(req,res)=>{try{const file=path.resolve(root,'.'+new URL(req.url,'http://localhost').pathname);if(!file.startsWith(root+path.sep))throw Error();res.setHeader('Content-Type',{'.html':'text/html','.js':'text/javascript','.css':'text/css'}[path.extname(file)]??'application/octet-stream');res.end(await readFile(file))}catch{res.writeHead(404).end()}});
 await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));const origin=`http://127.0.0.1:${server.address().port}`;
 const browser=await chromium.launch({executablePath:process.env.CHROME_PATH||(process.platform==='darwin'?'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome':undefined),headless:true});
 t.after(async()=>{await browser.close();await new Promise(resolve=>server.close(resolve))});
 const page=await browser.newPage({viewport:{width:1100,height:820},reducedMotion:'reduce',colorScheme:'light'});
 const errors=[];page.on('pageerror',e=>errors.push(e.message));
 await page.goto(origin+'/index.html');await page.waitForFunction(()=>Boolean(window.StillleafReader));
 await page.evaluate(input=>window.StillleafReader.open(input),book);
 await page.waitForFunction(()=>[...document.querySelectorAll('#reader iframe')].some(f=>f.contentDocument?.getElementById('first')));
 const frame=()=>page.evaluate(()=>{
  const f=[...document.querySelectorAll('#reader iframe')].find(f=>f.contentDocument?.getElementById('first'));const w=f.contentWindow,d=f.contentDocument;
  return {background:w.getComputedStyle(d.documentElement).backgroundColor,font:w.getComputedStyle(d.getElementById('first')).fontFamily,imageFilter:w.getComputedStyle(d.getElementById('plate')).filter,
   chrome:getComputedStyle(document.documentElement).getPropertyValue('--paper').trim(),theme:document.documentElement.dataset.theme,inset:parseFloat(getComputedStyle(document.getElementById('reading-viewport')).marginTop),
   width:parseFloat(getComputedStyle(document.documentElement).getPropertyValue('--reading-width')),prefs:window.StillleafReader.exportState().preferences};
 });
 const settle=()=>page.waitForTimeout(250);

 // System follows the Mac appearance.
 assert.equal((await frame()).theme,'paper');
 // Wait for the switch itself: a fixed pause lost the race on a slow runner.
 const themed=theme=>page.waitForFunction(theme=>document.documentElement.dataset.theme===theme,theme,{timeout:5000});
 await page.emulateMedia({colorScheme:'dark'});await themed('dark');assert.equal((await frame()).theme,'dark');
 await page.emulateMedia({colorScheme:'light'});await themed('paper');

 await page.getByRole('button',{name:'Appearance',exact:true}).click();
 assert.equal(await page.locator('#theme-options button').count(),THEMES.length+1,'Every page theme plus System');
 for(const [id,background]of Object.entries(themes)){
  await page.getByRole('button',{name:labels[id],exact:true}).click();await settle();
  const state=await frame();
  assert.equal(state.theme,id);assert.equal(state.prefs.theme,id);
  assert.equal(state.background,background,id+' page colour in the book frame');
  assert.equal(state.chrome.toLowerCase(),'#'+background.match(/\d+/g).map(n=>Number(n).toString(16).padStart(2,'0')).join(''),id+' reader chrome follows the page');
  assert.equal(await page.getByRole('button',{name:labels[id],exact:true}).getAttribute('aria-pressed'),'true');
  if(id==='night')assert.match(state.imageFilter,/brightness/,'Night dims illustrations');
  else assert.equal(state.imageFilter,'none',id+' leaves illustrations untouched');
 }
 await mkdir(artifacts,{recursive:true});await page.screenshot({path:path.join(artifacts,'appearance-night.png')});

 // Typefaces: always-available faces are listed; missing ones are not offered.
 const offered=await page.locator('#font-options [role=radio]').evaluateAll(buttons=>buttons.map(b=>b.dataset.font));
 assert.ok(offered.includes('publisher')&&offered.includes('sans'),offered.join());
 await page.getByRole('radio',{name:'San Francisco',exact:true}).click();await settle();
 let state=await frame();assert.equal(state.prefs.fontFamily,'sans');assert.match(state.font,/system-ui/);
 assert.equal(await page.getByRole('radio',{name:'San Francisco',exact:true}).getAttribute('aria-checked'),'true');
 assert.equal(await page.evaluate(()=>document.activeElement?.dataset.font),'sans','focus stays on the chosen typeface');
 const sansWidth=state.width;
 await page.evaluate(()=>window.StillleafReader.setPreferences({fontFamily:'athelas'}));await settle();
 state=await frame();assert.match(state.font,/Athelas/);
 const athelas=page.getByRole('radio',{name:'Athelas',exact:true});
 assert.equal(await athelas.getAttribute('aria-checked'),'true','a saved typeface stays visible even when it is not installed here');
 await page.getByRole('radio',{name:'Original',exact:true}).click();await settle();
 state=await frame();assert.equal(state.prefs.fontFamily,'publisher');
 if(!offered.includes('athelas'))assert.equal(await athelas.count(),0,'an uninstalled typeface disappears once deselected');
 assert.ok(sansWidth>200&&Number.isFinite(state.width),JSON.stringify({sansWidth,width:state.width}));

 // Margins: page inset and gutter widen together; arrow keys move the choice.
 assert.equal(state.inset,32);const normalWidth=state.width;
 await page.getByRole('radio',{name:'Wide',exact:true}).click();await settle();
 state=await frame();assert.equal(state.prefs.margins,'wide');assert.equal(state.inset,48);assert.ok(state.width>normalWidth,'wider gutters widen the page');
 await page.getByRole('radio',{name:'Wide',exact:true}).focus();await page.keyboard.press('ArrowRight');await settle();
 state=await frame();assert.equal(state.prefs.margins,'narrow','arrow keys wrap to the first margin');assert.equal(state.inset,16);assert.ok(state.width<normalWidth);
 // Delay resize work beyond the old fixed pause; wait for the actual compact inset.
 await page.evaluate(()=>{window.originalTimeout=window.setTimeout;window.setTimeout=(callback,delay,...args)=>window.originalTimeout(callback,delay===100?600:delay,...args)});
 await page.setViewportSize({width:520,height:800});await page.waitForFunction(()=>parseFloat(getComputedStyle(document.getElementById('reading-viewport')).marginTop)===12);await page.evaluate(()=>{window.setTimeout=window.originalTimeout});assert.equal((await frame()).inset,12,'compact windows use the compact narrow inset');
 await page.setViewportSize({width:1100,height:820});await page.waitForFunction(()=>parseFloat(getComputedStyle(document.getElementById('reading-viewport')).marginTop)===16);

 // Everything survives a reopen.
 await page.getByRole('button',{name:'Night',exact:true}).click();await settle();
 const saved=await page.evaluate(()=>window.StillleafReader.exportState());
 assert.deepEqual({theme:saved.preferences.theme,margins:saved.preferences.margins,fontFamily:saved.preferences.fontFamily},{theme:'night',margins:'narrow',fontFamily:'publisher'});
 await page.keyboard.press('Escape');
 await page.evaluate(input=>window.StillleafReader.open(input),{...book,state:saved});
 await page.waitForFunction(()=>[...document.querySelectorAll('#reader iframe')].some(f=>f.contentDocument?.getElementById('first')));await settle();
 state=await frame();assert.equal(state.theme,'night');assert.equal(state.background,themes.night);assert.equal(state.inset,16);
 // Unknown values from a future version fall back instead of breaking the book.
 await page.evaluate(input=>window.StillleafReader.open(input),{...book,state:{...saved,preferences:{...saved.preferences,theme:'aurora',fontFamily:'comic',margins:'huge'}}});
 const fallback=await page.evaluate(()=>window.StillleafReader.exportState().preferences);
 assert.deepEqual({theme:fallback.theme,fontFamily:fallback.fontFamily,margins:fallback.margins},{theme:'system',fontFamily:'publisher',margins:'normal'});
 // Bundled font bytes must render inside the publication, survive navigation/reopen,
 // and coexist with the older saved theme/margin IDs.
 await page.evaluate(()=>window.StillleafReader.setPreferences({fontFamily:'literata',theme:'custom',backgroundColor:'#162530',textColor:'#F2E6CB',contentWidth:80,sideMargin:18}));
 await page.waitForFunction(()=>[...document.querySelectorAll('#reader iframe')].some(f=>f.contentDocument&&[...f.contentDocument.fonts].some(face=>face.family.includes('Stillleaf Literata')&&face.status==='loaded')));
 await page.waitForFunction(()=>[...document.querySelectorAll('#reader iframe')].some(f=>f.contentDocument?.getElementById('first')&&f.contentWindow.getComputedStyle(f.contentDocument.documentElement).backgroundColor==='rgb(22, 37, 48)'),null,{timeout:5000});
 const custom=await frame();assert.equal(custom.background,'rgb(22, 37, 48)');assert.match(custom.font,/Stillleaf Literata/);
 const customState=await page.evaluate(()=>window.StillleafReader.exportState());
 await page.evaluate(input=>window.StillleafReader.open(input),{...book,state:customState});
 assert.deepEqual(await page.evaluate(()=>window.StillleafReader.exportState().preferences),customState.preferences);
 await page.getByRole('button',{name:'Focus reading',exact:true}).click();
 await page.waitForFunction(()=>document.documentElement.classList.contains('immersive'));
 assert.equal(await page.locator('.reader-bar').isVisible(),false);
 await page.getByRole('button',{name:'Show reading controls',exact:true}).click();
 await page.waitForFunction(()=>!document.documentElement.classList.contains('immersive'));
 await page.getByRole('button',{name:'Appearance',exact:true}).click();
 await page.screenshot({path:path.join(artifacts,'appearance-integrated.png')});
 assert.deepEqual(errors,[]);
});
