/** The margin garden: ASCII vines in the empty window space around the page card, grown in step with
 * chapter progress, a spine vine in the column gap of facing pages, and a progress vine along the footer
 * pill. Decorative only: every canvas is aria-hidden, takes no input and never affects layout.
 * See docs/specs/glass-vines.md and design/glass-vines/garden-and-reader-themes.html (the approved mockup).
 *
 * An animated margin garden is also Living (design/dynamic-motion): once it has settled, a light loop (living.js,
 * at most 15 frames a second) grows the occasional shoot, withers old growth, flutters leaves in the wind, drops petals
 * and, in dark themes, lets fireflies out. Each of those frames repaints only the cells and particles that changed.
 * It is off in Still, Off and Reduce Motion, and it stops while the page is hidden, scrolling or turning. */
import {createField, vinePalette, gardenSeed, isDarkColor} from './vines.js';
import {createLiving, windAt, swayOf, REST, FRAME_MS} from './living.js';

const FONT = 13, LINE = 16, FOOT_FONT = 12, FOOT_LINE = 14, MIN_MARGIN_CELLS = 7, BUDGET = 1500, STAGGER = 7, FADE = 700, GHOST = 900, FREEZE = 300;
// Every chapter starts as a young garden (about the mockup at 18%: START_CELLS vines, or START_SHARE of a small garden)
// and fills out to its full size by the chapter's end.
const START_CELLS = 270, START_SHARE = 0.4, CARD_EDGE = 16, CLEAR_PAGE = 2, CLEAR_BARS = 1;
const smooth = (a, b, x) => { const t = Math.min(1, Math.max(0, (x - a) / (b - a))); return t * t * (3 - 2 * t); };
const overlaps = (a, b) => a.left < b.right && a.right > b.left && a.top < b.bottom && a.bottom > b.top;
const MODES = ['animated', 'still', 'off'];
// A glyph's ink can overhang its cell by a few pixels; a swaying one also moves by up to a third of a cell.
const INK_PAD = 3, FLY_GLOW = 46, VSYNC_MS = 14;
const poseKey = pose => pose.dx * 32 + pose.flip * 4;
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
  let holdUntil = 0, ticks = 0, drawMs = 0, slowestDraw = 0, progress = 0, chapter = null, pending = null, palette = null, deferred = false;
  // The Living layer. `drawn` remembers what each moving margin cell looked like when it was last painted, so a frame
  // repaints only the cells that differ now; `swayers` are the settled garden's leaves and blooms, which the wind moves.
  const living = createLiving({pace: window.__stillleafGardenDebug ? Number(window.__stillleafGardenPace) || 1 : 1});
  const stats = {frames: 0, drawMs: 0, slowestMs: 0, shortestGap: Infinity, idle: 0, dirtyTotal: 0, peakDirty: 0, swaying: 0};
  const drawn = new Map(), glows = new Map();
  let swayers = [], particleRects = [], ambientTimer = 0, ambientFrame = 0, ambientLast = 0, lastFrameAt = 0;
  const scene = (target, font, line, trackAlpha) => ({canvas: target, field: null, born: new Map(), ghosts: [], context: target.getContext('2d'), origin: {left: 0, top: 0}, font, line, cw: 7.8, ch: line, track: [], trackAlpha});
  const margins = scene(canvas, FONT, LINE, 0), column = scene(spine, FONT, LINE, 0.55), foot = scene(footer, FOOT_FONT, FOOT_LINE, 0.9);
  const scenes = [margins, column, foot];

  root.dataset.garden = mode;
  const active = () => mode !== 'off' && enabled();
  const still = () => mode === 'still' || reduce.matches;
  /** Wind, shoots, petals and fireflies: an animated garden only. */
  const lively = () => active() && !still();

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
    // The live layer keeps its shoots while the layout stays the same, and keeps wind, petals and fireflies clear of the page and bars.
    const gap = 2 * cw + 4, zone = (left, right) => ({left, right, top: 70, bottom: innerHeight - 20});
    margins.layout = {key: [columns, rows, cw, Math.round(page.left), Math.round(page.right), leftOK, rightOK].join('|'), avoid: keepClear,
      zones: [...(leftOK ? [zone(14, page.left - gap)] : []), ...(rightOK ? [zone(page.right + gap, innerWidth - 14)] : [])]};
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
    for (const s of scenes) { s.field = null; s.born = new Map(); s.ghosts = []; s.track = []; s.context.clearRect(0, 0, 1e5, 1e5); s.canvas.classList.remove('breathing', 'held'); }
    cancelAnimationFrame(frame); frame = 0;
    stopAmbient(); living.reset(); drawn.clear(); swayers = []; particleRects = [];
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
    if (lively()) living.attach({field: margins.field, columns: margins.field.columns, rows: margins.field.rows, cw: margins.cw, ch: margins.ch, width: innerWidth, height: innerHeight, dark: palette.dark, ...margins.layout});
    else { stopAmbient(); living.reset(); }
    swayers = lively() ? [...margins.field.cells].filter(([, cell]) => cell.kind !== 'stem') : [];
    regrow(column, plantSpine(progress), now);
    regrow(foot, plantFoot(progress), now);
    schedule();
  }

  /** A cell at `alpha`, shifted and fluttered by the wind `pose` (a leaf cross-fades to its fluttered glyph). */
  function paint(s, cell, alpha, pose = REST) {
    if (alpha <= 0.01) return;
    const colors = palette[cell.kind === 'stem' ? 'stems' : cell.kind === 'leaf' ? 'leaves' : 'blooms'];
    // Blooms stay subtle on dark pages; every cell carries a fixed shimmer so the garden is not one flat tone.
    const tone = (cell.kind === 'bloom' && palette.dark ? 0.75 : 1) * (0.86 + 0.14 * Math.sin(cell.phase));
    const level = Math.min(1, alpha * depth(cell) * tone), x = cell.x * s.cw + pose.dx, y = cell.y * s.ch, flutter = cell.alternate && pose.flip > 0 ? pose.flip : 0;
    s.context.fillStyle = colors[cell.slot % colors.length];
    s.context.globalAlpha = level * (1 - flutter);
    if (flutter < 1) s.context.fillText(cell.glyph, x, y);
    if (flutter > 0) { s.context.globalAlpha = level * flutter; s.context.fillText(cell.alternate, x, y); }
  }

  /** The settled wind pose of a margin cell right now. */
  function poseOf(cell) {
    if (cell.kind === 'stem' || !lively()) return REST;
    return swayOf(cell.kind, windAt((cell.x + 0.5) * margins.cw, (cell.y + 0.5) * margins.ch, living.time / 1000), margins.cw);
  }
  const restAlpha = cell => palette.baseAlpha * (cell.kind === 'stem' ? 0.9 : 1);
  /** What a live-growth cell looks like now: its opacity, pose, and a signature that changes whenever either does. */
  function liveLook(entry) {
    const fade = living.alpha(entry), pose = poseOf(entry.cell);
    return {alpha: fade * restAlpha(entry.cell), pose, sig: Math.round(fade * 24) * 1000 + poseKey(pose)};
  }

  function glow(color) {
    let sprite = glows.get(color);
    if (!sprite) {
      sprite = document.createElement('canvas'); sprite.width = sprite.height = 64;
      const g = sprite.getContext('2d'), ramp = g.createRadialGradient(32, 32, 0, 32, 32, 32);
      ramp.addColorStop(0, color + 'f2'); ramp.addColorStop(0.18, color + '73'); ramp.addColorStop(0.5, color + '1f'); ramp.addColorStop(1, color + '00');
      g.fillStyle = ramp; g.fillRect(0, 0, 64, 64); glows.set(color, sprite);
    }
    return sprite;
  }

  /** The rectangles the visible spores, petals and fireflies cover now. */
  function particleBounds() {
    const {cw, ch} = margins, rects = [];
    for (const p of living.particles) if (p.alpha > 0.01) rects.push({left: p.x - INK_PAD, top: p.y - INK_PAD, right: p.x + cw + INK_PAD, bottom: p.y + ch + INK_PAD});
    for (const f of living.flies) if (f.alpha > 0.01) rects.push({left: f.x - FLY_GLOW / 2, top: f.y - FLY_GLOW / 2, right: f.x + FLY_GLOW / 2, bottom: f.y + FLY_GLOW / 2});
    return rects;
  }

  function paintParticles() {
    const {context} = margins;
    for (const p of living.particles) {
      if (p.alpha <= 0.01) continue;
      context.globalAlpha = p.alpha; context.fillStyle = p.kind === 'spore' ? palette.leaves[1] : palette.blooms[p.slot % palette.blooms.length];
      context.fillText(p.glyph, p.x, p.y);
    }
    for (const f of living.flies) {
      if (f.alpha <= 0.01) continue;
      context.globalAlpha = f.alpha * 0.8; context.drawImage(glow('#e6f59a'), f.x - FLY_GLOW / 2, f.y - FLY_GLOW / 2, FLY_GLOW, FLY_GLOW);
      context.globalAlpha = f.alpha; context.fillStyle = '#fbffe0';
      context.beginPath(); context.arc(f.x, f.y, 1.8, 0, Math.PI * 2); context.fill();
    }
  }

  function draw(s, now) {
    const {context} = s;
    context.clearRect(0, 0, 1e5, 1e5);
    if (s === margins) drawn.clear();
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
      const pose = s === margins ? poseOf(cell) : REST;
      if (pose !== REST) drawn.set(key, poseKey(pose));
      paint(s, cell, smooth(0, FADE, age) * restAlpha(cell), pose);
    }
    if (s === margins) {
      for (const [key, entry] of living.entries) { const look = liveLook(entry); drawn.set(key, look.sig); paint(s, entry.cell, look.alpha, look.pose); }
      particleRects = particleBounds(); paintParticles();
    }
    s.ghosts = s.ghosts.filter(g => now - g.dying < GHOST);
    for (const ghost of s.ghosts) { busy = true; paint(s, ghost.cell, palette.baseAlpha * (1 - smooth(0, GHOST, now - ghost.dying))); }
    context.globalAlpha = 1;
    return busy;
  }

  function tick() {
    frame = 0;
    // A full redraw supersedes the ambient loop, which starts again below once the garden has settled.
    stopAmbient();
    if (!active() || !palette) return;
    ticks++;
    const now = performance.now();
    const busy = scenes.map(s => draw(s, now)).some(Boolean);
    const spent = performance.now() - now;
    drawMs += spent; slowestDraw = Math.max(slowestDraw, spent);
    // Draw only while something fades; a settled garden is a still image that breathes in CSS.
    if (busy && !frozen) frame = requestAnimationFrame(tick);
    for (const s of scenes) s.canvas.classList.toggle('breathing', !busy && !frozen && !still());
    if (!busy) startAmbient();
  }

  const canAmbient = () => lively() && !frozen && !frame && !document.hidden && !!palette && !!margins.field;
  const kick = () => { ambientTimer = 0; ambientFrame = requestAnimationFrame(ambientTick); };
  function startAmbient() {
    if (ambientTimer || ambientFrame || !canAmbient()) return;
    ambientLast = performance.now(); lastFrameAt = 0;
    ambientTimer = setTimeout(kick, FRAME_MS);
  }
  function stopAmbient() {
    clearTimeout(ambientTimer); cancelAnimationFrame(ambientFrame);
    ambientTimer = ambientFrame = 0;
  }

  /** One Living frame: move the model on, then repaint just the cells whose look changed and the particles' old and new places. */
  function ambientTick() {
    ambientFrame = 0;
    if (!canAmbient()) return;
    const began = performance.now(), {context, cw, ch} = margins, {columns} = margins.field;
    // The timer wakes a little early to land on the right display frame; a frame that arrives too soon waits for the next one.
    if (lastFrameAt && began - lastFrameAt < FRAME_MS - 2) { ambientFrame = requestAnimationFrame(ambientTick); return; }
    if (lastFrameAt) stats.shortestGap = Math.min(stats.shortestGap, began - lastFrameAt);
    lastFrameAt = began;
    living.advance(began - ambientLast); ambientLast = began;
    const changed = [], current = particleBounds(), remember = (key, sig) => { if (sig) drawn.set(key, sig); else drawn.delete(key); changed.push(key); };
    let swaying = 0;
    for (const [key, cell] of swayers) {
      const sig = poseKey(poseOf(cell));
      if (sig) swaying++;
      if (sig !== (drawn.get(key) ?? 0)) remember(key, sig);
    }
    for (const [key, entry] of living.entries) {
      const look = liveLook(entry);
      if (look.pose !== REST) swaying++;
      if (look.sig !== (drawn.get(key) ?? 0)) remember(key, look.sig);
    }
    // Live cells that finished withering since the last frame leave their last pixels behind unless they are cleared too.
    for (const key of drawn.keys()) if (!margins.field.cells.has(key) && !living.entries.has(key)) remember(key, 0);
    if (!changed.length && !current.length && !particleRects.length) { stats.idle++; return finishAmbient(began, 0, swaying); }
    // The rectangles to repaint, snapped to whole pixels so a clip edge never half-covers a device pixel.
    const reach = INK_PAD + Math.ceil(cw * 0.3), rects = [...particleRects, ...current];
    for (const key of changed) { const x = key % columns, y = Math.floor(key / columns); rects.push({left: x * cw - reach, right: (x + 1) * cw + reach, top: y * ch - INK_PAD, bottom: (y + 1) * ch + INK_PAD}); }
    let area = 0;
    context.font = monospace(margins.font); context.textBaseline = 'top';
    context.save();
    context.beginPath();
    for (const r of rects) {
      const left = Math.max(0, Math.floor(r.left)), top = Math.max(0, Math.floor(r.top)), right = Math.min(innerWidth, Math.ceil(r.right)), bottom = Math.min(innerHeight, Math.ceil(r.bottom));
      r.left = left; r.top = top; r.right = right; r.bottom = bottom;
      context.rect(left, top, right - left, bottom - top); area += Math.max(0, right - left) * Math.max(0, bottom - top);
    }
    context.clip();
    context.clearRect(0, 0, 1e5, 1e5);
    // Every cell the cleared rectangles touch is painted again, once, so nothing is lost or doubled.
    const touched = new Set(), now = performance.now();
    for (const r of rects) {
      for (let y = Math.max(0, Math.floor((r.top - INK_PAD) / ch)); y <= Math.floor((r.bottom + INK_PAD) / ch); y++) {
        for (let x = Math.max(0, Math.floor((r.left - INK_PAD) / cw)); x <= Math.min(columns - 1, Math.floor((r.right + INK_PAD) / cw)); x++) touched.add(y * columns + x);
      }
    }
    for (const key of touched) {
      const cell = margins.field.cells.get(key);
      if (cell) paint(margins, cell, smooth(0, FADE, now - margins.born.get(key)) * restAlpha(cell), poseOf(cell));
      else { const entry = living.entries.get(key); if (entry) { const look = liveLook(entry); paint(margins, entry.cell, look.alpha, look.pose); } }
    }
    paintParticles();
    particleRects = current;
    context.restore();
    context.globalAlpha = 1;
    finishAmbient(began, area / (innerWidth * innerHeight), swaying);
  }

  function finishAmbient(began, share, swaying) {
    const spent = performance.now() - began;
    stats.frames++; stats.drawMs += spent; stats.slowestMs = Math.max(stats.slowestMs, spent);
    stats.dirtyTotal += share; stats.peakDirty = Math.max(stats.peakDirty, share); stats.swaying = swaying;
    if (canAmbient()) ambientTimer = setTimeout(kick, Math.max(0, FRAME_MS - spent - VSYNC_MS));
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

  // Nothing moves in a hidden window; it picks up where it left off when shown again.
  document.addEventListener('visibilitychange', () => { if (document.hidden) stopAmbient(); else startAmbient(); });
  reduce.addEventListener?.('change', () => rebuild());

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
    activity(hold = FREEZE) {
      // An Off garden has nothing to hold still and must never schedule a frame.
      if (!active()) return;
      frozen = true;
      cancelAnimationFrame(frame); frame = 0;
      stopAmbient();
      // Hold the breathing where it is: removing it would snap the canvases back to full opacity on every key press.
      for (const s of scenes) s.canvas.classList.add('held');
      // Later input extends a hold; it never shortens one that a page turn asked for.
      holdUntil = Math.max(holdUntil, performance.now() + Math.max(FREEZE, hold));
      clearTimeout(freezeTimer);
      freezeTimer = setTimeout(() => {
        frozen = false;
        for (const s of scenes) s.canvas.classList.remove('held');
        if (pending != null) { progress = pending; pending = null; rebuild(); } else if (deferred) rebuild(); else schedule();
      }, holdUntil - performance.now());
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
      chapter = null; progress = 0; pending = null; frozen = false; deferred = false; holdUntil = 0;
      root.classList.remove('garden-on');
      percent.textContent = '';
      wipe();
    },
    debug(light = false) {
      const ambient = {running: ambientTimer !== 0 || ambientFrame !== 0, frames: stats.frames, drawMs: stats.drawMs, slowestMs: stats.slowestMs, shortestGap: stats.shortestGap,
        idleFrames: stats.idle, meanDirtyShare: stats.frames ? stats.dirtyTotal / stats.frames : 0, peakDirtyShare: stats.peakDirty, swaying: stats.swaying, time: living.time, living: living.counts()};
      // Cheap enough to poll every few milliseconds, unlike the cell rectangles below.
      if (light) return {frozen, mode, animating: frame !== 0, ticks, ambient};
      const rects = s => {
        if (!s.field) return [];
        return [...s.field.cells.values()].map(c => ({left: s.origin.left + c.x * s.cw, right: s.origin.left + (c.x + 1) * s.cw, top: s.origin.top + c.y * s.ch, bottom: s.origin.top + (c.y + 1) * s.ch, kind: c.kind}));
      };
      const track = s => s.track.map(p => ({left: s.origin.left + p.x * s.cw, right: s.origin.left + (p.x + 1) * s.cw, top: s.origin.top + p.y * s.ch, bottom: s.origin.top + (p.y + 1) * s.ch}));
      return {cells: rects(margins), spine: rects(column), foot: rects(foot), footTrack: track(foot), progress, frozen, mode,
        gutter: layout().gutter, animating: frame !== 0, ticks, drawMs, slowestDraw, ghosts: scenes.reduce((n, s) => n + s.ghosts.length, 0),
        card: root.classList.contains('garden-card'), on: root.classList.contains('garden-on'), palette, ambient};
    }
  };
}
