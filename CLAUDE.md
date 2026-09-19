# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Recorder: a native macOS (15+, Apple Silicon) screen recorder + non-destructive video editor, modelled on Screen Studio.
The repo is currently a **buildable skeleton plus a full spec and plan**. `docs/SPEC.md` is the source of truth for *what*:
feature scope, ASCII mockups of every screen, acceptance criteria (`AC-*`), project file format, milestones M1–M6.
`docs/PLAN.md` is the ordered task list **and the progress tracker** (79 tasks, `T-001`…`T-610`). `reference/*.png` are
screenshots of the real Screen Studio recording flow that the mockups were derived from.

## How to work here (mandatory)

1. Open `docs/PLAN.md`, take the **first unchecked task**, and do only that task. No skipping, no batching.
2. Read the SPEC sections and files the task names. Code-block signatures in the plan are normative.
3. Run the task's Verify step for real (`make test FILTER=…`, `--selftest …`). Never tick a task on unverified work.
4. Tick it (`- [x]`), bump the Status table, append a line to the plan's Log, commit as `T-xxx <title>`.
5. `HUMAN:` steps (granting TCC permissions, judging visuals against a mockup) cannot be done by an agent: finish the rest,
   mark `- [~]`, and ask the user. If a task is wrong or impossible, write `BLOCKED: …` under it and ask — don't redesign.

If the user asks for something that isn't in the plan, do it, then add/adjust the matching task or SPEC section so the
docs stay the source of truth.

## Ponytail (lazy senior dev) — applies to every change

Lazy = efficient, not careless. Before writing code, stop at the first rung that holds:

1. Does this need to exist? If the current task doesn't ask for it, don't build it. (YAGNI)
2. Already in this repo? Reuse it — `Theme`, `FloatingPanel`, `SelectionRectView` (area selection *and* crop *and* manual-zoom
   target), `LabeledSlider`, `EditorModel.edit`/gesture API, `TimeMap`, `Spring`, the generic timed-block ops.
3. Does Foundation/AppKit/SwiftUI/AVFoundation/ImageIO already do it? Use that (`NSMenu`, `Form`, `NSPopover`,
   `FileManager.trashItem`, `CGImageDestination`, `AVMutableComposition.scaleTimeRange`…).
4. Can it be one line? One line.
5. Only then: the minimum code that works.

Hard limits: no third-party packages · no protocol with a single conformer · no manager/service/coordinator layers · no
config for values that never change · no speculative options or settings · fewest files (use the file the task names) ·
deletion over addition · boring over clever.

