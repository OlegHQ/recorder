---
name: recorder-ui-design
description: Design and rebuild Recorder's native macOS layouts, UI kit, and interactions from its FUI references and established visual direction. Use for app UI redesigns, new screens, component galleries, or motion prototypes; not unrelated backend or rendering work.
---

# Recorder UI design

Build the screen around the user's work, then design its components. A redesign is not a color swap,
new font on an unchanged screen, or a component gallery presented as a finished application.
Keep implementation economical; do not use minimal-code guidance to reduce the requested design scope.

This skill records this project's design direction, not universal UI rules. New explicit user choices
take precedence. Apply it to the requested surface; it does not authorize unrelated app changes.

## Start with evidence

Paths below are relative to the repository root, three levels above this skill directory.

1. Inspect the current worktree and the requested screen's view hierarchy, callers, state and commands.
   Preserve unrelated work. Read `docs/UI-KIT.md` for context and `docs/SPEC.md` for behavior.
   The original Screen Studio-derived visual spec is superseded by the direction here and current user
   feedback; existing recording, editing, export and keyboard behavior still matters.
2. **Open the actual images** in `reference/ui-kit-inspiration/`. Do not work from filenames or a prose
   summary alone. For a broad redesign, study all seven; for a focused change, revisit the relevant boards.
   Compare at readable scale:
   - `111992e19467feb7524c370d74c75a61.jpg`: narrow technical type, large white areas, black negative space.
   - `72e44cafd3071e968ced6a11d1692e42.jpg`: compact navigation, aligned regions, thin corner brackets.
   - `2ff1aa8a2421df8b9784e82d54455871.jpg`: asymmetric hierarchy and strong horizontal white structure.
   - `3e597ebeeb79a6757405ba2f60f549b9.jpg`: restrained local color within a predominantly dark interface.
   The photographic boards inform measurement marks and density, not blur effects or illegible microtext.
3. State the concrete layout and interaction changes before implementing them. Tie decisions to observed
   reference features or user needs. For a whole-app request, inventory every affected surface and track
   completion separately; do not silently narrow it to the easiest screen.

## Build the layout

For a broad Signal UI redesign or migration across app surfaces, read
[references/signal-ui.md](references/signal-ui.md). It turns the gallery study and UX research into
Recorder-specific hierarchy, density, disclosure, motion, surface mapping and acceptance criteria.

- Identify the primary task, primary action, working content, navigation, contextual controls and status.
  Give these distinct places. Design idle, hover, focus, selected, dragging, disabled, empty and error
  states where relevant, not just a populated static screenshot.
- Establish shared alignment edges, column proportions, reading order and resize behavior before styling.
  Use whitespace to separate groups. Do not center unequal-height cards in rows or accept accidental
  gaps from intrinsic sizing. Align row boundaries when modules belong together.
- Prefer **smaller controls inside generous space**, not large controls packed against their containers.
  Do not shrink hit regions or essential labels to imitate decorative microtype.
- Use a composition suited to the task: a timeline needs a broad continuous working area; an inspector
  needs compact ordered fields; a library needs content hierarchy and usable empty/search states.
  Do not apply the same two-column card grid to every screen.
- Reconsider existing grouping and placement when redesign is requested. Reusing state and commands is
  valuable; retaining an unsuitable layout solely to keep the diff short is not.
- Add white mass deliberately: primary buttons, selection tabs, short structural bars, or useful readouts.
  Balance it against black negative space. Thin borders alone do not create the references' hierarchy.
- Corner brackets and indices are occasional structural accents, not mandatory decoration on every group.
  No fake telemetry, arbitrary serial numbers, promotional slogans or fabricated system status.

## Visual direction

**Palette:** black and neutral charcoal surfaces; white and near-white foregrounds. Pale colors belong
primarily to solid timeline blocks: cream, ice blue, sage, lavender. Keep dark labels readable on them.
Avoid the rejected cyan/neon rainbow, tinted navy dashboard backgrounds, gradients and routine glow.
Status colors remain sparse and accompanied by text or shape.

