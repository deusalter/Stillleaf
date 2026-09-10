# Shared type and motion refinement

Branch: `ui/shared-type-motion`. Base: `029b1be` (`ui/appearance-mode`).

## Decision and scope

The walkthrough's dedicated display scale, staged reveals, direction-aware steps,
and constrained content already provide useful hierarchy. Preserve that composition
and its motion. In the daily interface, distinguish navigation and measurements from
book titles instead of introducing another font family or additional entrance effects.

- Shared page heading: native SF, 30 pt semibold (formerly New York, 34 pt regular).
- Shared numbers: native SF regular, with monospaced digits at the token level.
  Equal-length counts keep their width; adding another digit can still change width.
- Book titles and small section labels retain their existing treatments.
- Segmented labels use a constant 12 pt medium weight. Selection no longer changes
  glyph metrics from medium to semibold while the highlight travels.
- Selection uses a 0.24 response, damping 1 spring. No delay, overshoot, or input lock
  is added. SwiftUI can retarget the existing highlight during rapid selections.
- Reduce Motion continues to remove selection animation. Native Buttons, focus
  outlines, selected accessibility traits, arrow navigation, and hit geometry remain.

## Preservation and coordination

`Onboarding.swift` has one narrow call-site change: the goal-unit picker explicitly
requests its existing typography and 0.16-second ease-out. Its remaining source and
the shared button style are unchanged. The walkthrough uses no changed page-title
or numeral tokens.

Shared-file changes: `ReadingLayout.swift`, `ReadingMotion.swift`,
`ReadingControls.swift`; preservation call: `Onboarding.swift`. No History, Library,
Settings, titlebar, appearance, or icon page implementation is edited. Integrate the
shared primitives once; page owners should not duplicate the new font/motion tokens.

## Audit boundaries

Existing shared buttons use a 0.985 press scale and opacity feedback, 100 ms press and
140 ms hover easing. They keep their layout bounds and disable scaling under Reduce
Motion. That tiny scale may contribute to a softer/tactile impression, but this pass
does not claim it is the cause of the reported cheapness and preserves it because the
walkthrough shares the treatment. No hover/press runtime change is claimed.

The shared entrance is an opacity-only 180 ms reveal without retaining an outgoing
page. It is not a continuous page-to-page crossfade. Page-specific appearance keys,
layout jumps, cover hover geometry, and completion effects need evaluation by their
owners; this change does not hide them with a global animation.

## Review evidence and reproduction

Run `bash scripts/render-shared-style.sh` (Swift compiler, macOS, and ffmpeg needed).
It compiles the three original primitive files from the base commit and the current
ones into separate native fixtures, with the same unchanged palette/button sources.
It never creates an AppModel, reads a reading database, installs an app, or starts
tracking. Outputs are in `.local/shared-style/`:

- `index.html`: review gallery.
- `comparison-light.png`, `comparison-dark.png`: before left / after right.
- `comparison-motion.mp4`: ordinary selection, rapid reversals, final selection.
- `comparison-reduced.mp4`: same changes with Reduce Motion.
- `before/` and `after/`: original PNG frames in both appearances and motion modes.

The harness uses Swift 5.8's underscored writable Reduce Motion environment hook only
in preview code because its public property is read-only. Frame capture uses the
app-owned NSHostingView, not the user's screen. Movies encode those frames at 60 fps;
capture overhead means they are interpolation evidence, not refresh-pacing or latency
measurements. Keyboard/VoiceOver behavior is preserved in source, not interactively
certified by these movies.

Validation: full native app compilation and existing `--self-test-ui` passed, including
six-step onboarding, light/dark page layouts, six themes, and synthetic model checks.
The compiler reports the existing Onboarding `primaryAction` actor-conversion warning.
Before/after light fixtures each have 90 frames; Reduce Motion has exactly three
distinct images, versus 24 before / 37 after with normal motion. No installed app was
replaced or relaunched. Full app-owned page previews are under `.local/shared-style/pages/`.
