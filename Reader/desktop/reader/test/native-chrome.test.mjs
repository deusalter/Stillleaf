import test from 'node:test';
import assert from 'node:assert/strict';
import {nativeChromeAdapter} from '../src/native-chrome.js';

test('native commands negotiate one owner and reject stale or malformed requests',async()=>{
 let ready=true,visible=false,prefs={fontSize:1.2,scroll:false},calls=[],events=[];
 const adapter=nativeChromeAdapter({edition:()=> 'fixture',ready:()=>ready,current:()=>prefs,definitions:()=>[],visibility:v=>visible=v,perform:async(c,p)=>{calls.push(c);if(c==='preferences')prefs={...prefs,...p}}});
 const request=(id,command,payload)=>({version:1,editionId:'fixture',id,command,...(payload===undefined?{}:{payload})});
 await assert.rejects(adapter.dispatch(request(1,'next')));
 const connected=await adapter.dispatch(request(2,'activate'));assert.equal(connected.requestId,2);assert.equal(visible,true);
 await assert.rejects(adapter.dispatch(request(2,'next')));
 await assert.rejects(adapter.dispatch({...request(3,'next'),editionId:'other'}));
 await assert.rejects(adapter.dispatch(request(3,'preferences',{fontSize:Infinity})));
 await assert.rejects(adapter.dispatch(request(3,'preferences',{annotations:[]})));
 await assert.rejects(adapter.dispatch(request(3,'next',{extra:true})));
 await adapter.dispatch(request(3,'preferences',{fontSize:1.5}));assert.equal(prefs.fontSize,1.5);
 adapter.changed(v=>events.push(v));adapter.changed(v=>events.push(v));assert.equal(events.length,1);assert.equal('position' in events[0],false);
 ready=false;await assert.rejects(adapter.dispatch(request(4,'next')));assert.deepEqual(calls,['preferences']);
 adapter.disconnect();assert.equal(visible,false);
});

test('timed-out and cancelled activation restore web ownership despite late completion',async()=>{
 let visible=false,release;
 const pending=new Promise(resolve=>release=resolve);
 const adapter=nativeChromeAdapter({edition:()=> 'fixture',ready:()=>true,current:()=>({}),definitions:()=>[],activationTimeoutMs:20,visibility:(v)=>{visible=v;return v?pending:undefined},perform:()=>{}});
 const request=(id,command)=>({version:1,editionId:'fixture',id,command});
 const activation=adapter.dispatch(request(1,'activate'));
 assert.equal(visible,true);
 await assert.rejects(activation,/timed out/);assert.equal(visible,false);
 await adapter.dispatch(request(2,'deactivate'));release();await Promise.resolve();assert.equal(visible,false);
 await assert.rejects(adapter.dispatch(request(3,'next')),/not connected/);
});

test('panel commands carry rows back and reject malformed payloads', async () => {
  const calls = [];
  const adapter = nativeChromeAdapter({edition: () => 'fixture', ready: () => true, current: () => ({}), definitions: () => [], visibility: () => {},
    perform: async (command, payload) => {
      calls.push([command, payload]);
      if (command === 'panel') return {panel: {name: payload.name, rows: [{id: 'o0', title: 'Prologue'}]}};
      if (command === 'find') return {panel: {name: 'search', query: payload.query, rows: []}};
      if (command === 'remove') return {panel: {name: payload.kind === 'bookmark' ? 'bookmarks' : 'notes', rows: []}};
      return {panel: {name: 'must not leak'}};
    }});
  let id = 0;
  const send = (command, payload) => adapter.dispatch({version: 1, editionId: 'fixture', id: ++id, command, ...(payload === undefined ? {} : {payload})});
  await send('activate');
  assert.deepEqual((await send('panel', {name: 'outline'})).panel, {name: 'outline', rows: [{id: 'o0', title: 'Prologue'}]});
  assert.equal((await send('panel', {name: 'bookmarks'})).panel.name, 'bookmarks');
  assert.equal((await send('panel', {name: 'notes'})).panel.name, 'notes');
  assert.equal((await send('find', {query: 'light'})).panel.query, 'light');
  assert.equal((await send('remove', {kind: 'bookmark', id: 'b1'})).panel.name, 'bookmarks');
  assert.equal('panel' in await send('go', {kind: 'outline', id: 'o0'}), false, 'navigation returns state, not rows');
  assert.equal('panel' in await send('editNote', {id: 'n1'}), false);
  assert.equal('panel' in await send('bookmark'), false, 'other commands never return rows');
  const bad = [['panel'], ['panel', {name: 'secrets'}], ['panel', {name: 'outline', extra: 1}], ['find', {query: 3}], ['find', {query: 'x'.repeat(201)}], ['find', {}],
    ['go', {id: 'o0'}], ['go', {kind: 'chapter', id: 'o0'}], ['go', {kind: 'outline'}], ['go', {kind: 'outline', id: 'x'.repeat(201)}],
    ['remove', {kind: 'result', id: 'r0'}], ['remove', {kind: 'note'}], ['editNote'], ['editNote', {id: 7}], ['editNote', {id: 'n1', extra: true}]];
  const before = calls.length;
  for (const [command, payload] of bad) await assert.rejects(send(command, payload), /Reader control request|Invalid/, command + ' ' + JSON.stringify(payload));
  assert.equal(calls.length, before, 'a rejected request never reaches the renderer');
});
