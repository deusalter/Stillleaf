// One horizontal trackpad stroke turns one page; its momentum cannot cascade
// through a chapter. Vertical scrolling and modified/zoom gestures stay native.
export function installPageTurnWheel(wnd, {enabled, rtl, turn, gesture = {distance: 0, sign: 0, latched: false, last: 0}}) {
  wnd.addEventListener('wheel', event => {
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
  }, {capture: true, passive: false});
}
