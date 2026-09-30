# Whole-book screen pagination

The footer sums measured chapter screens for the current layout. One facing
spread is one screen, including an odd final leaf. Before every chapter is
measured, it explicitly shows the current chapter's count and “Calculating book
pages…”. It never presents text units or estimated continuous placeholders as
an exact whole-book denominator.

`ScreenPaginationIndex` keeps up to eight layouts per open book. Keys contain
edition, viewport width/height, actual column fallback, typography/settings,
continuous versus Readium renderer, and a renderer version. Live measurements
populate the index first. Missing chapters are measured sequentially in one
inert invisible renderer at the same viewport, with the same resource sanitizer,
fonts and appearance settings. Images and fonts settle before counting. Work
yields between chapters and waits during scrolling and layout changes. A chapter
that cannot settle leaves the footer calculating; a later live measurement can
complete its count.

WebKit suspends frame handshakes far outside the window, so the transparent
measurement surface sits behind the UI within the window. It has no pointer,
keyboard or accessibility input; its frames remain outside the live reader.

Probes have no annotation decorators, selection callbacks, state callbacks or
reading-evidence listeners. Every annotation/frame query remains scoped to the
live `#reader`. They cannot steal keyboard focus. A changed layout aborts stale
measurements; closing waits for probe disposal before revoking publication
resources. Continuous content mutations and publication resource completion
invalidate affected live measurements; paginated resource changes update the
constant-cost screen extent. Note-only saves retain cached highlight ranges;
highlight styles do not invalidate publication geometry.

Displayed whole-book pages are independent of durable locators and native
evidence. Native positions retain chapter-local screen units and canonical text
coverage. Background completion, resizing, font changes and mode changes emit
no reading turns and rewrite no historical evidence or annotations.

Tests cover unequal chapter counts, odd spreads, cache reuse, stale font/viewport
generations, incomplete resources, both renderer modes, actual two-chapter
Readium totals, narrow facing fallback, continuous measured totals, focus,
closing during a probe and switching books. The native smoke additionally
checks rejected-save close cancellation and autosaved durable close. Synthetic
cloud tests do not replace the user's final test with their own EPUBs on macOS.
