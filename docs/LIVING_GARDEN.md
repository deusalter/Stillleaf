# Living garden

The dashboard and menu panel gardens keep moving after they have grown. This is the "Living garden" direction from `design/dynamic-motion/index.html` (PR #43), built natively in `Sources/BooksPresence/Vines/`.

## What moves

| What | How often | Where it runs |
| --- | --- | --- |
| New shoot | One every 30–60 s, up to three growing at once; one cell per 1.5 s | App wakes once per step; each new cell is a layer that fades in |
| Growing tip | While a shoot grows | A glowing `•` layer that glides cell to cell |
| Old growth withers | When the garden is above the density it grew to; one branch at a time, over ~20 s, tip to stem | Cells fade out on a stagger; leaves and blooms let go of spores |
| Wind | A soft band crosses about every 10–14 s | Two leaf layers cross-fade under gradient masks the render server moves |
| Petals | A bloom sheds one about every 9 s on the dashboard | One layer per petal, flight sampled into a keyframe animation |
| Fireflies (dark) / pollen motes (light) | 8 on the dashboard, 3 around the menu panel, 3–7 s blink | One layer each, a looping keyframe path and a blink animation |

Density stays steady because a withering branch is chosen only when the garden holds more cells than it had when it finished growing, and the smallest suitable old branch goes first.

## How it stays cheap

- Settled growth is drawn into 256 pt tiles (three images each: stems, leaves and blooms at rest, the same blown aside). A tile is redrawn only when a cell in it settles or withers, about once every 3 s per growing shoot (new cells settle every other step), and at most two tiles per step. Nothing redraws on a frame clock.
- The app wakes once per growth step (1.5 s, 0.4 s tolerance) to hand the render server the next few layers. Wind, breathing, fades, glides, petals, spores and fireflies are Core Animation animations.
- Hidden, minimised or occluded: the timer stops and the moving layers and animations are removed. On return the garden catches up in one step; a gap longer than 20 minutes skips its oldest part.
- The glass's blurred copy of the garden is refreshed every two minutes and cross-faded.

## Modes

- **Animated** lives. **Still** (also Reduce Motion and Low Power Mode) is today's garden as one image: no wind, petals, fireflies or growth. **Off** draws nothing.
- Only layouts with `living: true` live (the dashboard and the menu panel's three gardens). The onboarding tour and the reader's margins are unchanged.

## Determinism and offscreen renders

`LivingGarden` is pure: the same seed and the same clock give the same garden, so tests and renders agree. `--living-time <seconds>` (or `STILLLEAF_LIVING_TIME`) renders a living garden at that moment of its life, with its wind band, petals, fireflies and any shoot or withering branch caught mid-way:

```sh
.build/local/BooksPresence --render-ui out --offscreen --living-time 420 --preview-filter today,popover
```

Without `--living-time`, frozen renders show the grown garden as before.

## Budget

`GardenFrameBudget` (in `DevTools/LivingGardenSmoke.swift`) sets the limits: idle main-thread CPU of at most 1.5% per window, a growth step of at most 8 ms at the 95th percentile and 33 ms at worst, and one-off limits for the first build, the return from hidden and the glass refresh. Each window is measured three times and judged on its best trial per metric: a shared runner only adds time, and a real regression raises every trial.

- CI runs `BooksPresence --garden-frame-budget <report.json>` on the release build and uploads the report.
- `scripts/measure-living-garden.sh` runs the same check locally, and with `--live` also samples real idle CPU in a window (run that only when the Mac is free).
- The render server's compositing work is not in either number; check it in Activity Monitor's Energy tab when tuning.

## Not in this change

- The mockup's **Calm** tier for Low Power Mode (growth once a minute, wind kept). Low Power still turns Animated into Still, as before.
- The reader's margins (wind, petals and fireflies there are a separate change).
