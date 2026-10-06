/** The vine model shared with the Mac app (Sources/BooksPresence/Vines/VineField.swift):
 * tips that wander or follow paths across a character grid, leaving stems, leaves
 * and blooms. Deterministic for a seed, one cell per step, with masks and budgets. */

const TAU = Math.PI * 2;
const RANK = {stem: 1, leaf: 2, bloom: 3};
export const LEAVES = [['(', ')'], ['{', '}'], ['6', '9'], ['@', '@'], ['o', 'o'], ['(', ')']];
export const FLUTTER = {'(': '{', ')': '}', '{': '(', '}': ')', '6': '(', '9': ')', '@': 'o', 'o': '@'};
export const BLOOMS = ['✿', '❀', '✽', '*', '❁', '✻'];

/** The stem glyph for a step of (dx, dy) points; screen y grows downward. */
export function stemGlyph(dx, dy) {
  let degrees = Math.atan2(dy, dx) * 180 / Math.PI;
  if (degrees < 0) degrees += 180;
  if (degrees < 22.5 || degrees >= 157.5) return '─';
  if (degrees < 67.5) return '╲';
  if (degrees < 112.5) return '│';
  return '╱';
}

/** FNV-1a over kind and day: a garden stays the same for a day. */
export function gardenSeed(kind, day) {
  let hash = 2166136261;
  for (const byte of new TextEncoder().encode(`${kind}|${day}`)) hash = Math.imul(hash ^ byte, 16777619) >>> 0;
  return hash || 1;
}

function random(seed) {
  let state = seed >>> 0 || 7;
  return () => {
    state ^= state << 13; state >>>= 0;
    state ^= state >>> 17;
    state ^= state << 5; state >>>= 0;
    return state / 4294967296;
  };
}

const angleDifference = (a, b) => {
  let d = (a - b) % TAU;
  if (d > Math.PI) d -= TAU;
  if (d < -Math.PI) d += TAU;
  return d;
};

const DEFAULTS = {heading: -Math.PI / 2, life: 40, generation: 0, bias: null, biasStrength: 0.06, curl: 0, hue: 0, branchChance: 0.06,
  leafChance: 0.24, bloomChance: 0.75, maxGeneration: 3, branchLife: 14, path: null, wobble: 0, wobbleFrequency: 0.33, outward: null};

