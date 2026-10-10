# Quiet UI motion

The garden stays as it ships. The interface carries a little motion on top of it:

- **Counts.** Numbers count up the first time a screen appears (0.8 s) and roll when their value
  changes. Digits are fixed-width, so nothing shifts. They use SwiftUI's numeric content
  transition on macOS 14 and later, and a cross-fade on macOS 13.
- **Goal ring.** It fills dot by dot when it first appears (1.1 s). The leading dot then breathes on
  a 4 s cycle, and while a book is being read a light runs along the filled dots every 8 s.
- **Ripples.** Hovering a sidebar item, a button or the ring sends a soft ripple through the garden
  glyphs, behind the glass as well as around it. A click sends a stronger one.
- **Parallax.** The garden drifts up to 3 pt toward the pointer while the glass stays put. The
  drift snaps to whole device pixels, so text and glyphs stay crisp at rest.

## How it is kept light

Nothing here runs a per-frame loop or a timer.

| Effect | How it runs | Idle cost |
|---|---|---|
| Counts | SwiftUI text transition, one state change | none |
| Ring fill | the existing `Animatable` arc, once | none |
| Pulse and light | repeating `CABasicAnimation`/`CAKeyframeAnimation` on one layer each | none in the app; the render server animates |
| Ripple | a second copy of the garden image under a gradient mask whose stops and opacity are animated by Core Animation, 1.25 s, then removed | none |
| Parallax | a SwiftUI `offset` that changes only when the pointer crosses a device pixel (about 20 times across a whole window) | none |

The garden's frost masks stay where the glass is; only the garden underneath them moves.

## Stepping down

`QuietMotion` is the one policy (`QuietMotion.swift`):

| Tier | When | What plays |
|---|---|---|
| `full` | nothing turned down | everything |
| `calm` | Low Power Mode, or the garden set to Still or Off | counts and the ring's first fill only |
| `still` | Reduce Motion, and offscreen captures | nothing: values appear at their final state |

Repeating animations are removed while the window is hidden, occluded or minimised
(`WindowVisibilityObserver`) and added again when it returns. Counts do not replay when a screen
comes back unless its value changed or it has been away for ten minutes (`QuietLedger`).

## Checks

`BooksPresence --self-test-quiet-motion` (also part of `--self-test-ui`) inspects the layers
directly, so it needs no window and no waiting: the policy matrix, counting rules, Reduce Motion
(ring, counts, ripples and parallax), and that the pulse, light, ripples and parallax all stop with
the window, Low Power Mode, Reduce Motion and Reading.

`BooksPresence --render-ui <dir> --quiet-ui --offscreen` writes `quiet-ring-*.png` and
`quiet-ripple-*.png` frames for review. CI uploads them as `Stillleaf-Quiet-UI-previews`.
