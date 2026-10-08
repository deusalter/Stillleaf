import test from 'node:test';
import assert from 'node:assert/strict';
import {createServer} from 'node:http';
import {readFile} from 'node:fs/promises';
import path from 'node:path';
import {chromium,webkit} from 'playwright';

test('native host retains complete preferences, modal ownership and backwards-compatible reopen',{timeout:90000},async t=>{
 const root=path.resolve(import.meta.dirname,'../dist');
 const server=createServer(async(req,res)=>{try{const file=path.resolve(root,'.'+new URL(req.url,'http://localhost').pathname);if(!file.startsWith(root+path.sep))throw Error();res.setHeader('Content-Type',{'.html':'text/html','.js':'text/javascript','.css':'text/css'}[path.extname(file)]??'application/octet-stream');res.end(await readFile(file))}catch{res.writeHead(404).end()}});
 await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
 const engine=process.env.READER_TEST_BROWSER==='webkit'?webkit:chromium;
 let browser;
 t.after(async()=>{await browser?.close();server.closeAllConnections();server.close()});
 browser=await engine.launch({...engine===chromium?{executablePath:process.env.CHROME_PATH||(process.platform==='darwin'?'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome':undefined)}:{},headless:true});
 const page=await browser.newPage({viewport:{width:1000,height:800},reducedMotion:'reduce'});
 await page.goto(`http://127.0.0.1:${server.address().port}/index.html`);
 const chapter='<html><body><h1>Native fixture</h1>'+('<p>A quiet passage with room to read and return.</p>'.repeat(100))+'</body></html>';
 const book={editionId:'native-fixture',title:'Native fixture',readingOrder:[{href:'one.html',type:'text/html'}],resources:[{href:'one.html',type:'text/html',dataBase64:Buffer.from(chapter).toString('base64')}]};
 await page.evaluate(async book=>{window.events=[];window.addEventListener('stillleaf-reader-event',e=>events.push(e.detail));await StillleafReader.open(book)},book);
 const dispatch=(id,command,payload)=>page.evaluate(async request=>StillleafReader.nativeControl(request),{version:1,editionId:book.editionId,id,command,...(payload===undefined?{}:{payload})});
 const connected=await dispatch(1,'activate');
 assert.deepEqual(connected.definitions.map(x=>x.key).sort(),Object.keys(connected.preferences).sort());
 for(const definition of connected.definitions){
  if(definition.options)assert.equal(new Set(definition.options.map(option=>option.value)).size,definition.options.length,`${definition.key} has unique choices`);
 }
 assert.deepEqual(connected.definitions.filter(item=>item.kind==='color').map(item=>[item.key,item.label]),[['backgroundColor','Page color'],['textColor','Text color']]);
 assert.equal(await page.locator('.reader-bar').isVisible(),false);
 assert.equal(await page.locator('#next').isVisible(),false);
 await dispatch(2,'preferences',{fontSize:1.37,scroll:true,columns:'two',backgroundColor:'#f6f1e3'});
 const persisted=await page.evaluate(()=>StillleafReader.exportState());assert.equal(persisted.preferences.fontSize,1.37);assert.equal(persisted.preferences.scroll,true);
 assert.equal(persisted.preferences.theme,'custom');assert.ok(persisted.preferences.textColor,'complementary color is preserved');
 const pageColor=await page.evaluate(()=>{const f=[...document.querySelectorAll('#reader iframe')].find(f=>f.contentDocument?.body);return f.contentWindow.getComputedStyle(f.contentDocument.documentElement).backgroundColor});
 assert.equal(pageColor,'rgb(246, 241, 227)','native custom color affects the actual page');
 await dispatch(3,'notes');assert.equal(await page.locator('#library-panel').isVisible(),true);
 await assert.rejects(dispatch(4,'next'),/Finish the open/);
 await page.locator('#library-panel [data-close]').click();
 await dispatch(5,'policy',{reduceMotion:true,reduceTransparency:true,increaseContrast:true});
 assert.equal(await page.evaluate(()=>events.some(x=>x.type==='pageTurn')),false,'chrome and reflow do not manufacture turns');
 await page.emulateMedia({reducedMotion:'no-preference'});
 await dispatch(6,'preferences',{scroll:false,columns:'one'});
 await page.evaluate(()=>{window.slideAnimations=0;const original=Element.prototype.animate;Element.prototype.animate=function(...args){if(this.classList.contains('page-slide-track'))slideAnimations++;return original.apply(this,args)}});
 await dispatch(7,'next');assert.equal(await page.evaluate(()=>slideAnimations),0,'native Reduced Motion suppresses subsequent WAAPI slides independently of web media');
 // Native color wells display the effective pair; choosing a theme restores both colors.
 let nextRequest=8;
 for(const theme of ['white','dark']){
  const themed=await dispatch(nextRequest++,'preferences',{theme,backgroundColor:null,textColor:null});
  const colors=themed.effectiveAppearance;
  assert.ok(colors.backgroundColor&&colors.textColor);
  assert.notEqual(colors.backgroundColor.toLowerCase(),colors.textColor.toLowerCase());
  const custom=await dispatch(nextRequest++,'preferences',{textColor:colors.textColor});
  assert.deepEqual(custom.effectiveAppearance,colors,'enabling a custom text color keeps the current page pair');
  const customPage=await dispatch(nextRequest++,'preferences',{backgroundColor:colors.backgroundColor});
  assert.deepEqual(customPage.effectiveAppearance,colors,'a custom page color keeps the complementary text');
  await dispatch(nextRequest++,'preferences',{backgroundColor:'#403020',textColor:'#f0e0d0'});
  const restored=await dispatch(nextRequest++,'preferences',{theme});
  assert.deepEqual(restored.effectiveAppearance,colors,'choosing a page theme restores its full color pair despite saved custom colors');
 }
 await dispatch(nextRequest++,'preferences',{sideMargin:96});
 const preset=await dispatch(nextRequest++,'preferences',{margins:'narrow'});
 assert.equal(preset.preferences.sideMargin,null,'a named margin preset clears the custom gutter');
 const explicit=await dispatch(nextRequest++,'preferences',{margins:'wide',sideMargin:28});
 assert.equal(explicit.preferences.sideMargin,28,'an explicit custom gutter in the same patch remains intentional');
 await dispatch(nextRequest++,'deactivate');assert.equal(await page.locator('.reader-bar').isVisible(),true);
 await page.locator('#appearance').click();
 await page.locator('#reading-mode [aria-checked=true]').focus();await page.keyboard.press('Tab');
 const margins=page.getByRole('radiogroup',{name:'Margins',exact:true});
 assert.equal(await margins.getByRole('radio',{name:'Wide',exact:true}).evaluate(button=>document.activeElement===button),true,'custom spacing leaves the preset group reachable by Tab');
 assert.equal(await margins.getByRole('radio',{name:'Wide',exact:true}).getAttribute('aria-checked'),'false','custom spacing is not misrepresented as a selected preset');
 await page.keyboard.press('ArrowLeft');
 await page.waitForFunction(()=>StillleafReader.exportState().preferences.sideMargin===null);
 assert.equal(await margins.getByRole('radio',{name:'Normal',exact:true}).getAttribute('aria-checked'),'true','keyboard selection restores preset spacing');
 await page.keyboard.press('Escape');
 await page.evaluate(async book=>{await StillleafReader.close();await StillleafReader.open(book)},{...book,state:persisted});
 assert.equal(await page.locator('.reader-bar').isVisible(),true,'standalone reopen does not inherit host capability');
 const reopened=await page.evaluate(()=>StillleafReader.exportState());assert.deepEqual(reopened.preferences,persisted.preferences);assert.equal('nativeChrome' in reopened,false);
});
