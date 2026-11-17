# Notch motion study

The layout and transition target is the user-supplied 57-second, 720×720,
30 fps prototype. The video is not redistributed in this repository. Character
direction uses small deterministic geometric avatars: soft coloured silhouettes,
two-mark faces and direct pointer reactions. drem's paths and native layer code
are original; no web package, image asset or runtime dependency is embedded.
The menu-bar brand mark is unchanged.

## Reference observations

The entire clip was surveyed at half-second intervals. Dense consecutive
30 fps frames were inspected at 7.5–9, 12.5–14 and 39–40.5 seconds:

| Sequence | Observed behavior | drem interpretation |
| --- | --- | --- |
| Compact → overview | Black shell widens first, the character enlarges, two shallow areas appear | Fixed-height overview, one persistent character, clipped spring geometry |
| Overview → detail | Left card grows; task grid compresses into a narrow selector | Session selection by stable ID; same outer size and character anchor |
| Pointer / selection | Eyes follow the pointer; accent identifies the selected character | Two-axis gaze, stable project identity, finite squash/pop on hover or click |
| Collapse | Text recedes, cards contract toward the notch, character stays visible | Menu-bar-height shell; face, count/completion and actual wake-state glyph remain |

The reference includes error and upload/progress stories. drem does not invent
these states, percentages, task histories or results when the detector has no
such evidence. It shows confirmed actions and the last available public status.

## Motion ownership

SwiftUI owns the shell and overview/detail layout. Expansion uses a spring
with 0.42 response / 0.84 damping; collapse uses 0.34 / 0.84. Selection grows
the main card horizontally while shrinking the right-hand selector. The same
character view moves from the compact wing into the overview's left area.

Core Animation owns the character's small layer tree: a slow 2.4-point float,
sparse blinks, cursor gaze and a subtle body focus motion for confirmed
editing/tool activity. Reading moves the eyes, compacting squashes the body,
and direct interaction triggers one finite pop. Confirmed attention holds a
wide-eyed expression and plays one finite pop; simulated work motion stops while
waiting. Completion uses happy closed eyes and a mint body. Amber icon, border
and text keep attention legible without motion. Only the featured character
animates. Static grid faces share its deterministic identity but run no animation.
No display timer updates the SwiftUI hierarchy.

The normalized project folder is hashed once with FNV. After a 64-bit trait mix,
that seed selects a 24-bit pastel colour token, one of seven original silhouettes,
eye spacing, height and lean. Parallel Codex or Claude sessions in one folder
therefore share one character, while different folders are no longer reduced to
seven colour buckets. The folder keeps its character across refreshes and launches.
No provider, session ID, prompt or private transcript text affects appearance.
Reduce Motion removes repeating motion and gaze, with a short 0.12s transition.
Hidden, locked, sleeping and closed-lid states destroy the host and animations.
Manual dismissal retains only click/scroll event monitors over the camera target
for left/right/down restoration to compact mode. Left/right/up hide the compact
surface or expanded header; content scrolling is not a dismissal gesture. One
recognizer survives monitor replacement and latches each physical gesture until
the next gesture begins, excluding momentum. Click/menu commands still expand.
No hidden mouse-move monitor or polling remains.

`IslandSwipe` captures target eligibility and locks the dominant axis. The
surface follows normalized finger deltas with bounded offset, squeeze and
opacity; the 44 pt threshold only arms one haptic, never commits early. Release
commits distance or an intentional short flick, while reversal/cancellation
springs back. Momentum is ignored. Devices without phase events use one
cancellable 160 ms end debounce, not a timer loop. Mouse header drag shares
the reducer. Reduce Motion removes spatial feedback and haptics.

A restore drag creates a temporary compact, click-through host while preserving
the dismissed latch. Cancellation folds away and destroys it; successful release
restores only compact mode. Display/Space/lock/lid changes cancel capture and
tear down the host. Geometry-aware hit testing follows the visible transform.
Compact and hover heights equal the screen's safe-area top; only the invisible
camera hit target extends 12 pt below it. Partial completion has a six-second
notice; count and sleep ownership update immediately and independently.
The shell has square top corners, flush with the screen edge, and rounded lower
corners. Drawing and screen-space hit testing use the same path.

## Reproducible visual checks

Use empty, existing temporary directories as destinations:

```sh
DREM_ISLAND_RENDER_DIRECTORY=/path/to/renders \
  zsh scripts/test-automation.sh --filter renderReviewFixtures
DREM_ISLAND_MOTION_DIRECTORY=/path/to/motion \
  zsh scripts/test-automation.sh --filter renderMotionReview
DREM_ISLAND_GESTURE_DIRECTORY=/path/to/gestures \
  zsh scripts/test-automation.sh --filter renderFingerFollowingAndSettlement
DREM_ISLAND_PERFORMANCE=1 \
  zsh scripts/test-automation.sh --filter measureVisibleAnimationCost
```

The static fixtures cover compact, hover, overview, detail, privacy, attention,
overflow and completion. The gesture fixture samples a short hide drag, its
spring-back, a compact restore preview and its settlement from synthetic traces.
Reducer tests separately cover reversal, cancellation, commit and direction rules.
It does not replay a physical AppKit trackpad stream. The motion fixture samples
a real NSHostingView in an offscreen
nonactivating panel through expansion, detail selection, agent switching and
collapse. `sample-times.csv` records actual sampling times; it is not a GPU
frame-pacing benchmark. These frames verify layout choreography, not live
display smoothness, hardware notch occlusion, trackpad gestures or Spaces.

The opt-in performance fixture briefly shows a nonactivating synthetic panel
and reports process CPU in compact, post-expansion, expanded-steady, reduced
motion and removed-host intervals. Keep transition cost separate from steady
animation cost. It does not measure WindowServer/GPU usage or guarantee an FPS.

On the installed app, verify first click, session switching, action buttons,
outside click, hide/restore, no focus stealing, Reduce Motion and a full work
cycle. Screen capture privacy may prevent capturing the live island; do not
mistake a blank screenshot or a passing build for visual verification.

Terminal navigation reads kernel PID/start-time/TTY metadata only on a click,
walks a bounded parent chain to a running supported terminal, and selects an
unambiguous TTY match. A read-only AppleScript lookup can request Automation
permission; process identities are checked again before a second focus request.
Both requests run off the main thread with timeouts. iTerm2 supports session TTY;
Ghostty requires a scripting dictionary exposing `terminal.tty` (not present in
the tested stock 1.3.1). An error does not activate an arbitrary tab. No terminal
text, environment, keyboard input or project-title matching is used.
