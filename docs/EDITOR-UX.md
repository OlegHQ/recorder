# Editor workspace study

Status: design and implementation handoff complete. Research, density iterations, shared gallery prototypes, motion and integrated editor panels are delivered. The user has taken over hands-on testing and explicitly stopped further agent validation. Native OS Save/Finder interaction remains unverified; accessibility work stays deferred.

## Start with the editing job

A recording editor helps someone turn a captured explanation into a clear, intentional sequence.
The working loop is: watch → find the distracting moment → select its interval → adjust → replay.
Composition is a parallel loop: establish framing, camera and annotation defaults → inspect exceptions
at particular moments → return to the overall look. Export follows review. These are hypotheses based
on the product's capabilities and the user's feedback, not findings from invented user interviews.

The user needs to answer three questions before moving a control: what am I changing, where does it
apply, and where will I see the result? The current editor answers these inconsistently.

## Initial implementation audit

| Surface | Observed relationship problem | Direction / verification still needed |
|---|---|---|
| Document bar | Aspect and crop sit beside file navigation/export despite changing composition | Put framing with Canvas; retain native document actions. Verify min width, rename/save errors |
| Preview | Selection, playhead and the scope of global style are different contexts without a stable explanation | Label the viewed time separately from the edited object. Verify overlays and select/reveal actions |
| Transport | Review actions must stay attached to the image rather than the property form | Preserve stable play/step/time controls; test keyboard focus during field editing |
| Inspector navigation | Six project categories disappear on selection, requiring Back to recover | Persistent composition navigation; explicit Whole project / Selection scope; preserve selection while browsing defaults |
| Background | Background blur and screen padding/corners share an undifferentiated stack | Canvas groups: output shape, backdrop, recording frame; show the result together |
| Camera | Camera clip selection shows global CameraTab, implying clip-local appearance | Footage selection explains timing; global appearance has its own destination; timed layout is a deliberate separate action |
| Cursor | Appearance, movement and click feedback need separate outcome groups | Cursor groups: visibility/appearance, follow behavior, click feedback |
| Keys | Global defaults and interval overrides resemble the same form | State inheritance explicitly; show interval vs default scope; verify show/allKeys behavior |
| Audio | Sources and absence of recorded tracks determine available controls | Source-labelled gain/mute with actual absence states; verify listening workflow |
| Motion | “Screen” and “Advanced” do not explain zoom spring vs blur sources | Name the visible outcome, preview finite motion, disclose blur sources next to amount |
| Clip / Zoom / Layout / Mask | Selection forms lose project navigation; some actions need preview context | Stable selection identity, exact timing, reveal in preview; direct adjustment + precise fields |
| Multiple selection | selectedClip returns minimum index, so a group can look like one editable clip | Explicit group count; no accidental single-item property editing |
| Crop sheet | Modal framing separate from background/aspect | Evaluate integrated Canvas controls while preserving crop apply/cancel semantics |
| Export | Needs final review context and format-valid controls | Retain progress/cancel/result; verify narrow, failure and complete states |
| Loading/error/empty | Must preserve workspace landmarks | Verify loading, absent camera/audio, no clips, missing media, save/export failure |
| Timeline | User explicitly likes the current implementation | Keep its visual/gesture structure; use it in the prototype, do not redesign it |

## Research → decisions

