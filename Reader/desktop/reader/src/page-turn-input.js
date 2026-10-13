// One horizontal trackpad stroke turns one page; its momentum cannot cascade
// through a chapter. Vertical scrolling and modified/zoom gestures stay native.
//
// A wheel listener that may call preventDefault() makes the engine wait for script before it scrolls, so it is
// only attached while it can matter. `set(false)` detaches it (scroll mode scrolls on the compositor again) and
// `set(true)` attaches it. It starts attached.
export function installPageTurnWheel(wnd, {enabled, rtl, turn, gesture = {distance: 0, sign: 0, latched: false, last: 0}}) {
  const handler = event => {
    if (!enabled(event) || event.ctrlKey || event.metaKey || event.altKey || event.shiftKey || event.defaultPrevented) return;
    if (Math.abs(event.deltaX) <= Math.abs(event.deltaY) * 1.25 || !event.deltaX) return;
    event.preventDefault();
    event.stopImmediatePropagation();
    const now = performance.now(), nextSign = Math.sign(event.deltaX);
    if (now - gesture.last > 180 || (gesture.sign !== nextSign && Math.abs(event.deltaX) > 5)) { gesture.distance = 0; gesture.latched = false; }
    gesture.last = now; gesture.sign = nextSign;
    if (gesture.latched) return;
    gesture.distance += event.deltaX * (event.deltaMode === 1 ? 16 : event.deltaMode === 2 ? wnd.innerWidth : 1);
    if (Math.abs(gesture.distance) < 40) return;
    gesture.latched = true;
    turn((gesture.distance > 0) !== rtl() ? 'next' : 'previous');
  };
  return toggledListener(wnd, 'wheel', handler, {capture: true, passive: false});
}

/** A listener that can be attached and detached by one switch, and is idempotent either way. */
export function toggledListener(target, type, handler, options) {
  let attached = false;
  const control = {
    get attached() { return attached; },
    set(active) {
      active = Boolean(active);
      if (active === attached) return control;
      attached = active;
      if (active) target.addEventListener(type, handler, options); else target.removeEventListener(type, handler, options);
      return control;
    }
  };
  return control.set(true);
}
