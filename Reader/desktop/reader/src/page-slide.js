// Presentation only: snapshots never join #reader, receive input, or emit locators.
// Readium continues to own live document layout, selection and navigation.
//
// A turn slides two inert copies of the live chapter, the outgoing page and the incoming one, as one strip
// inside a persistent stage. The copies are built once per chapter, off the animation path, and reused by
// every following turn: a turn only scrolls them to their columns, so nothing heavier than a style change
// runs between the key press and the first moving frame. Only transform and opacity animate.
export const slideSign = (direction, rtl = false) => (direction === 'next' ? 1 : -1) * (rtl ? -1 : 1);

/** The motion contract: tests, and the Mac smoke, hold the slide to these numbers. */
export const SLIDE = Object.freeze({
  duration: 320,                       // ms for a turn
  hurried: 150,                        // ms when more turns are already waiting
  easing: 'cubic-bezier(.3,.05,.12,1)', // eases in from rest (no first-frame jump), long gentle settle
  dim: 0.42,                           // how far the departing page fades toward the paper
  finishWithin: 90,                    // a held key fast-forwards the running turn to finish in about this long
  resident: 160,                       // how long the stage stays up after a turn for a follow-up turn to reuse it
  edge: 44,                            // width of the soft shadow along the incoming page's leading edge
});

const paint = () => new Promise(resolve => requestAnimationFrame(resolve));
const later = () => new Promise(resolve => setTimeout(resolve));

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

const liveFrame = reader => [...reader.querySelectorAll('iframe')].find(frame => getComputedStyle(frame).visibility !== 'hidden');

/** Everything that changes how a chapter lays out: when it differs, a copy of the chapter is stale. */
function fingerprint(source) {
  const doc = source.contentDocument, root = doc.documentElement;
  return [source.clientWidth, source.clientHeight, root.getAttribute('style'), root.className, doc.body.getAttribute('style'), doc.body.className,
    doc.styleSheets.length, doc.head.childElementCount, doc.body.childElementCount].join('|');
}

/** An inert copy of the live chapter, laid out at the live frame's size. Its column is set per use by `place`. */
async function buildFrame(source, track) {
  const frame = document.createElement('iframe');
  frame.className = 'page-slide-snapshot';
  frame.setAttribute('sandbox', 'allow-same-origin');
  frame.setAttribute('aria-hidden', 'true'); frame.tabIndex = -1;
  frame.style.width = `${source.clientWidth}px`; frame.style.height = `${source.clientHeight}px`;
  track.append(frame);
  const original = source.contentDocument, doc = frame.contentDocument;
  // A fresh about:blank iframe is quirks-mode. Match the live document before
  // importing its tree: identical CSS in a different mode changes column breaks.
  doc.open();
  doc.write(original.compatMode === 'CSS1Compat' ? '<!doctype html><html><head></head><body></body></html>' : '<html><head></head><body></body></html>');
  doc.close();
  const root = doc.importNode(original.documentElement, true);
  // Cloned publication markup is already sanitized. Do not clone engine scripts.
  root.querySelectorAll('script').forEach(script => script.remove());
  doc.replaceChild(root, doc.documentElement);
  // Force style resolution before waiting for fonts.
  void doc.body.offsetHeight;
  await Promise.all([...doc.querySelectorAll('link[rel="stylesheet"]')].filter(link => !link.sheet).map(link =>
    new Promise(resolve => { link.addEventListener('load', resolve, {once: true}); link.addEventListener('error', resolve, {once: true}); })));
  await doc.fonts.ready;
  await Promise.all([...doc.images].filter(image => !image.complete).map(image => image.decode().catch(() => {})));
  if (!frame.isConnected || !frame.contentWindow) return null;
  void doc.documentElement.offsetHeight;
  return frame;
}

/** Puts a copy at `offset` showing the column at (x, y), with the live document's highlights. */
function place(frame, source, offset, x, y) {
  frame.style.left = `${offset}px`;
  frame.contentWindow.scrollTo(x, y);
  copyHighlights(source.contentDocument, frame.contentDocument);
}

export class PageSlide {
  /** @param {HTMLElement} reader @param {{motion?: (ms: number) => void}} options `motion` hears when a turn starts moving. */
  constructor(reader, {motion = () => {}} = {}) {
    this.reader = reader; this.motion = motion;
    this.reduced = matchMedia('(prefers-reduced-motion: reduce)');
    this.reduced.addEventListener('change', () => { if (this.reduced.matches) this.invalidate(); });
    this.revision = 0; this.generation = 0; this.cache = null; this.building = null; this.shown = null; this.animations = [];
  }

