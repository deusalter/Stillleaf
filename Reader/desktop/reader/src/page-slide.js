// Presentation only: snapshots never join #reader, receive input, or emit locators.
// Readium continues to own live document layout, selection and navigation.
export const slideSign = (direction, rtl = false) => (direction === 'next' ? 1 : -1) * (rtl ? -1 : 1);
const paint = () => new Promise(resolve => requestAnimationFrame(resolve));

function corresponding(node, source, target) {
  const path = [];
  while (node && node !== source) {
    path.push(Array.prototype.indexOf.call(node.parentNode.childNodes, node));
    node = node.parentNode;
  }
  return node === source ? path.reverse().reduce((root, index) => root?.childNodes[index], target) : null;
}

function copyHighlights(source, target) {
  if (!source.defaultView.CSS?.highlights || !target.defaultView.CSS?.highlights) return;
  for (const [name, highlight] of source.defaultView.CSS.highlights) {
    const ranges = [];
    for (const range of highlight) {
      const start = corresponding(range.startContainer, source.documentElement, target.documentElement);
      const end = corresponding(range.endContainer, source.documentElement, target.documentElement);
      if (!start || !end) continue;
      const copy = target.createRange();
      copy.setStart(start, range.startOffset); copy.setEnd(end, range.endOffset); ranges.push(copy);
    }
    target.defaultView.CSS.highlights.set(name, new target.defaultView.Highlight(...ranges));
  }
}

async function snapshot(reader, track, offset) {
  const source = [...reader.querySelectorAll('iframe')].find(frame => getComputedStyle(frame).visibility !== 'hidden');
  if (!source?.contentDocument?.body) return null;
  const frame = document.createElement('iframe');
  frame.className = 'page-slide-snapshot';
  frame.setAttribute('sandbox', 'allow-same-origin');
  frame.setAttribute('aria-hidden', 'true'); frame.tabIndex = -1;
  frame.style.left = `${offset}px`;
  frame.style.width = `${source.clientWidth}px`; frame.style.height = `${source.clientHeight}px`;
  track.append(frame);
  const original = source.contentDocument, doc = frame.contentDocument;
  const root = doc.importNode(original.documentElement, true);
  // Cloned publication markup is already sanitized. Do not clone engine scripts.
  root.querySelectorAll('script').forEach(script => script.remove());
  doc.replaceChild(root, doc.documentElement);
  const x = source.contentWindow.scrollX, y = source.contentWindow.scrollY;
  // Force style resolution before waiting for fonts, then restore the same column.
  void doc.body.offsetHeight;
  await Promise.all([...doc.querySelectorAll('link[rel="stylesheet"]')].filter(link => !link.sheet).map(link =>
    new Promise(resolve => { link.addEventListener('load', resolve, {once: true}); link.addEventListener('error', resolve, {once: true}); })));
  await doc.fonts.ready;
  await Promise.all([...doc.images].filter(image => !image.complete).map(image => image.decode().catch(() => {})));
  await paint();
  if (!frame.isConnected || !frame.contentWindow) return null;
  frame.contentWindow.scrollTo(x, y);
  copyHighlights(original, doc);
  await paint();
  return frame;
}

export class PageSlide {
  constructor(reader) {
    this.reader = reader;
    this.reduced = matchMedia('(prefers-reduced-motion: reduce)');
    this.reduced.addEventListener('change', () => { if (this.reduced.matches) this.cancel(); });
    this.revision = 0;
  }

  cancel() {
    this.revision++;
    this.animation?.cancel(); this.animation = null;
    this.stage?.remove(); this.stage = null;
  }

  hurry() {
    const animation = this.animation;
    if (!animation || animation.playState !== 'running') return;
    const remaining = Number(animation.effect.getTiming().duration) - Number(animation.currentTime ?? 0);
    animation.playbackRate = Math.max(1, remaining / 65);
  }

  async run(direction, {enabled, rtl, hurried = () => false}, navigate) {
    if (!enabled || this.reduced.matches) return navigate();
    this.cancel();
    const revision = this.revision;
    const stage = document.createElement('div');
    stage.className = 'reader-page-slide'; stage.setAttribute('aria-hidden', 'true'); stage.inert = true;
    stage.style.visibility = 'hidden';
    const track = document.createElement('div'); track.className = 'page-slide-track'; stage.append(track);
    this.reader.parentElement.append(stage); this.stage = stage;
    const width = this.reader.clientWidth, sign = slideSign(direction, rtl);
    let timeout;
    const capture = offset => Promise.race([
      snapshot(this.reader, track, offset).catch(() => null),
      new Promise(resolve => { timeout = setTimeout(() => resolve(null), 600); })
    ]).finally(() => clearTimeout(timeout));
    try {
      const outgoing = await capture(0);
      if (revision !== this.revision) return navigate();
      if (!outgoing) { this.cancel(); return navigate(); }
      stage.style.visibility = 'visible';
      const moved = await navigate();
      if (!moved || revision !== this.revision) return moved;
      const incoming = await capture(sign * width);
      if (!incoming || revision !== this.revision || this.reduced.matches) return moved;
      this.animation = track.animate([
        {transform: 'translate3d(0,0,0)'},
        {transform: `translate3d(${-sign * width}px,0,0)`}
      ], {duration: hurried() ? 90 : 260, easing: 'cubic-bezier(.22,.7,.22,1)', fill: 'forwards'});
      await this.animation.finished.catch(() => {});
      return moved;
    } finally {
      stage.remove();
      if (revision === this.revision) { this.animation?.cancel(); this.animation = null; this.stage = null; }
    }
  }
}
