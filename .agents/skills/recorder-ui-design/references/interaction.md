# Motion and direct manipulation

Read this when implementing interaction, not for static copy or palette edits.

## Design a sequence, not isolated effects

Write a compact state sequence for the requested control. For example:

| Trigger | Visible response | Behavior |
|---|---|---|
| Enter timeline | Structure appears, lanes wipe in sequentially | One finite entrance; controls remain usable |
| Hover block | Edge scan, handles/readout become available | No layout shift or hit-target movement |
| Select | Selection frame resolves, detail panel reveals | Related fields stagger in reading order |
| Pick up | Block separates visually, origin stays marked | Pointer tracking starts immediately |
| Move/trim | Live position or duration plus destination feedback | No delayed animation on pointer position |
| Release | Resolve snap and settle; clear origin marker | One committed edit in a real editor |
| Cancel/change selection | Stop old reveal and restore coherent state | No queued stale animation |

Use the requested futuristic character through precise sequencing, masks, line drawing, spatial continuity
and selective contrast. Do not substitute a global scale bounce, constant scan loop, blinking decoration
or delayed text scramble for useful feedback. Changes should remain legible and actionable.

Current timing experiments, not fixed requirements: press 80 ms; hover 160 ms; reveal 300–420 ms;
lane stagger 60–90 ms; field stagger 50–80 ms; short damped settle around 200–250 ms.
Assess them live together. Do not copy a timing table and declare the experience polished.

## Dragging and trimming

- Use a stable coordinate space owned by the timeline. Snapshot initial position/duration at gesture
  start and compute each update from that snapshot plus total pointer translation. Do not accumulate
  the same translation repeatedly or measure against a view whose position is changing.
- Separate click, move and trim hit regions. Avoid a button recognizer competing with a drag recognizer.
  Give narrow handles a larger invisible hit region. Decorative overlays must not intercept input.
- Continuous motion follows the pointer. In this prototype, snapping every half-second during dragging
  was rejected as jumpy: show a candidate and resolve snapping at release. A production editor may need
  magnetic snapping near actual boundaries, with an escape modifier, if that is the requested behavior.
- Keep origin and destination distinct. An origin outline uses the original start AND original length,
  not whichever value is currently being trimmed. Clip previews to the lane without clipping feedback
  that is intentionally outside the block.
- Constrain moves and trims to timeline bounds and minimum durations. Support reverse drags, repeated
  drags, edge grabs, release outside the lane, cancellation, and window resizing. Do not change lanes
  unless the real model supports it.
- In the actual editor, preserve source/output time mapping and one undo transaction per gesture.
  A gallery mock with one block per lane does not prove collision handling or real timeline behavior.

## Reveals and staggering

- Animate an actual property over time: reveal mask, line extent, panel extent, field opacity/offset.
  Ensure views can reach their hidden initial state before animating. Check that the chosen transition
  applies to a real insertion/removal rather than an unchanged view.
- Preserve identity during a drag so selection details do not restart on every pointer update.
  Restart detail reveals only for meaningful selection changes or explicit replay.
- Stagger related children, not the whole window as one slab. Keep a consistent lead-to-follow order.
  The container reveal must not hide all of its children's staggered stages.
- Delayed work must cancel when selection changes, replay stops, or the view disappears. Test rapid
  clicking and repeated replay. Prefer cancellable state-bound tasks over untracked delayed closures.
- Masks and clipping can cut off focus rings, selection outlines, lifted blocks, shadows or handles.
  Inspect intermediate and settled frames, not only the interior content.
- Keep essential controls immediately responsive during entrance and replay. Avoid perpetual idle
  animation; a replay should terminate and leave a useful, stable state.

## Accessibility and verification

Read Reduce Motion at the component level. Remove translation, spring and wipe movement when requested;
preserve state feedback via static contrast or modest opacity. No flashing or strobing.
Keyboard selection, adjustment, focus and accessible values need explicit support in custom controls.

Exercise, at minimum, the changed paths: hover in/out; click; rapid reselection; slow and fast dragging;
trim both directions; bounds; release; replay interruption; reduced motion. For code that claims
frame-accurate editing, also test zoom/scroll coordinate conversion. Use a synthetic project or isolated
prototype, and do not automate unrelated desktop interactions.

Record outcomes honestly. Compilation, snapping assertions and a static screenshot are separate evidence;
none proves smooth live dragging. If live input cannot be exercised, state that limit.

## Primary research sources

Consult current platform documentation when API behavior or availability matters:

- [SwiftUI animations](https://developer.apple.com/documentation/swiftui/animations)
- [Input and event modifiers](https://developer.apple.com/documentation/swiftui/view-input-and-events)
- [Reduce Motion environment](https://developer.apple.com/documentation/swiftui/environmentvalues/accessibilityreducemotion)
- [Apple motion guidance](https://developer.apple.com/design/human-interface-guidelines/motion)

These establish mechanisms and accessibility constraints. The visual direction comes from the supplied
reference images and user feedback; platform defaults are not a substitute for studying them.
