import {test} from 'node:test';
import assert from 'node:assert/strict';
import {estimateCounts,StablePageCount,pageMapsFor} from '../src/page-estimate.js';

test('a complete measured map is exact and is never altered by the estimator',()=>{
 const best=estimateCounts({exact:[3,7,1],weights:[{text:9000,images:0},{text:1,images:0},{text:0,images:0}]});
 assert.deepEqual(best,{counts:[3,7,1],exact:true});
});

test('another layout of the same book is rescaled by the chapters measured in both',()=>{
 // Larger type: the measured chapter grew from 20 to 30 screens, so the others grow alike. Covers keep one page.
 const best=estimateCounts({exact:[null,30,null,null],references:[[1,20,40,10]]});
 assert.equal(best.exact,false);
 assert.equal(best.counts[1],30,'measured chapters are kept exactly');
 assert.equal(best.counts[0],1,'a one-screen cover stays one screen');
 assert.ok(Math.abs(best.counts[2]-60)<=1&&Math.abs(best.counts[3]-15)<=1,JSON.stringify(best.counts));
});

test('a tiny measured sample does not rescale a reference; the text model calibrates instead',()=>{
 const weights=[{text:0,images:1},{text:20000,images:0},{text:40000,images:2}];
 const best=estimateCounts({exact:[1,null,null],references:[[1,10,22]],weights});
 // One cover page says nothing about the new type size, so the reference is not used and the text model has no text sample.
 assert.equal(best,null);
 const calibrated=estimateCounts({exact:[1,null,null],references:[[1,10,22]],weights,density:10.5/20000});
 assert.deepEqual(calibrated.counts.slice(0,2),[1,11]);
 assert.ok(calibrated.counts[2]>=21&&calibrated.counts[2]<=23,'images add part of a screen each');
});

test('text weights calibrated on measured chapters estimate unmeasured ones',()=>{
 const weights=[{text:30000,images:0},{text:60000,images:0},{text:15000,images:1},{text:0,images:0}];
 const best=estimateCounts({exact:[12,null,null,null],weights});
 assert.equal(best.exact,false);
 assert.equal(best.counts[0],12);
 assert.ok(Math.abs(best.counts[1]-24)<=1,String(best.counts[1]));
 assert.ok(best.counts[2]>=6&&best.counts[2]<=8,String(best.counts[2]));
 assert.equal(best.counts[3],1,'an empty chapter still occupies one screen');
});

test('a one-screen title page does not calibrate the text model',()=>{
 const weights=[{text:50,images:0},{text:3000,images:0}];
 assert.equal(estimateCounts({exact:[1,null],weights}),null);
 assert.deepEqual(estimateCounts({exact:[1,null],weights,density:()=>1/1500}).counts,[1,2],'the geometric density is used instead, and only when needed');
});

test('host page maps are accepted only for this book shape and bounded',()=>{
 const good={key:'{"edition":"e"}',counts:[1,2,3]};
 assert.deepEqual(pageMapsFor([good,{key:'x',counts:[1,2]},{key:'y',counts:[1,0,3]},{key:'z',counts:[1,2.5,3]},{key:7,counts:[1,2,3]},null],3),[good]);
 assert.deepEqual(pageMapsFor('nonsense',3),[]);
 assert.equal(pageMapsFor(Array.from({length:40},(_,i)=>({key:'k'+i,counts:[1,1,1]})),3).length,16);
 assert.deepEqual(pageMapsFor([{key:'a'.repeat(9000),counts:[1,2,3]}],3),[]);
});

test('a new layout waits briefly for its exact count, then shows the estimate and holds it',()=>{
 let now=0;const shown=new StablePageCount({hold:300,now:()=>now});
 const estimate={counts:[10,20,30],exact:false};
 assert.deepEqual(shown.show({key:'k',best:estimate,chapter:1,local:{first:5}}),{hold:300},'the footer keeps its previous page');
 now=120;assert.deepEqual(shown.show({key:'k',best:{counts:[11,20,30],exact:false},chapter:1,local:{first:5}}),{hold:180});
 now=200;assert.deepEqual(shown.show({key:'k',best:{counts:[11,20,31],exact:true},chapter:1,local:{first:5}}),{first:16,last:16,total:62,exact:true},'an exact count shows at once');
 now=0;const slow=new StablePageCount({hold:300,now:()=>now});slow.show({key:'k',best:estimate,chapter:1,local:{first:5}});
 now=300;assert.deepEqual(slow.show({key:'k',best:estimate,chapter:1,local:{first:5}}),{first:15,last:15,total:60,exact:false},'after the hold, the estimate');
 assert.equal(slow.show({key:'k',best:null,chapter:1,local:{first:5}}).total,60,'a missing estimate keeps the shown count');
});

