# Signal UI research and implementation

Read this for a broad redesign, a new Recorder surface, or migration from the component gallery into the
application. For an isolated palette or copy edit, the main skill is enough. For gesture and animation
mechanics, also read [interaction.md](interaction.md).

Signal UI is Recorder's product interface language: a high-density, high-contrast native Mac workspace
whose structure is inspired by instrumentation. It is not a dashboard skin. Its purpose is to keep capture,
editing and export actions visible, fast and understandable while the recording remains the dominant content.

## Research synthesis

The supplied boards establish the visual grammar:

- `111992…jpg` uses clear type-scale changes, short grouped facts, dense monospaced measurements and large
  white anchors. Adapt the hierarchy and grouping; do not copy label text, barcodes or warning language.
- `72e44c…jpg` gets density from shared rails, repeated module geometry and compact navigation. Adapt those
  alignment systems; do not turn Recorder into a grid of interchangeable analytics cards.
- `2ff1aa…jpg` uses asymmetric white mass to establish reading order. Use this for one primary action,
  selection or value at a time, not as decoration on every panel.
- `3e597e…jpg` keeps color local and functional inside a dark field. Recorder's pale timeline colors can
  distinguish track semantics; red and yellow remain reserved for recording/error and warning.
- `5d5dc…jpg`, `6a23f6…jpg` and `b6fb94…jpg` contribute layering, measurement rails and information rhythm.
  Their blur, tiny text, fake maps and depth effects are image-making techniques, not usable controls.

External research supports the product behavior, but does not define the visual style:

- Apple recommends using a Mac's space and precision to show more content with less modality, while keeping
  density comfortable, windows resizable and keyboard workflows complete. Recorder should be a stable,
  resizable editing workspace rather than a chain of full-screen steps.
- Research on complex applications recommends reducing clutter without removing capability, keeping primary
  and secondary information close, and making important information salient partly by removing noise. For
  Recorder this means contextual inspectors and direct preview, not hiding core editing tools behind a wizard.
- Progressive disclosure helps only when the initial view contains the common path and the reveal is obvious.
  Do not hide frequent controls merely to make a screenshot sparse.
- Motion should explain status, causality or spatial continuity; frequent interactions need brief, precise
  feedback, cancellation and a reduced-motion equivalent.
- Dense visible geometry cannot create tiny effective targets. As a cross-platform accessibility heuristic,
  keep pointer targets at least 24×24 points or provide equivalent spacing/hit area. Timeline geometry may be
  visually smaller where density is essential, but handles need enlarged invisible hit regions and keyboard
  alternatives.

## Product hierarchy

Organize each surface around three layers. Do not give them equal visual weight.

1. **Work:** the recording preview, timeline, project thumbnails, capture target or export result. Give this
   most of the area and the clearest reading order.
2. **Action:** the few commands that advance the task now: record, open, play, split, export, cancel or done.
   Keep the primary action visually unique within its local scope.
3. **Evidence:** timecode, duration, selection bounds, device state, progress and warnings. Keep it adjacent to
   the object or action it explains. Omit status that doesn't change a decision.

Density comes from shared edges, consistent row heights, short labels, visible values and spatially stable
regions. It does not come from shrinking type, collapsing every control to an icon, eliminating breathing room,
or surrounding every group with a card. Prefer one continuous work surface with rules and spacing for grouping.

## Layout grammar

- Establish a small number of persistent alignment rails per window. Align headings, values, control columns,
  panel boundaries and timeline labels to them. An intentional asymmetric rail is better than centered modules
  with unrelated widths.
- Use a compact chrome band for global commands, a dominant flexible work region, and a stable contextual
  region. Preserve the current editor model: 44-point top bar, flexible preview, 44-point transport, 300-point
  inspector and a 160–420-point resizable timeline are current implementation constraints to evaluate at real
  window sizes, not universal tokens.
