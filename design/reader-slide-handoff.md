# Reader slide handoff

Separate follow-up to `859ea9f` on `ui/shared-type-motion`. No installation or merge.

## Behavior

Replaces the old post-navigation opacity/perspective tilt with a 260 ms horizontal
slide. The outgoing and incoming page surfaces share one track and easing curve;
they remain aligned at the seam. Next/previous reverse physical direction for RTL.
Both ordinary pages and chapter boundaries take the same path. The current page
remains visible while Readium prepares a new chapter.

Readium ignores its animated argument for these reflowable navigation methods.
The implementation therefore renders inert, script-free copies outside `#reader`.
The live iframe's dimensions, scroll offset, text nodes and transform are never
animated. Snapshots preserve CSS, loaded fonts, image assets, scroll position and
CSS Highlight ranges. They cannot receive input or enter the accessibility tree.
If capture cannot prepare within 600 ms, navigation falls back without a slide.

Turns share the existing navigation queue with jumps. Rapid input shortens the
remaining slide to at most roughly 65 ms, and queued turns use 90 ms slides, retaining
the input sequence without overlapping Readium calls. This is serial acceleration,
not an interactive drag or a mid-transition reversal of the same page pair.

Reduce Motion bypasses snapshots. Enabling it during a slide removes the transient
surface. Resize, preference changes, close and reopen also cancel presentation;
preference application waits for the navigation queue before reflowing the engine.
Buttons, arrows, Page Up/Down, existing Readium edge taps and horizontal trackpad
strokes enter the same turn path. Shift-arrows remain available for text selection.
Vertical wheel input, modified/zoom gestures, dialogs and text fields keep their
existing handling. One trackpad stroke cannot cascade through chapters on momentum.

## Exact shared files and progress integration

- `Reader/desktop/reader/src/main.js`: imports; PageSlide instance; turn queue;
  preference/resize/close cancellation; keyboard, wheel and existing edge-tap routing.
- `Reader/desktop/reader/src/reader.css`: isolated overlay styles only.
- New modules: `page-slide.js`, `page-turn-input.js`.
- Tests: new `test/page-slide.test.mjs`; one motion-expectation update in
  `test/reader-ui.test.mjs` (it previously asserted the old whole-reader animation).
- Native preview and reproduction scripts under `scripts/`.

No edits to `page-progress.js`, `resources.js`, native event handling, progress
payloads, counting rules, position calculations or page-evidence tests.

**Merge invariant for accuracy commit `00696c3d559893e19209245390510b680f209dba`:**
inside the queued callback in `turn`, after its validity guard and `dismissSelection`,
preserve these two lines from the accuracy implementation:

```js
refreshPosition();
const departure = nativePosition;
```

Keep them before `pageSlide.run` (after previous queued turns have completed).
Inside the successful Readium callback, retain:

```js
pageTurned(direction === 'next' ? 'forward' : 'backward', departure);
```

Do not sample at initial input enqueue time, and do not copy this branch's older
one-argument call over the new evidence hook. Keep all of that commit's position,
coverage, sequence/time and resource-length changes. The overlays are outside the
accuracy helper's `#reader iframe` scope. Shared edge taps now enter the same
deliberate-turn path as buttons; they emit one event, never a second synthetic event.

## Validation and evidence

- Renderer build passes; existing Vite large-chunk warning remains.
- Full renderer suite: 13/13 passed, including original page-evidence and continuous
  scroll checks, appearance, annotations, state restore, and responsive facing pages.
- Dedicated Chromium and WebKit tests cover LTR/RTL direction, rapid reversal,
  chapter boundaries, book end, keyboard and trackpad momentum, selection, removal
  under Reduce Motion/resize/close, live geometry, and inert/script-free snapshots.
- Native WKWebView fixture loaded the actual built renderer and executed seven turns
  in expected order (forward, backward, forward, forward, backward, forward, backward).
  It ended back on chapter one's final page, with no overlays remaining. Every sampled
  live-reader transform was `none`.

Run `bash scripts/render-reader-slide.sh`. It needs existing npm dependencies,
Playwright WebKit (`npx playwright install webkit` from the renderer directory), the
Swift compiler and ffmpeg. It briefly shows its own synthetic WKWebView window and
closes it; it never launches or replaces the installed Stillleaf application.
Run with the Mac's Reduce Motion disabled to produce the native slide samples;
the browser tests emulate both modes without changing the Mac's setting.

Review assets are in `.local/reader-slide/`: `index.html`,
`webkit-reader-slide.mp4`, `native-sampled-slide.mp4`, `native/sample-02.png`,
`native/result.json`, and `native/frames.json`. The native sample clip is explicitly
slowed 4x; compositor-frame capture is not a display-pacing or input-latency benchmark.
The existing application, database and preferences are not involved in these fixtures.

Final combined native progress/coverage validation belongs to the integration owner
and core reviewer after preserving the departure hook above. This isolated branch
does not claim to have run the merged accuracy implementation.

## Follow-up: navigation completion must own the queue

Independent review identified that the four-second turn timeout could release the
queue while Readium still held `_isNavigating`, losing a subsequent queued turn.
The same deadline existed in jumps, which now share this queue, so both paths use
`NavigationCompletion`. Only Readium's callback releases a live operation. Retiring
the owning navigator cancels the application wait; duplicate/late callbacks cannot
run its completion effects. Close retires those waits before awaiting preference
work. A preference request waiting for navigation also retains its original lifecycle
so it cannot apply to a reopened publication.

The new browser regression delays a real Readium chapter-activation message for
4.25 seconds (prefetch cannot bypass this delay). It verifies that no later command
starts, neither accepted input resolves early, and release completes both in order.
It repeats this for a jump followed by a turn, with only the turn producing evidence.
A separate case withholds a turn command on an already-loaded frame, disposes that
navigator, checks that pending turns/preferences settle without stale effects, and
reopens the book successfully. Unit tests cover duplicate callbacks, thrown starts,
disposed-owner rejection and isolation of the new navigator.
The existing facing-page UI assertion now waits for preference work to complete
before turning; its old fixed delay could attempt a turn during reflow under load.

This disposal regression concerns a navigator that Readium can actually retire.
It does not claim to force-abort an indefinitely stalled Readium chapter activation:
Readium's existing `FramePoolManager.destroy()` itself waits for in-progress chapter
loads. An exploratory fixture that withheld that activation forever also held its
destructor. The fix does not fabricate a completion or navigate again on that live
engine to work around it.

The accuracy integration requirement above is unchanged: capture `departure` inside
the queued turn and pass it to `pageTurned` in the `NavigationCompletion.wait`
completion callback. No event payloads or coverage calculations changed here.

Follow-up validation: renderer build passed; final full renderer suite passed 16/16;
the delayed-navigation regression also passed independently in WebKit. No installed
app was changed and no branch was merged.
