# Recorder — Implementation Plan & Tracker

This file is **both the plan and the progress tracker**. `docs/SPEC.md` says *what* (mockups, behaviour, `AC-*`);
this file says *in what order, in which file, with what code, and how to prove it*.

## 0. Protocol (read every session)

1. Find the first task below that is `- [ ]`. Do **only that task**. Never skip ahead, never batch tasks.
2. Read the SPEC sections the task lists. Read the files the task touches.
3. Implement exactly what "Do" says. Signatures in code blocks are **normative** (names, parameters, types); bodies are yours.
4. Run the task's **Verify** commands. Paste nothing, fake nothing: if a command fails, fix it or stop.
5. When Verify passes: change `- [ ]` to `- [x]`, append one line to §Log at the bottom
   (`T-xxx · date · what you verified · any deviation`), and commit: `git commit -am "T-xxx <title>"`.
6. `HUMAN:` lines need a person (permissions, looking at the screen). Do everything else, then stop and ask the user to
   perform the HUMAN step. Mark the task `- [~]` (blocked on human) until they confirm. Do not tick it yourself.
7. If the task is wrong or impossible: do not improvise an architecture. Write `BLOCKED: <why>` under the task, stop, ask.

### Ponytail rules (apply to every task)

Before writing code, stop at the first rung that holds:
1. Is it in this task? If not, **don't build it** (no "while I'm here", no options for later).
2. Does it already exist in this repo? Reuse it (`SelectionRectView`, `Theme`, `model.edit`, `TimeMap`, `Spring`).
3. Does Foundation/AppKit/SwiftUI/AVFoundation already do it? Use that (`NSMenu`, `Form`, `Slider`, `FileManager.trashItem`, `CGImageDestination`…).
4. Can it be one line? One line.
5. Only then: the minimum code that works.

Hard limits: no third-party packages · no protocol with one conformer · no generic "manager/service/coordinator" layers ·
no new file when the task names the file · no comments that restate code · no extra settings/toggles.
A deliberate shortcut gets `// ponytail: <ceiling>, <upgrade path>`.
**Never lazy about:** permissions checks, atomic writes, not logging typed text, invariants in `TimelineOps`, the Verify step.
Tests: Core logic gets the tests the task lists — no more. App target gets none; it is verified with `--selftest` and HUMAN checks.

### Verification tools

- `make test FILTER=<name>` — Core unit tests (swift-testing; `import Testing`, never XCTest).
- `make app && build/Recorder.app/Contents/MacOS/Recorder --selftest <name> [args]` — headless app checks added by tasks below.
  Each selftest prints `SELFTEST <name> OK` and exits 0, or prints the reason and exits 1.
- `HUMAN:` visual checks reference a SPEC mockup; the human compares the running app against it.

### Status

| Milestone | Tasks | Done |
|---|---|---|
| M0 Foundations | T-001…T-006 | 6/6 |
| M1 Record | T-101…T-114 | 2/14 |
| M2 Record+ | T-201…T-208 | 0/8 |
| M3 Editor shell | T-301…T-313 | 0/13 |
| M4 Timeline | T-401…T-418 | 0/18 |
| M5 Ship | T-501…T-509 | 0/9 |
| M6 Polish | T-601…T-609 | 0/9 |

Update the "Done" column whenever you tick a task.

---

## M0 — Foundations

- [x] **T-001 git + signing identity**
  - Do: `git init && git add -A && git commit -m "skeleton + spec"`. Then `make cert`.
  - HUMAN: `make cert` asks for the login-keychain password once; on first `codesign` click "Always Allow".
  - Verify: `security find-identity -p codesigning | grep "Recorder Dev"` prints a line; `make app` output ends with signing by `Recorder Dev`; `codesign -dv build/Recorder.app 2>&1 | grep Authority` shows `Recorder Dev`.

- [x] **T-002 Theme** · SPEC §3
  - File: `Sources/Recorder/App/Theme.swift`
  - Do: one `enum Theme` with static `NSColor`s for every token in SPEC §3 (+ `Color` accessors via `Color(nsColor:)`), radii, fonts. Add `NSColor(hex:)` (6/8-digit) here — the only hex parser in the repo.
  ```swift
  enum Theme {
      static let bgWindow = NSColor(hex: "#0A0B0F") // …one per token
      enum Radius { static let control: CGFloat = 6, card: CGFloat = 10, panel: CGFloat = 16 }
      static func timecodeFont(_ size: CGFloat) -> NSFont { .monospacedDigitSystemFont(ofSize: size, weight: .medium) }
  }
  ```
  - Verify: `make build`.

- [x] **T-003 App shell** · SPEC §8
  - Files: replace `Sources/Recorder/main.swift` with `Sources/Recorder/App/main.swift` + `App/AppDelegate.swift`.
  - Do: `main.swift` = parse `--selftest` (T-004) else run `NSApplication` with `AppDelegate`. AppDelegate: `NSApp.appearance = NSAppearance(named: .darkAqua)`; build the main menu in code exactly as SPEC §8 (items may have `action: nil` for now — they get wired by later tasks); `applicationShouldTerminateAfterLastWindowClosed → false`; create `NSStatusItem` with menu `New Recording / Projects / Quit`.
  - Verify: `make run`. HUMAN: menu bar shows Recorder/File/Edit/Record/Export/View/Window; status item present; closing windows doesn't quit.

- [x] **T-004 Selftest harness**
  - File: `Sources/Recorder/App/SelfTest.swift`
  ```swift
  enum SelfTest {
      /// Register with: SelfTest.cases["name"] = { args in … throws }
      nonisolated(unsafe) static var cases: [String: ([String]) async throws -> Void] = [:]
      static func runIfRequested() // reads CommandLine.arguments; runs case; prints "SELFTEST <name> OK"; exit(0|1)
  }
  ```
  - Do: add case `metal` that compiles `"kernel void k(uint2 g [[thread_position_in_grid]]) {}"` with `makeLibrary(source:)`.
  - Verify: `make app && build/Recorder.app/Contents/MacOS/Recorder --selftest metal` → `SELFTEST metal OK`.

- [x] **T-005 Project model** · SPEC §5
  - File: `Sources/RecorderCore/Project.swift`. Test: `Tests/RecorderCoreTests/ProjectTests.swift`.
  - Do: `public struct Project: Codable, Equatable, Sendable` mirroring the JSON in SPEC §5 **field for field, same names**. Nested structs: `Source, Zoom, Layout, Mask, TimeRange, NormRect, NormPoint, Background, Frame, CursorStyle, Animation, Camera, Audio, Keys, Output`. String-backed enums for every `a|b|c` field. `Clip` already exists in `TimeMap.swift` — reuse it.
    Every struct has `init()` with the defaults shown in SPEC §5 and a custom `init(from:)` that uses `decodeIfPresent ?? default` for **every** key. Write one private helper and use it everywhere:
  ```swift
  extension KeyedDecodingContainer {
      func value<T: Decodable>(_ key: Key, default d: T) throws -> T { try decodeIfPresent(T.self, forKey: key) ?? d }
  }
  public static let currentVersion = 1
  public static func load(from url: URL) throws -> Project   // throws ProjectError.newerVersion if version > current
  public func save(to url: URL) throws                        // JSONEncoder [.prettyPrinted,.sortedKeys], Data.write(options:.atomic)
  ```
  - Tests (exactly these): `projectRoundTrip` (fully populated → encode → decode → equal) · `projectDefaultsFromMinimalJSON` (`{"version":1,"source":{…}}` decodes; `frame.padding == 0.08`) · `projectRejectsNewerVersion`.
  - Verify: `make test FILTER=project` · covers AC-PRJ-1, AC-PRJ-2.

