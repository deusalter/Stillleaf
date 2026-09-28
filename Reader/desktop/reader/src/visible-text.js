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
  return {first: boundary(0, node.length, false), last: boundary(0, node.length, true)};
}
