/** The margin garden: ASCII vines in the empty window space beside the page,
 * grown in step with chapter progress, plus a spine vine in the column gap of
 * facing pages. Decorative only: both canvases are aria-hidden, take no input
 * and never affect layout. See docs/specs/glass-vines.md. */
import {createField, vinePalette, gardenSeed, isDarkColor} from './vines.js';

const FONT = 13, LINE = 16, MIN_MARGIN_CELLS = 7, BUDGET = 1500, STAGGER = 7, FADE = 700, GHOST = 900, FREEZE = 300;
const smooth = (a, b, x) => { const t = Math.min(1, Math.max(0, (x - a) / (b - a))); return t * t * (3 - 2 * t); };
const overlaps = (a, b) => a.left < b.right && a.right > b.left && a.top < b.bottom && a.bottom > b.top;
const MODES = ['animated', 'still', 'off'];
const hex = value => /^#[0-9a-f]{6}$/i.test(value) ? value : null;

/**
 * @param {object} options
 * @param {HTMLCanvasElement} options.canvas full-window canvas behind the page
 * @param {HTMLCanvasElement} options.spine overlay canvas covering the reading viewport
 * @param {HTMLElement} options.viewport the reading viewport (the page)
 * @param {() => Element[]} options.chrome visible bars the garden must stay clear of
 * @param {() => {columns: number, gutter: number, scroll: boolean}} options.layout
 * @param {() => boolean} options.enabled the reader's own Vines preference
 * @param {() => string} options.edition
 */