- [x] **T-006 Event log model** · SPEC §4.8, §5
  - File: `Sources/RecorderCore/Events.swift`. Test in `ProjectTests.swift`.
  ```swift
  public struct InputEvent: Codable, Equatable, Sendable {
      public enum Kind: String, Codable, Sendable { case move, down, up, drag, scroll, key, typing, cursor }
      public var t: Double; public var k: Kind
      public var x: Double?; public var y: Double?     // normalised 0…1, top-left origin
      public var b: Int?                               // button
      public var keyCode: Int?; public var mods: UInt? // only for k == .key
      public var id: String?                           // cursor image hash for k == .cursor
  }
  public struct EventLog: Codable, Sendable { public var events: [InputEvent]
      public func moves() -> [InputEvent]; public func clicks() -> [InputEvent] }   // drag counts as move; clicks = left .down
  ```
  - Test: `eventLogRoundTrip`. Verify: `make test FILTER=eventLog`.

---

## M1 — Record  (SPEC §4.1–4.5, §4.8)

- [x] **T-101 Permissions** · SPEC §4.1
  - File: `Sources/Recorder/App/Permissions.swift`
  ```swift
  enum Permissions {
      static var screen: Bool { CGPreflightScreenCaptureAccess() }
      static var accessibility: Bool { AXIsProcessTrusted() }
      static func requestScreen() { CGRequestScreenCaptureAccess() }
      static func requestAccessibility() { AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary) }
      static var allGranted: Bool { screen && accessibility }
  }
  ```
  - Selftest `permissions`: prints both booleans, always OK. Verify: run it.

