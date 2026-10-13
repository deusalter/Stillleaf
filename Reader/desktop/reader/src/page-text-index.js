// Text rectangles of a chapter frame in paged or Readium-scrolled layout, measured once per layout.
//
// Finding the text on screen used to walk every text node of the chapter on each page turn and ask the
// engine for its rectangles. The rectangles do not move between turns (only the scroll offset does), so
// they are kept per document in document coordinates and a turn looks up the few nodes that can be on
// screen by binary search. The lookup returns a superset: every node whose bounding box meets the window.
// Callers still run their exact per-fragment test on those nodes, so results are what the full walk gave.
const indexes = new WeakMap();
const revisions = new WeakMap();

/** Tells the index that the document's content or layout changed in a way its cheap fingerprint cannot see. */
export function touchTextIndex(doc) {
  revisions.set(doc, (revisions.get(doc) ?? 0) + 1);
}

function fingerprint(wnd, axis) {
  const doc = wnd.document, root = doc.documentElement, scroller = doc.scrollingElement;
  return [axis, wnd.innerWidth, wnd.innerHeight, scroller?.scrollWidth, scroller?.scrollHeight, root.getAttribute('style'), root.className,
    doc.body.getAttribute('style'), doc.body.className, doc.styleSheets.length, doc.head?.childElementCount, doc.body.childElementCount, revisions.get(doc) ?? 0].join('|');
}

function build(wnd, axis) {
  const doc = wnd.document, sx = wnd.scrollX, sy = wnd.scrollY;
  const entries = [], walk = doc.createTreeWalker(doc.body, NodeFilter.SHOW_TEXT), range = doc.createRange();
  let node, offset = 0;
  while ((node = walk.nextNode())) {
    if (node.parentElement?.closest('script,style')) continue;
    if (node.textContent.trim()) {
      range.selectNodeContents(node);
      const rect = range.getBoundingClientRect();
      if (rect.width > 0 && rect.height > 0) {
        const left = rect.left + sx, right = rect.right + sx, top = rect.top + sy, bottom = rect.bottom + sy;
        entries.push(axis === 'x' ? {node, offset, start: left, end: right} : {node, offset, start: top, end: bottom});
      }
    }
    offset += node.length;
  }
  entries.sort((a, b) => a.start - b.start);
  let maximum = -Infinity;
  for (const entry of entries) { maximum = Math.max(maximum, entry.end); entry.maximum = maximum; }
  return entries;
}

/**
 * Text nodes (with their offsets into the chapter's text) whose bounding box meets [from, to) along `axis`
 * ('x' for columns, 'y' for a scrolled chapter), in window coordinates, in document order.
 */
export function pageTextCandidates(wnd, axis, from, to) {
  const doc = wnd.document, print = fingerprint(wnd, axis);
  let index = indexes.get(doc);
  if (!index || index.print !== print) { index = {print, entries: build(wnd, axis)}; indexes.set(doc, index); }
  const scroll = axis === 'x' ? wnd.scrollX : wnd.scrollY, low0 = from + scroll, high0 = to + scroll, entries = index.entries;
  let low = 0, high = entries.length;
  // Prefix maxima handle overlapping or reordered publisher content.
  while (low < high) { const middle = (low + high) >>> 1; if (entries[middle].maximum > low0) high = middle; else low = middle + 1; }
  const candidates = [];
  for (let i = low; i < entries.length && entries[i].start < high0; i++) if (entries[i].end > low0) candidates.push(entries[i]);
  return candidates.sort((a, b) => a.offset - b.offset);
}