export function installGarden({canvas, spine, viewport, chrome, layout, enabled, edition}) {
  const reduce = matchMedia('(prefers-reduced-motion: reduce)');
  // The app injects its Garden setting at document start so the first frame already honours Off and Still;
  // setMode() then follows live changes.
  let mode = MODES.includes(window.__stillleafGardenMode) ? window.__stillleafGardenMode : 'animated', frozen = false, freezeTimer = 0, layoutTimer = 0, frame = 0;
  let ticks = 0, progress = 0, chapter = null, pending = null, metrics = null, palette = null, deferred = false;
  const margins = {field: null, born: new Map(), ghosts: [], context: canvas.getContext('2d'), origin: {left: 0, top: 0}};
  const column = {field: null, born: new Map(), ghosts: [], context: spine.getContext('2d'), origin: {left: 0, top: 0}};

  document.documentElement.dataset.garden = mode;
  const active = () => mode !== 'off' && enabled();
  const still = () => mode === 'still' || reduce.matches;

  function measure() {
    const context = margins.context;
    context.font = `${FONT}px ui-monospace, "SF Mono", Menlo, monospace`;
    metrics = {cw: context.measureText('M').width || 7.8, ch: LINE};
    const style = getComputedStyle(document.documentElement);
    const paper = hex(style.getPropertyValue('--paper').trim()) ?? '#fbfcfa';
    palette = vinePalette({accent: hex(style.getPropertyValue('--accent').trim()) ?? '#176650',
      ink: hex(style.getPropertyValue('--ink').trim()) ?? '#183d33', paper}, isDarkColor(paper));
  }

  function size(target, width, height) {
    const dpr = Math.min(2, devicePixelRatio || 1);
    target.width = Math.max(1, Math.round(width * dpr)); target.height = Math.max(1, Math.round(height * dpr));
    target.getContext('2d').setTransform(dpr, 0, 0, dpr, 0, 0);
  }

  /** Vines beside the page, in margins at least seven cells wide. */
  function plantMargins(budget) {
    const {cw, ch} = metrics, columns = Math.ceil(innerWidth / cw), rows = Math.ceil(innerHeight / ch);
    const page = viewport.getBoundingClientRect();
    const bars = chrome().map(e => e.getBoundingClientRect()).filter(r => r.width > 0 && r.height > 0);
    const keepClear = [{left: page.left - cw, right: page.right + cw, top: -Infinity, bottom: Infinity}, ...bars];
    const leftOK = Math.floor(page.left / cw) - 1 >= MIN_MARGIN_CELLS, rightOK = columns - Math.ceil(page.right / cw) - 1 >= MIN_MARGIN_CELLS;
    const field = createField({columns, rows, cellWidth: cw, cellHeight: ch, seed: gardenSeed('reader', `${edition()}|${chapter}`), maxCells: BUDGET});
    field.budget = budget;
    field.allows = (x, y) => {
      const cell = {left: x * cw, right: (x + 1) * cw, top: y * ch, bottom: (y + 1) * ch};
      if (keepClear.some(r => overlaps(cell, r))) return false;
      return cell.right <= page.left ? leftOK : rightOK;
    };
    // Root vines just above the footer and start edge vines just below the toolbar.
    const floor = Math.min(innerHeight, ...bars.filter(r => r.bottom >= innerHeight - 1).map(r => r.top));
    const ceiling = Math.max(0, ...bars.filter(r => r.top <= 1).map(r => r.bottom));
    const bottom = Math.floor(floor / ch) - 1, top = Math.ceil(ceiling / ch) + 1;
    const left = Math.floor(page.left / cw) - 3, right = Math.ceil(page.right / cw) + 2;
    const seeds = [];
    if (leftOK) seeds.push({x: 3, y: bottom, heading: -1.3, bias: -1.5}, {x: Math.max(2, left), y: bottom, heading: -1.75, bias: -1.6},
      {x: Math.floor(left / 2), y: bottom, heading: -1.5, bias: -1.5}, {x: 1, y: top + 2, heading: 0.7, bias: 1.25});
    if (rightOK) seeds.push({x: columns - 4, y: bottom, heading: -1.8, bias: -1.6}, {x: Math.min(columns - 2, right), y: bottom, heading: -1.4, bias: -1.55},
      {x: Math.floor((right + columns) / 2), y: bottom, heading: -1.6, bias: -1.6}, {x: columns - 2, y: top + 2, heading: 2.45, bias: 1.9});
    seeds.forEach((s, i) => field.plant({...s, life: 56, hue: i, biasStrength: 0.045, branchChance: 0.09, branchLife: 16}));
    field.growToCompletion(20000);
    return field;
  }

  /** One vine up the column gap of facing pages: the chapter progress. */
  function plantSpine() {
    const {columns, gutter, scroll} = layout(), {cw, ch} = metrics, page = viewport.getBoundingClientRect();
    if (columns !== 2 || scroll || gutter < cw * 2.5) return null;
    const cols = Math.ceil(page.width / cw), rows = Math.ceil(page.height / ch);
    const center = page.width / 2, half = gutter - cw;
    const field = createField({columns: cols, rows, cellWidth: cw, cellHeight: ch, seed: gardenSeed('spine', `${edition()}|${chapter}`), maxCells: 400});
    field.allows = (x, y) => Math.abs((x + 0.5) * cw - center) <= half && y > 0 && y < rows - 1;
    const x = center / cw - 0.5, top = 1.5 + (rows - 3) * (1 - progress), bottom = rows - 1.5;
    if (bottom - top < 1) return field;
    const path = [];
    for (let y = bottom; y >= top; y -= 0.5) path.push({x, y});
    field.plant({x: Math.round(x), y: Math.round(bottom), life: 9999, path, wobble: 0.9, wobbleFrequency: 0.42, leafChance: 0.5, branchChance: 0, bloomChance: 1});
    field.growToCompletion(4000);
    return field;
  }

  /** Swaps a scene to a new garden: kept cells stay, new ones fade in in growth order, lost ones fade out.
   *  Still and Reduce Motion show the new garden at once: no fade in, no fading ghosts. */
  function regrow(scene, field, now) {
    const previous = scene.field?.cells ?? new Map(), born = new Map();
    let order = 0;
    for (const [key, cell] of field?.cells ?? []) {
      const kept = previous.get(key);
      born.set(key, kept && scene.born.has(key) ? scene.born.get(key) : still() ? now - FADE : now + (order++) * STAGGER);
    }
    if (still()) scene.ghosts = [];
    else for (const [key, cell] of previous) if (!field?.cells.has(key)) scene.ghosts.push({cell, dying: now});
    scene.field = field; scene.born = born;
  }

  /** Drops every garden, fades and ghosts included, blanks both canvases and stops drawing. */
  function wipe() {
    for (const scene of [margins, column]) { scene.field = null; scene.born = new Map(); scene.ghosts = []; scene.context.clearRect(0, 0, 1e5, 1e5); }
    cancelAnimationFrame(frame); frame = 0;
    canvas.classList.remove('breathing');
  }

  function rebuild() {
    // While input is arriving, keep the current garden on screen; regrow once it stops.
    if (frozen && active()) { deferred = true; return; }
    deferred = false;
    const now = performance.now();
    if (!active()) { wipe(); return; }
    measure();
    size(canvas, innerWidth, innerHeight);
    const page = viewport.getBoundingClientRect();
    size(spine, page.width, page.height);
    column.origin = {left: page.left, top: page.top};
    regrow(margins, plantMargins(Math.max(24, Math.round(BUDGET * progress))), now);
    regrow(column, plantSpine(), now);
    schedule();
  }

  function draw(scene, now) {
    const {context} = scene, {cw, ch} = metrics;
    context.clearRect(0, 0, 1e5, 1e5);
    context.font = `${FONT}px ui-monospace, "SF Mono", Menlo, monospace`;
    context.textBaseline = 'top';
    let busy = false;
    const paint = (cell, alpha) => {
      if (alpha <= 0.01) return;
      const colors = palette[cell.kind === 'stem' ? 'stems' : cell.kind === 'leaf' ? 'leaves' : 'blooms'];
      context.globalAlpha = Math.min(1, alpha);
      context.fillStyle = colors[cell.slot % colors.length];
      context.fillText(cell.glyph, cell.x * cw, cell.y * ch);
    };
    for (const [key, cell] of scene.field?.cells ?? []) {
      const age = now - scene.born.get(key);
      if (age < FADE) busy = true;
      paint(cell, smooth(0, FADE, age) * palette.baseAlpha * (cell.kind === 'stem' ? 0.9 : 1));
    }
    scene.ghosts = scene.ghosts.filter(g => now - g.dying < GHOST);
    for (const ghost of scene.ghosts) { busy = true; paint(ghost.cell, palette.baseAlpha * (1 - smooth(0, GHOST, now - ghost.dying))); }
    context.globalAlpha = 1;
    return busy;
  }

  function tick() {
    frame = 0;
    if (!active() || !metrics) return;
    ticks++;
    const now = performance.now();
    const busy = draw(margins, now) | draw(column, now);
    // Draw only while something fades; a settled garden is a still image that breathes in CSS.
    if (busy && !frozen) frame = requestAnimationFrame(tick);
    canvas.classList.toggle('breathing', !busy && !frozen && !still());
  }

  /** Paints the next frame. A Still garden has nothing to fade, so it paints at once instead of waiting for a frame. */
  function schedule() {
    if (frozen || !active()) return;
    if (still() && metrics) { cancelAnimationFrame(frame); tick(); return; }
    if (!frame) frame = requestAnimationFrame(tick);
  }

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
      canvas.classList.remove('breathing');
      clearTimeout(freezeTimer);
      freezeTimer = setTimeout(() => {
        frozen = false;
        if (pending != null) { progress = pending; pending = null; rebuild(); } else if (deferred) rebuild(); else schedule();
      }, FREEZE);
    },
    /** The app's Garden setting: animated, still or off. */
    setMode(value) {
      mode = MODES.includes(value) ? value : 'animated';
      document.documentElement.dataset.garden = mode;
      rebuild();
    },
    /** The book closed: forget its chapter and blank everything without planting a placeholder garden. */
    clear() {
      clearTimeout(layoutTimer); clearTimeout(freezeTimer);
      chapter = null; progress = 0; pending = null; frozen = false; deferred = false;
      wipe();
    },
    debug() {
      const rects = (scene, origin) => {
        if (!scene.field || !metrics) return [];
        const {cw, ch} = metrics;
        return [...scene.field.cells.values()].map(c => ({left: origin.left + c.x * cw, right: origin.left + (c.x + 1) * cw, top: origin.top + c.y * ch, bottom: origin.top + (c.y + 1) * ch}));
      };
      return {cells: rects(margins, {left: 0, top: 0}), spine: rects(column, column.origin), progress, frozen, mode,
        gutter: layout().gutter, animating: frame !== 0, ticks, ghosts: margins.ghosts.length + column.ghosts.length};
    }
  };
}