- Let data determine grouping. Use proximity first, a fine rule second, and a containing panel only when the
  group needs a distinct surface or interaction boundary.
- Keep a visible label for unfamiliar or consequential actions. Icons alone are acceptable for conventional,
  repeatedly used actions only when they have help text and accessible names.
- Use tabular figures or monospaced type for timecodes, dimensions and changing measurements so updates do not
  disturb alignment. Use the narrow heading face for hierarchy, not long body copy.
- At reduced widths, protect the work area first. Shorten secondary labels, move infrequent actions to an
  existing menu, and allow the inspector or navigation to hide only when there is a familiar command to restore
  it. Never clip the primary action or silently discard controls.

## Disclosure and functional simplicity

Keep the common path visible and move only conditional or expert detail behind a nearby, named reveal.

- Selection is the main disclosure mechanism in the editor: selecting a clip, zoom, layout or mask changes the
  inspector in place. Preserve the preview and timeline so context does not disappear.
- A disclosure must preserve the user's values when closed, reveal directly below or beside its trigger, and
  avoid shifting the primary action out of view.
- Prefer direct manipulation plus a precise inspector value over duplicate editing modes. Dragging answers
  “where”; the inspector answers “exactly how much.” Both edit the same model and undo transaction.
- Put every command in a predictable menu even when a toolbar accelerator exists. Teach a shortcut in context
  after the user encounters the command; do not fill the interface with permanent shortcut labels.
- Simplicity means fewer concepts and transitions, not fewer capabilities. Reuse the project model, commands,
  menus, undo boundaries and system dialogs already present.

## Surface map

| Surface | Primary work | Signal UI application | Avoid |
|---|---|---|---|
| Library | Resume or start work | Search and New capture stay in the header; thumbnails, title, duration and modified time form a scan-friendly adaptive grid; selected and keyboard-focused states are distinct; empty/search-empty/import states give one next action | Decorative per-card status when every item is “Ready”; equal emphasis on metadata and title |
| Capture toolbar | Confirm target and inputs, then record | Keep the compact horizontal sequence: target mode, camera, microphone, system audio, settings and record state. Show real device names or clear off states. Selection and recording must remain legible without color alone | Dashboard metrics, nested cards, ambiguous icon-only device state, animated idle decoration |
| Editor shell | Inspect the preview while editing time | Preview remains the largest flexible region; top bar holds document/global actions; transport stays attached to preview; timeline spans the window; inspector remains stable and contextual | Floating unrelated modules, centering the preview at the expense of timeline/inspector, hiding core commands in a custom command surface |
| Timeline | Understand and edit time | Use compact labeled lanes, pale semantic blocks, persistent ruler/playhead and strong selection. Hover reveals precision; selection reveals exact bounds; direct manipulation remains continuous and reversible | Ornament that resembles data, animated pointer lag, snapping every drag update, color-only track meaning |
| Inspector | Change the current context precisely | Default tabs expose project styling; selecting a timeline object swaps to that object's controls in place; group controls by outcome and keep label/value columns aligned; reveal advanced options only when their parent feature is active | A scrolling wall of unrelated controls, six unlabeled icons without help/accessibility, duplicate model mutations |
| Export | Choose output, understand progress, retrieve result | Keep the compact form; show only format-valid options; place estimated output beside the export action; during work show determinate progress plus current detail and Cancel; completion identifies the file and offers Show, Copy and Done | Indefinite spinner for measurable work, options that are merely dimmed when they can be removed without disorientation, completion that loses the destination |

## Components are contracts

The gallery validates shared behavior before broad adoption; it is not an alternate app shell.

- `TechButtonStyle`: demonstrate primary, secondary, quiet, danger, hover, pressed, focused and disabled states.
  One local primary button is the default. Its visible shape may be compact, but its effective target must remain
  usable.
- `TechSectionLabel`: use the index block only when it aids scanning through peer sections. Do not index a lone
  group or invent a system code.