**Type:** light, narrow technical headings and monospaced measurements. DIN Condensed Bold was rejected
for dense, hard-to-read mixed-case titles, including “Actions.” Explore a genuine light face rather
than shrinking bold text, reducing its opacity or inventing a nonexistent DIN weight. The current trial
is bundled Barlow Semi Condensed Light with Andale Mono, defined in `Theme.swift`; it is an alternative,
not DIN Light. Do not treat an implemented experiment as user approval.
Use natural casing and letter spacing; the user rejected forced capitals and tracked-out labels.
Section titles need sufficient size: 18-point bold titles were rejected; 24 points is a trial size,
not a solution to the wrong weight. Make controls smaller independently of headings. Judge type at actual
window scale, not only an enlarged image. Verify font availability and readable fallback for shipping.

**Geometry:** flat surfaces, fine rules, squared or minimally rounded controls, restrained corner marks.
Spacing values are starting points, not a composition recipe: current gallery uses roughly 28-point
outer insets, 12-point gutters, and 16-point panel insets. Derive spacing from content relationships.

Read current values in `Sources/Recorder/App/Theme.swift` rather than creating parallel token definitions.
Use `UIComponents.swift` for shared controls. Intentional visual changes should reach both AppKit and
SwiftUI consumers; inspect label contrast, selected states and disabled states after token changes.

## Interaction and motion

When changing hover, selection, reveals, timeline gestures or animation, read
[references/interaction.md](references/interaction.md).

Motion is part of the layout: decide what appears, where it comes from, which state it explains and how
it is interrupted. A single opacity transition or moving underline is not a complete motion prototype.
Provide a replayable sequence and working direct manipulation when those are requested.

## Implement in this app

- Keep the native AppKit shell and existing project/editing model. Trace shared controls and their
  callers before changing them. Reuse commands, undo boundaries and bindings rather than duplicating
  business logic in a redesigned view.
- Key files: `App/Theme.swift`, `App/UIComponents.swift`, `App/UIKitGallery.swift`,
  `App/TimelineInteractionPrototype.swift`, `Editor/TimelineView.swift`,
  `Editor/EditorWindowController.swift`, `Editor/Inspector/`, `Library/LibraryView.swift`,
  and `Recording/ToolbarView.swift`, all under `Sources/Recorder/`.
- The motion study is isolated from real projects. Do not assume its gestures or latest revisions have
  been validated merely because they exist. Prototype success is not editor integration.
- Include the actual shared widgets in the AppKit gallery. Demonstrate their meaningful states and
  transitions, not attractive substitutes with unrelated implementations.
- Avoid dependencies for layout and animation already covered by AppKit, SwiftUI or Core Animation.
  Keep system dialogs and expected keyboard semantics. Custom styling must preserve focus, accessible
  names, selection/value reporting, and usable pointer targets.

## Verification and handoff

- Run `make gallery` to build/open the gallery; `make gallery-png` creates
  `build/signal-ui-gallery.png`. Inspect the resulting image. A successful renderer can produce a blank
  image or capture an unfinished entrance animation; wait for layout and the relevant motion to settle.
- Inspect default and minimum window sizes, scroll positions, empty/long content and selected states.
  Check clipping, alignment, hierarchy and white/color balance against the references. Fix defects
  before presenting the render as evidence.
- Test motion live. Record or sample intermediate states if helpful. Static PNGs cannot establish
  gesture stability, stagger timing, interruption behavior or perceived smoothness.
- Use existing focused selftests where applicable. `ui-motion` currently checks only snapping math;
  it does not validate dragging, reveal timing or the full app. Add a small runnable regression check
  for changed nontrivial logic. Use `make test`, not bare `swift test`, for core tests.
- Do not modify source while SwiftPM is compiling it. Reuse the active process handle and wait for it.
- Report what changed and what was actually verified. Separate implemented prototypes, integrated app
  surfaces and unverified interaction feel. Leave the full redesign incomplete until its full scope
  has evidence. Give the user the launch command and a current artifact, not a claim of visual success.
