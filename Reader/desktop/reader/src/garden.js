/** The margin garden: ASCII vines in the empty window space around the page card, grown in step with
 * chapter progress, a spine vine in the column gap of facing pages, and a progress vine along the footer
 * pill. Decorative only: every canvas is aria-hidden, takes no input and never affects layout.
 * See docs/specs/glass-vines.md and design/glass-vines/garden-and-reader-themes.html (the approved mockup). */
import {createField, vinePalette, gardenSeed, isDarkColor} from './vines.js';

const FONT = 13, LINE = 16, FOOT_FONT = 12, FOOT_LINE = 14, MIN_MARGIN_CELLS = 7, BUDGET = 1500, STAGGER = 7, FADE = 700, GHOST = 900, FREEZE = 300;
// Every chapter starts as a young garden (about the mockup at 18%: START_CELLS vines, or START_SHARE of a small garden)
// and fills out to its full size by the chapter's end.
const START_CELLS = 270, START_SHARE = 0.4, CARD_EDGE = 16, CLEAR_PAGE = 2, CLEAR_BARS = 1;
const smooth = (a, b, x) => { const t = Math.min(1, Math.max(0, (x - a) / (b - a))); return t * t * (3 - 2 * t); };
const overlaps = (a, b) => a.left < b.right && a.right > b.left && a.top < b.bottom && a.bottom > b.top;
const MODES = ['animated', 'still', 'off'];
const hex = value => /^#[0-9a-f]{6}$/i.test(value) ? value : null;
const monospace = size => `${size}px ui-monospace, "SF Mono", Menlo, monospace`;
/** A rect grown to whole cells, plus `cells` more cells on every side. */
const padded = (r, cw, ch, cells) => ({left: (Math.floor(r.left / cw) - cells) * cw, right: (Math.ceil(r.right / cw) + cells) * cw, top: (Math.floor(r.top / ch) - cells) * ch, bottom: (Math.ceil(r.bottom / ch) + cells) * ch});
/** Static depth: the main stems sit in front, finer branches recede. */
const depth = cell => cell.kind === 'bloom' ? 1 : cell.generation >= 2 ? 0.6 : cell.generation === 1 ? 0.82 : 1;

/**
 * @param {object} options
 * @param {HTMLCanvasElement} options.canvas full-window canvas behind the page
 * @param {HTMLCanvasElement} options.spine overlay canvas covering the reading viewport
 * @param {HTMLCanvasElement} options.footer canvas inside the footer pill, along its progress track
 * @param {HTMLElement} options.percent the footer's percentage label
 * @param {HTMLElement} options.viewport the reading viewport (the page card)
 * @param {() => Element[]} options.chrome visible bars the garden must stay clear of
 * @param {() => {columns: number, gutter: number, scroll: boolean}} options.layout
 * @param {() => boolean} options.enabled the reader's own Vines preference
 * @param {() => string} options.edition
 */
