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