test('the shown count only refines alongside a move in the same direction',()=>{
 let now=0;const shown=new StablePageCount({hold:0,now:()=>now});
 const estimate={counts:[11,20,30],exact:false},exact={counts:[12,20,31],exact:true};
 assert.deepEqual(shown.show({key:'k',best:estimate,chapter:1,local:{first:5}}),{first:16,last:16,total:61,exact:false});
 now=5000;
 assert.deepEqual(shown.show({key:'k',best:exact,chapter:1,local:{first:5}}),{first:16,last:16,total:61,exact:false},'no movement: nothing visibly changes');
 assert.deepEqual(shown.show({key:'k',best:exact,chapter:1,local:{first:6}}),{first:18,last:18,total:63,exact:true},'a forward turn carries the refinement');
 // A refinement that would make a forward turn go backwards waits for a later move.
 const later={counts:[2,20,31],exact:true};
 assert.deepEqual(shown.show({key:'k',best:later,chapter:1,local:{first:7}}),{first:19,last:19,total:63,exact:true});
 assert.deepEqual(shown.show({key:'k',best:later,chapter:1,local:{first:6}}),{first:8,last:8,total:53,exact:true},'a backward turn may carry a lower number');
 assert.deepEqual(shown.show({key:'other',best:estimate,chapter:1,local:{first:1}}),{first:12,last:12,total:61,exact:false},'a new layout shows its own count');
});

test('an identical refinement upgrades to exact without changing a number',()=>{
 let now=0;const shown=new StablePageCount({hold:0,now:()=>now});
 shown.show({key:'k',best:{counts:[4,4],exact:false},chapter:0,local:{first:1}});now=9000;
 assert.deepEqual(shown.show({key:'k',best:{counts:[4,4],exact:true},chapter:0,local:{first:1}}),{first:1,last:1,total:8,exact:true});
 shown.reset();assert.equal(shown.show({key:'k',best:null,chapter:0,local:{first:1}}),null);
});

test('a layout change keeps the previous page a little longer, until the estimate rests on enough measured screens',()=>{
 let now=0;const shown=new StablePageCount({hold:300,changeHold:900,enough:40,now:()=>now});
 shown.show({key:'old',best:{counts:[5,5],exact:true},chapter:0,local:{first:1}});
 assert.deepEqual(shown.show({key:'new',best:{counts:[7,7],exact:false,sample:7},chapter:0,local:{first:1}}),{hold:900});
 now=400;assert.deepEqual(shown.show({key:'new',best:{counts:[7,7],exact:false,sample:7},chapter:0,local:{first:1}}),{hold:500});
 assert.equal(shown.show({key:'new',best:{counts:[7,8],exact:false,sample:45},chapter:0,local:{first:1}}).total,15,'a well-founded estimate shows before the hold ends');
 const sample=estimateCounts({exact:[20,null],weights:[{text:2000,images:0},{text:2000,images:0}]});
 assert.equal(sample.sample,19.5);
 assert.equal(estimateCounts({exact:[null,30,null,null],references:[[1,20,40,10]]}).sample,30);
});

test('a chapter being measured again keeps its last count, so only the exact status changes',()=>{
 const best=estimateCounts({exact:[4,null,6],provisional:[undefined,5],weights:[{text:1,images:0},{text:1,images:0},{text:1,images:0}]});
 assert.deepEqual(best,{counts:[4,5,6],exact:false,sample:15});
 let now=0;const shown=new StablePageCount({hold:0,now:()=>now});
 shown.show({key:'k',best:{counts:[4,5,6],exact:true},chapter:1,local:{first:2}});
 assert.deepEqual(shown.show({key:'k',best,chapter:1,local:{first:3}}),{first:7,last:7,total:15,exact:false});
 assert.deepEqual(shown.show({key:'k',best:{counts:[4,5,6],exact:true},chapter:1,local:{first:3}}),{first:7,last:7,total:15,exact:true});
});

test('a move during the hold shows the new place at once',()=>{
 let now=0;const shown=new StablePageCount({hold:300,changeHold:900,enough:40,now:()=>now});
 shown.show({key:'old',best:{counts:[5,5],exact:true},chapter:0,local:{first:3}});
 const best={counts:[7,7],exact:false,sample:7};
 assert.deepEqual(shown.show({key:'new',best,chapter:0,local:{first:4}}),{hold:900});
 now=100;assert.deepEqual(shown.show({key:'new',best,chapter:1,local:{first:1}}),{first:8,last:8,total:14,exact:false});
});

test('a move within a chapter whose shown count is too small still carries the refinement',()=>{
 let now=0;const shown=new StablePageCount({hold:0,now:()=>now});
 // The chapter was one screen; an illustration settled and it is now eight. The reader turns from its first screen.
 shown.show({key:'k',best:{counts:[1,1],exact:true},chapter:0,local:{first:1}});
 assert.deepEqual(shown.show({key:'k',best:{counts:[8,1],exact:true},chapter:0,local:{first:1}}),{first:1,last:1,total:2,exact:true});
 assert.deepEqual(shown.show({key:'k',best:{counts:[8,1],exact:true},chapter:0,local:{first:2}}),{first:2,last:2,total:9,exact:true});
});
