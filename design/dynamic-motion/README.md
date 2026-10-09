# Dynamic motion directions

Open `index.html` in a browser. It is one self-contained page with no build step.

Four directions for keeping the garden moving all day, each running live in the dashboard, the menu bar panel and the reader:

- **Living garden.** It never finishes growing: new shoots keep growing, old branches wither into spores, leaves move in a slow wind, petals fall, and fireflies (pollen motes in light mode) drift.
- **Responsive garden.** Still until you act: vines lean away from the pointer, the garden fills with today's reading goal, the reader's margins rustle on page turns, and the colour follows the time of day.
- **Passing weather.** Calm by default. Every few minutes a gust, soft rain or drifting seeds passes, then the garden settles.
- **Quiet UI.** The garden stays as it ships. The interface carries the motion: count-ups, a breathing goal ring, ripples through the glyphs on hover, and slight glass parallax.

The controls above the windows switch between directions and simulate **Low Power**, **Reduce Motion** and **Window hidden**, so you can see how each one steps down. **Fast preview** compresses growth and weather into seconds; **Real time** uses the planned rates. The meter shows what this page itself costs to draw. That number is for the mockup, not the app plan.

Below the windows, each direction lists what moves and how often, how the app would run it (compositor work, frame budget, idle CPU target, behaviour when hidden), and how it steps down. A comparison table and a recommendation close the page.

URL parameters select a state directly, for example `index.html?dir=weather&tier=calm&theme=light&tod=dusk`.

## Screenshots

`shots/` is produced headless, so no window opens:

```sh
cd Reader/desktop/reader
npm ci   # first time in a clone
node ../../../design/dynamic-motion/capture.mjs          # everything
node ../../../design/dynamic-motion/capture.mjs weather  # only shots whose name contains "weather"
```

- `<direction>-frame<N>.png`: controls plus all three windows, several frames apart.
- `<direction>-dash-<N>.png`, `-panel.png`, `-reader.png`: single windows at 2×.
- `<direction>-spec.png`: the direction's plan.
- `quiet-ripple.png`: a click ripple spreading through the pollen, read straight from the garden canvas. A ripple lasts 1.6 s, shorter than an element screenshot takes.
- `light-<direction>.png`: light appearance.
- `tod-<dawn|day|dusk|night>.png`: Responsive garden's time-of-day colour.
- `tier-<calm|still|hidden>.png`: Living garden under Low Power, Reduce Motion and a hidden window.
- `page-full.png`: the whole page.