export function createField({columns, rows, cellWidth, cellHeight, seed, maxCells}) {
  columns = Math.max(1, columns); rows = Math.max(1, rows);
  const next = random(Math.imul(seed >>> 0, 9973) + 17 >>> 0);
  const cells = new Map();
  const tips = [];
  const field = {columns, rows, cellWidth, cellHeight, maxCells, maxTips: 60, budget: Infinity, allows: () => true, cells, stepCount: 0,
    get isGrowing() { return tips.length > 0 && cells.size < field.budget; },
    heads: () => tips.map(t => ({x: t.px, y: t.py})),
    plant, step, growToCompletion};

  const permits = (x, y) => x >= 0 && y >= 0 && x < columns && y < rows && field.allows(x, y);

  function put(x, y, glyph, kind, slot) {
    if (!permits(x, y) || cells.size >= maxCells) return false;
    const key = y * columns + x, existing = cells.get(key);
    if (existing && RANK[existing.kind] >= RANK[kind]) return false;
    cells.set(key, {x, y, glyph, alternate: kind === 'leaf' ? FLUTTER[glyph] ?? null : null, kind, slot, step: field.stepCount, phase: next() * TAU});
    return true;
  }

  function plant(spec) {
    const s = {...DEFAULTS, ...spec};
    tips.push({spec: s, px: (s.x + 0.5) * cellWidth, py: (s.y + 0.5) * cellHeight, heading: s.heading, drift: 0, life: s.life,
      lastX: s.x, lastY: s.y, index: 0, phase: next() * TAU});
  }

  function sprout(tip, x, y, dx, dy) {
    const s = tip.spec;
    if (next() < s.leafChance * (s.generation > 1 ? 0.7 : 1)) {
      const vertical = Math.abs(dy) > Math.abs(dx) * 0.6;
      const side = next() < 0.5 ? -1 : 1;
      const pair = LEAVES[Math.floor(next() * LEAVES.length)];
      const glyph = vertical ? (side < 0 ? pair[0] : pair[1]) : (next() < 0.5 ? pair[0] : pair[1]);
      put(vertical ? x + side : x, vertical ? y : y + side, glyph, 'leaf', Math.floor(next() * 5));
    }
    if (s.generation < s.maxGeneration && next() < s.branchChance && tips.length < field.maxTips) {
      let heading = Math.atan2(dy, dx) + (next() < 0.5 ? -1 : 1) * (0.55 + next() * 0.65);
      if (s.outward != null) heading = s.outward + (next() - 0.5) * 0.9;
      plant({x, y, heading, life: Math.floor(s.branchLife * (0.4 + next() * 0.8)), generation: s.generation + 1,
        bias: s.path == null ? s.bias : null, biasStrength: s.biasStrength * 0.6, hue: s.hue + 1, branchChance: s.branchChance * 0.7,
        leafChance: s.leafChance, bloomChance: s.bloomChance, maxGeneration: s.maxGeneration, branchLife: s.branchLife, curl: (next() - 0.5) * 0.08});
    }
  }

  function wander(tip) {
    const s = tip.spec;
    tip.drift = tip.drift * 0.82 + (next() - 0.5) * 0.42;
    tip.heading += tip.drift;
    if (s.bias != null) tip.heading += angleDifference(s.bias, tip.heading) * s.biasStrength;
    tip.heading += s.curl;
    let moved = false;
    for (let tries = 0; tries < 3 && !moved; tries++) {
      // Exactly one cell along the dominant axis, so stems never leave gaps.
      const length = 0.999 / Math.max(Math.abs(Math.cos(tip.heading)) / cellWidth, Math.abs(Math.sin(tip.heading)) / cellHeight);
      const nx = tip.px + Math.cos(tip.heading) * length, ny = tip.py + Math.sin(tip.heading) * length;
      const cx = Math.floor(nx / cellWidth), cy = Math.floor(ny / cellHeight);
      if (!permits(cx, cy)) { tip.heading += (next() < 0.5 ? -1 : 1) * (0.7 + next() * 0.6); continue; }
      const dx = nx - tip.px, dy = ny - tip.py;
      tip.px = nx; tip.py = ny; moved = true;
      if (cx === tip.lastX && cy === tip.lastY) return;
      let glyph = stemGlyph(dx, dy);
      if (s.generation >= 2 && Math.abs(tip.drift) > 0.32) glyph = tip.drift > 0 ? ')' : '(';
      else if (s.generation >= 2 && glyph === '─') glyph = '~';
      put(cx, cy, glyph, 'stem', (s.generation + s.hue) % 4);
      sprout(tip, cx, cy, dx, dy);
      tip.lastX = cx; tip.lastY = cy;
    }
    if (!moved) tip.life = 0;
    tip.life -= 1;
  }

  function follow(tip) {
    const path = tip.spec.path;
    if (tip.index >= path.length - 1) { tip.life = 0; return; }
    let placed = false;
    while (!placed && tip.index < path.length - 1) {
      tip.index += 1;
      const a = path[tip.index - 1], b = path[tip.index];
      const tx = b.x - a.x, ty = b.y - a.y, length = Math.max(Math.hypot(tx, ty), Number.EPSILON);
      const offset = tip.spec.wobble * Math.sin(tip.index * tip.spec.wobbleFrequency + tip.phase);
      const fx = b.x - ty / length * offset, fy = b.y + tx / length * offset * 0.6;
      const cx = Math.round(fx), cy = Math.round(fy);
      tip.px = (fx + 0.5) * cellWidth; tip.py = (fy + 0.5) * cellHeight;
      if (cx === tip.lastX && cy === tip.lastY) continue;
      const dx = (cx - tip.lastX) * cellWidth, dy = (cy - tip.lastY) * cellHeight;
      put(cx, cy, stemGlyph(dx, dy), 'stem', tip.spec.hue % 4);
      sprout(tip, cx, cy, dx, dy);
      tip.lastX = cx; tip.lastY = cy;
      placed = true;
    }
    if (tip.index >= path.length - 1) tip.life = 0;
  }

  function finish(tip) {
    if (next() >= tip.spec.bloomChance) return;
    const glyph = BLOOMS[Math.floor(next() * BLOOMS.length)];
    put(tip.lastX + Math.round(Math.cos(tip.heading)), tip.lastY + Math.round(Math.sin(tip.heading)), glyph, 'bloom', Math.floor(next() * 4));
  }

  /** Advances every tip by one cell. */
  function step() {
    if (cells.size >= field.budget) return;
    for (let i = tips.length - 1; i >= 0; i--) {
      const tip = tips[i];
      if (tip.life > 0) tip.spec.path ? follow(tip) : wander(tip);
      if (tip.life <= 0) { finish(tip); tips.splice(i, 1); }
    }
    field.stepCount += 1;
  }

  function growToCompletion(limit = 10000) {
    for (let steps = 0; field.isGrowing && steps < limit; steps++) step();
  }

  return field;
}