  /** The persistent stage, hidden except while a turn is on screen. Created on first use. */
  ensureStage() {
    if (this.stage) return this.stage;
    const stage = document.createElement('div');
    stage.className = 'reader-page-slide'; stage.dataset.state = 'idle'; stage.setAttribute('aria-hidden', 'true'); stage.inert = true;
    const track = document.createElement('div'); track.className = 'page-slide-track';
    const shade = side => { const e = document.createElement('div'); e.className = `page-slide-shade page-slide-${side}`; return e; };
    const edge = document.createElement('div'); edge.className = 'page-slide-edge';
    this.shades = {outgoing: shade('outgoing'), incoming: shade('incoming')}; this.edge = edge;
    track.append(this.shades.outgoing, this.shades.incoming, edge);
    stage.append(track);
    this.reader.parentElement.append(stage);
    this.stage = stage; this.track = track;
    return stage;
  }

  /** Stops any motion and hides the stage. The chapter copies stay for the next turn. */
  cancel() {
    this.revision++;
    clearTimeout(this.residentTimer);
    this.stopMotion();
    this.hide();
  }

  /** The chapter or its layout changed: forget the copies too. */
  invalidate() {
    this.cancel();
    clearTimeout(this.warmTimer);
    this.generation++;
    this.cache = null; this.building = null;
    this.track?.querySelectorAll('iframe').forEach(frame => frame.remove());
  }

  stopMotion() {
    for (const animation of this.animations) animation.cancel();
    this.animations = []; this.animation = null;
  }

  hide() {
    if (this.stage) this.stage.dataset.state = 'idle';
    this.shown = null;
  }

  /** A queued or held-key turn fast-forwards the one on screen: smoothly, never faster than it can be seen. */
  hurry() {
    const main = this.animation;
    if (!main || main.playState !== 'running') return;
    const remaining = Number(main.effect.getTiming().duration) - Number(main.currentTime ?? 0);
    const rate = Math.max(1, remaining / SLIDE.finishWithin);
    for (const animation of this.animations) animation.updatePlaybackRate(rate);
  }

  /** Builds the chapter copies for the page on screen, ahead of the next turn, once things have been quiet for a moment. */
  warm(enabled = () => true) {
    clearTimeout(this.warmTimer);
    this.warmTimer = setTimeout(async () => {
      if (!enabled() || this.reduced.matches || this.running) return;
      const source = liveFrame(this.reader);
      if (!source?.contentDocument?.body) return;
      try { await this.ensure(source); } catch { /* the next turn builds them itself */ }
    }, 350);
  }

  /** The two copies of the live chapter (outgoing and incoming), built or completed as needed, one task each. */
  async ensure(source) {
    const doc = source.contentDocument, print = fingerprint(source);
    if (this.cache && (this.cache.doc !== doc || this.cache.print !== print)) this.drop();
    if (this.building && this.building.doc === doc && this.building.print === print) return this.building.promise;
    if (this.cache?.frames.length >= 2 && this.cache.frames.every(frame => frame.isConnected)) return this.cache;
    const stage = this.ensureStage(), generation = this.generation;
    const entry = this.cache ?? {doc, print, frames: []};
    entry.frames = entry.frames.filter(frame => frame.isConnected);
    const promise = (async () => {
      while (entry.frames.length < 2) {
        const frame = await buildFrame(source, this.track);
        if (!frame || generation !== this.generation || stage !== this.stage) { frame?.remove(); return null; }
        entry.frames.push(frame);
        this.cache = entry;
        if (entry.frames.length < 2) await later();
      }
      return entry;
    })().finally(() => { if (this.building?.promise === promise) this.building = null; });
    this.building = {doc, print, promise};
    return promise;
  }

  /** For tests and diagnostics: whether the copies are built and still match the live chapter. */
  debug() {
    const source = liveFrame(this.reader);
    return {frames: this.cache?.frames.length ?? 0, fresh: Boolean(source?.contentDocument && this.cache && this.cache.doc === source.contentDocument && this.cache.print === fingerprint(source)),
      cached: this.cache?.print ?? null, live: source?.contentDocument ? fingerprint(source) : null, state: this.stage?.dataset.state ?? null};
  }

  drop() {
    this.generation++;
    this.track?.querySelectorAll('iframe').forEach(frame => frame.remove());
    this.cache = null; this.building = null; this.shown = null;
  }