- `TechStatus`: pair state text with shape or contrast. Render only state that can change what the user does.
- `TechPanel`: reserve corner marks and full outlines for real bounded modules. Most inspector groups should use
  alignment, spacing and rules instead.
- `TechGridBackground`: use as low-contrast structure on broad empty surfaces only. It must never reduce text,
  selection, focus or preview contrast.
- Native pickers, sliders, menus, dialogs and text fields keep their platform behavior unless the shared style
  can preserve focus, keyboard, VoiceOver, validation and disabled semantics.

## Motion system

Give every animation a state change, an origin and a settled end. See [interaction.md](interaction.md) for the
gesture mechanics and current timing experiments.

- **Direct manipulation:** the object follows the pointer with no decorative easing. Animate only the release
  settlement or a valid model transition.
- **Disclosure:** reveal from the trigger or selected object, in reading order. Keep it cancellable and short.
- **Status:** progress moves because work progressed; selection and record state may pulse once on transition,
  never indefinitely.
- **Spatial continuity:** an inspector replacement, lane insertion or panel reveal should show where content
  came from without moving the whole window.
- **Reduced motion:** replace translation, parallax, wipe and spring with immediate state plus contrast or a
  short opacity change. Preserve all information and input response.

Do not animate routine value changes, hover every piece of chrome, run ambient scans, or delay a command so an
effect can finish. Motion polish is successful when the state change is easier to understand and no slower to use.

## Implementation order

Prefer the smallest vertical slice that exercises the real shared components:

1. Confirm tokens and component states in `Theme.swift`, `UIComponents.swift` and the gallery.
2. Apply them to the library and capture toolbar, which test adaptive layout, selection, menus and device state.
3. Apply the same contracts to editor chrome and inspector without changing the project/editing model.
4. Refine the timeline's drawing and direct-manipulation feedback separately from general SwiftUI chrome.
5. Finish sheets, empty/error/progress states and accessibility across every migrated surface.

Do not call step 1 an app redesign. A surface is migrated only when its populated, empty, selected, focused,
disabled, error and minimum-size states relevant to that surface have been exercised.

## Acceptance checks

- At first glance, a user can identify the work object, current selection/state and next primary action.
- Removing color still leaves track type, selection, warning and recording state understandable.
- The default and minimum window sizes preserve primary work and actions without overlap or accidental gaps.
- Visible control density does not reduce effective targets, keyboard access, focus indication or accessible
  names/values.
- Conditional controls appear next to their cause and preserve values when hidden; routine controls remain
  discoverable without opening multiple layers.
- Motion terminates, can be interrupted, follows direct manipulation, and has a coherent reduced-motion form.
- Export and other waits report useful progress; completion states identify the result and next actions.
- Gallery components used in the app are the actual shared implementations, and their gallery states match
  their runtime behavior.

## Research sources

- [Apple: Designing for macOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-macos)
- [Apple: Motion](https://developer.apple.com/design/human-interface-guidelines/motion)
- [Apple: Keyboards](https://developer.apple.com/design/human-interface-guidelines/keyboards)
- [Apple: Focus and selection](https://developer.apple.com/design/human-interface-guidelines/focus-and-selection)
- [Apple: Reduced Motion evaluation criteria](https://developer.apple.com/help/app-store-connect/manage-app-accessibility/reduced-motion-evaluation-criteria)
- [Nielsen Norman Group: 8 Design Guidelines for Complex Applications](https://www.nngroup.com/articles/complex-application-design/)
- [Nielsen Norman Group: Progressive Disclosure](https://www.nngroup.com/articles/progressive-disclosure/)
- [Nielsen Norman Group: Designing for Long Waits and Interruptions](https://www.nngroup.com/articles/designing-for-waits-and-interruptions/)
- [W3C: Understanding Target Size (Minimum)](https://www.w3.org/WAI/WCAG22/Understanding/target-size-minimum)