- [NN/g, UX Strategies for Complex-Application Design (2025)](https://www.nngroup.com/articles/strategies-complex-application-design/)
  recommends studying the work and its constraints, then using prototypes to test domain assumptions.
  Our application: use a shared real project in the gallery so selection and controls cannot drift apart.
- [NN/g, 8 Design Guidelines for Complex Applications](https://www.nngroup.com/articles/complex-application-design/)
  recommends maintaining context, reducing clutter without removing capability, and supporting learning
  in context. Our application: keep composition destinations available while editing time; distinguish
  local edits from defaults with scope labels instead of a tutorial or a wizard.
- [Apple, Final Cut Pro Info inspector](https://support.apple.com/en-sg/guide/final-cut-pro/ver39581b11/mac)
  documents properties corresponding to the selected media. Our application: selection must truthfully
  identify the object that receives edits; global camera controls must not impersonate clip properties.
- [Apple, Motion](https://developer.apple.com/design/human-interface-guidelines/motion)
  informs continuity and state feedback. Our application: property groups reveal in reading order,
  selection feedback is immediate, replay can be interrupted, and Reduce Motion removes displacement.

Sources inform the principles; they do not prove this layout usable. Task walkthroughs and visual/input
checks are needed. No claim of completed usability research or user testing is made.

## Visual architecture

The seven local reference boards were opened and studied. The useful features are stable rails,
asymmetric white anchors, thin rules, narrow light headings and localized pale color. The photographic
boards' tiny type, blur and fake telemetry are unsuitable for the editor. Use whitespace between
relationships, not boxes around everything. Selected destinations have a white block; selected timeline
objects retain their existing semantic colors. Natural-case readable labels carry meaning without color.

Prototype: 132-point composition rail → flexible spatial preview → 320-point properties; full-width
production timeline below. At constrained widths the rail should eventually collapse to a labelled
menu, not consume the preview. The gallery starts at 900 points to expose this pressure early.

## Motion contract

Selection changes the scope immediately. A brief stagger reveals the context and controls; the navigation,
preview bounds and timeline remain stationary. Direct manipulation receives no decorative easing.
Replay walks through project framing → zoom selection → camera footage → camera defaults. User input
cancels replay. Reduce Motion keeps the same states with no translation. Finite tasks cancel when the
view disappears or the selection changes. Verify rapid selection, replay restart and interruption.

## Original acceptance checklist (current evidence below)

- [x] Review whole workspace at default and minimum editor sizes, long titles and deep scroll.
- [x] Complete shared widget/panel designs for Canvas, camera, cursor, keys, sound and motion.
- [x] Verify real preview correspondence, direct manipulation and exact interval evidence.
- [x] Integrate the workspace architecture into the native editor shell; user-approved camera pad is the default.
- Deferred by user: accessibility acceptance. Named native keyboard/focus checks pass; this does not claim a complete accessibility audit.
- [x] Implement crop/export/error/empty/loading flows and preserve timeline behavior. Existing checks pass; remaining hands-on OS Save/Finder testing belongs to the user by explicit instruction.
- [x] Perform combined command-driven walkthrough: frame recording; trim dead time; emphasize one moment;
      hide camera for one interval; adjust global camera; mask private data; visit audio/keys; export and
      retrieve the file URL through Copy. Individual native gestures are checked separately; this is not
      an end-to-end OS pointer session or a study with users.

A gallery prototype, screenshot or passing model test alone cannot check these boxes.

## Space evaluation log

The user explicitly requested multiple evaluated iterations. Keep comparing usable work area and task
clarity, rather than treating a prettier render as success.

| Pass | Evidence | Decision |
|---|---|---|
| 1: persistent side rail | `build/editor-workspace-900-v1.png`, `build/editor-workspace-1120-v1.png`; rail consumes 132 pt and is largely empty below six destinations | Retain as an interactive comparison, test a horizontal destination row |
| 2: compact navigation | `build/editor-workspace-900-v2.png`, `build/editor-workspace-1120-v2.png`; 40 pt row replaces the rail. At 900 pt, specimen width grows 406 → 547 pt (35%); at 1120 pt, 588.5 → 608 pt (3%), limited by height | Prefer compact navigation at constrained widths. Added width is not automatically added usable image area |
| 3: property relationships | `build/editor-workspace-900-v3.png`; split Recording frame from Backdrop and put frame controls first; scope copy shorter | Better distinction, but Blur falls below the viewport. Reject the spacing as finished |
| 4: compact within groups | Reduce inter-control gaps from 12 to 8 pt; retain section headings and rule; center the fitted specimen | Render again and verify all common Canvas controls remain visible |

Measurements are the longest contiguous backdrop-colored run in captured PNGs, converted to logical
points using capture width. This measures the schematic image, not real video preview or task success.
The time-editing area stays 250 pt in these comparisons. The gallery chrome is experimental and is not
the production document/transport chrome; these measurements cannot claim a production area gain.

Current checks: `make test` passed 68 core tests. `workspace-png` captures Canvas, zoom, camera footage,
multiple selection and deselection, and asserts that browsing those states adds no edits or undo steps.
These checks do not establish keyboard navigation, human usability or motion feel.

Run the interactive study with `make gallery CONFIG=debug`. Compare side rail/compact navigation and
Replay workflow are in the workspace header. Capture the five states with:

```
build/Recorder.app/Contents/MacOS/Recorder --selftest workspace-png build/editor-workspace.png 1120
build/Recorder.app/Contents/MacOS/Recorder --selftest workspace-png build/editor-workspace-900.png 900
```

Outstanding for the next iteration: replace the specimen with a real media fixture and production preview,
exercise replay interruption and reduced motion, consolidate redundant selection headings, design the
individual camera/cursor/keys/sound/motion controls, and integrate the validated architecture into the editor.

Pass 4 result: inspected `build/editor-workspace-900.png` and `build/editor-workspace.png` (1120 pt).
All common Canvas color-mode controls, including Blur, are visible without scrolling. The fitted specimen
is centered at the wider size. The final gallery render was also generated and inspected. Wallpaper/image
variants, remaining destinations and real preview interaction still need their own space evaluation.

## Inspector workflow research: defaults, intervals and effective state

A second source/code pass examined CameraTab, KeysTab, LayoutPanel, ZoomPanel, CursorTab, AudioTab,
PreviewView camera hit-testing, TimelineOps.addLayout and makeFrameState. The critical distinction is
not simply “global versus local”: it is **default → explicit override → effective result at the playhead**.

Evidence from the implementation:
- Creating a camera bubble layout copies the whole current Camera value into the interval. Future default
  changes do not update that snapshot. The UI must not promise that global edits affect every moment.
- Preview camera dragging chooses the active bubble layout at the playhead, otherwise the project default.
  The editing destination can therefore differ even though the user grabs the same visible camera object.
- Camera footage intervals control media visibility/timing; layout intervals control composition. Selecting
  footage must not silently change the meaning of the global form.
- Keys intervals also store settings separately. A default change can be hidden by an existing interval.
- Add layout requires free space; the API returns nil when no valid interval fits. A clickable command with
  no visible result is a workflow failure, not a cosmetic problem.
- Multiple selected video clips currently expose the minimum selected index to the old ClipPanel. A group
  inspector needs truthful scope or deliberate batch semantics, not accidental first-item editing.

External comparison:
- [Adobe: Apply effects to Source clips](https://helpx.adobe.com/uk/premiere/desktop/add-video-effects/apply-video-effects/apply-effects-to-source-clips.html)
  explicitly separates source-wide adjustments from sequence-instance effects. The relevant lesson is to
  expose scope and inheritance; Recorder does not need to copy Premiere's panel arrangement.
- [NN/g: Progressive Disclosure](https://www.nngroup.com/articles/progressive-disclosure/)
  reserves secondary areas for less common detail while retaining the important initial choices. Our
  hypothesis: position/size and “change at playhead” belong in the initial camera view; exact coordinates
  and cosmetic finish can be named disclosures. Validate this with actual tasks, not taste.
- [NN/g: Onboarding Tutorials vs. Contextual Help](https://www.nngroup.com/articles/onboarding-tutorials/)
  supports guidance near the current task. Replace the broad explanatory wall with a specific scope/status
  at the point where the default and interval diverge.

| User intent | Entry / context | Proposed shortest coherent path | What must be evaluated |
|---|---|---|---|
| Make camera smaller everywhere | Camera destination | Size in project defaults; show timed overrides if present | User understands why a particular interval may differ |
| Move camera for one moment | Playhead + Camera | Change at playhead → new interval selected → placement control | Scope changes visibly, no accidental global mutation |
| Remove a camera segment | Camera footage interval | Timeline removal, with footage identity in inspector | Distinct from hiding camera via a layout |
| Hide camera briefly | Camera default or active interval | Hide at playhead → trim interval → preview boundary | Availability and duration are visible, undo is one action |
| Emphasize an action | Zoom interval | Target preview + scale + movement behavior | Auto/manual ownership clear; no separate competing spatial mode |
| Restyle shortcuts | Keystrokes defaults / selected interval | Defaults labelled; interval explicitly overrides them | Show where inherited settings stop applying |
| Clean up pointer motion | Cursor destination | Movement and idle behavior first, uncommon effects disclosed | Hover explanations/finite demo distinguish named motion presets |
| Balance voice and system sound | Sound destination | Recorded sources → gain/mute → listen | Missing source is explained; controls correspond to audible tracks |
| Conceal private information | Mask interval | Direct rectangle + kind/opacity → check interval ends | Mask coordinates remain anchored through crop/zoom |
| Speed up selected content | Single or group video selection | Single speed controls; explicit group state until batch supported | No first-clip-only edits disguised as group changes |

FUI experiment: `PlacementPad` has a real coordinate grid, origin marker during a move, one bright value
readout and a directly manipulated camera marker. It keeps arrow-key adjustment, accessible position,
exact sliders under a labelled disclosure, bounds clamping, Escape cancellation and one undo per drag.
It is opt-in through the gallery's Compare menu; the production camera retains the standard control.
The visual treatment has a job: explain the position and the change. No idle scan or fabricated data.
The `placement` selftest checks mapping, clamping, degenerate bounds, gesture coalescing, undo and cancel;
it does not substitute for live pointer, keyboard or VoiceOver verification.

### Camera experiment revisions

The first spatial pad pushed timed actions out of sight. The next revision pins those actions below the
scrolling form. A third reduces the pad to 84 pt and tightens internal gaps; precise coordinates and finish
remain explicit disclosures. The fourth removes redundant preset buttons (the pad itself supports direct
placement at every point) and makes the pinned footer contextual: create a change in free space, or edit
the active timed layout. It no longer adds an override warning/button above the position controls and
simultaneously displays disabled creation controls below them.

The prototype fixture now contains a real camera layout override at 16–20 seconds. `workspace-png`
additionally captures that selection, spatial placement and the active-override state at 17 seconds.
`placement` and `inspector-panels` passed after the camera changes. Input dispatch, reduced-motion runtime,
VoiceOver and real preview output remain unverified; this is not a finished production redesign.

## Production integration: persistent navigation and scope

The current editor now includes the 36-point composition row explored in the gallery. The inspector's
former navigation grid is removed; Whole project / Selection stays visible, and project navigation retains
the timeline selection. A changed selection follows the new object; unchanged selection does not steal
scope back. Menu shortcuts and the navigation row share the model's transient inspector state, and state
snapshots report the actual displayed scope. These UI values do not enter project saves or undo history.

Camera footage selection now explains timing and offers Edit camera appearance, rather than exposing
project-wide settings as clip properties. Camera defaults have a pinned action area: create a timed change
where there is room, or edit the active layout. Multiple selection is identified as a group, with no misleading
first-clip-only speed control. The old Back button is now labelled Deselect.

The top bar now anchors output controls and Export to the right. Long titles truncate before those controls
are displaced. Loading/error shells reserve the same navigation row and show its disabled destinations.
Timeline drawing and editing remain unchanged; its divider's maximum height adapts to window height to
reserve 180 points for the preview/transport row when expanded.

Space tradeoff: the new composition row consumes 36 points of height across the window, while removing
the old inspector title/navigation stack. This is a deliberate continuity tradeoff, not a claim that every
region is larger. Wallpaper options still require scrolling at the minimum editor height; detailed panel
layout work remains open.

Verified this pass:
- `inspector-scope`: project navigation preserves selection; selection changes follow context; unchanged
  selection retains scope; browsing does not mutate project/history.
- `menu-actions`: existing native menu/responder actions, including renamed composition destinations.
- `timeline-ops`: timeline edit/undo operations after the selection-state changes.
- `project-navigation`: loading, cancellation, error, reopen and retained editor state.
- Visually inspected `build/editor-scope-1100.png`, `build/editor-scope-1200.png`, and
  `build/editor-scope-long-title.png`; group and camera footage inspector renders were also inspected.
  `editor-png` remains an offscreen shell capture with Loading preview, not a live-video assertion.
- Gallery Compare now includes Production inspector, embedding the actual shared navigation and inspector
  alongside the experimental controls. The gallery was rebuilt and rendered.

Still outstanding: real preview/media-backed gallery study, direct input/motion/accessibility validation,
remaining property workflows and widget designs, crop/export evaluation, and complete editor acceptance.
This is partial production integration, not completion of the full redesign.

The final `inspector-scope` run also dispatches a real divider drag against the native root view at
1100×700, expands the timeline, and checks the preview retains at least 136 points while inspector
content remains below the document/navigation rows. It passed.

## Real preview study: defaults versus the result at the playhead

The workspace gallery now uses the production Metal PreviewView, transport and mask overlay over
labelled, disposable screen/camera movies. The schematic remains available in Compare. Production
inspector is the default comparison. PNG capture copies the actual GPU drawable before rasterizing
native controls: a cached AppKit view alone omitted the Metal video. Normal editor drawing retains
framebuffer-only drawables; only the gallery enables readable frames.

The 1120- and 900-point workspace runs both passed pixel assertions: a default camera edit changes
unoverridden output; an active timed camera override ignores default changes; editing that override
changes output; undo restores identical pixels in both scopes. Browsing all six selection states leaves
project data and undo unchanged. These are renderer/model checks, not pointer or accessibility tests.

Visual findings:
- At 900 points, the 320-point inspector occupies 35.6% of width. The remaining preview region is about
  579 points wide; the complete color-mode Canvas form remains visible in the 429-point content row.
- At 1120 points the video is height constrained. The spatial camera variant does not increase video
  area; its benefit is reducing exposed controls and keeping timed actions visible.
- In the standard camera form, finish controls extend below the visible area. The spatial form fits its
  collapsed coordinate/finish disclosures above the footer. This trades immediate access for less
  scrolling and still needs task-based input evaluation before adoption.
- The old nine identical position circles communicated little. Shared camera/keystroke preset buttons
  now show a miniature frame with a dot at the destination, retaining names, selection and help.
- At 17 seconds the preview's large top-left camera differs visibly from the bottom-right project
  default shown in the form. The persistent active-layout action is essential to explaining this state.

Inspected `build/editor-workspace-live.placement.png`, `.override.png`, `.spatial.png`, and
`build/editor-workspace-live-900.png`. Spatial captures wait for the finite property reveal to settle;
static screenshots do not prove motion quality. Remaining acceptance work listed above still applies.

## Selected effects: edit the region versus inspect the result

A workflow audit found that manual zoom selection intentionally renders the unzoomed frame so the
rectangle can be positioned. Previously the Zoom panel offered a Level slider without explaining why
the preview stayed unzoomed. Masks use the same editing presentation. This is a mode-visibility problem,
not primarily a density problem. NN/g's [visibility of system status](https://www.nngroup.com/articles/visibility-system-status/)
and [mode guidance](https://www.nngroup.com/articles/modes/) support making the current interpretation
explicit; the specific two-mode control is our design inference for Recorder.

Manual zoom and mask inspectors now offer Edit region / View result. The first retains the production
rectangle tools; the second hides those guides and uses the normal composed render without losing the
selection. This state is transient, preserved on repeated selection, reset on changed selection, and
excluded from project history. Whole-project inspection shows the composed result even with a retained
selected region; returning to Selection restores its editing mode.

Zoom, mask and layout panels also explain when the playhead is outside the selected interval and offer
Go to interval. The command chooses a retained point with the existing source/output mapping; cuts and
speed are respected. It does not move the playhead merely because selection changed. The older layout
Preview change action, buried below the form, is replaced by this contextual action near the heading.

Verified this iteration: `inspector-scope` checks preview-state reset/preservation and interval navigation
across trimming and 2× speed. `workspace-png` checks actual GPU pixels differ between region/result modes,
remain identical between result and project inspection, and restore when returning to Selection. Project
and undo history remain unchanged. Inspected the 900-point `editor-effect-preview.zoom-region.png` and
`.zoom-result.png` pair. Built/opened the gallery with `make gallery CONFIG=debug`. Direct pointer/keyboard
activation and mask-specific rendered mode switching still need separate validation.

## Remaining composition panels: source, behavior, and timed changes

Tracing controls to rendering found that microphone cleanup is an export-only high-pass/normalization
pass, while the Motion panel's Screen choice selects the zoom spring. The inspector now states those
behaviors in user terms. Sound groups microphone and system audio separately; unavailable sources say
Not recorded instead of showing unexplained disabled sliders. Microphone cleanup reads Reduce rumble &
normalize and explains that preview retains the original audio. No audio-processing behavior changed.

Motion leads with Zoom transitions and names the difference between the two existing presets. Blur
sources replaces Advanced. Cursor's None option becomes Original movement; its disclosure names pointer
appearance and cleanup. Keystrokes moves recording guidance and precise coordinates into named disclosures.
These are progressive-disclosure tradeoffs, not proof that every task needs fewer actions.

The first 900-point render still placed the keystroke interval action below the fold. The next iteration
pins it outside the form and switches from adding settings to editing the interval at the playhead.
The gallery uses the shared production control. Its fixture now contains generated pointer motion,
recorded shortcut events, and a timed keystroke interval, all routed through the real preview pipeline.
This makes the settings demonstrable without recording private input or synthesizing a separate UI-only
animation. The sample's 2 fps video is still not suitable for judging real recorded-motion fidelity.

Keystroke density iteration 3: pinning the footer exposed a partially visible position grid at the
900-point fixture. Include all recorded keys now lives inside Recorded keys, with its explanation;
internal field gaps drop from 12 to 8 points. This keeps primary placement controls ahead of recording
policy and precision controls. The policy toggle remains discoverable by its named disclosure.

Validation: app/gallery build and `inspector-panels` passed. `workspace-png` passed with real pointer/key
events and its existing renderer/scope/undo checks. Inspected microphone-present, audio-absent, Motion,
and timed-keystroke workspace captures. These checks establish layout and state presentation, not
perceived motion quality or the ease of finding newly disclosed options; those remain acceptance work.

## Export workflow: configure, run, recover, finish

The export audit found a silent failure path: the model returned to Idle without any error information.
It also left all configuration controls visible after completion and displayed MP4-only settings for
GIF. The sheet now separates configuration from running/completed output, hides quality/codec for GIF,
labels GIF as audio-free, and presents a wrapped filename with separate completion actions. Failures
preserve settings and show a readable error above the available retry/export actions. Cancellation
remains distinct from failure. Progress callbacks verify exporter identity before updating state so a
late callback cannot replace a terminal result or a newer attempt.

The initial failure render clipped the footer. A second pass tightened field/section gaps and changed
the sheet from 620×360 to 620×440. This spends 80 points to accommodate errors and longer text without
covering actions. GIF has more unused space; dynamic sheet sizing remains a possible later refinement.
The output pixel dimensions remain visible beside the existing resolution preset labels.

The gallery workspace now has a Workflows menu opening the actual crop and export sheets over its
sample media. These are real document-modal workflows, not mock buttons. Export still uses the native
save dialog. `export-sheet-png` now accepts gif/failure/done variants. Failure exercises missing-media
export; Done writes a real one-second sample export with a long filename. Both assert actual model
outcomes before rendering. Their captures and GIF configuration were inspected. Full save-dialog,
clipboard, cancellation/retry input and crop interaction acceptance are still outstanding.

## Crop workflow: source framing and commit

The crop sheet now identifies itself as Crop source, states whole-recording scope and source-pixel units,
and shows the current aspect constraint instead of Select…. Pixel fields have explicit accessible names.
Cancel and Apply crop sit at the trailing edge with standard keyboard actions; preview-unavailable state
has a visible explanation. The keyboard help no longer incorrectly promises source-pixel nudges: the
shared rectangle tool moves in view points.

Tracing preview correspondence also found crop decoded timeline source time directly, ignoring a clip's
mediaStart and independent playback speed. Crop now uses the same clip media-time conversion as rendering;
gap intervals have no source preview. This change is covered by an unlinked-speed/shifted-media example
and a gap check in `crop`.

Space evaluation: the unchanged 920×660 sheet uses a 100-point header and 60-point footer, leaving a
500-point image region versus 528 previously (5.3% less image-region height). The deliberate cost buys
explicit scope/units without crowding the existing precision fields. `build/crop-workflow.png` was
rendered and inspected; labels and trailing actions fit.

`crop` passed mapping round trips, independent media-time mapping, apply/undo, and a real sheet
cancelOperation dismissal (the previous discard test was a no-op). `crop-png` passed. Pointer drag,
actual Return/Escape key dispatch, focus traversal, and VoiceOver remain separate acceptance work.

## Keyboard acceptance: rectangle editing

Input tracing found that SelectionRectView handled arrow keys locally, but the mask and manual-zoom
adapters only opened model gestures around mouse input. As a result, keyboard movement could change
the drawn rectangle without persisting its value or creating undo history. The shared rectangle now
brackets arrow-key mutations with an optional keyboard-edit callback. Both model adapters reuse their
existing gesture boundaries; crop/area tools retain their local editing behavior. Keyboard nudges are
ignored during a pointer drag and cannot edit a hidden rectangle.

`mask-rect` now dispatches Shift-Right into the actual rectangle, verifies a 10-point/model-coordinate
move and exactly one undo step, restores it, and checks handles hide/reappear across result/edit modes.
The workspace check dispatches Right into the live manual-zoom target and verifies persisted movement,
one undo step, and full project restoration. The crop check now sends an Escape NSEvent through its
window rather than calling cancelOperation directly. These are concrete responder/model checks, still
not a substitute for a human assessment of keyboard discoverability, focus order or VoiceOver.


## Current acceptance map

The original objective remains the whole editor. This map distinguishes implemented work from missing
proof rather than using a single green model test to stand in for product acceptance.

| Requirement | Current evidence | Assessment / remaining proof |
|---|---|---|
| Task model and research | Cited guidance, scope/selection/playhead model; actual nine-stage `workspace-replay` reaches live playback and Export without modifying the fixture | Architecture and review navigation verified. This is a developer walkthrough, not user research; the continuous command-driven edit/export/copy check below now passes; OS Save/Finder remains separate |
| Whole workspace and density | Native 1100×700 / 1200×760 Canvas, Camera and Zoom renders in `build/editor-final/`; title synchronization/undo; native deep-scroll/reset check | Layout and scroll verified. Inspector uses 29.1% / 26.7% of width. Longer forms intentionally scroll |
| Shared panels and widgets | Production Canvas, Cursor, Camera, Sound, Motion, Keys and selection forms in shared gallery; native disclosure/Mirror interactions; coordinate pad and direct preview drags | Implemented and covered by focused checks; accessibility verification deferred |
| Preview correspondence | `workspace-png`: real GPU zoom region/result, camera default/timed overrides, native camera drags, three mask modes and undo; crop media-time check | Verified for the named modes and sample media; not a universal rendering guarantee |
| Motion and FUI | Live replay plus timed reveal/interruption samples; old form removed immediately; incoming form settles in 180 ms; actual walkthrough cancellation checked | Behavior and intermediate states verified. Subjective feel is still reviewable in the live gallery |
| Native behavior | Zoom/mask keyboard undo, camera Escape, crop Escape, scope/menu tests; Return opens Save, cancellation retains settings, Return closes completion | System Save confirmation and Finder reveal still unverified. File-copy payload and receipt passed |
| Finish and recovery | Playable export, cancellation, retry with settings retained; native preview Retry/Undo, stale-load rejection, empty/absent-source states | Named recovery paths verified; final OS file handoff remains open |

Audit evidence was re-read from the current files, rendered artifacts and successful logs. The two native
window examples were reopened for visual inspection. Do not use the completed rows to imply the whole
handoff has passed. Accessibility-specific acceptance is deferred by the user's instruction.


## User priority correction

Accessibility-specific work is deferred at the user's explicit request. Do not spend the next passes
on VoiceOver, accessibility tree harnesses, or accessibility acceptance gates. Prioritize people recording
demos: framing, emphasis, camera treatment, direct interaction, review, and export. The attempted
headless SwiftUI accessibility harness did not expose the controls and was removed; it proves nothing
about VoiceOver. Existing native behavior remains available, but accessibility verification is outside
the current completion gate until requested again.

## Demo framing: one Canvas destination

Output shape and crop now live with Canvas treatment, rather than beside document/export actions.
Six compact shape tiles show Source, 16:9, 9:16, 1:1, 4:3 and 16:10; Source reflects the cropped source
ratio. Crop source sits alongside them. The native document bar retains Projects, title, save status
and Export; the existing Crop menu command remains available.

Padding stays exposed. Corners, inset and shadow move into a named disclosure. The first 900-point
render left Blur below the fold, despite a solid-color backdrop having no detail to blur. The second
pass omits Blur for Color and keeps all common color-mode framing controls visible. Wallpaper/image
choices and expanded finish settings still scroll; no claim that every option fits at once.

The gallery's real preview was captured in source and portrait shapes. Portrait correctly leaves space
around a wide recording, making the nearby crop action useful when a tighter composition is wanted.
`workspace-png` checks that changing shape then undoing restores the project, alongside existing preview
checks. `menu-actions` and `inspector-scope` passed after removing the old AppKit aspect observer/popup.
Inspected `build/editor-framing.png` and `.portrait.png`; built/opened the interactive gallery.

## Demo review loop and camera-pad adoption

The user explicitly preferred the coordinate pad over the camera matrix. CameraTab now defaults to the
pad in production, including selected timed camera layouts. Precise coordinates and Shape & finish stay
available as named disclosures; the matrix remains available through the gallery's experimental form.
The timed layout kind choices are a compact Bubble / Fullscreen / Hidden row instead of three radio rows.

Zoom, mask and layout inspectors now provide Replay change. It maps retained interval bounds into output
time, starts 0.6 seconds before the change, switches to the composed result, and stops 1.5 seconds after
its exit (clamped to the project duration). This preserves the selected effect and its controls. Stop
preview, pausing, changing selection, or switching back to region editing ends the bounded replay.
Normal playback remains unbounded. No project data or undo history stores replay state.

Model checks cover retained/trimmed intervals, speed mapping, the bounded stop and selection interruption.
The media-backed workspace check additionally starts actual playback and requires it to advance to the
end boundary, stop, retain selection and leave result mode visible. This exercises the real preview
player/display-link path, not just a simulated progress counter. The coordinate-pad mapping/undo/cancel
check remains part of the focused validation. Accessibility-specific work remains deferred by request.

Validation: debug build, `inspector-scope`, `placement`, and the media-backed `workspace-png` check passed.
The first live replay run exposed that changing the model flag did not start AVPlayer; PreviewView now
observes playback commands as well as playhead changes. The rerun advanced and stopped at the expected
boundary. Inspected the 900-point timed-layout render: compact kind selection, size/aspect and the pad
fit above the fold, with precise coordinates disclosed below. This verifies layout and playback behavior;
it does not establish subjective pointer or motion feel.


## Connecting Motion to the moment being edited

The workflow review found that Motion exposed global zoom transitions but had no visible route to add
or edit the zoom being watched. A pinned footer now offers Add zoom at playhead, changing to Edit this
zoom inside an existing interval. It uses the same footer pattern as camera and keystrokes. No new
navigation row or preview overlay consumes working space.

Creation is shared by the Motion action, menu command, and normal timeline add path. It pauses playback,
selects the new interval, clears clip selection and opens its inspector. Click proximity determines
manual/auto mode consistently. Failed insertion preserves selection and adds no empty undo step.

Debug build, inspector-scope, menu-actions and media-backed workspace-png passed. The focused check
covers creation from project scope, one undo, failed overlapping insertion and restoration. Inspected
both 900-point Motion renders: the pinned footer fits with the primary controls; the active-state
button corresponds to the zoom visible in the real composed preview. Artifacts:
`build/editor-zoom-entry.motion.png` and `build/editor-zoom-entry.motion-active.png`.


## Mask workflow: positioning versus reviewing

The first media-backed mask walkthrough exposed a correspondence problem: a 100% Cover remained opaque
inside its resize handles in Edit region. Users could not see the content whose edges they were trying
to cover. The preview now omits only the selected mask while Edit region is active, while retaining the
source-space handles and unzoomed framing. The inspector states “Mask hidden; preview unzoomed for
positioning.” View result, project scope, and replay apply the real effect again. Project data and export
rendering are unchanged.

The workspace renderer now exercises Cover, Blur and Highlight over an active zoom, capturing each in
region/result modes. It checks that all region views reveal the same source pixels, each result differs
from the unmasked output and other effects, the handles disappear in result mode, and undo restores
both the project and original composed pixels. This extends correspondence evidence beyond zooms and
camera layouts; pixel differences alone are not a claim of redaction effectiveness or export parity.

Validation passed: debug build, mask-rect, and the expanded media-backed workspace-png check. Inspected
Cover region/result and Blur/Highlight result renders at 900 points. The covered text is now visible
within region-edit handles, and Cover returns to the corresponding zoomed rectangle in View result.
Artifacts: `build/editor-mask-review.mask-cover-region.png` and `.mask-cover-result.png`.

## Inspector motion: remove competing contexts

Runtime samples at 20/80/160 ms exposed overlapping outgoing/incoming forms in the original production
crossfade. Rapid Camera → Sound switching also retained the outgoing Zoom controls long enough to show
three contexts together. This contradicted the explicit-scope model even though settled renders looked
correct. Evidence: `build/inspector-motion-before/02-zoom-80ms.png` and `05-interrupted-50ms.png`.

Production now removes the outgoing form immediately. Scope and pinned actions update immediately;
the incoming form uses the gallery's existing cancellable reveal, promoted to a shared InspectorReveal
modifier. Project headings remain stable while properties follow. The first revised capture eliminated
the overlapping forms, but its 35% starting opacity resembled disabled controls. A second pass raises
that to 65%, retaining the six-point offset and short settle. No extra navigation space is required.

`inspector-motion-png` captures the actual production inspector during selection and rapid destination
changes. It checks final scope, retained selection and unchanged project/undo history. These timed
samples expose overlap and final-state defects; they do not establish subjective smoothness at every
frame rate. Launch the gallery with `make gallery CONFIG=debug` to compare the shared interaction.

Final debug build, inspector-motion-png and inspector-scope passed. Inspected the final 80 ms Zoom and
50 ms interrupted Sound samples: one context remains visible with readable incoming controls.
Current artifacts are under `build/inspector-motion-final/`.

## Export handoff and recovery

The completion screen now acknowledges successful file copying (“File copied — ready to paste.”).
Both export-directly-to-clipboard and the completion screen's Copy file action use the same receipt.
A failed clipboard write offers retry/Show in Finder without claiming that export itself failed.
The first completion render exposed unused space above the result; the second places result details
below the output summary and leaves only the handoff actions anchored at the bottom.

`export-sheet` can now prepare its own disposable one-second media fixture. The real export produced a
playable file, the private native pasteboard round-tripped that file URL, cancellation returned to idle
without an error/partial file, and retry through the same model retained all settings and produced a
playable output. The user's general clipboard was not changed. This validates the handoff model and
pasteboard payload; native Save-panel/Finder UI interaction remains separate evidence.

## Preview recovery: distinguish missing footage from an empty edit

Empty clip lists previously flowed into composition loading, while missing media produced a single
unactionable label. Preview now distinguishes loading, unavailable media, and no video clips. The empty
state offers the current Undo operation when available; unavailable media offers Retry preview. Both
use the existing AppKit button style. A composition revision check ignores obsolete asynchronous loads,
and unavailable/empty states stop playback and discard cached frames instead of leaving stale footage.

The new `preview-recovery` check uses actual native button actions: missing source files → prepare media
→ Retry → decoded frame; remove all clips → Undo → original project and decoded frame. It also changes
clips while a prior composition is loading and checks that the empty state remains authoritative.
The first render put white status text over the pale canvas; the second adds a solid neutral status
panel using shared theme colors, so canvas color no longer determines message readability.

Debug build, native preview-recovery and the full media-backed workspace render passed. Inspected both
recovery panels, corrected horizontal text padding, and reran preview-recovery successfully. Current
artifacts: `build/preview-recovery-final/empty.png`, `unavailable.png`, and `recovered.png`.


## Gallery walkthrough: connect the editing loop

The old four-panel replay changed selection without moving into the chosen intervals, so its preview
could not explain the controls. The walkthrough now follows nine stages: frame, trim, zoom target,
actual zoom playback, timed camera layout, camera default, keystrokes, sound, then the real export sheet.
It navigates the disposable example without changing project data or undo history. The header identifies
the current stage. It waits for media, plays the zoom through its exit, and cancels delayed work when the
user changes context or edits the project. Manual review can resume from the current state.

The actual SwiftUI walkthrough test initially reached its final state but could not open Export when
there was no key window. Gallery sheets now use their own hosting-window anchor rather than a global
active window. This also prevents them from being attached to an unrelated window.

Validation: debug build, inspector-scope and the actual workspace-replay task passed. The latter observed
live playback, presentation of ExportSheetWindow on the gallery's own window, unchanged project/undo
history, and cancellation after a manual switch to Cursor during the next replay. `make test` passed
all 68 core tests. This walkthrough demonstrates navigation/review; it does not substitute for the
remaining direct-manipulation and native Save-panel checks.

## Camera direct manipulation and preview input routing

The camera input review found that its hit rectangle used the zoomed camera scale while Edit region
rendered an unzoomed frame. Hit testing and drag geometry now use the same effective scale as that
preview. Picking up the camera pauses playback so the edited time stays fixed. Escape cancels an active
camera gesture, restoring the project without adding undo history; releasing afterward does not commit.
Camera layouts use the inspector's half-open interval convention and keystroke settings do not claim
camera gestures.

The same review caught a preview input-routing regression: PreviewView's custom hitTest always returned
itself, bypassing native recovery buttons. It now delegates hits inside the visible status panel to that
panel. The recovery check verifies the actual hit target before invoking Retry, in addition to restoring
real media. The standalone camera-drag check now prepares its own fixture and covers Escape and the
unzoomed bubble's visible edge, alongside existing default/timed placement, one undo and hidden-camera
checks. Those focused checks passed.

The workspace's real GPU camera comparisons now move the bubble with native mouse events in its actual
window rather than directly assigning a camera position. They check rendered movement, default versus
timed scope, one undo and restoration of original pixels/project state.

The media-backed workspace check passed after the native-event camera changes, including default/timed
scope and pixel restoration. Debug build and gallery refresh also passed.

## Compact inspector scrolling

A 320 × 280-point production-inspector check reproduced a retained-scroll bug: after scrolling Camera
to its bottom and switching to Keystrokes, the new panel started 161 points down, hiding its heading
and primary controls. The context identity now belongs to the ScrollView itself. Changing destination
or selected object starts at the top; editing a value in the same context preserves the user's place.

`inspector-scroll` exercises the actual native scroll view and sends pointer events to expand Shape &
finish, scroll to its bottom and toggle Mirror. The toggle changes the project while retaining the
scroll offset. Switching to Keystrokes and then a selected zoom starts each form at zero. Inspected the
expanded camera and new-panel renders at the short height: controls remain reachable and timed actions
stay pinned. Debug build, inspector-scroll and inspector-motion-png passed; the motion/interruption
check still passes after moving the scroll identity. Current artifacts: `build/inspector-scroll-final/`.

## Export keyboard handoff

Export and Done now declare the native default action. `export-native` sends real NSEvent Return keys
to the export sheet: Return opens NSSavePanel with the correct type/name, cancelling the panel preserves
settings and idle state, a real export to an explicit disposable path completes, and Return dismisses
the completion sheet. Debug build and this check passed.

The OS Save confirmation is not simulated. Apple's [NSSavePanel ok documentation](https://developer.apple.com/documentation/appkit/nssavepanel/ok(_:))
explicitly excludes programmatic invocation on current macOS. A first test used that unsupported method;
a subsequent test attempted to change an already-open remote panel's destination, which remained at its
original value. One generated fixture export landed at Documents/Workspace study.mp4 and was relocated
to `build/export-native-generated-sample.mp4`. The corrected test never exports using an unverified
panel URL: native opening/cancellation and explicit temporary-path export are separate assertions.

## Final native-window review

`editor-review-png` now captures the real EditorWindowController, including live Metal pixels beneath
its real interaction overlays, at 1100 × 700 and 1200 × 760 content sizes. Inspected Canvas, Camera and
selected Zoom across those sizes. The fixed 320-point inspector takes 29.1% and 26.7% of the respective
widths. Navigation remains one 36-point row; timeline structure remains intact. The default camera form
shows both disclosures above its pinned actions. At minimum height, longer forms scroll; primary zoom
controls fit and the tested context reset keeps new panels at the top. No claim that all expanded
properties fit without scrolling.

The first native render revealed that model title changes were not reflected in the document bar.
The document-header observation now tracks title as well as save status, and avoids replacing text
while the user is editing it. The updated native render check verifies title synchronization and undo.
Also corrected export copy from “Video with recorded audio” to “Video · uses your Sound settings,” so
recordings without audio are not described as containing recorded sound.

Final debug build, native minimum/default renders and menu-actions passed. The default-width media-backed
workspace run passed replay, native camera drags, override precedence, mask modes, scope and undo checks.
Current complete-window artifacts live in `build/editor-final/`; shared gallery states use
`build/editor-final-workspace*.png`. System Save confirmation and Finder interaction remain outside the
automated evidence; neither has been represented as manually verified. Accessibility remains deferred.

## Native handoff audit follow-up

An optional directed-CGEvent experiment attempted to navigate the real Save dialog to a unique temporary
folder, then confirm only after checking its URL. The remote dialog stayed in Documents. The guard failed
before Save, so these attempts produced no export there. Initializing NSApplication and using its event
loop did not resolve remote input delivery. The unsuccessful experiment was removed rather than retained
as a purported working check. `export-native` keeps the reliable opening/cancellation, explicit temporary
export, and completion-Return assertions. This is a test automation limitation; it neither proves nor
disproves ordinary user Save behavior. Native Save/Finder acceptance remains open.

After removing the experiment, the debug build, `export-native`, and `git diff --check` passed again.

## Continuous edit, review and export

`workspace-replay` now continues past its navigation/interruption checks on the same media-backed project.
It changes output framing; trims one second from the opening; creates and actually replays a new zoom;
adds a timed camera hide; changes global camera placement while preserving that selected interval;
adds an opaque mask; changes keystroke duration; visits Sound; checks undo/redo; saves and reloads the
project; exports the resulting 31 seconds; and retrieves the resulting file URL from a private clipboard.
The real preview is rendered after the combined edits and the real export sheet is presented. Exported
media duration matches the edited timeline and exporting/copying leave project state and undo untouched.

This combined check passed with the current debug build. It drives the same model commands and bindings'
mutations used by the controls; it is not a claim that every step was performed through OS pointer input.
The focused native gesture, scrolling and keyboard checks provide that complementary evidence. No audio
track is invented for the silent fixture; the Sound visit exercises the absent-source workflow. System
Save confirmation and Finder reveal remain separate from this successful file-copy handoff.

The subsequent global OS-input attempt used a foreground-process guard and required the destination to
match the unique temporary folder before confirming Save. App launching and visual inspection established
that the dialog appeared and had focus, but automated folder navigation still did not take effect. The
experiment was removed. No Save confirmation was sent to an unverified destination. This remaining check
needs a working native-input route or human interaction; it is not evidence of an export product defect.

## Implementation handoff — user testing ownership

The user explicitly said to stop validating interactions they can test themselves. This supersedes the
remaining agent-owned native Save/Finder and subjective interaction acceptance gates above. Their
unverified status is preserved; they are not retroactively marked as tested. No additional automated
validation or speculative polish is needed to finish this implementation handoff.

Delivered: research-led editing/scope model; persistent composition navigation; redesigned shared
inspectors; the approved camera coordinate pad; region/result/replay correspondence; functional gallery
prototypes and interruptible motion; repeated space comparisons; native editor integration; crop/export
and recovery treatments. Timeline structure remains preserved. The gallery has been built and opened.

Run `make gallery CONFIG=debug` for the interactive gallery. Current native workspace examples are in
`build/editor-final/`, including `default-camera.png` and `minimum-zoom.png`. The earlier 95% estimate
included validation and unspecified polish; no concrete remaining implementation item supports holding
this delivered redesign open. Further changes should follow the user's hands-on feedback.

## Follow-up visual polish

At the user's request, reduced border competition: secondary actions use a quieter resting stroke;
quiet/dismiss actions use secondary text that brightens on hover; destructive actions retain their red
label without a permanent red box; Crop Cancel is quiet; the selection header no longer adds another
horizontal rule beneath Deselect. AppKit buttons use the same calmer resting-border treatment.

Camera now reveals size, aspect, the position pad, then precision/finish controls in 40 ms steps. Zoom
reveals preview controls, level, mode, then secondary actions; Sound reveals its source groups in order.
These forms bypass the whole-form entrance in the production inspector, so the groups do not animate
inside another moving container. Reveals use a 4-point travel and 180 ms settle, keep controls usable,
and cancel pending work when their context disappears. Ordinary value changes do not restart them.

The debug app builds. Hands-on motion and hover review is left to the user as requested; no additional
interaction validation was run for this polish pass.

## September refinement — composition and control rhythm

The new screenshot request supersedes the prior handoff: all editor inspectors, transport, title gestures,
and the division of space are back in scope. Downloaded the supplied screenshot with curl and inspected
all seven FUI boards. The repeated miniature screens and duplicate menu indicators in the screenshot
created noise without useful hierarchy. The boards' useful features are shared alignment edges, strong
white selections, light headings and small measurements separated by space.

Decisions and integrated changes:
- Keep the 320-point inspector beside both preview and timeline. The timeline fits its actual lanes,
  toolbar and overview by default; adding/removing a lane updates the fit. Manual enlargement remains
  available, with a minimum that cannot clip lanes. Preview and transport share the remaining column.
- Give scalar controls a label/value line above a full-width native slider. This preserves native drag
  behavior and gives long labels enough room. Existing gesture transactions and typed/reset values remain.
- Align switches to the right; animate the thumb and track over 180 ms, with no motion under Reduce Motion.
  Named disclosures use a trailing plus/close indicator, one fine rule, and a 180 ms reveal.
- Keystroke anchors occupy one nine-point frame, rather than nine framed-screen buttons. Every cell remains
  at least 32 × 26 points, named and selectable. Arbitrary coordinates remain available below it.
- Separate cursor appearance/movement/playback, motion transitions/blur, clip speed/duration and mask
  treatment/transition. Camera retains its shared direct-manipulation pad. Selection headings align with
  project headings and provide a quiet, named Deselect action.
- Use a single native Presets indicator. Fill the whole selected segment, rather than only its text's width.
- Keep playback controls together at the left and current/total time aligned at the right. Play is the
  local white primary action. Fix centisecond carry so 59.999 formats as 01:00.00.
- Double-click on the document title or empty document bar zooms the window; a single title click waits
  for the double-click interval before renaming. Native fullscreen remains available via the green button.

Apple's [window settings](https://support.apple.com/en-il/guide/mac-help/-mchlp1119/mac) distinguish filling/
zooming a window from fullscreen. This implementation uses AppKit zoom for the requested enlargement.
[Apple motion guidance](https://developer.apple.com/design/human-interface-guidelines/motion) informs
brief state feedback; the FUI boards determine its visual character. These are design decisions supported
by task analysis and runtime review, not invented user research.

Verification artifacts: `build/editor-refined/` contains real media-backed native-window captures at
1100 × 700 and 1200 × 760. `editor-review-png` checks full-height inspector geometry, lane visibility,
long title synchronization, timecode carry, native switch click/undo, disclosure expansion and title
resize without accidental rename. Transition and settled switch frames are separate captures.
`inspector-panels` checks the preserved model/undo paths. These checks do not claim human evaluation
of animation feel or a complete accessibility audit.

Final refinement evidence: debug app and gallery build succeeded; all 68 core tests and
`inspector-panels` passed. Inspected all 13 project/selection contexts at both sizes, plus expanded
keystroke coordinates and intermediate/settled switch states. Native disclosure input expanded the
form without an edit; switch input produced exactly one reversible edit; double-click resized without
starting rename. Gallery live rendering was correct but `cacheDisplay` returned black for its nested
SwiftUI scroll surface. `gallery-png` now uses the system utility to capture only the gallery window's
composited pixels at its normal size; the resulting image was opened and inspected. The native editor
captures, rather than the historical gallery shell arrangement, are authoritative for the new layout.
