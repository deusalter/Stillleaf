import {test} from 'node:test';
import assert from 'node:assert/strict';
import {chromium, webkit} from 'playwright';
import {visibleTextBounds} from '../src/visible-text.js';

test('visible text boundaries match exhaustive fragment scans with bounded layout queries', {timeout:120000}, async t => {
  const browser = process.env.READER_TEST_BROWSER === 'webkit' ? await webkit.launch({headless:true}) : await chromium.launch({executablePath:process.env.CHROME_PATH || (process.platform === 'darwin' ? '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome' : undefined), headless:true});
  t.after(() => browser.close());
  const page = await browser.newPage({viewport:{width:1000,height:800}});
  await page.setContent('<p style="width:500px;font:18px serif"></p>');
  await page.addScriptTag({content:visibleTextBounds.toString()});
  const results = await page.evaluate(() => {
    const results = [], p = document.querySelector('p');
    for (const scenario of [
      {name:'long paragraph', text:'The river moved slowly beneath the bridge. '.repeat(2000)},
      {name:'middle of paragraph', text:'The river moved slowly beneath the bridge. '.repeat(2000), scroll:9000},
      {name:'mixed direction', text:'Reading العربية עברית quietly. '.repeat(100), scroll:300},
      {name:'columns', text:'The river moved slowly beneath the bridge. '.repeat(100), columns:true},
      {name:'ligatures and graphemes', text:'office affinity e\u0301 👩🏽‍💻 العربية ffi '.repeat(100), scroll:300},
      {name:'whitespace only', text:' \n\t '.repeat(100)},
      {name:'preserved whitespace', text:'word \n\t '.repeat(100), css:'white-space:pre-wrap', scroll:300},
      {name:'clipped horizontal edge', text:'office e\u0301 👩🏽‍💻 '.repeat(100), css:'margin-left:-37px', scroll:300},
      {name:'offscreen', text:'No visible text', css:'margin-top:2000px'},
      {name:'webkit wrapped Unicode', text:'a\u0301e\u0308👩🏽‍💻😀𐐀 '.repeat(10), css:'font:24px Times;width:220px', right:220, bottom:80},
      {name:'webkit narrow Unicode', text:'a\u0301e\u0308👩🏽‍💻😀𐐀 '.repeat(10), css:'font:24px Times;width:220px', right:9, bottom:80},
      {name:'single character', text:'x'},
      {name:'empty', text:''},
      {name:'invisible', text:'No visible text', hidden:true}
    ]) {
      p.replaceChildren(document.createTextNode(scenario.text));
      p.style.cssText='width:500px;font:18px serif;' + (scenario.columns ? 'height:300px;columns:2;column-fill:auto;' : '') + (scenario.hidden ? 'display:none;' : '') + (scenario.css || '');
      scrollTo(scenario.columns ? 500 : 0,scenario.scroll || 0);
      const node=p.firstChild,range=document.createRange();
      const visible=r=>r.width>0&&r.height>0&&r.right>0&&r.left<(scenario.right ?? 500)&&r.bottom>0&&r.top<(scenario.bottom ?? 720);
      let first=null,last=null,baselineCalls=0;
      const start=performance.now();
      // Reproduce the old production whole-node check and scans from both ends.
      range.selectNodeContents(node); baselineCalls++;
      if ([...range.getClientRects()].some(visible)) {
        first=0; last=node.length;
        for(;first<node.length;first++) {
          range.setStart(node,first);range.setEnd(node,first+1);baselineCalls++;
          if(visible(range.getBoundingClientRect())) break;
        }
        for(;last>first;last--) {
          range.setStart(node,last-1);range.setEnd(node,last);baselineCalls++;
          if(visible(range.getBoundingClientRect())) break;
        }
        if(last<=first) first=last=null;
      }
      const baselineMS=performance.now()-start;
      const legacy=first===null?null:{first,last};
      // Ground truth uses actual fragments: bounding boxes can bridge blank space
      // between lines in WebKit when one fragment has zero width.
      first=last=null;
      for(let i=0;i<node.length;i++) {
        range.setStart(node,i);range.setEnd(node,i+1);
        if([...range.getClientRects()].some(visible)) {first??=i;last=i+1;}
      }
      const original=Range.prototype.getClientRects;let calls=0;
      Range.prototype.getClientRects=function(){calls++;return original.call(this)};
      const optimizedStart=performance.now();
      const actual=visibleTextBounds(node,visible);
      const optimizedMS=performance.now()-optimizedStart;
      Range.prototype.getClientRects=original;
      results.push({name:scenario.name,length:node.length,expected:first===null?null:{first,last},legacy,actual,calls,baselineCalls,baselineMS,optimizedMS});
    }
    return results;
  });
  results.forEach(result=>t.diagnostic(JSON.stringify(result)));
  for(const result of results) {
    assert.deepEqual(result.actual,result.expected,result.name+' preserves exact text coverage');
    assert.ok(result.calls<=65+2*Math.ceil(Math.log2(Math.max(1,result.length))),result.name+' requires logarithmic search plus bounded whitespace refinement at both ends');
  }
});