- [~] **T-102 Onboarding window** · SPEC §4.1 mockup
  - File: `Sources/Recorder/App/OnboardingView.swift` (SwiftUI) — shown by AppDelegate in a 660×470 non-resizable `NSWindow` when `!Permissions.allGranted`.
  - Do: two rows + Continue, as the mockup. `Timer.publish(every: 1)` re-reads `Permissions`. Relaunch button (only if screen was just requested and still false after 5 s): `Process` launch `open -n <bundlePath>` then `NSApp.terminate`.
  - HUMAN: grant both permissions to `/Applications/Recorder.app` after `make install`; confirm AC-ONB-1/2/3.
  - WAITING ON HUMAN: run `make install`, grant Screen Recording and Accessibility to `/Applications/Recorder.app` in System Settings, then confirm AC-ONB-1 (window appears fresh / doesn't when both granted), AC-ONB-2 (rows flip within 2 s, Relaunch button appears/works if needed), AC-ONB-3 (Continue disabled until both granted).

- [x] **T-103 Floating panel base**
  - File: `Sources/Recorder/Recording/FloatingPanel.swift`
  ```swift
  /// Borderless, non-activating, above everything, on all Spaces, HUD material, radius 16. Every recording-flow window uses this.
  final class FloatingPanel: NSPanel {
      init(content: NSView, draggable: Bool)
      override var canBecomeKey: Bool { true }
      static var allWindowIDs: [CGWindowID] { get }   // every live FloatingPanel/overlay window number → used to exclude from capture
  }
  ```
  - Do: `styleMask [.borderless,.nonactivatingPanel]`, `level = .init(Int(CGShieldingWindowLevel()) - 1)`, `collectionBehavior [.canJoinAllSpaces,.fullScreenAuxiliary]`, `isMovableByWindowBackground = draggable`, content wrapped in `NSVisualEffectView(material: .hudWindow)` with `layer.cornerRadius = Theme.Radius.panel`. Keep a static weak list for `allWindowIDs`.
  - Verify: `make build` (exercised by T-104).

- [ ] **T-104 Recording toolbar** · SPEC §4.2 mockup + menus
  - Files: `Recording/RecordingSettings.swift`, `Recording/ToolbarView.swift` (SwiftUI), `Recording/ToolbarController.swift`.
  ```swift
  @Observable final class RecordingSettings {          // persisted to UserDefaults on didSet, one key each
      enum Mode: String { case display, window, area }
      var mode: Mode; var cameraID: String?; var micID: String?
      enum SystemAudio: Codable { case off, all, apps([String]) }   // bundle ids
      var systemAudio: SystemAudio
      var denoise, disableAGC, hideDesktopIcons, hideDockIcon, highlightArea: Bool
      var countdown: Int                                  // 0,3,5,10
      static let shared = RecordingSettings()
  }
  ```
  - Do: toolbar = `HStack` of close · 3 mode buttons (SF Symbols `display`, `macwindow`, `rectangle.dashed`) · 3 input buttons · gear. Input buttons and gear pop a **native `NSMenu`** built in `ToolbarController` (`NSMenu.popUp(positioning:at:in:)`) with the exact items of SPEC §4.2; checkmarks from settings. Devices: `AVCaptureDevice.DiscoverySession` (`.video` / `.audio`); observe `AVCaptureDevice.wasConnectedNotification`/`wasDisconnected`. No "Device" button. `Esc` handling per AC-TB-4 via `cancelOperation(_:)`.
    Wire: status item "New Recording", `⌘N`, dock click (`applicationShouldHandleReopen`) → `ToolbarController.shared.show()`.
  - HUMAN: compare to `reference/Screenshot…12.50.40.png`; AC-TB-2/3/4.

- [ ] **T-105 SelectionRectView (shared)** · SPEC §4.5, §6.7
  - File: `Sources/Recorder/Recording/SelectionRectView.swift` — used by area selection **and** the crop sheet. Build it once.
  ```swift
  final class SelectionRectView: NSView {
      var rect: CGRect                     // in view coords; didSet → needsDisplay + onChange
      var limit: CGRect                    // rect is clamped inside this
      var minSize = CGSize(width: 100, height: 100)
      var aspect: CGFloat?                 // locked aspect (crop presets); ⇧ locks current
      var onChange: ((CGRect) -> Void)?
  }
  ```
  - Do: draws 45% dim outside, dashed thirds inside, 8 round handles. Mouse: create / move / resize per SPEC §4.5 (⇧ aspect, ⌥ from centre), arrow keys nudge 1 px (⇧ = 10). Cursor rects for handles.
  - Verify: `make build`; exercised by T-108.

- [ ] **T-106 CaptureTarget + content filter**
  - File: `Sources/Recorder/Recording/CaptureTarget.swift`
  ```swift
  enum CaptureTarget { case display(SCDisplay), window(SCWindow), area(SCDisplay, CGRect /* display points, top-left origin */) }
  extension CaptureTarget {
      func filter(content: SCShareableContent, settings: RecordingSettings) -> SCContentFilter
      func configuration(settings: RecordingSettings) -> SCStreamConfiguration
      var pixelSize: CGSize { get }; var scale: CGFloat { get }
      var frameInScreenPoints: CGRect { get }     // for normalising cursor positions
  }
  ```
  - Do: display/area → `SCContentFilter(display:excludingWindows:)` excluding every window whose `windowID ∈ FloatingPanel.allWindowIDs` (+ Finder desktop-icon windows when `hideDesktopIcons`, see SPEC open question 3); window → `SCContentFilter(desktopIndependentWindow:)`. Configuration exactly per SPEC §4.8 (`showsCursor=false`, 60 fps, `420v`, `queueDepth 6`, even-rounded size, `sourceRect` for area, audio + mic flags).
  - Verify: `make build`.

- [ ] **T-107 Display & window pickers** · SPEC §4.3, §4.4 mockups
  - File: `Sources/Recorder/Recording/SourcePickerOverlay.swift`
  - Do: one borderless full-screen overlay window per `NSScreen` (same level as `FloatingPanel` − 1, registered in `allWindowIDs`). Content = SwiftUI: dim + title + size line + `Start recording` button (accent, with `⌄` countdown submenu). Display mode: active = screen under `NSEvent.mouseLocation` (tracking area). Window mode: on mouse move, hit-test `SCShareableContent.windows` (on-screen, `windowLayer == 0`, ≥100×100, not ours) front-to-back; draw accent tint + 2 px border on its frame; click selects. Convert `SCWindow.frame` (top-left origin, global) to the overlay's coords — write one `func flip(_ r: CGRect, in screen: NSScreen) -> CGRect` and reuse it in T-109.
    `Return` = start. Omit the `[Resize]` button until T-206.
  - HUMAN: AC-DSP-1, AC-WIN-1 vs `reference/…13.02.15.png`, `…13.02.25.png`.

- [ ] **T-108 Area overlay** · SPEC §4.5 mockup
  - File: `Sources/Recorder/Recording/AreaSelectionOverlay.swift`
  - Do: overlay window on the display under the mouse hosting `SelectionRectView` + a small `FloatingPanel` with the Size/Position fields (SwiftUI `TextField(value:format:.number)`), two-way bound to `rect`. Remember last rect per display in `UserDefaults` keyed by `CGDirectDisplayID`. Start button below the toolbar.
  - HUMAN: AC-AREA-1 vs `reference/…13.02.32.png`.

- [ ] **T-109 EventRecorder** · SPEC §4.8
  - File: `Sources/Recorder/Recording/EventRecorder.swift`
  ```swift
  final class EventRecorder {
      init(target: CaptureTarget, cursorsDir: URL)
      func start(t0HostTime: CMTime)          // call when the first screen frame arrives
      func pause(); func resume()             // accumulates pausedSoFar
      func stop() -> EventLog
  }
  ```
  - Do: `CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly, eventsOfInterest: mask, …)` on a dedicated thread's run loop. `t = hostSeconds(event.timestamp) − t0 − pausedSoFar` (convert mach ticks with `mach_timebase_info`). Position: `event.location` (global, top-left) → normalised against `target.frameInScreenPoints`; for `.window` re-read the window frame at 10 Hz.
    **Keys:** store `.key` only if ⌘/⌃/⌥ is down or the key is non-printing (arrows, return, esc, tab, delete, F-keys). Otherwise store `.typing` with **no keyCode**. This is a privacy rule; do not relax it.
    Cursor: 60 Hz `DispatchSourceTimer` reads `NSCursor.currentSystem`; hash `tiffRepresentation` (SHA256 via CryptoKit, first 8 hex); new hash → write largest rep as `cursors/<id>.png` + `<id>.json` `{hotX,hotY,scale}`; emit `.cursor`. Coalesce `.move` closer than 1/240 s.
  - Selftest `events 3`: records 3 s into a temp dir, prints counts per kind; OK if ≥1 cursor image exists. HUMAN: wiggle the mouse while it runs.

- [ ] **T-110 CaptureSession (screen + audio writers)** · SPEC §4.8
  - File: `Sources/Recorder/Recording/CaptureSession.swift`
  ```swift
  final class CaptureSession: NSObject, SCStreamOutput, SCStreamDelegate {
      init(target: CaptureTarget, settings: RecordingSettings, packageURL: URL) async throws
      func start() async throws
      func pause(); func resume()
      func finish() async throws -> Project.Source     // stops stream, finishes writers, returns measured duration/size
      func cancel() async                                // stop + delete packageURL
      private(set) var elapsed: Double                    // for the widget
  }
  ```
  - Do: one private `final class TrackWriter { init(url:, videoSettings|audioSettings); func append(_ sb: CMSampleBuffer, offset: CMTime); func finish() async }` wrapping `AVAssetWriter` + one input (`expectsMediaDataInRealTime = true`, `movieFragmentInterval = 10 s`). Three instances: `screen.mov` (HEVC, bitrate `min(60e6, w*h*4)`), `system.m4a`, `mic.m4a` (AAC 48 k/192 k).
    In `stream(_:didOutputSampleBuffer:of:)`: for `.screen` skip unless attachment `SCStreamFrameInfo.status == .complete`; first complete frame sets `t0` and calls `eventRecorder.start(t0HostTime:)`; retime every buffer with `CMSampleBufferCreateCopyWithNewTiming` to `pts − t0 − pausedSoFar`. While paused drop buffers; on resume add the gap to `pausedSoFar`.
    Add outputs for `.screen`, `.audio`, `.microphone` on one serial queue. `// ponytail: one queue for all three outputs; split if audio ever drops.`
  - Selftest `record display 3`: records main display 3 s to a temp package; asserts `screen.mov` has a video track, duration 2.5–3.5 s, size == display pixels, `events.json` exists. Verify: run it (needs T-102 HUMAN done).

- [ ] **T-111 Recording flow glue**
  - File: `Sources/Recorder/Recording/RecordingController.swift`
  ```swift
  @MainActor final class RecordingController {
      static let shared = RecordingController()
      enum State { case idle, picking, countdown, recording, paused, finishing }
      private(set) var state: State
      func begin(target: CaptureTarget)     // from pickers' Start button
      func finish(); func cancel()
  }
  ```
  - Do: `begin` → close overlays/toolbar → create `~/Movies/Recorder/Recording <yyyy-MM-dd HH.mm.ss>.recorder/` → `CaptureSession.start`. `finish` → `CaptureSession.finish` → write `events.json` → build `Project` (source, one clip `0…duration`, defaults) → `project.save` → for now `NSWorkspace.shared.activateFileViewerSelecting([package])` (editor arrives in M3). Minimal stop UI for M1: status item title shows `● mm:ss`, its menu gains `Finish Recording`.
  - Verify: HUMAN records 10 s of a display, a window and an area; each package opens in Finder ("Show Package Contents") with playable `screen.mov` **without a cursor**; AC-AREA-2, AC-WIN-3.

- [ ] **T-112 Highlight recorded area**
  - Do (in `RecordingController`): when `highlightArea` and target is area/window: a click-through overlay window (`ignoresMouseEvents = true`, in `allWindowIDs`) drawing a 2 px accent outline 2 px outside the rect. Remove on finish.
  - HUMAN: outline visible while recording, absent in `screen.mov`. AC-TB-1.

- [ ] **T-113 Crash-safe recording** · AC-REC-3
  - Do: on launch scan the projects folder for packages that have `screen.mov` but no `project.json`; for each, build the default `Project` from the asset's duration/size and save it. (Fragmented writing from T-110 makes the `.mov` readable.)
  - HUMAN: start a recording, run `pkill -9 Recorder`, relaunch: `project.json` now exists in the package and `screen.mov` plays.

- [ ] **T-114 M1 performance gate** · AC-REC-1
  - HUMAN: record 10 min of the display at 60 fps; Activity Monitor CPU < 25% of one core; `ffprobe`/QuickTime inspector shows ≥ 99% of expected frames when content is animating. Record the numbers in §Log. If it fails: check `pixelFormat` is `420v` and the writer is HEVC hardware (`AVVideoCodecType.hevc`), nothing else.

---

## M2 — Record+  (SPEC §4.6, §4.7, §4.4 resize)

- [ ] **T-201 Camera capture + bubble** · SPEC §4.6
  - Files: `Recording/CameraCapture.swift`, `Recording/CameraBubblePanel.swift`.
  - Do: `AVCaptureSession` (preset `.high`) with the selected device; `AVCaptureVideoPreviewLayer` in a 200×200 `FloatingPanel` (mirrored via `connection.isVideoMirrored`, `cornerRadius 40`, `cornerCurve .continuous`), draggable, snaps to the nearest corner (24 pt margin) on mouse-up. `AVCaptureVideoDataOutput` → a fourth `TrackWriter` (`camera.mov`, H.264) using the **same** `t0`/`pausedSoFar` as `CaptureSession` (expose them). Buffers before `t0` are dropped. Store the bubble's final corner into `project.camera.corner`.
  - HUMAN: AC-CAM-1; clap test for AC-CAM-2 (compare `camera.mov` and `mic.m4a` in QuickTime).

- [ ] **T-202 Countdown** · SPEC §4.7 — File `Recording/CountdownOverlay.swift`. SwiftUI number in a panel centred on the target rect, scale+fade per second, `Esc` cancels back to the picker. `RecordingController.begin` awaits it when `countdown > 0`.
  - HUMAN: 3/5/10 work; Esc cancels.

- [ ] **T-203 Recording widget** · SPEC §4.7 mockup — File `Recording/RecordingWidgetPanel.swift`. `FloatingPanel` with timer (`Theme.timecodeFont`), Finish / Pause⇄Resume / Restart / Delete (confirm alert). Right-click → Hide. Replaces the M1 status-item-only UI (status item keeps the same actions).
  - HUMAN: AC-REC-2 (pause 5 s: duration excludes it, no audio click, cursor aligned later in M4).

- [ ] **T-204 Global hotkeys** — File `App/Hotkeys.swift` (do not reuse `EventRecorder`'s tap; it only lives while recording): `NSEvent.addGlobalMonitorForEvents(matching: .keyDown)` + local monitor; match `⌃⌥⌘R` (start: show toolbar / finish) and `⌃⌥⌘P` (pause/resume). `// ponytail: fixed bindings; rebinding UI is T-609.`
  - HUMAN: hotkeys work while another app is focused.

- [ ] **T-205 Hide dock icon / desktop icons** — `NSApp.setActivationPolicy(.accessory)` on start, `.regular` on finish. Desktop icons: answer SPEC open question 3 empirically (list `SCShareableContent.windows` where `owningApplication?.bundleIdentifier == "com.apple.finder"` and inspect `windowLayer`/title), exclude them, **write the answer into SPEC §9**.
  - HUMAN: both toggles behave.

- [ ] **T-206 Window resize presets** · SPEC §4.4 menu — File `Recording/WindowResizer.swift`: `static func resize(pid: pid_t, windowTitle: String?, to: CGSize)` via `AXUIElementCreateApplication` → `kAXWindowsAttribute` → match by title/frame → set `kAXSizeAttribute`. Add the `[Resize]` `NSMenu` to the window picker; sizes larger than the screen are disabled; saved sizes in `UserDefaults`; `Custom…` = `NSAlert` with two text fields.
  - HUMAN: AC-WIN-2.

- [ ] **T-207 Settings window (minimal)** · SPEC §8 — File `App/SettingsView.swift`: SwiftUI `Form` with General (projects folder via `NSOpenPanel`) and Recording (fps 30/60, countdown, 3 toggles) bound to `RecordingSettings`. `⌘,`.
  - HUMAN: values persist across relaunch.

- [ ] **T-208 M2 gate** — HUMAN: full pass of SPEC §4 mockups vs the app; list deviations in §Log.

---

## M3 — Editor shell  (SPEC §5.1, §6.1, §6.2, §6.6 Background, §6.7)

- [ ] **T-301 ProjectStore** · SPEC §5.1
  - File: `Sources/Recorder/Library/ProjectStore.swift`
  ```swift
  @Observable final class ProjectStore {
      struct Item: Identifiable { let id: URL; var title: String; var duration: Double; var modified: Date; var thumbnail: NSImage? }
      private(set) var items: [Item]
      var folder: URL                                    // default ~/Movies/Recorder, from Settings
      func reload()                                      // background scan of *.recorder, sorted by modified desc
      func rename(_ url: URL, to: String) throws; func duplicate(_ url: URL) throws; func trash(_ url: URL) throws
  }
  ```
  - Do: `DispatchSource.makeFileSystemObjectSource` on the folder → `reload()`. Rename moves the package dir **and** sets `project.title`. Trash = `FileManager.trashItem`. Thumbnail: `AVAssetImageGenerator` at 1 s → `thumbnail.jpg` written once (during `RecordingController.finish`).
  - Selftest `library`: creates 3 fake packages in a temp folder, asserts order, rename, duplicate, trash.

- [ ] **T-302 Library window** · SPEC §5.1 mockup — File `Library/LibraryView.swift`: `LazyVGrid(.adaptive(minimum: 220))`, search field, context menu, inline rename, empty state, `New Recording` button. Open on launch (when permissions OK) and `⇧⌘O`. Document open: `application(_:open:)` for `.recorder` packages; already-open project → focus its window.
  - HUMAN: AC-LIB-2, AC-LIB-3.

- [ ] **T-303 EditorModel (state + undo + autosave)** · SPEC §2 "Undo", §5 "Autosave"
  - File: `Sources/Recorder/Editor/EditorModel.swift`
  ```swift
  @MainActor @Observable final class EditorModel {
      let packageURL: URL
      private(set) var project: Project
      let events: EventLog
      var playhead: Double = 0            // OUTPUT seconds
      var isPlaying = false
      var selection: Set<UUID> = []       // zoom/layout/mask ids
      var selectedClip: Int?
      var timeMap: TimeMap { TimeMap(project.clips) }

      /// The ONLY way to mutate `project`. One call = one undo step.
      func edit(_ name: String, _ change: (inout Project) -> Void)
      /// For drags: begin → many `update` → commit | cancel. One undo step total.
      func beginGesture(); func update(_ change: (inout Project) -> Void); func commitGesture(_ name: String); func cancelGesture()
      func undo(); func redo()
      func saveNow()
  }
  ```
  - Do: undo/redo = two `[Project]` stacks (cap 200). `// ponytail: whole-struct snapshots; Project is a few KB.` Autosave: cancel+reschedule a 0.5 s `DispatchWorkItem` on every mutation → `project.save`; also on window close and `applicationWillTerminate`. SwiftUI sliders use `beginGesture/commitGesture` through `onEditingChanged`.
  - Selftest `model`: edit → undo → redo equality; gesture with 10 updates = 1 undo step; file on disk updated after 0.6 s. (AC-INS-2, AC-PRJ-3 partially.)

- [ ] **T-304 Shaders + Compositor v1 (background, frame, shadow, crop, aspect)** · SPEC §6.2 passes 1–2
  - Files: `Sources/Recorder/Render/Shaders.swift` (one `let shaderSource = """ … """`), `Render/Compositor.swift`, `Render/FrameState.swift`.
  ```swift
  struct FrameState {                       // built by pure code; the compositor never reads EditorModel
      var outputSize: CGSize
      var screen: MTLTexture?; var camera: MTLTexture?
      var view: ViewTransform; var prevView: ViewTransform      // {center: NormPoint, scale: Double}; identity for now
      var cursor: CursorSample?                                  // nil until T-412
      var project: Project
  }
  final class Compositor {
      init(device: MTLDevice) throws                              // makeLibrary(source: shaderSource)
      func render(_ s: FrameState, to target: MTLTexture, commandBuffer: MTLCommandBuffer)
      func outputSize(for project: Project, longEdge: Int) -> CGSize   // aspect: auto = cropped source aspect
  }
  ```
  - Shader: one vertex fn (unit quad + per-draw uniforms: rect in NDC, uv rect) and one fragment fn with `mode` uniform (0 colour, 1 gradient, 2 texture, 3 rounded-texture-with-shadow). Rounded rect + shadow = SDF:
    `float d = length(max(abs(p) - halfSize + r, 0.0)) - r;` alpha = `1 - smoothstep(-1, 1, d)`; shadow = `shadowAlpha * (1 - smoothstep(0, blurPx, d_offset))` drawn in the same quad (quad is enlarged by `blurPx`).
    Layout math (put in `RecorderCore/Layout.swift`, pure, tested): `screenRect(output:, cropAspect:, padding:) -> CGRect` = largest rect of the crop aspect inside output inset by `padding × min(w,h)`. Test `layoutFitsAndCentres`.
    Background kinds: colour, gradient (2 stops + angle), wallpaper/image (texture loaded with `MTKTextureLoader`, aspect-fill UVs); blur via `MPSImageGaussianBlur` once per change, cached.
  - Selftest `render <package> <out.png>`: renders output frame 0 at 1920 long edge to PNG; OK if file exists and the centre pixel ≠ the corner pixel.
  - HUMAN: open the PNG — rounded corners, shadow, padding, background look like SPEC §6.1's preview.

- [ ] **T-305 FrameSource + composition**
  - File: `Sources/Recorder/Render/FrameSource.swift`
  ```swift
  /// Builds the AVMutableComposition from project.clips (insertTimeRange + scaleTimeRange per clip) for screen, camera, mic, system.
  func makeComposition(package: URL, project: Project) async throws -> (AVMutableComposition, AVAudioMix)
  final class TextureCache { init(device:); func texture(from pb: CVPixelBuffer) -> MTLTexture? }   // CVMetalTextureCache; 420v → two planes, convert in shader (mode 4: biplanar YCbCr → RGB, BT.709)
  ```
  - Do: composition tracks: video[0]=screen, video[1]=camera, audio[0]=mic, audio[1]=system; volumes/mutes → `AVMutableAudioMixInputParameters`; `audioTimePitchAlgorithm = .spectral`.
  - Verify: used by T-306; selftest `composition <package>` prints composition duration == `TimeMap.outputDuration` ± 1/60.

- [ ] **T-306 PreviewView + transport** · SPEC §6.1, §6.2 "Preview"
  - File: `Sources/Recorder/Editor/PreviewView.swift` (`MTKView`, `isPaused = true`, `enableSetNeedsDisplay = true`).
  - Do: `AVPlayer` + `AVPlayerItemVideoOutput` (one per video track via `AVPlayerItem.add`; request `kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange`). `CADisplayLink` (from `NSView.displayLink(target:selector:)`) while playing → `model.playhead = player.currentTime` → `needsDisplay`. `draw`: `copyPixelBuffer(forItemTime:)` (keep last buffer if nil) → `FrameState` → `Compositor.render` to `currentDrawable`. Observe `model.project` → redraw. Seek: coalesce (`isSeeking` flag + `pendingTime`), `toleranceBefore/After: .zero`. Clip edits → rebuild composition, `replaceCurrentItem`, restore playhead. Letterbox with `Theme.bgWindow`.
    Transport bar (SwiftUI under the preview) + keys `Space ← → ⇧← ⇧→ Home End J K L`.
  - HUMAN: AC-ED-1, AC-ED-3.

- [ ] **T-307 Editor window** · SPEC §6.1 mockup — File `Editor/EditorWindowController.swift`: `NSSplitView`-free manual layout (preview | 300 pt inspector) over a timeline placeholder (`NSView`, 220 pt, height draggable 160–420). Top bar in the titlebar (`NSTitlebarAccessoryViewController`): `‹ Projects`, title (click = rename), aspect `NSPopUpButton`, Crop, Export (disabled until M5). `RecordingController.finish` and the library now open this window instead of Finder.
  - HUMAN: layout matches the mockup; AC-REC-4 (editor visible < 2 s after Finish).

- [ ] **T-308 Inspector shell + Background tab** · SPEC §6.6 — Files `Editor/Inspector/InspectorView.swift`, `Inspector/BackgroundTab.swift`, `Inspector/LabeledSlider.swift`.
  - Do: `LabeledSlider(title:, value: Binding<Double>, range:, default:, format:)` — the **only** slider component: label left, value right (double-click to type), ⌥-click resets, wraps `model.beginGesture/commitGesture`. Tab bar with 6 SF Symbol buttons (`1`–`6` keys); non-implemented tabs show `Text("Coming in M4/M5")`. Background tab: kind picker, wallpaper grid (bundled `Resources/Wallpapers/*.jpg` + `/System/Library/Desktop Pictures/*.heic` thumbnails), `ColorPicker`s, image `NSOpenPanel` (copy file into the package as `background.<ext>`), Blur/Padding/Corners/Inset/Shadow sliders.
    Wallpapers: generate 12 abstract gradient JPEGs with a throwaway selftest `make-wallpapers` (Core Image `CILinearGradient`/`CIRadialGradient` blends) and commit them. Update the Makefile `app` target: `cp -R Resources/Wallpapers $(APP)/Contents/Resources/`.
  - HUMAN: AC-INS-1 for every Background control.

- [ ] **T-309 Output aspect** — `Compositor.outputSize` honours `project.output.aspect`; popup in the top bar edits it. Test in Core: `layoutAspects` (9:16 output with 16:10 source keeps source aspect inside padding). HUMAN: switching aspect re-letterboxes instantly.

- [ ] **T-310 Crop sheet** · SPEC §6.7 mockup — File `Editor/CropSheet.swift`. Sheet window hosting the current source frame (`AVAssetImageGenerator` at playhead's source time) under a `SelectionRectView` (reuse T-105; pass `aspect` for presets). Fields in source pixels. Confirm = one `model.edit("Crop")`; Discard/Esc = nothing.
  - HUMAN: AC-CROP-1 vs `reference/…13.05.18.png`.

- [ ] **T-311 Menu wiring** — connect File/Edit/View items that now have targets (Open, Projects, Save, Save As = copy package, Show Raw Files = reveal in Finder, Undo/Redo, Crop, tabs). Items without a target stay disabled automatically (`validateMenuItem`).

- [ ] **T-312 Library perf** · AC-LIB-1 — selftest `library-perf`: 200 fake packages, `reload()` < 300 ms. If slower: make sure only `project.json` + `thumbnail.jpg` are read.

- [ ] **T-313 M3 gate** — HUMAN: record → editor opens → change every Background control → quit → reopen: identical (AC-INS-1, AC-PRJ-3 by `pkill -9` mid-edit).

---

## M4 — Timeline  (SPEC §6.3–6.5, §7 — read §7 fully before T-404)

Core first (T-401…T-403, T-410…T-412 are pure + tested), then the view.

- [ ] **T-401 TimelineOps: clips** · SPEC §7.4
  - File: `Sources/RecorderCore/TimelineOps.swift`. Tests: `Tests/RecorderCoreTests/TimelineOpsTests.swift`.
  ```swift
  public enum Edge: Sendable { case leading, trailing }
  public extension Project {
      mutating func split(atOutput t: Double, fps: Double = 60) -> Bool     // false if within 2 frames of a clip edge
      mutating func removeClip(_ i: Int) -> Bool                            // false if it is the last clip
      mutating func trimClip(_ i: Int, edge: Edge, toSource s: Double)      // clamps: neighbour's source boundary, min 0.1 s, 0…duration
      mutating func restoreCut(afterClip i: Int)                            // i = -1 → restore head; merges with neighbour when speeds match
      mutating func restoreAllCuts()
      mutating func setSpeed(_ i: Int, _ speed: Double)                     // clamp 0.25…16
      func clipIndex(atOutput t: Double) -> Int?
      func checkInvariants() -> String?                                     // nil = OK; message otherwise
  }
  ```
  - Invariants (SPEC §7.4): clips sorted by `sourceStart`, non-overlapping, each ≥ 0.1 s, speed 0.25…16, count ≥ 1. Every mutating op ends with `assert(checkInvariants() == nil)`.
  - Tests (exactly): `splitProducesTwoClipsSameSpeed` · `splitNearEdgeRefused` · `removeLastClipRefused` · `trimClampsToNeighbour` · `splitRemoveRestoreIsIdentity` (AC-TL-2) · `randomOpsKeepInvariants` (seeded `SystemRandomNumberGenerator` replacement: write a 5-line LCG; 1 000 iterations; AC-TL-1).

- [ ] **T-402 TimelineOps: zooms & generic blocks**
  ```swift
  public extension Project {
      mutating func addZoom(atSource s: Double, length: Double = 3, mode: Zoom.Mode) -> UUID?   // fits into the free gap; nil if gap < 0.5 s
      mutating func moveZoom(_ id: UUID, toStart s: Double)             // clamps against neighbours and 0…duration
      mutating func resizeZoom(_ id: UUID, edge: Edge, to s: Double)    // min 0.5 s, no overlap
      mutating func removeBlock(_ id: UUID)                             // zoom, layout or mask
  }
  public func snap(_ x: Double, candidates: [Double], threshold: Double) -> (value: Double, snapped: Bool)
  ```
  - Layout/mask blocks get the same three ops — implement **once** over a private `protocol TimedBlock { var id: UUID; var start: Double; var end: Double }` that `Zoom`, `Layout`, `Mask` adopt (three conformers ⇒ allowed), with `minLength` parameter (0.5 s).
  - Tests: `zoomsNeverOverlap` (random moves/resizes, 1 000 iters) · `addZoomFitsGap` · `snapPicksNearest`.

- [ ] **T-403 Spring** · SPEC §6.3
  - File: `Sources/RecorderCore/Spring.swift`
  ```swift
  public struct Spring: Sendable {
      public var response: Double, damping: Double            // ω = 2π/response, ζ = damping
      /// Closed form, rest → 1. ζ ≥ 1: 1 − (1 + ωt)·e^(−ωt).  ζ < 1: 1 − e^(−ζωt)·(cos ω_d t + (ζω/ω_d)·sin ω_d t), ω_d = ω√(1−ζ²)
      public func value(at t: Double) -> Double
      /// One semi-implicit Euler step toward a moving target: a = ω²(target − x) − 2ζω·v;  v += a·dt;  x += v·dt
      public func step(x: inout Double, v: inout Double, target: Double, dt: Double)
      public static let focused = Spring(response: 0.55, damping: 1), smooth = Spring(response: 0.9, damping: 0.85)
      public static let cursorRapid = Spring(response: 0.12, damping: 1), cursorMedium = Spring(response: 0.22, damping: 1), cursorSmooth = Spring(response: 0.38, damping: 1)
  }
  ```
  - Tests (AC-ZM-1): `springStartsAtZeroEndsAtOne` · `criticallyDampedIsMonotonicNoOvershoot` · `stepConvergesToClosedForm` (|step-sim − value(at:)| < 0.01 at dt = 1/240).

- [ ] **T-404 TimelineView: geometry + static drawing** · SPEC §7.1
  - File: `Sources/Recorder/Editor/TimelineView.swift` (+ `TimelineGeometry.swift` in **Core**, pure, tested).
  ```swift
  // Core
  public struct TimelineGeometry: Sendable {
      public var pxPerSecond: Double, scrollX: Double, width: Double
      public func x(forOutput t: Double) -> Double
      public func output(forX x: Double) -> Double
      public mutating func zoom(by factor: Double, anchorX: Double, minPxPerSecond: Double, maxPxPerSecond: Double)   // time under anchorX stays put (AC-TL-4)
      public func tickInterval() -> Double      // adaptive: 1/60,1/10,0.5,1,5,10,30,60… so labels are ≥ 70 px apart
  }
  ```
  - Tests: `zoomKeepsAnchorTime` · `tickIntervalReadable`.
  - View: flipped `NSView`, `wantsLayer = true`, draws in `draw(_ dirtyRect:)` with Core Graphics only. Lanes top→bottom: ruler 22, clip 44, zoom 32, layout 28 (only if `source.hasCamera`), mask 28 (hidden until T-601). Blocks: rounded rect radius 10, fill from Theme (`clip`, `accent`, `layout`, `mask`), 1 px inner highlight, label (`🔍 2.0× A`, `2× ⏩`). Zoom x-extents = `timeMap.outputTime(atSource:)` of start/end, clipped to visible clips (torn edge `⌇` when partially hidden). Playhead + cap + timecode. Observe `model` with `withObservationTracking` → `needsDisplay = true`.
  - HUMAN: static look vs SPEC §7.1 mockup.

- [ ] **T-405 Timeline navigation** · SPEC §7.2 "Navigation" — `scrollWheel` (pan; `⌘` = zoom at mouse), `magnify(with:)` (pinch at mouse), `⌘=`/`⌘-` (anchor playhead), `⇧Z`/Fit button, slider in the timeline toolbar. Click/drag on ruler = scrub (`model.playhead`, preview seeks coalesced). Page-wise auto-scroll during playback; manual scroll disables it until next play. Hover line + timecode tooltip (`NSTrackingArea`, `mouseMoved`).
  - HUMAN: AC-TL-4 (pinch keeps the time under the pointer fixed).

- [ ] **T-406 Hit-testing + cursors + selection** · SPEC §7.2 table
  ```swift
  enum TimelineHit { case playhead, clipEdge(Int, Edge), clipBody(Int), cutBubble(afterClip: Int),
                     blockEdge(UUID, Edge), blockBody(UUID), emptyLane(Lane, source: Double), ruler, none }
  func hitTest(at p: CGPoint) -> TimelineHit       // order exactly as the SPEC table; edge zone 6 pt, 3 pt when block < 24 pt
  ```
  - Do: cursor per hit (`resizeLeftRight`, `openHand`/`closedHand`, `pointingHand`, `crosshair`-style plus). Click selects (white 2 px outline + glow), `⇧`-click adds same-lane, empty click/`Esc` deselects. `⌫` removes selection (`removeClip`/`removeBlock` via `model.edit`). Inspector swap arrives in T-413.
  - HUMAN: every row of the hit table shows the right cursor.

- [ ] **T-407 Split** · SPEC §7.2 "Split" — **the headline interaction; implement every sentence of that paragraph.**
  - Do: `C` → `model.edit("Split") { $0.split(atOutput: playhead) }` (works during playback: AC-TL-5). Split mode: `flagsChanged` ⌥ = momentary, `S`/✂ button = sticky, `Esc` exits. In split mode draw a full-height dashed accent blade at the snapped mouse x with a timecode chip; preview hover-scrubs to the blade time without moving `model.playhead` (add `model.hoverTime: Double?`; `PreviewView` renders `hoverTime ?? playhead`). Click = split there. Refused split (returns false) → 3-cycle 4 px horizontal shake of the blade, no alert. Success → 0.25 s fading white line.
  - HUMAN: AC-TL-5, AC-TL-7.

- [ ] **T-408 Trim, remove, restore, speed, ripple animation** · SPEC §7.2
  - Do: clip edge drag = `beginGesture` → `update { trimClip }` per mouseDragged → `commitGesture("Trim")`; `Esc` mid-drag → `cancelGesture` (AC-TL-6). During drag: chip `00:20.60 (Δ −0:01.20)`, preview shows the edge frame via `hoverTime`. ✂ bubble drawn at every seam where `clips[i].sourceEnd != clips[i+1].sourceStart` and at head/tail when trimmed; click → `NSPopover` "Restore 00:05.80 removed here [Restore]". Context menus per SPEC (clip / empty clip area / ruler) as `NSMenu`. Speed submenu + `Custom…`. Ripple animation: when `project.clips` changes and **no drag is active**, animate block x/width from old to new geometry over 0.18 s (keep `previousRects: [Int: CGRect]`, drive with the display link, ease-out). `// ponytail: animate by index; fine because ops change at most one seam.`
  - HUMAN: remove a middle segment → neighbours slide together, bubble appears, restore works, undo is one step each.

- [ ] **T-409 Snapping + zoom-block gestures** · SPEC §7.2 "Snapping", "Zoom blocks"
  - Do: candidates = playhead, all clip edges, all block edges (except the dragged one), left-click times from `events` (draw them as 1×4 pt ticks in the zoom lane); threshold `6 / pxPerSecond`; `⌘` held disables; while snapped draw a 1 px accent guide across all lanes. Applies to: split blade, trims, block move/resize. Empty zoom lane: ghost block under pointer; click → `addZoom` (mode `.auto` if a click event lies within ±1 s, else `.manual`). Body drag = `moveZoom`, edges = `resizeZoom`. `Z` adds at playhead. Double-click = select + playhead to start. `⌘D` duplicates after itself. Context menu Disable/Enable · Instant · Remove.
  - HUMAN: AC-TL-3 feel check with a long project; AC-TL-6.

- [ ] **T-410 AutoZoom** · SPEC §6.4
  - File: `Sources/RecorderCore/AutoZoom.swift` — `public func generateAutoZooms(clicks: [InputEvent], duration: Double) -> [Zoom]` implementing the 5 numbered rules literally.
  - Tests (AC-AZ-1): `clusterByTimeAndDistance` · `mergeCloseZooms` · `dropShortAndClamp` · `outputSortedNonOverlappingDeterministic`.
  - Wire: `RecordingController.finish` fills `project.zooms`; Edit ▸ Regenerate Auto Zooms / Remove All Zooms.

- [ ] **T-411 CursorPath** · SPEC §6.5
  - File: `Sources/RecorderCore/CursorPath.swift`
  ```swift
  public struct CursorSample: Sendable { public var x, y, prevX, prevY: Double; public var imageID: String?; public var alpha, rotation, clickScale: Double }
  public struct CursorPath: Sendable {
      public init(events: EventLog, style: CursorStyle, hidden: [TimeRange], duration: Double, rate: Double = 240)
      public func sample(atSource t: Double) -> CursorSample          // index + lerp; pure lookup
  }
  ```
  - Pipeline order exactly as SPEC §6.5 (shake removal → spring follow → idle hide → loop → rotation → click pulse → hidden ranges). M4 implements: spring follow, idle hide, click pulse, imageID, hidden flag. The rest are `// T-604`.
  - Tests (AC-CUR-1): `smoothedNeverLeadsRaw` · `settlesWithinHalfPixelAfterRest` · `idleHidesAfterTwoSeconds` · `sampleIsOrderIndependent`.

- [ ] **T-412 CameraPath** · SPEC §6.3
  - File: `Sources/RecorderCore/CameraPath.swift`
  ```swift
  public struct ViewTransform: Sendable, Equatable { public var cx, cy, scale: Double; public static let identity = ViewTransform(cx: 0.5, cy: 0.5, scale: 1) }
  public struct CameraPath: Sendable {
      public init(zooms: [Zoom], cursor: CursorPath, spring: Spring, duration: Double, rate: Double = 240)
      public func sample(atSource t: Double) -> ViewTransform
  }
  ```
  - Do: build the target signal per step (outside enabled zooms: identity; inside: `scale`, centre = manual centre or dead-zone follower: move the target only when the cursor leaves the central 60% of the current viewport, then by just enough to bring it back to the 60% box). Simulate `cx, cy, scale` with `Spring.step`. `instant` zooms: copy target, zero velocity. After each step clamp centre so the viewport `[c − 0.5/scale, c + 0.5/scale]` stays inside 0…1.
  - Tests: `viewportAlwaysInsideSource` (AC-ZM-2, random zooms) · `sampleIsOrderIndependent` (AC-ZM-3) · `instantZoomJumps` · `outsideZoomsIsIdentityEventually`.

- [ ] **T-413 Paths into the renderer + cursor pass** · SPEC §6.2 passes 2–3
  - Do: `EditorModel` owns `cursorPath`/`cameraPath`, rebuilt inside `edit/update` only when `zooms`, `cursor`, `animation.screen` or `cursorHidden` changed (compare before/after). `FrameState.view/prevView/cursor` filled from them (prev = `t − 1/60`). Shader: screen UV = `center + (uv − 0.5) / scale`, inside the crop rect. Cursor pass: texture from `cursors/<id>.png` (cache `[String: MTLTexture]`), quad positioned in **screen space** (so it zooms), size = image points × `cursor.size` × output scale, offset by hotspot, × `clickScale`, alpha.
  - Selftest `render` gains `--t <seconds>`; HUMAN: play a recording with clicks — view zooms in on clicks and follows; cursor smooth, large, sharp (AC-CUR-2).

- [ ] **T-414 Inspector: selection panels + Cursor tab (basic)** · SPEC §6.6 — Files `Inspector/ZoomPanel.swift`, `ClipPanel.swift`, `CursorTab.swift`. Selection replaces tabs; `‹ Back`/`Esc` deselects (AC-INS-3). Zoom panel: Level 1.2–5, Auto/Manual, Instant, Disable, Remove. Clip panel: speed presets + custom slider 0.25–16, duration readout, Remove. Cursor tab: Hide, Size 0.5–4, Movement picker, Hide when idle (others disabled with "M6").
- [ ] **T-415 Manual zoom target in preview** — when a `.manual` zoom is selected, `PreviewView` shows the **un-zoomed** frame with a draggable accent rectangle (size = 1/scale) — reuse `SelectionRectView` with `aspect` locked and resize disabled (`allowsResize = false`, add that flag). Drag = `update { zoom.center }`.
- [ ] **T-416 Waveform** — File `Render/Waveform.swift`: `AVAssetReader` over mic (else system) → min/max peaks at 200/s → `[Float]` cached in memory; drawn inside clip blocks mapped through `TimeMap`. `// ponytail: computed on open, not cached on disk.`
- [ ] **T-417 Accessibility** · AC-TL-8 — `accessibilityChildren()` returns one `NSAccessibilityElement` per block, role `.button`, label per SPEC, `accessibilityPerformIncrement/Decrement` move by one frame. HUMAN: VoiceOver reads blocks.
- [ ] **T-418 M4 gate** — `make test` all green; HUMAN walks SPEC §7.2 paragraph by paragraph and §7.3 key by key; deviations into §Log. AC-TL-3 on a 30-min recording.

---

## M5 — Ship  (SPEC §6.2 blur, §6.6 remaining tabs, §6.8)

- [ ] **T-501 Motion blur** · SPEC §6.2 pass 2–3 — shader: when `|view − prevView|` > 0.5 px (in output px), average 8 taps of the screen texture along the UV delta, scaled by `animation.motionBlur` and gated by `blurZoom`/`blurPan` (scale change vs centre change); cursor quad: 8 taps along `pos − prevPos`, gated by `blurCursor`. Animations tab (`Inspector/AnimationsTab.swift`): slider + 3 advanced toggles + Focused/Smooth. The cursor Movement picker stays in the Cursor tab.
  - HUMAN: blur visible during zoom-in on a paused frame mid-transition (scrub slowly); none when static.
- [ ] **T-502 Camera compositing** · SPEC §6.6 Camera — pass 4: camera texture in a rounded-rect SDF quad (reuse mode 3), size/corner/roundness/mirror/shadow; `shrinkWhenZoomed`: size × `lerp(1, 0.7, (scale−1)/(2−1) clamped)`. Camera tab UI; dragging the camera in the preview snaps to nearest corner.
- [ ] **T-503 Layout track** — lane enabled; blocks via the generic block ops (T-402); kinds `cameraFull` (camera fills output, screen hidden) / `hidden`; 0.3 s cross-fade using `Spring.focused.value(at:)` at block edges; `LayoutPanel.swift`.
- [ ] **T-504 Audio tab** — volumes/mutes → rebuild `AVAudioMix` only (no composition rebuild). `denoise`: applied **at export only** as an 80 Hz high-pass + peak normalise to −1 dBFS over the mic samples; preview plays the raw mic. `// ponytail: no real noise suppression and no preview; add an audio tap if users ask.` Click sound: mix `Resources/click.caf` at each `.down` time (export only; preview plays it with `NSSound`).
- [ ] **T-505 Exporter (MP4)** · SPEC §6.8
  - File: `Sources/Recorder/Render/Exporter.swift`
  ```swift
  struct ExportSettings: Codable { enum Format: String, Codable { case mp4, gif }; var format: Format; var shortEdge: Int /*720,1080,2160*/; var fps: Int; var quality: Quality; var codec: Codec }
  final class Exporter {
      init(model: EditorModel, settings: ExportSettings, destination: URL)
      var progress: (Double, Int, Int) -> Void          // fraction, frame, total
      func run() async throws; func cancel()
  }
  ```
  - Do: video: use `AVAssetReaderTrackOutput` (not `AVAssetReaderVideoCompositionOutput`) per video track of the T-305 composition, decode sequentially, and for output frame `n` at `t = n/fps` advance each reader until its buffer PTS ≥ t (hold last). Build `FrameState` with the **same function** the preview uses (extract `func makeFrameState(model:, outputTime:, screen:, camera:, size:)` into `FrameState.swift` and call it from both). Render into a `CVPixelBuffer` from `AVAssetWriterInputPixelBufferAdaptor.pixelBufferPool` (Metal-compatible, BGRA). Audio: `AVAssetReaderAudioMixOutput` → AAC input. Bitrate formula from SPEC §6.8. Cancel → `cancelWriting` + delete file (AC-EXP-3).
  - Selftests: `export <package> <out.mp4>` (asserts duration == `timeMap.outputDuration` ± 1 frame — AC-EXP-4) · `parity <package>` (renders frame at t via preview path and export path into textures; max channel delta ≤ 1 — AC-ED-2).
- [ ] **T-506 Export sheet UI** · SPEC §6.8 mockup — `Editor/ExportSheet.swift`: pickers, size estimate (`bitrate × duration / 8`), states Exporting/Done, Copy to clipboard (temp file URL on `NSPasteboard`), persisted defaults, editor locked while exporting. Enable the Export button + `⌘E`.
- [ ] **T-507 GIF** — same frame loop → `CGImageDestinationCreateWithURL(… UTType.gif …)`, per-frame `kCGImagePropertyGIFDelayTime`, loop 0, long edge ≤ 960; warn if > 60 s. `// ponytail: ImageIO's default palette; add per-frame quantisation only if banding is reported.`
- [ ] **T-508 Perf gates** — HUMAN + selftest timing: AC-EXP-1 (1 min 1080p60 < 30 s), AC-EXP-2 (10-min drift < 1 frame: compare last click sound vs cursor pulse), AC-APP-3 (idle CPU/RAM). Numbers into §Log.
- [ ] **T-509 M5 gate / v1.0** — `make install` from a clean clone (AC-APP-1); record → edit → export end-to-end by HUMAN; tag `v1.0`.

---

## M6 — Polish  (each independent; any order)

- [ ] **T-601 Masks & highlights** · SPEC §7.1 lane, §6.6 Mask panel — lane on; rect edited in preview with `SelectionRectView`; mask = solid fill at `opacity`, highlight = dim everything outside the rect by `opacity`. Keys: only those in SPEC §7.3.
- [ ] **T-602 Keyboard-shortcut overlay** — render `.key` events as rounded chips (`⌘ ⇧ K`) bottom-centre for 1.2 s; text rendered to a texture with Core Text, cached per string. Keys tab.
- [ ] **T-603 Speed up typing** — Edit ▸ Speed Up Typing: find runs of `.typing` events (gap < 1 s, length > 3 s), split clips around them, set 2×. Core fn `typingRanges(events:) -> [TimeRange]` + test.
- [ ] **T-604 Cursor advanced** — loop position, rotate, remove shakes, always-arrow, hide-cursor ranges via Edit ▸ Hide Cursor in Selected Clip (adds the clip's source range to `cursorHidden`). Tests per stage in `CursorPath`.
- [ ] **T-605 Presets** — save/apply = the styling subset of `Project` (`background, frame, cursor, animation, camera`) as JSON in `~/Library/Application Support/Recorder/Presets/`; export/import via file panels.
- [ ] **T-606 Import video** — drag a movie into the library → package with the file copied as `screen.mov`, empty `events.json`.
- [ ] **T-607 Command menu (⌘K)** — a searchable list over the existing `NSMenu` items (walk `NSApp.mainMenu`), performs the item's action. No separate command registry.
- [ ] **T-608 Cheat sheet (⌘/)** — static SwiftUI grid of SPEC §7.3.
- [ ] **T-609 Shortcut settings + Copy frame (⇧⌘C)** — rebind the two global hotkeys; copy current composed frame to the pasteboard as PNG.

---

## Log

Append one line per completed task: `T-xxx · YYYY-MM-DD · verified: <what> · deviations: <none|…>`

T-002 · 2026-09-18 · verified: `make build` succeeds with `Sources/Recorder/App/Theme.swift` added (enum `Theme`, `NSColor` tokens + `Color` accessors, `Radius`, body/caption/title fonts, `timecodeFont`, `NSColor(hex:)`) · deviations: none
T-003 · 2026-09-18 · verified: `make build` and `make app SIGN_ID=-` succeed; launched `build/Recorder.app/Contents/MacOS/Recorder` in the background, alive after 3 s (no crash), killed cleanly · deviations: "Record" menu's spec shorthand "Start/Finish" rendered as static title "Start/Finish" (toggling to real state comes with T-104/T-111); "View" tab items titled "1"–"6" (spec §8 says only "tabs 1–6", not yet named — inspector tab names arrive with T-308+); About/Quit/Close/Window-menu Minimize/Zoom/Bring-All-to-Front wired to standard AppKit responder-chain selectors (generic, not app logic) so the app is actually usable/quittable meanwhile; visual menu/status-item check is HUMAN (marked `[~]`).
T-004 · 2026-09-18 · verified: `make app SIGN_ID=-` builds; `build/Recorder.app/Contents/MacOS/Recorder --selftest metal` prints `SELFTEST metal OK` and exits 0; `--selftest nope` prints reason and exits 1; `make test` still passes (1 test) · deviations: none
T-005 · 2026-09-18 · verified: `make test FILTER=project` passes 3/3 (`projectRoundTrip`, `projectDefaultsFromMinimalJSON`, `projectRejectsNewerVersion`); `make test` passes 4/4 (adds `timeMapRoundTrip`); `make build` succeeds · deviations: SPEC §5's example JSON values are used as every nested struct's `init()` default (spec doesn't state defaults separately from the example) except where the example gives no value (`background.imagePath` defaults to `""`); `Zoom`/`Layout`/`Mask` (no example default given for `start`/`end`/`kind` alone) default to `start:0,end:3,scale:2,mode:.manual` / `start:0,end:0,kind:.cameraFull` / `start:0,end:0,kind:.mask,opacity:0.8`; `Output.Aspect` uses explicit raw values (`r16x9 = "16:9"` etc.) since Swift case names can't contain `:`; `id`/`createdAt` default to a freshly generated `UUID().uuidString`/current ISO8601 timestamp when missing.
T-001 · 2026-09-18 · verified: user clicked Always Allow; `codesign --sign "Recorder Dev"` succeeds, `codesign -dvv` shows `Authority=Recorder Dev` · deviations: identity lists as CSSMERR_TP_NOT_TRUSTED (self-signed, expected), signing works
T-003 · 2026-09-18 · HUMAN confirmed: user ran the app, menu bar is fine · deviations: none
T-006 · 2026-09-18 · verified: `make test FILTER=eventLog` passes 1/1 (`eventLogRoundTrip`, exercises encode/decode round trip plus `moves()` incl. drag and `clicks()` filtered to left `.down`); `make test` passes 5/5; `make build` succeeds · deviations: none
T-101 · 2026-09-18 · verified: `make app` builds and signs with `Recorder Dev`; `build/Recorder.app/Contents/MacOS/Recorder --selftest permissions` prints `screen=false accessibility=false` then `SELFTEST permissions OK`, exit 0; `make test` passes 5/5 · deviations: registered the `permissions` case directly in `SelfTest.swift`'s `cases` dictionary literal (same place `metal` was registered by T-004) rather than adding a second registration mechanism
T-102 · 2026-09-18 · verified: `make app` builds and signs with `Recorder Dev`; `make test` passes 5/5; launched `build/Recorder.app/Contents/MacOS/Recorder` in the background, alive after 3 s with no crash output, killed cleanly · deviations: AppDelegate's skeleton placeholder window replaced with a conditional show of `OnboardingView` only when `!Permissions.allGranted`; when all granted nothing is shown yet (toolbar arrives in T-104), per task instruction. HUMAN verification of AC-ONB-1/2/3 (needs real TCC grants via `make install`) not yet done — task marked `[~]`.
T-103 · 2026-09-18 · verified: `make build` succeeds with `Sources/Recorder/Recording/FloatingPanel.swift` added (`FloatingPanel: NSPanel`, `.borderless`/`.nonactivatingPanel`, level `CGShieldingWindowLevel()-1`, `.canJoinAllSpaces`/`.fullScreenAuxiliary`, `isMovableByWindowBackground`, `NSVisualEffectView(.hudWindow)` content wrapper with radius-16 + 1px `Theme.stroke` border, `canBecomeKey == true`, static `allWindowIDs`); `make test` passes 5/5 · deviations: added a `static func register(_ window: NSWindow)` (not in the task's code block) backing the weak window list, since T-107's overlay windows (not `FloatingPanel` instances) also need to register into the same list for `allWindowIDs`/T-106 capture exclusion — `FloatingPanel.init` calls it on itself, no other behavior added.