Deliberate corner-cuts get a `// ponytail: <known ceiling>, <upgrade path>` comment (e.g. full 240 Hz path re-simulation on
every edit; ImageIO's default GIF palette; whole-`Project` undo snapshots). Grep `ponytail:` to list the debt.

**Never lazy about:** understanding the task and the code it touches before editing · TCC permission checks · atomic
`project.json` writes · the privacy default that printable keys are not logged unless Record all keystrokes is explicitly enabled
· `TimelineOps` invariants · preview/export pixel parity · the Verify step. Non-trivial Core logic leaves exactly the tests
the plan lists; the app target has no unit tests and is checked through `--selftest` cases and HUMAN steps.

Bug fixes go to the root cause in the shared function (e.g. fix `TimeMap`/`TimelineOps`, not each caller).

## Commands

```
make build                 # swift build -c release   (CONFIG=debug for debug)
make test                  # all tests
make test FILTER=timeMap   # a single test or suite (passed to --filter)
make app                   # assemble + codesign build/Recorder.app
make run                   # app + open it
make install               # copy to /Applications/Recorder.app (kills a running instance first)
make cert                  # one-time: create the self-signed "Recorder Dev" signing identity
make clean
build/Recorder.app/Contents/MacOS/Recorder --selftest <name> [args]   # headless app checks (cases are added by plan tasks)
scripts/freeze-dump.sh [pid]                                          # hung main thread: sample+ps into a new snapshot folder, path to clipboard
```

`Recorder ▸ Copy State Snapshot` (⌃⌥⌘S, global, also works mid-recording) writes a debugging folder
(app/permission/recording/editor state, own-window screenshots) under `~/Library/Logs/Recorder/Snapshots/`
and copies its path (SPEC §8.1) — for handing an AI assistant one path instead of narrating a bug.

Always test via `make test`, not bare `swift test` — see the first constraint below.

## Toolchain constraints (verified on this machine — these drive the architecture)

This machine has **Command Line Tools only, no Xcode**:

- **No XCTest.** Tests use swift-testing (`import Testing`, `@Test`, `#expect`). Its frameworks ship with CLT but are off the
  default search path; the Makefile's `TESTFLAGS` add the `-F`/`-rpath` flags. Bare `swift test` fails with `no such module 'Testing'`.
- **No offline `metal` compiler.** Never add `.metal` files. Shaders are MSL source in a Swift string compiled at launch with
  `MTLDevice.makeLibrary(source:options:)`.
- **No `xcodebuild`.** SwiftPM only; the `.app` bundle is assembled by the Makefile from `.build/<config>/Recorder` + `Resources/Info.plist`.
  No asset catalogs, xibs, or storyboards — loose resource files copied into the bundle, SF Symbols for icons.
- **Signing / TCC.** With ad-hoc signing macOS drops Screen Recording + Accessibility grants on every rebuild. The Makefile
  signs with the `Recorder Dev` identity automatically when it exists (`make cert`), else falls back to ad-hoc.
- Swift tools 6.0 but **language mode 5** on all targets (set in `Package.swift`), deliberately, to avoid strict-concurrency
  friction with AVFoundation/ScreenCaptureKit callbacks.
- No third-party dependencies. Don't add any.

## Architecture (big picture)

Two targets with a hard boundary:

- **`RecorderCore`** — pure logic, no AppKit/AVFoundation/Metal imports, fully unit-tested: `Project` Codable model, `TimeMap`
  (output↔source time), `TimelineOps` (split/trim/remove/speed/zoom edits as `Project -> Project` functions with invariants),
  `Spring`, `AutoZoom` (clicks → zoom blocks), `CursorPath`, `CameraPath`.
- **`Recorder`** — the app, verified by running it, not unit-tested: AppKit shell (NSPanels/overlays/menus/event tap),
  SwiftUI forms inside `NSHostingView` (inspector, onboarding, export, settings, library), a single custom-drawn AppKit
  `TimelineView`, an `MTKView` preview, capture, Metal compositor, exporter.

Rule: if it can be computed from `project.json` + `events.json` without a framework, it belongs in Core with a test.

Key ideas that span files:

- **Record raw, render later.** Capture writes a cursor-less `screen.mov` (`showsCursor = false`), optional `camera.mov`,
  `mic.m4a`, `system.m4a`, plus `events.json` (mouse/click/key events in normalised source coords) and hi-res cursor images.
  All share one clock: seconds since the first screen frame, paused time already subtracted. Media is never modified afterwards.
- **One compositor for preview and export.** `Compositor.render(FrameState)` draws background → screen (rounded/shadow/crop/zoom/
  motion blur) → re-drawn smoothed cursor → camera/masks. The preview `MTKView` and the `AVAssetWriter` export loop call the same
  code, so they must be pixel-identical (AC-ED-2). `FrameState` is a pure function of output time.
- **Two time domains.** The timeline x-axis and playhead are *output* time; zooms/layouts/masks are stored in *source* time so
  cutting or speeding a clip never rewrites effects. Convert only through `TimeMap`.
- **Random-access animation.** Zoom camera and cursor smoothing are simulated once per edit into 240 Hz lookup tables, so any
  frame can be rendered independently of playback history (required for scrubbing and export determinism).
- **Project = package directory** `~/Movies/Recorder/<Title>.recorder/`. The editor only ever rewrites `project.json`
  (atomic, debounced autosave; no NSDocument). Undo is a snapshot stack of the `Project` value; every gesture = one undo step
  via `EditorModel.edit { }`.

## Conventions

- The spec's "Choices" table (§2) is final — don't swap frameworks or add abstraction layers.
- Colours/radii/fonts come only from the design tokens (SPEC §3) via one `Theme.swift`.
- SPEC §9 lists open questions to verify during M1; record answers in the spec rather than guessing.
