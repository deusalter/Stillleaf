import {test} from 'node:test';
import assert from 'node:assert/strict';
import {chromium,webkit} from 'playwright';
import {visibleTextBounds,firstFullyVisibleOffset} from '../src/visible-text.js';

test('reflow anchors match a full glyph scan without scanning the offscreen paragraph prefix',{timeout:60000},async t=>{
 const browser=process.env.READER_TEST_BROWSER==='webkit'?await webkit.launch():await chromium.launch({executablePath:process.env.CHROME_PATH||(process.platform==='darwin'?'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome':undefined),headless:true});t.after(()=>browser.close());
 const page=await browser.newPage({viewport:{width:1000,height:800}});
 await page.setContent('<p></p>');await page.addScriptTag({content:visibleTextBounds.toString()+'\n'+firstFullyVisibleOffset.toString()});
 const results=await page.evaluate(()=>{
  const results=[],p=document.querySelector('p');
  for(const scenario of [
   {name:'deep long paragraph',text:Array.from({length:2800},(_,i)=>`${String(i).padStart(5,'0')} ferry `).join(''),scroll:9000},
   {name:'partial line and whitespace',text:'  the ferry\n  crossed the river '.repeat(200),scroll:301,css:'white-space:pre-wrap'},
   {name:'bidi and ligatures',text:'office affinity العربية עברית e\u0301 👩🏽‍💻 '.repeat(100),scroll:309},
   {name:'columns',text:'The ferry crossed slowly. '.repeat(300),css:'height:300px;columns:2;column-fill:auto',x:500},
   {name:'clipped left edge',text:'The river moved slowly. '.repeat(100),scroll:200,css:'margin-left:-37px'},
   {name:'only whitespace',text:' \t\n'.repeat(100)},
   {name:'offscreen',text:'No visible text',css:'margin-top:2000px'},
   {name:'empty',text:''}
  ]){
   p.style.cssText='width:500px;font:18px serif;'+(scenario.css??'');p.replaceChildren(document.createTextNode(scenario.text));scrollTo(scenario.x??0,scenario.scroll??0);
   const node=p.firstChild,range=document.createRange();let expected=null,baselineCalls=0;
   for(let i=0;i<node.length;i++){range.setStart(node,i);range.setEnd(node,i+1);const rect=range.getBoundingClientRect();baselineCalls++;if(rect.left>=0&&rect.left<500&&rect.top>=0&&rect.bottom<=720&&node.textContent.slice(i).trim()){expected=i;break}}
   const original=Range.prototype.getBoundingClientRect;let boundsCalls=0;Range.prototype.getBoundingClientRect=function(){boundsCalls++;return original.call(this)};
   const actual=firstFullyVisibleOffset(node,{width:500,height:720});Range.prototype.getBoundingClientRect=original;
   results.push({name:scenario.name,expected,actual,baselineCalls,boundsCalls});
  }return results;
 });
 for(const result of results){t.diagnostic(JSON.stringify(result));assert.equal(result.actual,result.expected,result.name);}
 const deep=results[0];assert.ok(deep.baselineCalls>10000);assert.ok(deep.boundsCalls<100,'only the visible candidate glyphs need individual rectangles');
});
