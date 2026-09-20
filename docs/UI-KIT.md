# Recorder UI kit

## Direction and reference study

The user rejected the first cyan/neon palette, generic SF typography, widely tracked capitals,
slogans, and uneven gallery spacing. That direction is superseded.

The supplied references in `reference/ui-kit-inspiration/` are the visual source:

- `111992…jpg`: narrow technical lettering, white blocks, fine rules and black negative space.
- `72e44c…jpg`: aligned modules, white corner brackets, compact navigation, strong numbers.
- `2ff1aa…jpg`: white structural bars and changes in type scale; no need for saturated decoration.
- `3e597e…jpg`: restrained color used locally, never a rainbow of equal-weight signals.
- The remaining three boards demonstrate fine measurement marks and density. Their photographic blur,
  miniature text and ornamental data are not suitable for working controls.

Use black and neutral gray surfaces with white controls and text. Timeline blocks are opaque, pale
neutral/muted colors with dark labels. Red and yellow appear only in recording/error and warning states.
No neon cyan, magenta, acid green, glow, promotional slogans, forced uppercase or expanded tracking.
The refined timeline uses cream (#ECE6CE), ice (#D7EAF0), sage (#DCE8D7) and lavender (#E5DCEC),
all close to white. White index tabs and larger DIN headings strengthen the structure without adding
letter spacing or ornamental copy.

## Typography and layout

Heading trial: Barlow Semi Condensed Light, bundled under the SIL Open Font License, with Andale Mono
for labels, timecodes and controls. DIN Condensed Bold was rejected as too dense in mixed-case titles.
DIN Light is not installed; Barlow is an explicitly identified alternative, not a simulated DIN weight.
Use natural casing and letter spacing.
Keep actual controls readable rather than reproducing the references' decorative microtext.

Gallery: 28-point outer inset, 12-point gutters, aligned paired sections, 20-point panel insets.
Thin neutral outlines with white corner marks establish structure. White filled buttons and solid
timeline blocks create the stronger white areas visible in the references.

All runtime tokens live in `Sources/Recorder/App/Theme.swift`; shared controls live in
`UIComponents.swift`. Do not introduce another palette in individual views.

The editor document bar uses a 48-point row with vertically aligned native window controls,
a divider after Projects, a 16-point light project title, and save status beside Export.
Long titles truncate while navigation and document actions remain visible.

## UX research

- [Apple typography](https://developer.apple.com/design/human-interface-guidelines/typography):
  legibility and hierarchy remain relevant; SF is intentionally replaced following user feedback.
- [Dark Mode](https://developer.apple.com/design/human-interface-guidelines/dark-mode):
  keep readable foreground contrast and inspect controls in the correct appearance.
- [Color](https://developer.apple.com/design/human-interface-guidelines/color):
  use consistent meanings and labels alongside state colors.
- [macOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-macos/):
  retain resizing, keyboard operation, menu commands and precise editing.

## Implementation plan

1. Rework the shared palette, typography and component states against the user's corrections.
2. Render and inspect the actual gallery; fix layout and appearance defects.
3. Finish application-wide adoption: library, capture, editor, inspector, sheets and settings.
4. Verify keyboard/accessibility states, resize behavior, timeline interaction and rendered screens.
   A passing gallery build alone does not complete the redesign.

Run `make gallery` for the interactive AppKit window. Run `make gallery-png` to build and inspect
`build/signal-ui-gallery.png`. Add `--ui-gallery-audition` to the gallery launch arguments to start
the bounded timeline motion sequence automatically for deterministic live captures.

## Capture floating-surface audit

The floating capture flow has a stricter job than an editor panel: it must remain immediately actionable
over another app without becoming a competing dashboard. The Signal references contribute shared rails,
fine square rules, a single white action and stable monospaced measurements. They do not contribute tiny
targets, invented telemetry, blurred material, or dense decorative data.

| Surface | Work and next action | Signal treatment | Functional invariant |
| --- | --- | --- | --- |
| Capture toolbar | Choose source/input, then choose a target | Compact 560-point panel: capture modes above labelled input menus, with guidance and Options below. Solid white selected mode; four outer corner marks replace the enclosing border. Off inputs retain a slashed icon and explicit text. | Native menus, persistent settings, keyboard escape order and dragging stay unchanged. |
| Display/window picker | Identify the exact capture target, then start | The target remains the largest visual object. Its name and real dimensions sit beside the sole white Start action; Resize is a secondary bounded action. | One picker per display, hover/front-most logic, Return and native resize menu remain unchanged. |
| Area measurement panel | Set exact selection bounds | A compact labelled measurement group, with aligned size/position columns and proper fields, sits near the selected region. | Text entry goes through the existing shared clamp path; Escape and direct manipulation stay intact. |
| Countdown | Confirm imminent capture | A single high-contrast numeral, with no unrelated chrome. Motion is a short transition and resolves to opacity-only under Reduce Motion. | Escape cancellation and timer lifecycle stay unchanged. |
| Recording widget | See recording state and finish/pause/restart/delete | Time is the evidence rail; Finish is the one filled action. Secondary commands have visible, keyboard-accessible 28-point targets. | All commands retain their existing controller paths and right-click Hide menu. |
| Camera bubble | Frame the person on top of the recording | Preserve the uncluttered live preview; it is content, not a technical panel. | Manual drag, nearest-corner snap, preview sizing and capture exclusion remain unchanged. |

The capture setup panel uses open corner marks rather than nested enclosing borders. The full-screen picker and the camera
bubble deliberately keep their distinct interaction roles rather than being forced into the same panel shape.

## Interaction prototype

The gallery contains an isolated timeline study; its edits do not modify project files.
Hover subtly darkens pale blocks and lifts them one point; it does not sweep an edge. Selection expands an external
white outline and reveals the block's in/out details. Moving and trimming follow the pointer continuously,
then settle onto half seconds on release. A dashed origin outline remains during a move.
Scrubbing updates the playhead directly. Movement uses a stable named coordinate space, and the block
is a directly manipulated view rather than a button competing with a drag recognizer.
The “Replay reveals” button runs a cancellable, bounded selection/reveal sequence: four lane wipes
staggered 85 ms apart, then selection detail fields staggered 75 ms apart. Wipes last 420 ms.
Section headings use the shared light condensed heading face at the scale defined by each surface.

Shared buttons use a restrained 160 ms surface change and an 80 ms press displacement. Selection uses
a short, strongly damped spring. Reduced Motion disables displacement and springs, retaining static
selection and opacity feedback. There are no idle timers or endlessly flashing decorations.

Research:
[SwiftUI animations](https://developer.apple.com/documentation/swiftui/animations) provides state-driven
animation and insertion/removal transitions.
[Continuous hover](https://developer.apple.com/documentation/swiftui/view-input-and-events) provides
pointer location for the timeline guide.
[Reduce Motion](https://developer.apple.com/documentation/swiftui/environmentvalues/accessibilityreducemotion)
is read from the environment for every animated component.

Check snapping and boundary clamping with `Recorder --selftest ui-motion`. Visual PNG checks cannot
prove interaction feel; exercise selection, drag, trim, scrub, cancellation and Reduce Motion in the gallery.

## Capture panel redesign / September 2026

The supplied toolbar screenshot made mode selection and optional inputs equally prominent along a long
rail. Reorganize around the recording decision: source choice, input review, target selection. The new
560-point surface trades some height for less horizontal travel and stable input columns. It is deliberately
distinct from the original Screen Studio-derived strip; the design comes from Recorder's own corner marks,
light condensed heading, white selection and dark working surfaces.

- [Progressive disclosure, NN/g](https://www.nngroup.com/articles/progressive-disclosure/): keep camera,
  microphone and system audio visible because they affect the recording; defer countdown and other
  configuration to the labelled Options menu. Do not hide all inputs behind one gear.
- [Visibility of system status, NN/g](https://www.nngroup.com/articles/visibility-system-status/): separate
  stable input labels from their current values, explicitly show Off, and distinguish a missing configured
  device as Unavailable. Full names remain in tooltips and accessible values when the visible name truncates.
- [Buttons, Apple HIG](https://developer.apple.com/design/human-interface-guidelines/buttons): preserve
  press feedback, clear labels, selected states and native button semantics. Capture modes use the shared
  button style with a white selection; menu chevrons communicate that input clicks open choices.
- Hover uses the shared 160 ms surface response. No repeated sweep or progress-like line; Reduce Motion
  suppresses press displacement. Corner marks are structural, static, noninteractive and shared with TechPanel.

Inspect the actual borderless panel with `build/Recorder.app/Contents/MacOS/Recorder --selftest
capture-panel-png build/capture-panel.png`. The gallery also embeds the production ToolbarView.

## Project selector / September 2026

The library uses a regular preview grid because recordings are visual content. Keep three columns at
900 points and two at the 640 × 480-point minimum; Up/Down follow those columns and selection scrolls into
view. A separate search rail makes filtering distinct from the primary New capture action. A quiet
footer explains import when idle and exposes Open project when selected. Cards and titles open with one click; arrow keys select and Return opens.
Rename is available through the visible actions menu and context menu, avoiding accidental edits.

The header and native title bar share `Theme.bgWindow`, with transparent title-bar chrome and no
separator. Native traffic lights and title-bar dragging remain. There is no background graph paper or
accent stripe. Fixed 16:9 preview bounds contain the complete recording image, including ultrawide and
portrait sources; a missing image receives a labelled placeholder. Duration appears only on the preview.
Light condensed titles, monospaced metadata, fine rules and one white primary action retain Signal's
visual language. Hover changes the card surface in 160 ms without moving targets; Reduce Motion makes
this immediate. Selection has an immediate white outline and a separate keyboard focus indicator. The focusable
grid suppresses its SwiftUI focus effect, and the AppKit hosting view uses `focusRingType = .none`,
so focus is drawn on the selected card instead of around the window.

Research informing the choice:
- [NN/g: thumbnail use](https://www.nngroup.com/articles/mobile-list-thumbnail/): prioritize recognizable
  imagery for visual content. Its mobile research informs this choice; the macOS layout is our application.
- [Apple: windows](https://developer.apple.com/design/human-interface-guidelines/windows): preserve
  expected window behavior and usable resizing.
- [Apple: motion](https://developer.apple.com/design/human-interface-guidelines/motion): motion explains
  state without delaying actions; respect accessibility preferences.
- [AppKit transparent title bars](https://developer.apple.com/documentation/appkit/nswindow/titlebarappearstransparent):
  use the native window property instead of drawing replacement window controls.

Launch: `open -n build/Recorder.app --args --projects`.
Render a read-only view of an existing folder, including native title-bar chrome:
`build/Recorder.app/Contents/MacOS/Recorder --selftest library-png ~/Movies/Recorder build/projects.png 900 600 --existing`.
Omit `--existing` only for a scratch fixture folder; that mode creates three sample projects.

Finder imports accept file-URL drag representations and validate media through the existing importer.
Drops process sequentially, retain failures, and show release-to-import feedback in the footer.
`Recorder --selftest import` checks a URL-only item provider through project creation and source preservation.

## Timeline 2.0 / September 2026

The production editor now uses one continuous, compact editing surface: tool/navigation rail,
fixed track labels and counts, pale blocks, then selection evidence and a whole-project overview.
The gallery embeds `TimelineView` and `TimelineToolbar` with a disposable project alongside the
isolated motion study. Both widgets are the production implementations.

Research translated into decisions:
- [Final Cut Pro snapping](https://support.apple.com/en-hk/guide/final-cut-pro/ver9f7888dc3/mac):
  explicit Snap state, N to toggle, and Command to bypass during a gesture. Existing source/output
  time mapping, snapping candidates, collision constraints and undo boundaries remain shared.
- [NN/g complex applications](https://www.nngroup.com/articles/complex-application-design/):
  keep common tools visible; group Select/Split/Snap separately from Focus/Fit/zoom. Selection
  exposes exact output in/out/duration in a stable rail. F focuses clips or selected effects with
  context on both sides; the overview retains project context and pans without changing edits.
- [Apple motion](https://developer.apple.com/design/human-interface-guidelines/motion):
  continuous pointer tracking; stationary origin outline during effect moves/trims; a 240 ms
  ease-out selection outline and detail fade; existing 180 ms ripple explains committed clip
  changes. Animations terminate and rapid reselection replaces the current transition. Reduce
  Motion removes spatial selection/ripple/shake motion. No entrance delay or ambient loop.
- The supplied technical reference boards inform fixed alignment rails, natural-case monospaced
  evidence, narrow light heading, quiet rules and local opaque track colors. Color is reinforced
  with track names and counts, labels, selection outlines and visible trim grips.

Workflow and rendering details:
- The 220-point minimum reserves space for every track and the overview; the panel remains resizable.
- Track labels stay fixed and cannot intercept an offscreen clip. Blocks, rulers and playheads clip
  to the editing viewport. An offscreen playhead does not display a misleading pinned time chip.
- Waveforms use dark ink on cream and only sample visible pixels when deeply zoomed.
- The overview supports click-to-center outside the viewport, drag to pan, clamping and Escape.
  Its accessibility slider offers page navigation; existing block adjustment and keyboard commands
  remain available. Focus/zoom also work without a pointer.
- No clips receives recovery guidance. Focus disables without a visible selection.

Verification commands:
```
make test
make gallery CONFIG=debug
make gallery-png CONFIG=debug
build/Recorder.app/Contents/MacOS/Recorder --selftest timeline-ops
build/Recorder.app/Contents/MacOS/Recorder --selftest timeline-png build/timeline-v2.png 900 --motion
build/Recorder.app/Contents/MacOS/Recorder --selftest timeline-png build/timeline-v2-zoomed.png 1100 --zoomed
build/Recorder.app/Contents/MacOS/Recorder --selftest timeline-png build/timeline-v2-empty.png 640 --empty
```
`--motion` opens a native test window, exercises hover, selection, move, cancellation and rapid
reselection with synthetic events, samples intermediate PNGs and checks that motion terminates
and cancellation preserves the fixture. This verifies event/state behavior; it is not a human
assessment of pointer feel. The gallery provides the interactive comparison.

## Independent timeline tracks / September 2026

The title is removed. The 32-point tool rail uses unboxed 13-point native symbols in 28-point
hit regions, with a short white underline for active tools. Tooltips, accessible names and
keyboard commands remain. No rounded button shells, pill zoom slider, rounded time chips or
rounded timeline blocks: the user explicitly rejected those treatments. The footer anchors to
the panel bottom. Rows stay at their compact height when expanded; remaining height is open workspace.

Video, camera footage, zoom, keystrokes and masks are separate lanes. Camera layout effects have
an additional lane only when present. Blade clicks target the hit block; keyboard/menu Split targets
the selected block or primary video. A screen split does not draw artificial cuts through effects.
Delete lifts video into a gap; trims preserve duration. Dragging video uses adjacent free space,
clamped at occupied neighbours; moving the final clip right extends the timeline. Camera moves retain their media
in-point. Camera/keystroke cuts and removals are independent, with contextual inspector controls.
Background is enabled by default and remains visible in screen gaps. Screen-associated audio follows
video lifts/moves. Preview/export share gap visibility and independent camera composition.
Version 2 preserves gap/media in-points and the independent camera/keystroke arrays; version 1 opens
with a full camera clip when recorded and migrates keystroke-only layout blocks.

Research translated into these choices:
- [Apple: cut clips](https://support.apple.com/en-gb/guide/final-cut-pro/ver4e30479/mac):
  blade a target or selection, with all-track cutting a separate operation.
- [Apple: arrange clips](https://support.apple.com/en-in/guide/final-cut-pro/verc147f195/mac):
  position edits and gaps provide explicit placement without forced ripple.
- [Apple: toolbars](https://developer.apple.com/design/human-interface-guidelines/toolbars):
  group related commands and retain recognizable symbols. The unboxed square treatment follows
  the user's Signal direction and supplied boards, rather than copying platform chrome.

Checks: `make test`; `Recorder --selftest timeline-ops`; `Recorder --selftest timeline-tracks`.
The latter drives blade/selection/delete, undo/redo, checks shared frame visibility inside gaps,
and builds real AVFoundation screen/camera compositions to verify independent media placement.
`timeline-png ... 900 --motion`, `--gaps`, `--tall`, `--empty` and `--zoomed` cover rendering variants.
Synthetic input checks establish event behavior, not a human judgment of pointer feel.

The follow-up rejection of rounded corners also sets the shared control/card/panel radius tokens
in `Theme.swift` to zero, consistently across AppKit and SwiftUI. Native system window chrome and
media styling (such as a user's camera roundness setting) keep their own semantics.


Timeline follow-up: fixed 32-point video and 24-point overlay lanes leave additional panel height
as workspace; the overview/footer stays pinned to the bottom. Command–X cuts the selected clips to the clipboard; Command–V pastes them on their original
tracks at the playhead (text fields retain native Cut/Paste). The unboxed Link control beside Snapping is saved
with the project and defaults off. When enabled, video splits, lifts, trims and moves carry the
intersecting camera, zoom, keystroke and mask sections; layer edits never affect video or siblings.
Linked speed changes carry the layer clock. Unlinked speed changes preserve other layers' timing,
using adjacent gaps or extending the final clip; occupied video bounds how far a clip can slow down.
Version 3 persists the link setting, independent media/clock speeds and keystroke media offsets.
Rightward moves leave actual background gaps and retain media in-points. Synthetic interaction and
AVFoundation checks cover targeted splits, repeated linked drags, undo/redo and camera speed/move timing.

## Timeline selection and deletion modes / September 2026

Link layers to video and Ripple Delete default to on for new projects and missing saved fields;
explicit saved choices remain intact. Ripple Delete sits immediately beside Link, using
`arrow.left.to.line` with the existing active underline, tooltip and accessible On/Off value.
Ripple Delete closes deleted video time across the timeline; turning it off leaves a gap.
Link controls whether video edits slice, remove and move the overlapping layer content.

Drag empty video space or the blank area below the tracks to box-select video. Shift-click
adds/removes individual video clips; Shift-drag adds a rectangle selection. Command-A selects
all video. Dragging a selected video moves the group with its spacing intact, carrying linked
layers. Moves retain the existing collision/clock-boundary constraints. Escape restores the
pre-drag project and group selection; each completed move is one undo step. Effect-lane empty
space retains click/drag-to-create; Shift-drag there starts video box selection.

Video returning after a gap uses a 180 ms smooth opacity ramp, shortened for short clips.
The initial video frame and adjacent cuts remain immediate. The shared frame-state/compositor
path applies the same fade to preview and export, including the screen shadow, cursor and masks.

Research: [Apple's clip selection guide](https://support.apple.com/en-ca/guide/final-cut-pro/ver28912fd/mac)
documents rectangle selection and group moves; [Adobe's removal guide](https://helpx.adobe.com/sg/premiere/desktop/edit-projects/change-clip-sequence/remove-clips-from-a-sequence.html)
distinguishes leaving a gap from Ripple Delete. The default-on choice and automatic gap fade
come from this app's requested workflow, rather than a universal editor default.

Verification: `make test`, `Recorder --selftest timeline-selection build/timeline-selection.png`,
`Recorder --selftest timeline-tracks`, and `Recorder --selftest timeline-ops`.

Timeline clipboard: Command–X cuts the selection, Command–C copies, and Command–V pastes at
the playhead. Video, camera, keys, zoom, layout and mask clips retain their settings, speed and
media offsets. Video paste fills available gaps and inserts extra time where needed, shifting
existing content; layer paste replaces only overlaps on its own lane, keeping outside pieces.
Cut follows the saved Link/Ripple Delete modes; Cut and Paste each undo independently. Clipboard
media references currently work within the source project while Recorder remains open. C and
blade clicks still split. `Recorder --selftest timeline-clipboard` exercises all six tracks using
a private pasteboard, plus selection, undo/redo and stale-clipboard handling.

Project opening preserves the editor’s layout from the first frame: top bar, preview status, inspector and timeline. Preparation happens off the UI thread, with no artificial minimum wait. Ready controls reveal over 160 ms; Reduce Motion switches immediately. Preview loading remains labelled until the first video frame arrives.