export function installGarden({canvas, spine, footer, percent, viewport, chrome, layout, enabled, edition}) {
  const reduce = matchMedia('(prefers-reduced-motion: reduce)');
  const root = document.documentElement;
  // The app injects its Garden setting at document start so the first frame already honours Off and Still;
  // setMode() then follows live changes.
  let mode = MODES.includes(window.__stillleafGardenMode) ? window.__stillleafGardenMode : 'animated', frozen = false, freezeTimer = 0, layoutTimer = 0, frame = 0;
  let ticks = 0, drawMs = 0, slowestDraw = 0, progress = 0, chapter = null, pending = null, palette = null, deferred = false;
  const scene = (target, font, line, trackAlpha) => ({canvas: target, field: null, born: new Map(), ghosts: [], context: target.getContext('2d'), origin: {left: 0, top: 0}, font, line, cw: 7.8, ch: line, track: [], trackAlpha});
  const margins = scene(canvas, FONT, LINE, 0), column = scene(spine, FONT, LINE, 0.55), foot = scene(footer, FOOT_FONT, FOOT_LINE, 0.9);
  const scenes = [margins, column, foot];

  root.dataset.garden = mode;
  const active = () => mode !== 'off' && enabled();
  const still = () => mode === 'still' || reduce.matches;

  function measure() {
    const style = getComputedStyle(root), color = name => hex(style.getPropertyValue(name).trim());
    for (const s of scenes) { s.context.font = monospace(s.font); s.cw = s.context.measureText('M').width || 7.8; }
    const paper = color('--paper') ?? '#fbfcfa', ink = color('--ink') ?? '#183d33';
    palette = vinePalette({accent: color('--accent') ?? '#176650', ink, paper, muted: color('--muted') ?? ink, backdrop: color('--backdrop') ?? paper}, isDarkColor(paper));
    palette.dark = isDarkColor(paper);
  }

  function size(s, width, height) {
    const dpr = Math.min(2, devicePixelRatio || 1);
    s.canvas.width = Math.max(1, Math.round(width * dpr)); s.canvas.height = Math.max(1, Math.round(height * dpr));
    s.context.setTransform(dpr, 0, 0, dpr, 0, 0);
  }

  /** Vines around the page card, in margins at least seven cells wide, grown to this share of the chapter. */
  function plantMargins(fraction) {
    const {cw, ch} = margins, columns = Math.ceil(innerWidth / cw), rows = Math.ceil(innerHeight / ch);
    const page = viewport.getBoundingClientRect();
    const bars = chrome().map(e => e.getBoundingClientRect()).filter(r => r.width > 0 && r.height > 0);
    const keepClear = [{...padded(page, cw, ch, CLEAR_PAGE), top: -Infinity, bottom: Infinity}, ...bars.map(r => padded(r, cw, ch, CLEAR_BARS))];
    const x0 = Math.floor(page.left / cw), x1 = Math.ceil(page.right / cw);
    const leftOK = x0 - CLEAR_PAGE >= MIN_MARGIN_CELLS, rightOK = columns - x1 - CLEAR_PAGE >= MIN_MARGIN_CELLS;
    // Root vines at the bottom corners and start edge vines near the top, as in the mockup.
    const ceiling = Math.max(0, ...bars.filter(r => r.top <= 1).map(r => r.bottom));
    const bottom = rows - 1, top = Math.max(Math.ceil(ceiling / ch) + 3, 6), left = x0 - 3, right = x1 + 2;
    const seeds = [];
    if (leftOK) seeds.push({x: 3, y: bottom, heading: -1.3, bias: -1.5}, {x: Math.max(2, left), y: bottom, heading: -1.75, bias: -1.6},
      {x: Math.floor(left / 2), y: bottom, heading: -1.5, bias: -1.5}, {x: 1, y: top, heading: 0.7, bias: 1.25});
    if (rightOK) seeds.push({x: columns - 4, y: bottom, heading: -1.8, bias: -1.6}, {x: Math.min(columns - 2, right), y: bottom, heading: -1.4, bias: -1.55},
      {x: Math.floor((right + columns) / 2), y: bottom, heading: -1.6, bias: -1.6}, {x: columns - 2, y: top, heading: 2.45, bias: 1.9});
    const seed = gardenSeed('reader', `${edition()}|${chapter}`);
    const grow = budget => {
      const field = createField({columns, rows, cellWidth: cw, cellHeight: ch, seed, maxCells: BUDGET});
      field.maxTips = 50; field.budget = budget;
      field.allows = (x, y) => {
        const cell = {left: x * cw, right: (x + 1) * cw, top: y * ch, bottom: (y + 1) * ch};
        if (keepClear.some(r => overlaps(cell, r))) return false;
        return cell.right <= page.left ? leftOK : rightOK;
      };
      seeds.forEach((s, i) => field.plant({...s, life: 56, hue: i, biasStrength: 0.045, branchChance: 0.09, branchLife: 16}));
      field.growToCompletion(20000);
      return field;
    };
    // Growth is deterministic and stops at the budget, so a smaller budget is exactly the start of the full garden.
    const full = grow(Infinity), natural = full.cells.size, start = Math.min(START_CELLS, natural * START_SHARE);
    const target = Math.round(start + (natural - start) * fraction);
    return target >= natural ? full : grow(Math.max(24, target));
  }

  /** One vine up the column gap of facing pages: the chapter progress. */
  function plantSpine(fraction) {
    const {columns, gutter, scroll} = layout(), {cw, ch} = column, page = viewport.getBoundingClientRect();
    column.track = [];
    if (columns !== 2 || scroll || gutter < cw * 2.5) return null;
    const cols = Math.ceil(page.width / cw), rows = Math.ceil(page.height / ch);
    const center = page.width / 2, half = gutter - cw;
    const field = createField({columns: cols, rows, cellWidth: cw, cellHeight: ch, seed: gardenSeed('spine', `${edition()}|${chapter}`), maxCells: 400});
    field.allows = (x, y) => Math.abs((x + 0.5) * cw - center) <= half && y > 0 && y < rows - 1;
    const x = center / cw - 0.5, top = 1.5 + (rows - 3) * (1 - fraction), bottom = rows - 1.5;
    for (let y = bottom; y >= 1.5; y -= 1) column.track.push({x: Math.round(x), y: Math.round(y)});
    if (bottom - top < 1) return field;
    const path = [];
    for (let y = bottom; y >= top; y -= 0.5) path.push({x, y});
    field.plant({x: Math.round(x), y: Math.round(bottom), life: 9999, path, wobble: 0.9, wobbleFrequency: 0.42, leafChance: 0.5, branchChance: 0, bloomChance: 1});
    field.growToCompletion(4000);
    return field;
  }

  /** The footer vine: grows left to right along a dotted track to the chapter progress. */
  function plantFoot(fraction) {
    const rect = footer.getBoundingClientRect(), {cw, ch} = foot;
    foot.track = [];
    if (rect.width < cw * 4 || rect.height < ch) return null;
    const cols = Math.ceil(rect.width / cw), rows = Math.ceil(rect.height / ch), y = Math.floor(rows / 2);
    const field = createField({columns: cols, rows, cellWidth: cw, cellHeight: ch, seed: gardenSeed('footer', `${edition()}|${chapter}`), maxCells: 400});
    for (let x = 0; x < cols; x++) foot.track.push({x, y});
    const path = foot.track.slice(0, Math.max(2, Math.round(cols * fraction)));
    field.plant({x: 0, y, life: 9999, path, wobble: 0, leafChance: 0.42, branchChance: 0, bloomChance: 1});
    field.growToCompletion(4000);
    return field;
  }

  /** Swaps a scene to a new garden: kept cells stay, new ones fade in in growth order, lost ones fade out.
   *  Still and Reduce Motion show the new garden at once: no fade in, no fading ghosts. */
  function regrow(s, field, now) {
    const previous = s.field?.cells ?? new Map(), born = new Map();
    let order = 0;
    for (const [key] of field?.cells ?? []) {
      const kept = previous.get(key);
      born.set(key, kept && s.born.has(key) ? s.born.get(key) : still() ? now - FADE : now + (order++) * STAGGER);
    }
    if (still()) s.ghosts = [];
    else for (const [key, cell] of previous) if (!field?.cells.has(key)) s.ghosts.push({cell, dying: now});
    s.field = field; s.born = born;
  }

  /** Drops every garden, fades and ghosts included, blanks every canvas and stops drawing. */
  function wipe() {
    for (const s of scenes) { s.field = null; s.born = new Map(); s.ghosts = []; s.track = []; s.context.clearRect(0, 0, 1e5, 1e5); s.canvas.classList.remove('breathing'); }
    cancelAnimationFrame(frame); frame = 0;
    root.classList.remove('garden-card', 'garden-facing');
  }

  function rebuild() {
    // While input is arriving, keep the current garden on screen; regrow once it stops.
    if (frozen && active()) { deferred = true; return; }
    deferred = false;
    const now = performance.now(), on = active();
    // The footer pill and its vine exist while the garden does; the card and its backdrop need room around the page.
    root.classList.toggle('garden-on', on);
    if (!on) { wipe(); return; }
    measure();
    const page = viewport.getBoundingClientRect(), {columns, scroll} = layout();
    root.classList.toggle('garden-card', page.left >= CARD_EDGE && innerWidth - page.right >= CARD_EDGE);
    root.classList.toggle('garden-facing', columns === 2 && !scroll);
    size(margins, innerWidth, innerHeight);
    size(column, page.width, page.height);
    column.origin = {left: page.left, top: page.top};
    const rect = footer.getBoundingClientRect();
    size(foot, rect.width, rect.height);
    foot.origin = {left: rect.left, top: rect.top};
    regrow(margins, plantMargins(progress), now);
    regrow(column, plantSpine(progress), now);
    regrow(foot, plantFoot(progress), now);
    schedule();
  }

  function paint(s, cell, alpha) {
    if (alpha <= 0.01) return;
    const colors = palette[cell.kind === 'stem' ? 'stems' : cell.kind === 'leaf' ? 'leaves' : 'blooms'];
    // Blooms stay subtle on dark pages; every cell carries a fixed shimmer so the garden is not one flat tone.
    const tone = (cell.kind === 'bloom' && palette.dark ? 0.75 : 1) * (0.86 + 0.14 * Math.sin(cell.phase));
    s.context.globalAlpha = Math.min(1, alpha * depth(cell) * tone);
    s.context.fillStyle = colors[cell.slot % colors.length];
    s.context.fillText(cell.glyph, cell.x * s.cw, cell.y * s.ch);
  }

  function draw(s, now) {
    const {context} = s;
    context.clearRect(0, 0, 1e5, 1e5);
    context.font = monospace(s.font);
    context.textBaseline = 'top';
    if (s.track.length && s.field) {
      context.fillStyle = palette.track;
      context.globalAlpha = (palette.dark ? 0.16 : 0.2) * s.trackAlpha;
      for (const p of s.track) if (!s.field.cells.has(p.y * s.field.columns + p.x)) context.fillText('·', p.x * s.cw, p.y * s.ch);
    }
    let busy = false;
    for (const [key, cell] of s.field?.cells ?? []) {
      const age = now - s.born.get(key);
      if (age < FADE) busy = true;
      paint(s, cell, smooth(0, FADE, age) * palette.baseAlpha * (cell.kind === 'stem' ? 0.9 : 1));
    }
    s.ghosts = s.ghosts.filter(g => now - g.dying < GHOST);
    for (const ghost of s.ghosts) { busy = true; paint(s, ghost.cell, palette.baseAlpha * (1 - smooth(0, GHOST, now - ghost.dying))); }
    context.globalAlpha = 1;
    return busy;
  }

  function tick() {
    frame = 0;
    if (!active() || !palette) return;
    ticks++;
    const now = performance.now();
    const busy = scenes.map(s => draw(s, now)).some(Boolean);
    const spent = performance.now() - now;
    drawMs += spent; slowestDraw = Math.max(slowestDraw, spent);
    // Draw only while something fades; a settled garden is a still image that breathes in CSS.
    if (busy && !frozen) frame = requestAnimationFrame(tick);
    for (const s of scenes) s.canvas.classList.toggle('breathing', !busy && !frozen && !still());
  }

  /** Paints the next frame. A Still garden has nothing to fade, so it paints at once instead of waiting for a frame. */
  function schedule() {
    if (frozen || !active()) return;
    if (still() && palette) { cancelAnimationFrame(frame); tick(); return; }
    if (!frame) frame = requestAnimationFrame(tick);
  }

  /** The footer vine's room changes with its labels ("Page 9 of 20" to "Page 10 of 20"): regrow just that vine to fit. */
  let footTimer = 0;
  function fitFoot() {
    if (!active() || !palette) return;
    // Input is arriving: the rebuild that follows it will size the vine.
    if (frozen) { deferred = true; return; }
    const rect = footer.getBoundingClientRect();
    if (Math.abs(rect.width * (devicePixelRatio || 1) - footer.width) < 1.5 && Math.abs(rect.height * (devicePixelRatio || 1) - footer.height) < 1.5) return;
    size(foot, rect.width, rect.height);
    foot.origin = {left: rect.left, top: rect.top};
    regrow(foot, plantFoot(progress), performance.now());
    schedule();
  }
  if (typeof ResizeObserver === 'function') new ResizeObserver(() => { clearTimeout(footTimer); footTimer = setTimeout(fitFoot, 60); }).observe(footer);

  const showPercent = value => { percent.textContent = `${Math.round(value * 100)}%`; };

  return {
    /** Layout or appearance changed: regrow for the new geometry once it settles. */
    update() {
      clearTimeout(layoutTimer);
      layoutTimer = setTimeout(rebuild, 120);
    },
    /** Reading moved. Applied when scrolling stops, as one regrow step. */
    progress(locator) {
      if (!locator) return;
      const href = locator.href, value = Math.min(1, Math.max(0, locator.locations?.progression ?? 0));
      showPercent(value);
      if (href !== chapter) { chapter = href; progress = value; pending = null; if (!frozen) rebuild(); else pending = value; return; }
      if (Math.abs(value - progress) < 0.004) return;
      if (frozen) { pending = value; return; }
      progress = value; rebuild();
    },
    /** Wheel or scroll input: hold the garden still until it stops. */
    activity() {
      // An Off garden has nothing to hold still and must never schedule a frame.
      if (!active()) return;
      frozen = true;
      cancelAnimationFrame(frame); frame = 0;
      for (const s of scenes) s.canvas.classList.remove('breathing');
      clearTimeout(freezeTimer);
      freezeTimer = setTimeout(() => {
        frozen = false;
        if (pending != null) { progress = pending; pending = null; rebuild(); } else if (deferred) rebuild(); else schedule();
      }, FREEZE);
    },
    /** The app's Garden setting: animated, still or off. */
    setMode(value) {
      mode = MODES.includes(value) ? value : 'animated';
      root.dataset.garden = mode;
      rebuild();
    },
    /** The book closed: forget its chapter and blank everything without planting a placeholder garden. */
    clear() {
      clearTimeout(layoutTimer); clearTimeout(freezeTimer); clearTimeout(footTimer);
      chapter = null; progress = 0; pending = null; frozen = false; deferred = false;
      root.classList.remove('garden-on');
      percent.textContent = '';
      wipe();
    },
    debug() {
      const rects = s => {
        if (!s.field) return [];
        return [...s.field.cells.values()].map(c => ({left: s.origin.left + c.x * s.cw, right: s.origin.left + (c.x + 1) * s.cw, top: s.origin.top + c.y * s.ch, bottom: s.origin.top + (c.y + 1) * s.ch, kind: c.kind}));
      };
      const track = s => s.track.map(p => ({left: s.origin.left + p.x * s.cw, right: s.origin.left + (p.x + 1) * s.cw, top: s.origin.top + p.y * s.ch, bottom: s.origin.top + (p.y + 1) * s.ch}));
      return {cells: rects(margins), spine: rects(column), foot: rects(foot), footTrack: track(foot), progress, frozen, mode,
        gutter: layout().gutter, animating: frame !== 0, ticks, drawMs, slowestDraw, ghosts: scenes.reduce((n, s) => n + s.ghosts.length, 0),
        card: root.classList.contains('garden-card'), on: root.classList.contains('garden-on'), palette};
    }
  };
}
