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
