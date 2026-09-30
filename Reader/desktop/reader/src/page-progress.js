/** Screen pages for one laid-out chapter, never a spine ordinal or printed-page claim. */
export function screenPages({extent,viewport,offset=0,columns=1}){
 if(!(extent>0)||!(viewport>0))return null;
 columns=columns===2?2:1;
 const pageSize=viewport/columns,total=Math.max(1,Math.ceil(extent/pageSize-1e-6));
 const first=Math.min(total,Math.max(1,Math.floor(Math.max(0,offset)/pageSize+1e-6)+1));
 return {first,last:Math.min(total,first+columns-1),total};
}
export function pageLabel(pages){
 if(!pages)return 'Calculating pages…';
 return pages.last>pages.first?`Pages ${pages.first}–${pages.last} of ${pages.total}`:`Page ${pages.first} of ${pages.total}`;
}

// Reference pages use fixed text units, with at least one page for covers and
// illustrations. They are independent of fonts, viewport size and loading order.
export function bookPages({counts,chapter,lower,upper,progression=0,atEnd=false}){
 if(!counts||chapter<0||chapter>=counts.length)return null;
 const totals=counts.map(count=>Math.max(1,Math.ceil(count/1024)));
 const before=totals.slice(0,chapter).reduce((a,b)=>a+b,0),total=totals.reduce((a,b)=>a+b,0);
 const offset=Number.isFinite(lower)?lower:Math.max(0,Math.min(1,progression))*counts[chapter];
 const first=before+Math.min(totals[chapter],Math.floor(Math.max(0,offset)/1024)+1);
 const trailing=atEnd?counts[chapter]:Number.isFinite(upper)?upper:offset+1;
 const last=Math.max(first,before+Math.min(totals[chapter],Math.max(1,Math.ceil(trailing/1024))));
 return {first,last,total,remaining:before+totals[chapter]-last};
}
export function chapterPagesLeft({extent,viewport,offset=0,columns=1}){
 if(!(extent>0)||!(viewport>0))return null;
 return Math.max(0,Math.ceil((extent-Math.max(0,offset)-viewport)/(viewport/(columns===2?2:1))-1e-6));
}
