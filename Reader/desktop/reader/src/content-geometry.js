// Continuous chapter documents stay still inside their frames. Cache their text
// rectangles per layout; moving the outer scroll surface does not invalidate them.
const layouts=new WeakMap();
export function continuousTextCandidates(doc,revision,top,bottom){
 let layout=layouts.get(doc);
 if(!layout||layout.revision!==revision){
  const entries=[],walk=doc.createTreeWalker(doc.body,NodeFilter.SHOW_TEXT),range=doc.createRange();let node,offset=0;
  while((node=walk.nextNode())){
   if(node.parentElement?.closest('script,style'))continue;
   if(node.textContent.trim()){
    range.selectNodeContents(node);const rect=range.getBoundingClientRect();
    if(rect.width>0&&rect.height>0)entries.push({node,offset,top:rect.top,bottom:rect.bottom});
   }
   offset+=node.length;
  }
  entries.sort((a,b)=>a.top-b.top);let maximum=-Infinity;
  for(const entry of entries){maximum=Math.max(maximum,entry.bottom);entry.maximum=maximum;}
  layout={revision,entries};layouts.set(doc,layout);
 }
 const entries=layout.entries;let low=0,high=entries.length;
 // Prefix maxima handle overlapping/reordered publisher content safely.
 while(low<high){const middle=(low+high)>>>1;if(entries[middle].maximum>top)high=middle;else low=middle+1;}
 const candidates=[];
 for(let i=low;i<entries.length&&entries[i].top<bottom;i++)if(entries[i].bottom>top)candidates.push(entries[i]);
 return candidates.sort((a,b)=>a.offset-b.offset);
}