  async run(direction, {enabled, rtl, hurried = () => false}, navigate) {
    if (!enabled || this.reduced.matches) return navigate();
    clearTimeout(this.residentTimer); clearTimeout(this.warmTimer);
    this.revision++; this.stopMotion();
    const revision = this.revision;
    this.running = true;
    const stage = this.ensureStage(), reader = this.reader, sign = slideSign(direction, rtl);
    let timeout;
    const within = (promise, ms) => Promise.race([promise.catch(() => null), new Promise(resolve => { timeout = setTimeout(() => resolve(null), ms); })]).finally(() => clearTimeout(timeout));
    let resident = false;
    try {
      const source = liveFrame(reader);
      if (!source?.contentDocument?.body) { this.hide(); return navigate(); }
      const entry = await within(this.ensure(source), 600);
      if (revision !== this.revision) return navigate();
      if (!entry) { this.hide(); return navigate(); }
      const width = reader.clientWidth, x = source.contentWindow.scrollX, y = source.contentWindow.scrollY;
      const outgoing = this.shown && entry.frames.includes(this.shown) ? this.shown : entry.frames[0];
      let incoming = entry.frames.find(frame => frame !== outgoing);
      // The outgoing page in place, the incoming one pre-scrolled to where a turn within the chapter lands.
      place(outgoing, source, 0, x, y);
      place(incoming, source, sign * width, x + sign * width, y);
      this.layout(sign, width, outgoing, incoming);
      if (stage.dataset.state === 'idle') {
        // Rasterise the outgoing copy while it is all but invisible, so the first visible frame is the page itself.
        stage.dataset.state = 'arming';
        await paint(); await paint();
        if (revision !== this.revision) return navigate();
      }
      stage.dataset.state = 'active';
      this.motion(SLIDE.duration + 200);
      const moved = await navigate();
      if (!moved || revision !== this.revision) return moved;
      const live = liveFrame(reader);
      if (!live?.contentDocument?.body) return moved;
      const nx = live.contentWindow.scrollX, ny = live.contentWindow.scrollY;
      if (live.contentDocument === entry.doc && fingerprint(live) === entry.print) {
        // Same chapter. A turn lands where it was predicted, so this is almost always a no-op.
        if (incoming.contentWindow.scrollX !== nx || incoming.contentWindow.scrollY !== ny) { place(incoming, live, sign * width, nx, ny); await paint(); }
        else copyHighlights(live.contentDocument, incoming.contentDocument);
      } else {
        // A chapter crossing: the incoming page is a copy of the new chapter.
        const fresh = await within(buildFrame(live, this.track), 600);
        if (!fresh || revision !== this.revision) { fresh?.remove(); return moved; }
        incoming.remove();
        incoming = fresh;
        place(incoming, live, sign * width, nx, ny);
        this.layout(sign, width, outgoing, incoming);
        await paint();
        this.cache = {doc: live.contentDocument, print: fingerprint(live), frames: [incoming]};
        this.pendingDrop = outgoing;
      }
      if (revision !== this.revision || this.reduced.matches) return moved;
      this.animate(sign, width, hurried() ? SLIDE.hurried : SLIDE.duration);
      await this.animation.finished.catch(() => {});
      if (revision === this.revision) { this.settle(incoming, hurried()); resident = true; }
      return moved;
    } finally {
      clearTimeout(timeout);
      this.running = false;
      if (revision === this.revision && !resident) { this.stopMotion(); this.hide(); this.discard(); }
    }
  }

  /** Where the outgoing and incoming pages, their shades and the leading-edge shadow sit on the strip. */
  layout(sign, width, outgoing, incoming) {
    const {outgoing: out, incoming: inn} = this.shades;
    for (const [shade, frame] of [[out, outgoing], [inn, incoming]]) { shade.style.left = frame.style.left; shade.style.width = `${width}px`; }
    this.edge.className = `page-slide-edge ${sign > 0 ? 'page-slide-edge-right' : 'page-slide-edge-left'}`;
    this.edge.style.width = `${SLIDE.edge}px`;
    this.edge.style.left = `${sign > 0 ? width - SLIDE.edge : 0}px`;
  }

  animate(sign, width, duration) {
    const timing = {duration, easing: SLIDE.easing, fill: 'forwards'};
    const main = this.track.animate([{transform: 'translate3d(0,0,0)'}, {transform: `translate3d(${-sign * width}px,0,0)`}], timing);
    const fade = (element, from, to) => element.animate([{opacity: from}, {opacity: to}], {duration, easing: 'linear', fill: 'forwards'});
    this.animation = main;
    this.animations = [main, fade(this.shades.outgoing, 0, SLIDE.dim), fade(this.shades.incoming, SLIDE.dim, 0),
      this.edge.animate([{opacity: 0}, {opacity: 1, offset: 0.3}, {opacity: 1}], {duration, easing: 'linear', fill: 'forwards'})];
    this.motion(duration);
  }

  /** The turn is over: the incoming page, identical to the live one, takes the place of the strip, so nothing moves on screen. */
  settle(incoming, more) {
    // The other copy leaves the strip: moving a copy in the DOM would reload it, so it is shifted out of view instead.
    for (const frame of this.cache?.frames ?? []) if (frame !== incoming) frame.style.left = '-100000px';
    incoming.style.left = '0px';
    this.stopMotion();
    this.shown = incoming;
    this.discard();
    this.motion(0);
    // Stay up briefly: a follow-up turn (a held key) then reuses the stage and the rasterised page.
    clearTimeout(this.residentTimer);
    this.residentTimer = setTimeout(() => { this.hide(); this.warm(); }, more ? SLIDE.resident * 2 : SLIDE.resident);
  }

  /** Drops the outgoing copy of a chapter the reader has left. */
  discard() {
    if (this.pendingDrop) { this.pendingDrop.remove(); this.pendingDrop = null; }
  }
}