// ---- Colour ----

const channels = hex => [1, 3, 5].map(i => parseInt(hex.slice(i, i + 2), 16));
const toHex = rgb => '#' + rgb.map(v => Math.round(Math.max(0, Math.min(255, v))).toString(16).padStart(2, '0')).join('');
export const mixColor = (a, b, t) => { const x = channels(a), y = channels(b); return toHex(x.map((v, i) => v + (y[i] - v) * t)); };

function toHSL(hex) {
  const [r, g, b] = channels(hex).map(v => v / 255), high = Math.max(r, g, b), low = Math.min(r, g, b), l = (high + low) / 2;
  if (high === low) return [0, 0, l];
  const d = high - low, s = l > 0.5 ? d / (2 - high - low) : d / (high + low);
  const h = high === r ? (g - b) / d + (g < b ? 6 : 0) : high === g ? (b - r) / d + 2 : (r - g) / d + 4;
  return [h * 60, s, l];
}

function fromHSL(h, s, l) {
  h = ((h % 360) + 360) % 360; s = Math.max(0, Math.min(1, s)); l = Math.max(0, Math.min(1, l));
  const c = (1 - Math.abs(2 * l - 1)) * s, x = c * (1 - Math.abs((h / 60) % 2 - 1)), m = l - c / 2;
  const [r, g, b] = h < 60 ? [c, x, 0] : h < 120 ? [x, c, 0] : h < 180 ? [0, c, x] : h < 240 ? [0, x, c] : h < 300 ? [x, 0, c] : [c, 0, x];
  return toHex([(r + m) * 255, (g + m) * 255, (b + m) * 255]);
}

function luminance(hex) {
  const [r, g, b] = channels(hex).map(v => v / 255).map(v => v <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4);
  return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}
export const contrastRatio = (a, b) => { const [x, y] = [luminance(a), luminance(b)].sort((p, q) => q - p); return (x + 0.05) / (y + 0.05); };
export const isDarkColor = hex => luminance(hex) < 0.18;

function legible(hex, paper, dark) {
  let [h, s, l] = toHSL(hex), color = hex;
  for (let i = 0; i < 12 && contrastRatio(color, paper) < 3; i++) { l += dark ? 0.03 : -0.03; color = fromHSL(h, s, l); }
  return color;
}

/** Vine colours from the page theme's accent, nudged to 3:1 on the paper. */
export function vinePalette({accent, ink, paper}, dark) {
  const [hue, saturation] = toHSL(accent), s = Math.min(0.8, Math.max(0.38, saturation));
  const lightness = dark ? [0.64, 0.71, 0.57, 0.75, 0.67] : [0.36, 0.42, 0.32, 0.29, 0.40];
  const fix = color => legible(color, paper, dark);
  return {
    stems: [accent, mixColor(accent, ink, 0.25), fromHSL(hue, s * 0.9, dark ? 0.46 : 0.26), fromHSL(hue - 12, s, dark ? 0.52 : 0.3)].map(fix),
    leaves: [0, 16, -14, 30, -28].map((offset, i) => fix(fromHSL(hue + offset, s, lightness[i]))),
    blooms: [dark ? '#f5c65e' : '#d48e14', fromHSL(hue + 150, 0.62, dark ? 0.72 : 0.52), fromHSL(hue + 205, 0.55, dark ? 0.74 : 0.5), dark ? '#e2b574' : '#9a6424'].map(fix),
    head: dark ? mixColor(accent, '#ffffff', 0.7) : mixColor(accent, '#000000', 0.35),
    track: ink, baseAlpha: dark ? 0.85 : 0.96
  };
}
