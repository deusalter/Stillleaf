// Find exact visible character boundaries without measuring every character in
// a long paragraph. Range fragments preserve wrapped/bidirectional text geometry;
// a bounding box alone can bridge blank columns or a zero-width line-end
// fragment and an offscreen glyph in WebKit. Offsets are UTF-16, end-exclusive.
export function visibleTextBounds(node, visible) {
  const range = node.ownerDocument.createRange();
  const intersects = (start, end) => {
    range.setStart(node, start); range.setEnd(node, end);
    return [...range.getClientRects()].some(visible);
  };
  if (!node.length || !intersects(0, node.length)) return null;
  // Each recursive interval contains visible fragments. Search the preferred
  // half first; the other half contains the boundary when that half is empty.
  // Visibility need not be contiguous in text order (columns and bidi runs).
  const boundary = (start, end, trailing) => {
    if (end - start === 1) return trailing ? end : start;
    const middle = start + Math.floor((end - start) / 2);
    if (trailing) return intersects(middle, end)
      ? boundary(middle, end, true) : boundary(start, middle, true);
    return intersects(start, middle)
      ? boundary(start, middle, false) : boundary(middle, end, false);
  };
  const first=boundary(0,node.length,false);
  let last=boundary(0,node.length,true);
  // Chromium can omit a wrapped trailing space from a multi-character range
  // while its one-character fragment still occupies visible line-end width.
  // Refine only adjacent whitespace, keeping the offscreen search logarithmic.
  const limit=Math.min(node.length,last+32);
  while(last<limit&&/\s/u.test(node.textContent[last])&&intersects(last,last+1))last++;
  return {first,last};
}

// Appearance reflow retains the first fully contained glyph, rather than a
// partially clipped line. Narrow to intersecting fragments before inspecting
// individual glyphs; a long paragraph can begin thousands of characters offscreen.
export function firstFullyVisibleOffset(node,{width,height}){
 const candidates=visibleTextBounds(node,r=>r.right>=0&&r.left<width&&r.bottom>=0&&r.top<=height);
 if(!candidates)return null;
 const range=node.ownerDocument.createRange(),text=node.textContent;
 for(let i=candidates.first;i<candidates.last&&i<candidates.first+30000;i++){
  range.setStart(node,i);range.setEnd(node,i+1);const rect=range.getBoundingClientRect();
  if(rect.left>=0&&rect.left<width&&rect.top>=0&&rect.bottom<=height&&text.slice(i).trim())return i;
 }
 return null;
}
