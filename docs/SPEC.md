# Recorder — Product & Engineering Spec

Export/color regression correction: every asynchronous Metal consumer uses one
commit-and-wait operation, registering completion before commit and propagating GPU
errors. Capture explicitly requests sRGB with a Rec.709 YCbCr matrix; capture and MP4
encoders tag the same primaries, sRGB transfer function and matrix. Decoded screen/camera
buffers retain their color metadata and Core Image converts them to sRGB on the same
GPU command buffer before compositing. Preview, PNG and GIF also declare sRGB. This is
an SDR pipeline; it does not preserve out-of-sRGB gamut or HDR brightness.
`export-colors` checks asymmetric color patches, Display P3/Rec.709 conversion, H.264,
HEVC and GIF round trips; `--capture` adds a real ScreenCaptureKit window capture.
`export-sheet` covers MP4, animated GIF, automatic clipboard handoff, cancel and retry.
CI and release packaging run both export checks against the assembled app.

September 2026 permission/release correction: all permission checks are passive
CGPreflightScreenCaptureAccess / AXIsProcessTrusted calls. Never enumerate ScreenCaptureKit
content on a timer, activation, or Check again: enumeration can request consent and cause
a prompt/activation loop. Explicit Allow requests are bounded to once per permission per
process. Repair access requires confirmation before using tccutil to reset only
space.microapps.recorder's ScreenCapture and Accessibility grants, refuses while another Recorder
copy is running, and reports reset failures. Relaunch waits for the old process to exit
before opening this bundle again. The view displays the running path and version.
Verify with `Recorder --selftest permission-refresh` and `onboarding-png`; these checks
do not reset the developer's real grants. Fresh grant/revoke and old-signature migration
still require a human macOS Settings check. Ad-hoc releases cannot retain a stable
identity across updates; Developer ID signing remains required to solve that limitation.
The installer uses the shared monochrome capture mark and Barlow/Andale typography.
Configured Apple credentials enable signing, notarization and stapling of app and DMG;
credential-free releases remain explicitly labelled ad-hoc and require Open Anyway.

A native macOS screen recorder + editor, functionally modelled on Screen Studio 3.7.
Sources for this spec: Screen Studio's public guide (editor) and local toolchain probes
(build constraints).

**How to use this spec (for implementing agents):**
- Build milestone by milestone (§9). Do not start a milestone until the previous one's acceptance criteria pass.
- Every screen has an ASCII mockup, a behaviour list, and acceptance criteria (`AC-…`). An AC is done only when
  you have demonstrated it (unit test for Core logic; launching the app via `make run` for UI).
- Mockups define layout and content, not pixel sizes. Pixel/colour values come from §3 (design tokens).
- If something is not in this spec, pick the simplest native behaviour and leave a `// ponytail:` comment. Do not add features.
- Items marked **LATER** or **OUT** must not be built in M1–M6.

---

## 1. Scope

### 1.1 Feature inventory

| Area | Feature | Milestone |
|---|---|---|
| Record | Display / Window / Area source selection | M1 |
| Record | Cursor-less video + separate cursor/click/key event log | M1 |
| Record | Microphone, system audio (all apps / selected apps) | M1 |
| Record | Camera overlay bubble + separate camera file | M2 |
| Record | Countdown (off/3/5/10 s), highlight recorded area, hide own dock icon, hide desktop icons | M2 |
| Record | In-progress widget: finish, pause/resume, restart, delete; menu-bar item; global hotkeys | M1 (finish) / M2 (rest) |
| Record | Window resize presets (16:9, 4:3, 9:16, 16:10, square, custom, saved sizes) | M2 |
| Projects | `.recorder` package, autosave, library window, open recent, rename/duplicate/delete, reveal raw files | M3 |
| Projects | Create project from existing video file | M6 |
| Editor | Preview canvas, play/pause, frame-accurate scrub with audio | M3 |
| Editor | Background (wallpaper/gradient/colour/image, blur), padding, rounded corners, inset, shadow | M3 |
| Editor | Output aspect ratio (Auto, 16:9, 9:16, 1:1, 4:3, 16:10), crop | M3 |
| Editor | Timeline: clip track with split / trim / remove / speed; undo/redo | M4 |
| Editor | Zoom track: auto-zooms from clicks, manual zooms, add/move/resize/disable/remove, instant zoom | M4 |
| Editor | Cursor: size, smoothing preset, hide when idle, hide entirely, loop position, always-arrow, rotate, remove shakes, click sound, hide-cursor ranges | M4 (size/smooth/idle) / M6 (rest) |
| Editor | Animations: motion blur (cursor / zoom / pan), screen animation Focused/Smooth, cursor Smooth/Medium/Rapid/None | M5 |
| Editor | Camera: size, corner position, roundness, mirror, shadow, shrink-while-zoomed; layout track (Default / Camera fullscreen / Hidden) | M5 |
| Editor | Audio: per-track volume + mute, mic noise reduction + normalise | M5 |
| Export | MP4 (H.264/HEVC) 720p/1080p/4K, 24/30/60 fps, quality levels; GIF; copy to clipboard; progress + cancel | M5 |
| Editor | Masks & highlights track | M6 |
| Editor | Keyboard-shortcut overlay | M6 |
| Editor | Speed up typing segments, copy current frame as image, command menu (⌘K), shortcut cheat sheet (⌘/) | M6 |
| Editor | Presets (save/apply/export as JSON file) | M6 |
| Settings | General (project folder, defaults), Shortcuts, Recording | M2 (minimal) / M6 |
| LATER | Captions (on-device Speech), background music, speaker notes, quick-share widget, reactions | after M6 |
| OUT | Accounts/licensing/activation, shareable cloud links & comments, iPhone/iPad device recording + device frames, auto-update | never (unless asked) |

The "Device" button from the reference toolbar is therefore **not shown**.

### 1.2 Non-goals
No cloud, no telemetry, no third-party dependencies, no Electron/web views, no plugin system.

---

## 2. Tech stack & hard constraints

Verified on the dev machine (macOS 26.2, Swift 6.3, **Command Line Tools only, no Xcode**):

| Fact (verified) | Consequence |
|---|---|
| No `xcodebuild` | SwiftPM only. The `.app` is assembled by `Makefile` (`make app`). No `.xcodeproj`, no asset catalogs, no storyboards/xibs. |
| No offline `metal` compiler | **Never add `.metal` files.** Shaders live in a Swift string (`Shaders.swift`) compiled once at launch with `MTLDevice.makeLibrary(source:options:)`. Verified working. |
| No XCTest; swift-testing is present but off the search path | Tests use `import Testing` only. Run through `make test` (adds the `-F`/rpath flags). `import XCTest` will not compile. |
| No code-signing identity | Default signing is ad-hoc ⇒ macOS **forgets Screen Recording / Accessibility grants on every rebuild**. M1 task: `make cert` creates a self-signed "Recorder Dev" code-signing identity; the Makefile auto-uses it when present. |
| Resources | No asset catalog ⇒ images are loose files copied into `Contents/Resources` by `make app`; load with `Bundle.main.url(forResource:)`. Icons inside the UI are SF Symbols. |

**Choices (final, do not re-litigate):**

| Concern | Choice | Why |
|---|---|---|
| Min OS | macOS 15, universal (arm64 + x86_64) | `SCStreamConfiguration.captureMicrophone`, modern ScreenCaptureKit |
| Language | Swift, tools 6.0, **language mode 5** | avoids strict-concurrency churn around AVFoundation/SCK callbacks |
| App shell, windows, panels, overlays, menus | **AppKit** | floating `NSPanel`s, window levels, multi-display overlays, global event taps — SwiftUI cannot do these well |
| Forms (inspector, onboarding, export sheet, settings, library grid) | **SwiftUI** in `NSHostingView` | fastest way to build sliders/toggles/lists |
| Timeline | **One custom `NSView`** (`TimelineView`), layer-backed, manual drawing + mouse handling | needs pixel-exact hit-testing, 120 fps drag; SwiftUI gestures/layout are too slow and imprecise here |
| Preview | `MTKView` (paused, draw on demand) | zero-copy from decoder |
| Compositor | **One Metal renderer** used by both preview and export | preview == export, pixel for pixel |
| Capture | ScreenCaptureKit `SCStream` → own `AVAssetWriter` | need exact first-frame timestamp + pause offsets |
| Camera | `AVCaptureSession` + `AVCaptureVideoDataOutput` → second `AVAssetWriter` | separate file, editable after |
| Input events | `CGEventTap` (listen-only, session level) | needs Accessibility permission; gives moves/clicks/keys with timestamps |
| Decode (preview) | `AVPlayer` + `AVPlayerItemVideoOutput` | free audio playback + sync |
| Decode (export) | `AVAssetReader` | deterministic, frame by frame |
| Encode | `AVAssetWriter` (VideoToolbox HW) | H.264 / HEVC |
| GIF | ImageIO `CGImageDestination` | stdlib; ponytail: no palette optimiser |
| Persistence | `Codable` JSON in a package directory; **no NSDocument**, no Core Data | simplest thing that autosaves |
| Undo | Snapshot stack of the `Project` value type | the whole edit state is one small struct; no `UndoManager` registration per action |
| State | One `@Observable` `EditorModel` per editor window | SwiftUI panels and the AppKit timeline both observe it |

### 2.1 Module layout

```
Package.swift
Makefile                      build / test / app / run / install / cert
Resources/                    Info.plist, AppIcon.icns, Wallpapers/*.jpg, click.caf
Sources/RecorderCore/         PURE LOGIC. No AppKit/AVFoundation/Metal imports. 100% unit-tested.
    Project.swift             Codable model (§5)
    TimeMap.swift             output<->source time (exists)
    TimelineOps.swift         split / trim / remove / setSpeed / zoom add-move-resize (§7.4)
    Spring.swift              closed-form spring + easing (§6.3)
    AutoZoom.swift            clicks -> zoom blocks (§6.4)
    CursorPath.swift          smoothing, idle-hide, shake removal, loop (§6.5)
    CameraPath.swift          per-frame view transform from zooms + cursor (§6.3)
Sources/Recorder/             THE APP
    App/                      main.swift, AppDelegate, menus, Permissions, Settings
    Recording/                RecorderToolbarPanel, SourcePickerOverlay, AreaSelectionOverlay,
                              CaptureSession (SCStream+writers), EventRecorder (CGEventTap),
                              CameraBubblePanel, RecordingWidgetPanel, StatusItem
    Library/                  ProjectStore, LibraryWindow
    Editor/                   EditorWindowController, EditorModel, PreviewView (MTKView),
                              TimelineView (AppKit), Inspector/*.swift (SwiftUI), CropSheet
    Render/                   Compositor.swift, Shaders.swift (MSL string), FrameSource, Exporter
Tests/RecorderCoreTests/
```

**Boundary rule:** if it can be computed from the project JSON + event log without touching a framework, it goes in
`RecorderCore` and gets a test. `Recorder` (the app target) has no unit tests; it is verified by running it.

### 2.2 Data flow

```
 RECORD                                         EDIT / EXPORT
 SCStream ──frames──► AVAssetWriter ─► screen.mov ─┐
   ├─ system audio ──► writer ───────► system.m4a  │      ┌────────────── EditorModel (Project value + undo stack)
   └─ mic ───────────► writer ───────► mic.m4a     │      │                         │
 AVCaptureSession ───► writer ───────► camera.mov  ├─► FrameSource ─► Compositor(Metal) ─► MTKView      (preview)
 CGEventTap ─────────► events.json                 │      ▲    (same code, same shaders) └► AVAssetWriter (export)
 NSCursor images ────► cursors/*.png ──────────────┘      │
                                                   RecorderCore: TimeMap, CameraPath, CursorPath (pure functions of t)
```

All four media files and `events.json` share one clock: **seconds since the first screen frame**, derived from host time
(`CMClockGetHostTimeClock`). Paused intervals are subtracted at record time, so every file is gap-free.

---

## 3. Design tokens

Dark-only UI. Put these in one file (`Theme.swift`) and never hard-code colours elsewhere.

| Token | Value | Use |
|---|---|---|
| `bg.window` | `#0A0B0F` | window background |
| `bg.panel` | `#15161C` | cards, inspector, timeline background |
| `bg.control` | `#1F2027` | buttons, inputs, track lanes |
| `bg.hover` | `#2A2B33` | hover / selected toolbar item |
| `stroke` | `#FFFFFF` @ 10% | 1 px borders |
| `text.primary` | `#FFFFFF` | |
| `text.secondary` | `#FFFFFF` @ 55% | |
| `accent` | `#5B3DF5` | primary buttons, zoom blocks, selection |
| `accent.text` | `#A08CFF` | text buttons on dark |
| `clip` | `#E8B93C` | clip track blocks (yellow) |
| `layout` | `#3CB371` | camera layout blocks (green) |
| `mask` | `#E0567A` | mask/highlight blocks |
| `danger` | `#FF5A5F` | record dot, delete |
| radius | 6 (controls) · 10 (cards, timeline blocks) · 16 (floating panels) | |
| font | system (SF Pro). 13 body · 11 caption · 22 semibold titles · monospaced digits for all timecodes | |
| motion | UI transitions 0.18 s ease-out; nothing in chrome animates longer than 0.25 s | |
| floating panels | `NSVisualEffectView` material `.hudWindow`, 1 px `stroke`, radius 16, shadow | toolbar, widgets, menus |

---

## 4. Screens — recording flow

Window/panel rule: interactive recording-flow surfaces are borderless non-activating `NSPanel`s at level `.floating`
(pickers one level below, all below modal dialogs and system menus), `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]`, and **excluded from capture**
(`SCContentFilter(... excludingWindows:)` with all of our own windows).

### 4.1 Onboarding / permissions  (ref: `12.50.10.png`)

Shown at launch whenever a required permission is missing. 660×470, not resizable.

```
┌──────────────────────────────────────────────────────────────┐
│ ● ● ●                                                        │
│                          ( ◯ )   app icon                    │
│                   Welcome to Recorder!                       │
│   Before you can start recording, we need a few permissions. │
│                                                              │
│  Screen Recording                  ┌──────────────────────┐  │
│  Needed to capture your screen.    │ Allow Screen Recording│  │
│  You may need to restart the app.  └──────────────────────┘  │
│                                                              │
│  Accessibility                     ┌──────────────────────┐  │
│  Needed to capture mouse movement  │ Allow Accessibility   │  │
│  and shortcut keystrokes.          └──────────────────────┘  │
│                                                              │
│                        [ Continue ]  (disabled until both ✓) │
└──────────────────────────────────────────────────────────────┘
```

- Screen Recording: check `CGPreflightScreenCaptureAccess()`, request `CGRequestScreenCaptureAccess()`.
- Accessibility: `AXIsProcessTrustedWithOptions([prompt: true])`.
- Granted rows replace the button with `✓ Granted` (green). Poll both every 1 s while the window is visible.
- Camera/mic are requested lazily, the first time the user picks a device.

**AC-ONB-1** Fresh install shows this window; with both granted it never appears and the toolbar (§4.2) shows instead.
**AC-ONB-2** Granting a permission in System Settings flips the row to `✓ Granted` within 2 s without relaunch (Screen Recording may need relaunch: then show a `Relaunch` button that relaunches the app).
**AC-ONB-3** `Continue` is disabled until both are granted.

### 4.2 Recording toolbar  (ref: `12.50.40.png`, `13.02.09.png`)

Opens on launch, on the menu-bar New Recording/source actions, on `File ▸ New Recording` (⌘N), and on the global hotkey. Bottom-centre of the
active display, 40 pt above the Dock. Draggable by its background.
Entering capture setup hides Projects before showing the floating toolbar and source overlay.

Dock reopening returns to the existing editor/projects window (or opens Projects), never starts source selection.
Focusing a titled app window or switching to another application dismisses recording setup. Setup cannot reopen during countdown or capture.
Source pickers only open after the toolbar is visible; hiding the toolbar or the app dismisses all pickers together.
Starting a recording dismisses setup before countdown; Escape restores setup. Once capture starts, the selected
window's application is activated and that window is raised.

```
╭──────────────────────────────────────────────────────────────────────────────────────╮
│  ⓧ  │  ▭        ▢        ⬚     │  ⦸ No camera    ⦸ No microphone    ⦸ No system audio │  ⚙ ⌄ │
│     │ Display  Window   Area   │                                                       │      │
╰──────────────────────────────────────────────────────────────────────────────────────╯
  close   source mode (one selected,        inputs: each opens a native NSMenu              settings
          bg.hover pill behind it)          label = device name, truncated ("FaceTim…")     menu
```

- `ⓧ` or `Esc`: close the toolbar and every recording overlay together, then show Projects; app stays running (menu-bar item remains).
- Selecting a source mode immediately shows that mode's overlay (§4.3–4.5). Mode persists across launches.
- Input buttons dim (`text.secondary`, slashed icon) when off; white with plain icon when on.

Menus (all native `NSMenu`, check-marked current item — ref `13.03.07`, `13.03.22`, `13.03.32`):

```
 Camera                         Microphone                              System audio
 ─────────────────────         ──────────────────────────────────     ─────────────────────────────────────
   FaceTime HD Camera            Powerbeats Pro (default)               Record system audio from all apps
   …each AVCaptureDevice         MacBook Air Microphone                 Record system audio from selected apps ▸ (app list, multi-check)
 ─────────────────────         ──────────────────────────────────     ─────────────────────────────────────
 ✓ Don't record camera           Reduce noise and normalize volume    ✓ Don't record system audio
                                 Microphone gain: macOS / device controlled
                               ──────────────────────────────────
                               ✓ Don't record microphone

 ⚙ Settings menu
 ──────────────────────────────────────────
   Hide desktop icons in recorded video
 ✓ Hide Recorder dock icon while recording
 ✓ Highlight recorded area during recording
 ──────────────────────────────────────────
   Recording countdown            ▸  Off · 3 s · 5 s · 10 s
 ──────────────────────────────────────────
   Settings…                     ⌘,
```

**AC-TB-1** Toolbar never appears in any recording (own windows excluded from the filter).
**AC-TB-2** Device lists update live when devices are plugged/unplugged (`AVCaptureDevice` connect/disconnect notifications).
**AC-TB-3** All selections persist in `UserDefaults` and are restored next launch; a missing device falls back to "Don't record…".
**AC-TB-4** One `Esc` closes the toolbar and all recording overlays together and brings Projects forward, restoring it if minimized.

### 4.3 Display picker  (ref: `13.02.15.png`)

One full-screen overlay panel **per display**. The display under the mouse is "active": dimmed 45% black with centred
content; other displays are dimmed 65% with no content.

```
┌───────────────────────────── display under cursor ─────────────────────────────┐
│ (screen content, dimmed)                                                        │
│                         Built-in Retina Display                                 │
│                            1440×900 · 60FPS                                     │
│                       ╭─────────────────────────╮                               │
│                       │  ◉ Start recording   ⌄  │   ⌄ = countdown submenu       │
│                       ╰─────────────────────────╯                               │
│                      ╭──── toolbar (§4.2) ────╮                                 │
└────────────────────────────────────────────────────────────────────────────────┘
```

**AC-DSP-1** Moving the mouse to another display moves the title/button there within one frame.
**AC-DSP-2** `Start recording` (or `Return`) starts capturing that display at native pixel resolution, 60 fps.

### 4.4 Window picker  (ref: `13.02.25.png`, `13.03.54.png`)

Hovering a window highlights it (accent-tinted 25% overlay + 2 px accent border on the window's frame, everything else
dimmed). Window list from `SCShareableContent` (on-screen, layer 0, width/height ≥ 100, not ours). Click selects it.

```
┌──────────── hovered/selected window frame ────────────┐
│                      [app icon 64]                     │
│                  Firefox Developer Edition             │
│                   1440 × 834   [Resize]                │
│               ╭─────────────────────────╮              │
│               │  ◉ Start recording   ⌄  │              │
│               ╰─────────────────────────╯              │
└────────────────────────────────────────────────────────┘
        [Resize] menu:   1280 × 720 / 1920 × 1080 / 2560 × 1440
                         ─────────
                         4:3 ▸  640×480 · 800×600 · 1024×768 · 1280×960 · 1600×1200
                         9:16 ▸ · 16:10 ▸ · Square ▸
                         ─────────
                         (saved sizes…) / Save current size
                         ─────────
                         Custom…
```

- Resize uses the Accessibility API (`AXUIElement` `kAXSizeAttribute`), keeping the window's top-left. Sizes larger
  than the display are disabled (greyed) as in the reference.
- Capture uses `SCContentFilter(desktopIndependentWindow:)` so overlapping windows never leak in.

**AC-WIN-1** Hover highlight tracks the front-most window under the cursor, including across displays.
**AC-WIN-2** Choosing a resize preset resizes the real window and the size label updates.
**AC-WIN-3** A recorded window that is covered by another window during recording still records only itself.

### 4.5 Area selection  (ref: `13.02.32.png`)

```
 (dimmed 45%)   ○─────────────○─────────────○
                ┊      ┊             ┊      ┊     inside the rect: undimmed, rule-of-thirds
                ○      ┊   drag to   ┊      ○     dashed guides, 8 round handles
                ┊      ┊    move     ┊      ┊
                ○─────────────○─────────────○
                     ╭───────────────────────╮
                     │ Size     [ 607] × [ 361] px │    numeric fields, editable, Tab between
                     │ Position [ 357]   [ 259] px │
                     ╰───────────────────────╯
                     ╭ toolbar ╮   ╭ ◉ Start recording ⌄ ╮
```

- No rect yet: crosshair cursor, drag to create. Then: drag inside = move, handles = resize, `⇧` = keep aspect,
  `⌥` = resize from centre, arrow keys nudge 1 px (`⇧` 10 px). Min size 100×100. Clamped to one display.
- Last rect is remembered per display. Capture uses `SCStreamConfiguration.sourceRect`.
- With "Highlight recorded area" on, a 2 px accent outline stays visible (outside the rect, excluded from capture) while recording.

**AC-AREA-1** Size/position fields and the on-screen rect stay in sync both ways.
**AC-AREA-2** Recorded video pixel size == rect size × display scale, even-rounded.

### 4.6 Camera bubble  (ref: `13.02.58.png`)

When a camera is selected, a live preview bubble appears (bottom-right, 200×200 pt, squircle radius 40, mirrored).
Its opaque backing follows the same rounded shape so the window shadow matches the preview, even before the first camera frame.
Draggable; snaps to the four corners with a 24 pt margin. It is a preview only — excluded from screen capture; the camera
is recorded to `camera.mov` and composited in the editor. Its corner becomes the project's initial camera position.

**AC-CAM-1** Bubble is not burned into `screen.mov`. **AC-CAM-2** `camera.mov` and `screen.mov` are in sync within ±1 frame (clap test).

### 4.7 Countdown & in-progress controls

```
 Countdown (centre of recorded area)        Recording widget (bottom-centre, draggable, excluded from capture)
        ╭───────╮                           ╭─────────────────────────────────────────╮
        │   3   │  72 pt, scales/fades      │  ● 00:42   │  ■ Finish   ❙❙   ↺    🗑  │
        ╰───────╯  each second; Esc cancels ╰─────────────────────────────────────────╯
                                               red dot    finish   pause restart delete
 Menu-bar item: ◉ 00:42  → menu: Finish (⌃⌥⌘R) · Pause/Resume (⌃⌥⌘P) · Restart · Delete · ─ · Copy State Snapshot (⌃⌥⌘S) · Hide widget
```

- Finish → stop writers → create project → open editor (§6). Restart = discard + start again with same settings (no countdown re-prompt). Delete asks for confirmation.
- Pause: stop appending samples; resume subtracts the paused duration from all subsequent timestamps (video, audio, events).
- Global hotkeys — defaults: start/finish `⌃⌥⌘R`, pause/resume `⌃⌥⌘P`, copy state snapshot `⌃⌥⌘S` (works mid-recording too, like R/P — §8's "State snapshot"), new recording `⌃⌘↩`, record display/window/area `⌥⌘3`/`⌥⌘4`/`⌥⌘5`, open last project `⌥⌘Z` (menu: §8). Configurable in Settings (M6).
- "Hide dock icon while recording": `NSApp.setActivationPolicy(.accessory)` during recording, `.regular` after.
- "Hide desktop icons": exclude Finder's desktop-icon windows from the filter (windows owned by Finder at desktop-icon level), display mode only.

**AC-REC-1** A 10-minute 1440×900@2x 60 fps recording drops < 1% of frames and the app uses < 25% of one performance core on Apple Silicon (hardware HEVC).
**AC-REC-2** Pause 5 s then resume: final duration excludes those 5 s; audio has no gap/click; cursor events stay aligned.
**AC-REC-3** Killing the app mid-recording leaves a playable `screen.mov` (writer uses `movieFragmentInterval = 10 s`) and the project is recovered on next launch.
**AC-REC-4** After Finish the editor window is visible in < 2 s for a 5-minute recording.

### 4.8 Capture details (normative)

- `SCStreamConfiguration`: `showsCursor = false`, `minimumFrameInterval = 1/60`, `pixelFormat = 420v` for displays/areas, BGRA for windows to measure native corner alpha before HEVC encoding, `queueDepth = 6`,
  `width/height` = source pixels, `capturesAudio` per setting, `excludesCurrentProcessAudio = true`, `captureMicrophone` + `microphoneCaptureDeviceID` per setting, `sampleRate 48000`, `channelCount 2`.
- Only append frames whose `SCStreamFrameInfo.status == .complete`; if the screen is idle SCK sends no frames — that is fine, the file is variable-frame-rate; FrameSource (§6.2) holds the last frame.
- Screen: HEVC, `AVVideoAverageBitRateKey` ≈ `pixels × 4` bps capped at 60 Mbps, realtime = true. Audio: AAC 48 kHz 192 kbps, one file per source.
- `t0` = PTS of the first complete screen frame. Every sample/event is stored as `pts − t0 − pausedSoFar`.
- `EventRecorder`: listen-only `CGEventTap` for `mouseMoved`, `left/right/otherMouseDown/Up`, `*MouseDragged`, `scrollWheel`, `keyDown`, `flagsChanged`.
  Position is converted to **normalised source coordinates** (0…1, origin top-left of the captured rect/window) at record time; for window capture re-read the window frame (`SCWindow.frame` via a 10 Hz poll) so moves are tolerated.
  Key events store `keyCode` + modifier flags. By default only shortcuts and non-printing keys are recorded; Settings → Record all keystrokes explicitly enables printable key codes for future recordings. Typing timestamps remain available for "speed up typing" in both modes. The editor can filter all recorded keys back to shortcuts; older timestamp-only events cannot be reconstructed.
- Cursor image: 60 Hz timer reads `NSCursor.currentSystem` (deprecated but functional; ponytail: replace if Apple removes it); hash the image, write new ones to `cursors/<hash>.png` at the largest representation with hot-spot, and log `cursorChange` events.

---

## 5. Project format

`~/Movies/Recorder/<Title>.recorder/` (folder configurable). A package directory (UTI `space.microapps.recorder.project`, declared in Info.plist; legacy `sh.nexo.recorder.project` remains imported for compatibility).

```
My Recording.recorder/
  project.json      edit state (below) — the ONLY file the editor ever rewrites
  screen.mov        HEVC, cursor-less
  camera.mov        optional
  mic.m4a           optional
  system.m4a        optional
  events.json       { "events":[ {"t":1.234,"k":"move","x":0.41,"y":0.62}, {"t":…,"k":"down","b":0,…}, {"k":"key",…}, {"k":"cursor","id":"ab12"} ] }
  cursors/ab12.png  + cursors/ab12.json {"hotX":..,"hotY":..,"scale":2}
  thumbnail.jpg     640 px wide, frame at 1 s, written on first save
```

`project.json` (all times in **source seconds**; all positions/sizes normalised 0…1 of the source frame unless noted):

```jsonc
{
  "version": 1,
  "id": "UUID", "title": "My Recording", "createdAt": "ISO8601",
  "source": { "kind": "display|window|area", "pixelWidth": 2880, "pixelHeight": 1800, "scale": 2, "duration": 93.4, "hasCamera": true, "hasMic": true, "hasSystemAudio": false },
  "clips":   [ { "sourceStart": 0, "sourceEnd": 41.2, "speed": 1 }, { "sourceStart": 47.0, "sourceEnd": 93.4, "speed": 2 } ],
  "zooms":   [ { "id": "UUID", "start": 3.1, "end": 7.9, "scale": 2.0, "mode": "auto|manual", "center": {"x":0.5,"y":0.5}, "instant": false, "enabled": true } ],
  "layouts": [ { "id": "UUID", "start": 0, "end": 5, "kind": "cameraFull|hidden" } ],          // gaps = default layout
  "masks":   [ { "id": "UUID", "start": 10, "end": 14, "kind": "mask|highlight", "rect": {"x":..,"y":..,"w":..,"h":..}, "opacity": 0.8 } ],
  "cursorHidden": [ { "start": 20, "end": 25 } ],
  "crop": { "x": 0, "y": 0, "w": 1, "h": 1 },
  "output": { "aspect": "auto|16:9|9:16|1:1|4:3|16:10" },
  "background": { "kind": "wallpaper|gradient|color|image", "wallpaper": "01", "color": "#5B3DF5", "gradient": ["#5B3DF5","#E0567A"], "gradientAngle": 45, "imagePath": "background.jpg", "blur": 0 },
  "frame": { "padding": 0.08, "cornerRadius": 0.02, "inset": 0, "insetColor": "#000000", "shadow": 0.5 },
  "cursor": { "hidden": false, "size": 1.5, "style": "smooth|medium|rapid|none", "hideWhenIdle": true, "loop": false, "alwaysArrow": false, "rotate": false, "removeShakes": false, "clickSound": false },
  "animation": { "screen": "focused|smooth", "motionBlur": 0.5, "blurCursor": true, "blurZoom": true, "blurPan": true },
  "camera": { "size": 0.2, "corner": "bottomRight", "roundness": 0.5, "mirror": true, "shadow": 0.5, "shrinkWhenZoomed": true },
  "audio": { "micVolume": 1, "systemVolume": 1, "micMuted": false, "systemMuted": false, "denoise": false },
  "keys": { "show": false }
}
```

Rules:
- Every field has a default; decoding tolerates missing keys (`decodeIfPresent ?? default`). Unknown `version` > supported ⇒ refuse to open with an alert; never silently rewrite.
- **Autosave**: `EditorModel` writes `project.json` atomically (`Data.write(options: .atomic)`) 0.5 s after the last change and on window close/app quit. There is no "unsaved" state; `⌘S` forces a write, `⇧⌘S` copies the package elsewhere.
- Media files are never modified after recording. "Extract raw files" = reveal the package contents in Finder.
- Why source time for effects: removing/speeding a clip never requires rewriting zooms; an effect inside a removed range simply isn't visible. `TimeMap` (§2.1) converts for display.

**AC-PRJ-1** Round-trip: encode→decode of a fully populated `Project` is equal (unit test).
**AC-PRJ-2** A `project.json` containing only `{"version":1,"source":{…}}` opens with defaults (unit test).
**AC-PRJ-3** Force-quit during editing loses at most 0.5 s of edits and never corrupts `project.json`.

### 5.1 Project library window  (⇧⌘O, also shown on launch when no recording starts)

```
┌ Recorder ──────────────────────────────────────────────────────────────────────┐
│  Projects                                   [🔍 Search        ]  [ ◉ New Recording ] │
│ ┌───────────┐ ┌───────────┐ ┌───────────┐ ┌───────────┐                           │
│ │ thumbnail │ │ thumbnail │ │ thumbnail │ │ thumbnail │   adaptive grid, 220 pt   │
│ │      1:33 │ │      0:12 │ │     12:04 │ │      3:40 │   duration badge          │
│ └───────────┘ └───────────┘ └───────────┘ └───────────┘                           │
│  Onboarding     Bug repro     Demo v2       Untitled 4                            │
│  Today 13:04    Yesterday     12 Sep        3 Sep        sorted by modified desc  │
│                                                                                    │
│  empty state:  "No recordings yet"  [ ◉ New Recording ]                           │
└────────────────────────────────────────────────────────────────────────────────┘
 Right-click a card: Open · Rename · Duplicate · Show in Finder · ─ · Move to Trash
 Click / Return: open · arrows: select · Actions / right-click ▸ Rename: inline rename (renames the package dir) · drag a video file in: import (M6)
```

`ProjectStore` = scan the projects folder for `*.recorder`, read `project.json` title/duration + `thumbnail.jpg`. No database, no cache; watch the folder with `DispatchSource` and rescan.
New recordings and imported projects receive a random two-word name (for example, “Golden Willow”), with a numeric suffix when needed to avoid an existing package. Each card shows its edited duration beside the modified date.

**AC-LIB-1** 200 projects list in < 300 ms (only JSON headers + thumbnails are read, off the main thread).
**AC-LIB-2** Rename/duplicate/trash reflect in Finder immediately and vice versa. Delete uses `FileManager.trashItem` (recoverable).
**AC-LIB-4** A single card click immediately shows the editor shell while project data, motion paths and rendering resources load off the main thread. Repeated opens focus that window; closing cancels without saving. Loading errors offer Retry and Projects. The loaded editor uses a brief reveal, disabled with Reduce Motion.

**AC-LIB-3** Double-clicking a `.recorder` package in Finder opens it in the editor; opening an already-open project focuses its window.

---

## 6. Editor

### 6.1 Main window

Min 1100×700. The inspector spans the full working height beside preview, transport and timeline. The timeline fits its visible lanes, toolbar and overview by default; its divider permits enlargement up to 420 pt and prevents lane clipping. The historical sketch below is superseded by this layout and the current captures in `build/editor-refined/`.

```
┌ ● ● ●   ‹ Projects      My Recording ▾ (click = rename)            Auto ▾   ⌗ Crop     [ ⬆ Export ] ┐
├──────────────────────────────────────────────────────────────────────────┬──────────────────────────┤
│                                                                          │ ▣   ➤   ◉   ♪   ✦   ⌨    │ tabs: Background · Cursor ·
│        ╭──────────────────────────────────────────────╮                  │ ───────────────────────── │ Camera · Audio · Animations · Keys
│        │ background                                   │                  │ Background                │
│        │    ╭────────────────────────────────────╮    │                  │ [Wallpaper|Gradient|Color|Image]
│        │    │                                    │    │   PREVIEW        │ ▢ ▢ ▢ ▢ ▢ ▢  swatch grid  │
│        │    │     recorded screen (rounded,      │    │   (MTKView,      │ Blur      ──●──────  0   │
│        │    │     shadow, zoomable)        ╭───╮ │    │   letterboxed,   │ ───────────────────────── │
│        │    │                          ➤   │cam│ │    │   always shows   │ Padding   ────●────  8%  │
│        │    ╰──────────────────────────────╰───╯─╯    │   final output)  │ Corners   ──●──────  2%  │
│        ╰──────────────────────────────────────────────╯                  │ Inset     ●────────  0   │
│                                                                          │ Shadow    ─────●───  50% │
│              ⏮   ◀❙   ▶   ❙▶   ⏭        00:12.40 / 01:33.00             │   (selection replaces this │
│                                                                          │    panel — see §6.6)      │
├──────────────────────────────────────────────────────────────────────────┴──────────────────────────┤
│  ✂  ➕zoom   │ ↶ ↷ │                                              − ───●─── +   ⤢ fit                 │ timeline toolbar
│  TIMELINE (§7)                                                                                        │
└──────────────────────────────────────────────────────────────────────────────────────────────────────┘
```

- `‹ Projects` pauses playback and hides the current editor, preserving its editing session when the project is reopened.
- `Auto ▾` = output aspect (Auto = source aspect + padding). Changing it re-letterboxes the preview instantly.
- Preview is direct-manipulation: with a **manual zoom selected**, a rectangle overlay shows the zoom target and can be dragged; with the **Camera tab** open, the camera can be dragged between corners; with a **mask selected**, its rect has 8 handles.
- Canvas owns output-shape selection and Crop source. The document bar contains Projects, title, save state and Export. Padding remains exposed; corners, inset and shadow use a named disclosure.
- Selected manual zooms and masks expose **Edit region / View result**. Edit region presents unzoomed footage with handles and temporarily hides the selected mask so its edges can be aligned to the underlying content; View result preserves selection and shows the composed output without handles. Whole-project inspection also shows composed output. Preview mode is transient and resets when selection changes. An out-of-interval playhead is identified with a **Go to interval** action that respects retained footage and output timing.
- Transport: `Space` play/pause · `←/→` one frame · `⇧←/⇧→` 1 s · `Home/End` · `J K L` shuttle.

**AC-ED-1** Any inspector slider change is visible in the preview on the next frame (< 16 ms at 1080p preview size); dragging a slider never stutters playback.
**AC-ED-2** Preview frame at time *t* and exported frame at time *t* are pixel-identical at equal resolution (automated: render both paths to a texture, compare, max channel delta ≤ 1).
**AC-ED-3** Opening a 10-minute project shows the first frame in < 1 s.

### 6.2 Render pipeline (normative)

`Compositor.render(state: FrameState, into: MTLTexture)` where `FrameState` is produced by pure Core code:

```
FrameState(t_out) = {
  sourceTime      = TimeMap.sourceTime(atOutput: t_out)
  screenTexture   = FrameSource.screen(at: sourceTime)      // CVMetalTextureCache, zero-copy; holds last frame for VFR gaps
  cameraTexture   = FrameSource.camera(at: sourceTime)?
  view            = CameraPath.sample(sourceTime)            // {center, scale} — precomputed table, §6.3
  prevView        = CameraPath.sample(sourceTime − 1/fps)    // for motion blur
  cursor          = CursorPath.sample(sourceTime)            // {pos, prevPos, imageId, scale, alpha, rotation, clickPulse}
  layout, masks, keysOverlay, project styling
}
```

New window recordings initialise `frame.cornerRadius` from the captured native corner alpha, normalised to the shorter source dimension. The single circular mask encloses all four corners (non-circular shapes may receive a small trim); the largest measured radius during capture is retained. Existing recordings and manual corner edits retain their saved values.

Passes (single render encoder, 4 draw calls, all in `Shaders.swift`):
1. **Background** — textured/gradient/colour quad, optional blur (pre-blurred once on change with `MPSImageGaussianBlur`, cached).
2. **Screen** — quad with SDF rounded-rect mask, inset, soft shadow (analytic SDF, no blur pass, modelled on a measured native NSWindow shadow: Gaussian σ 20 pt, peak α 0.39, 17 pt drop, 1 pt black 0.155 hairline — all in source points so it scales with the window; `frame.shadow` 0.5 = native), crop + zoom applied as UV transform, and the frame itself (mask, corners, shadow) scales with the zoom (`zoomedScreenRect`: the viewed viewport lands on the un-zoomed frame rect, so mid-content the window fills the canvas and at a content edge the padding returns); motion blur = N taps (N = 8) along the UV delta between `prevView` and `view`, only when delta > 0.5 px.
3. **Cursor** — own quad **inside** the screen's coordinate space (so it zooms with the content), size × `cursor.size`, blur taps along `pos − prevPos`.
4. **Camera / masks / key overlay** — rounded-rect SDF quads.

Preview: `AVPlayer` drives time; `AVPlayerItemVideoOutput.copyPixelBuffer(forItemTime:)` inside `MTKView.draw`. Because clips/speeds are non-destructive, build an `AVMutableComposition` from `clips` (insert ranges + `scaleTimeRange`) for **both** player and exporter so audio speed/cuts come for free; rebuild it on clip edits (cheap) and keep the playhead.
Scrub: `seek(toleranceBefore: .zero, toleranceAfter: .zero)`, coalesced — never queue more than one pending seek.

### 6.3 Zoom camera & springs

- Spring: closed-form damped harmonic oscillator `x(t)` from rest → target (critically-damped and under-damped branches), in `Spring.swift`. Presets — screen **Focused**: response 0.55 s, damping 1.0; **Smooth**: response 0.9 s, damping 0.85. Cursor **Rapid/Medium/Smooth**: response 0.12 / 0.22 / 0.38 s, damping 1.0; **None** = raw.
- `CameraPath`: simulate the whole timeline once at 240 Hz (semi-implicit Euler toward a target signal), store a table, sample by index + lerp. Target signal: outside zooms `{center 0.5,0.5, scale 1}`; inside a zoom `scale = zoom.scale` and `center =` (manual) `zoom.center` or (auto) the smoothed cursor position with a **dead-zone**: the target only moves when the cursor leaves the central 60% of the zoomed viewport. Center is clamped so the viewport never leaves the source frame. `instant` zooms jump (no spring) on both edges. Zoom-in starts at `zoom.start`; zoom-out starts at `zoom.end`.
  `// ponytail: full re-simulation on every edit — 10 min = 144k steps ≈ 2 ms. Make incremental only if profiling says so.`
- Because it is a lookup table, scrubbing to any *t* is O(1) and deterministic (required for AC-ED-2).

**AC-ZM-1** (unit) Spring: `x(0)=0`, `x(∞)→1`, no overshoot when damping = 1, monotonic. **AC-ZM-2** (unit) viewport never exceeds source bounds for any zoom center/scale. **AC-ZM-3** (unit) `CameraPath.sample` is identical regardless of the order/number of previous samples.

### 6.4 Auto-zoom generation (runs once when a recording finishes)

1. Take `down` events (left button). 2. Cluster: a click joins the current cluster if it is < 3 s after the previous click **and** < 0.25 (normalised) away. 3. Each cluster ⇒ zoom `start = first − 0.4 s`, `end = last + 1.5 s`, `scale 2.0`, `mode auto`. 4. Merge zooms whose gap < 1.0 s. 5. Drop zooms shorter than 1.0 s; clamp to `[0, duration]`.
`Edit ▸ Regenerate Auto Zooms` re-runs it; `Edit ▸ Remove All Zooms` clears.

**AC-AZ-1** (unit) the five rules above, including: no overlaps, sorted, deterministic.

### 6.5 Cursor path

Pipeline over raw `move` events → 240 Hz table: (optional) shake removal (drop excursions < 3 px that return within 80 ms) → spring follow (preset) → idle hide (alpha→0 over 0.3 s after 2 s without movement, back in 0.15 s) → loop (last 1.5 s springs toward the first position) → rotation (tilt ∝ horizontal velocity, max 12°) → click pulse (scale 1→0.85→1 over 0.2 s on `down`). Hidden inside `cursorHidden` ranges.

**AC-CUR-1** (unit) output never leads the raw path; final position error after 1 s of rest < 0.5 px. **AC-CUR-2** Cursor at size 4× is sharp (uses the hi-res stored representation, not an upscaled frame).

### 6.6 Inspector (SwiftUI, 320 pt wide)

Rule: **composition navigation remains visible above preview and inspector**. Whole project / Selection explicitly chooses the property scope. Choosing a project destination preserves timeline selection; changing selection follows the new item. Deselect/`Esc` clears selection. Camera footage selection exposes timing context and a route to project appearance, not global appearance controls disguised as clip-local controls. Multiple selection shows group scope until explicit batch property editing is supported. The diagram below describes the individual property sets; the former disappearing tab bar is superseded by this navigation rule. All sliders: label left, value right (editable on double-click), `⌥`-click resets to default. Every control edits `EditorModel.project` through one `model.edit { }` closure (which snapshots undo; slider drags coalesce into one undo step).

```
 Background tab          Cursor tab                     Camera tab                  Audio tab
 ───────────────         ───────────────────────        ─────────────────────       ─────────────────────
 (see §6.1)              [ ] Hide cursor                (disabled w/o camera)       Microphone  ───●── 100% 🔇
                         Size        ──●──── 1.5×       Size       ──●─── 20%       System      ───●── 100% 🔇
 Animations tab          Movement [Smooth|Medium|       Position   ◰ ◳ ◱ ◲          [ ] Reduce noise & normalise
 ───────────────                   Rapid|None]          Roundness  ───●── 50%       [ ] Mouse click sound
 Motion blur ──●── 50%   [x] Hide when idle             Shadow     ───●── 50%
  ▸ Advanced             [ ] Loop cursor position       [x] Mirror                  Keys tab (M6)
   [x] Cursor            ▸ Advanced                     [x] Shrink when zoomed      ─────────────────────
   [x] Zoom               [ ] Always use arrow          [+ Add fullscreen layout]   [ ] Show keyboard shortcuts
   [x] Pan                [ ] Rotate while moving                                   Size ──●──  Position ◱ ◲
 Screen [Focused|Smooth]  [ ] Remove cursor shakes

 Zoom selected                       Clip selected                    Layout selected          Mask selected (M6)
 ────────────────────────           ─────────────────────────        ─────────────────────    ─────────────────────
 ‹ Back              Zoom            ‹ Back             Clip          ‹ Back        Layout     ‹ Back        Mask
 Level  ────●──── 2.0×  (1.2–5)      Speed [0.5×|1×|1.5×|2×|4×|8×|…]  ( ) Camera fullscreen    (•) Mask ( ) Highlight
 Mode   [ Auto | Manual ]            Custom ──●── 1.0×  (0.25–16)     ( ) Camera hidden        Opacity ───●── 80%
   Manual: "Drag the frame in        Duration 00:41.20 → 00:20.60     [ Remove ]               [ Remove ]
   the preview to set the target"    [ ] Mute audio in this clip
 [ ] Instant (no animation)          [ Remove clip ]
 [ Disable ]  [ Remove ]
```

Wallpapers: ship 12 JPEGs in `Resources/Wallpapers/` (abstract gradients generated by us — do not copy Apple's or Screen Studio's images) + list the user's `/System/Library/Desktop Pictures/*.heic` read-only at runtime.

**AC-INS-1** Every control round-trips: change → quit → reopen ⇒ same value and same preview. **AC-INS-2** One slider drag = one undo step. **AC-INS-3** Selecting a zoom/clip/layout/mask swaps the panel within one frame; `Esc` returns to the previous tab.

### 6.7 Crop sheet  (ref: `13.05.18.png`)

```
┌ ●      Size [ 800] × [ 600]   [⌗ Select… ▾]   Position [ 0] [ 0]    [⌗ Reset]   ⌨ ┐   Select… = aspect presets
│    ○──────────────○──────────────○                                                │   (Free, 16:9, 4:3, 1:1, 9:16)
│    ┊  source frame at current playhead, area outside the crop dimmed 60%,         │   ⌨ = shows nudge shortcuts
│    ○  rule-of-thirds guides, 8 handles, drag inside to move                       │
│    ○──────────────○──────────────○                                                │
│                  [ Confirm changes ⏎ ]   [ Discard changes ]                      │
└───────────────────────────────────────────────────────────────────────────────────┘
```

Reuses the same `SelectionRectView` as §4.5 (one implementation). Size/position in source pixels.

**AC-CROP-1** Confirm applies crop to preview + export and is one undo step; Discard/`Esc` changes nothing. **AC-CROP-2** Zoom centres and masks remain anchored to the same content after cropping (they are stored in uncropped source coordinates).

### 6.8 Export sheet (⌘E)

```
┌ Export ────────────────────────────────────────────────────────┐
│  Format       [  MP4  |  GIF  ]                                 │
│  Resolution   [ 720p | 1080p | 4K ]     → 1920 × 1080           │  preset = short edge; keeps output aspect;
│  Frame rate   [ 24 | 30 | 60 ]              (GIF: 10|15|24)     │  even numbers; upscaling is allowed
│  Quality      [ Web | Social | High | Studio ]                  │
│  Codec        [ H.264 | HEVC ]              (MP4 only)          │
│  ─────────────────────────────────────────────────────────     │
│  Estimated size  ~48 MB        Duration 01:33                   │
│                         [ Copy to clipboard ]   [ Export… ]     │
└─────────────────────────────────────────────────────────────────┘
 Exporting:  ▓▓▓▓▓▓▓▓░░░░░░  58%   ·  412 / 5580 frames  ·  ~00:21 left      [ Cancel ]
 Done:       ✓ Exported  My Recording.mp4 (46.2 MB)    [ Show in Finder ]  [ Copy ]  [ Done ]
```

- Bitrate (H.264, 30 fps, 1080p): Web 4 · Social 8 · High 16 · Studio 40 Mbps; scale ×(pixels/2.07 MP) ×(fps/30)^0.5; HEVC ×0.6.
- Export loop: for each output frame *n*: `t = n/fps` → `FrameState` → `Compositor.render` into a `CVPixelBuffer` from the writer's pool → append. Audio: the same `AVMutableComposition` (§6.2) through `AVAssetReaderAudioMixOutput` with an `AVAudioMix` for volumes (`audioTimePitchAlgorithm = .spectral` so sped-up speech keeps pitch). Runs on a background queue; feeds audio and video together as each input becomes ready, respecting `isReadyForMoreMediaData`. Writer backpressure and finalization waits fail after 30 seconds without progress; cancellation/failure removes partial MP4 files.
- GIF: render at chosen fps, max 960 px long edge, `CGImageDestination` with per-frame delay, loop forever. Warn (non-blocking) if duration > 60 s.
- Copy to clipboard: export to a temp file, put the file URL on `NSPasteboard`.
- Settings persist as the default for next export. The sheet is modal to the editor window; editing is locked during export. Idle: visible Cancel and Escape dismiss; clicking outside on the editor dismisses idle/completed sheets without activating editor controls. During export: a bordered Cancel export button and Escape stop the export, show Cancelling… while cleaning up, and return to settings; outside clicks do not interrupt the export.

**AC-EXP-1** 1-minute 1080p60 H.264 export finishes in < 30 s on an M-series Mac and plays in QuickTime, Safari and Chrome. **AC-EXP-2** A/V drift at the end of a 10-minute export < 1 frame. **AC-EXP-3** Cancel stops within 1 s and deletes the partial file. **AC-EXP-4** Export duration == `TimeMap.outputDuration` ± 1 frame, including sped-up and removed clips.

---

## 7. Timeline (the most important UI in the app)

One `TimelineView: NSView` (flipped, layer-backed, `wantsUpdateLayer = false`, draws in `draw(_:)` with Core Graphics; only
dirty rects are redrawn). It renders from `EditorModel.project` + a tiny local `InteractionState`; it never owns data.
The x-axis is **output time** (what the viewer sees) — removed segments take no space; a 2× clip is half as wide.

### 7.1 Anatomy

```
  ✂ Split   ➕ Zoom  │ ↶ ↷ │                                                 −  ────●────  +    ⤢ Fit      toolbar 32 pt
 ┌──────────────────────────────────────────────────────────────────────────────────────────────────┐
 │ 0:00      0:05      0:10      0:15      0:20      0:25      0:30      0:35      0:40      0:45   │ ruler 22 pt: adaptive ticks
 │  ┊    ┊    ┊    ┊    ┊    ┊    ▼ 00:12.40                                                         │  (1f…1m), click/drag = scrub
 ├────────────────────────────────┃─────────────────────────────────────────────────────────────────┤
 │ ╭─────────────────────────────╮┃╭───────────────────────╮ ✂ ╭─────────────────────────────────╮  │ CLIP track 44 pt (clip colour)
 │ │ ▁▂▃▅▃▂▁▁▂▅▇▅▃▂▁  waveform   │┃│ ▂▃▅▃▁   2×  ⏩        │   │ ▁▁▂▃▂▁▁▁▂▃▅▃▂                  │  │  ✂ bubble = a cut/trim exists
 │ ╰─────────────────────────────╯┃╰───────────────────────╯   ╰─────────────────────────────────╯  │  here; click it to restore
 ├────────────────────────────────┃─────────────────────────────────────────────────────────────────┤
 │    ╭────────────╮              ┃  ╭──────────────────╮              ╭┄┄┄┄┄┄┄┄┄┄╮                 │ ZOOM track 32 pt (accent)
 │    │ 🔍 2.0× A  │              ┃  │ 🔍 1.6× M        │              ┊ 🔍 + add ┊  ← ghost on hover│  A=auto M=manual; disabled =
 │    ╰────────────╯              ┃  ╰──────────────────╯              ╰┄┄┄┄┄┄┄┄┄┄╯     in empty lane│  hatched 40% opacity
 ├────────────────────────────────┃─────────────────────────────────────────────────────────────────┤
 │  ╭───────────────╮             ┃                                                                  │ LAYOUT track 28 pt (only if
 │  │ ◉ Camera full │             ┃                                                                  │  camera) — gaps = default layout
 ├────────────────────────────────┃─────────────────────────────────────────────────────────────────┤
 │                                ┃         ╭────────╮                                               │ MASK track 28 pt (M6)
 └────────────────────────────────┃─────────────────────────────────────────────────────────────────┘
   track headers are icon-only,   ┃ playhead: 2 px white line + ▼ cap with timecode; always on top
   16 pt gutter at left           hover line: 1 px white @ 30% following the mouse (with timecode tooltip)
```

### 7.2 Interaction rules (normative)

**Navigation**
- Scroll horizontally = pan. Pinch or `⌘`+scroll = zoom **anchored at the mouse x** (the time under the cursor stays put). `⌘=`/`⌘-` zoom anchored at the playhead. `⇧Z`/⤢ = fit whole project. Range: whole project ↔ 1 frame = 8 pt.
- Click on ruler or empty lane area = move playhead. Drag on ruler = scrub (audio scrubs too; seeks coalesced).
- During playback the view auto-scrolls page-wise when the playhead exits the right edge; any manual scroll disables auto-scroll until playback restarts.

**Hit-testing & cursors** (checked in this order; 6 pt edge zones, shrink to 3 pt when a block is < 24 pt wide)
| Pointer over | Cursor | Drag does |
|---|---|---|
| Playhead cap | ↔ | scrub |
| Block left/right edge | resize ⇔ | trim (clip) / resize (zoom, layout, mask) |
| Block body | open hand → closed | move (zoom/layout/mask only; clips don't reorder) |
| ✂ bubble | pointing hand | click = restore that cut/trim |
| Empty zoom/layout/mask lane | + | click = add block (ghost preview shown under pointer, default 3 s or the free gap if smaller) |
| Anything, in Split mode | blade ✂ line | click = split |

**Selection**: click selects one block (2 px white outline + glow; inspector swaps, §6.6). `⇧`-click adds same-track blocks. Click on empty space or `Esc` deselects. `⌫` removes the selection. Selection survives undo/redo when the ids still exist.

**Split (the headline interaction)**
- `C` = split the clip under the **playhead** immediately. No mode, no selection needed.
- Hold `⌥` (momentary) or press `S`/click ✂ (sticky until `Esc`) = **Split mode**: a full-height dashed accent blade line follows the mouse, **snapped**; timecode chip on the blade; the preview shows the frame under the blade (hover-scrub) so you can see where you cut. Click = split there. The playhead does not move.
- A split produces two clips with identical speed; it is invisible in output until one side is changed. Splitting within 2 frames of an existing edge does nothing (shake animation on the blade, no error dialog).
- After a split, a 0.25 s "cut flash" (white line fading) confirms it. Undo is one step.

**Remove a segment** = select clip → `⌫` (or right-click ▸ Remove). Neighbours close the gap with a 0.18 s slide animation; a ✂ bubble marks the seam. Ripple is inherent (x-axis is output time). The last remaining clip cannot be removed.

**Trim** = drag a clip edge. The clip's other edge stays fixed **on screen**; following clips ripple live. While dragging: preview shows the frame at the edge, a chip shows `new duration (Δ ±0:01.20)`. Can extend back up to the neighbour's source boundary (never overlap source ranges). Min clip length 0.1 s.

Video clip movement uses output-time distances across mixed playback speeds, including gaps and grouped selections. Camera and keystroke media rates are preserved when the editing clock is rebased; linking controls whether those layers follow the move.

**Restore**: clicking a ✂ bubble between two clips shows a popover `Restore 00:05.80 removed here` `[Restore]`; it re-inserts the removed source range (merging clips when speeds match).

**Speed**: right-click clip ▸ `Speed ▸ 0.5× 1× 1.5× 2× 4× 8× Custom…`, or the inspector. Block shows a `2× ⏩` badge and re-sizes with animation. Zoom blocks over it re-size automatically because they are stored in source time.

**Zoom blocks**: click empty lane = add (manual if no click nearby in the event log, else auto). Drag body = move, edges = resize; min 0.5 s. **Zoom blocks may not overlap**: dragging into a neighbour clamps at its edge. `Z` = add a zoom at the playhead. Double-click = select + move playhead to its start. Right-click ▸ `Disable/Enable · Instant · Remove`. A zoom partly inside a removed segment is drawn only for its visible part, with a torn edge `⌇`.

**Snapping** (all drags + the split blade): to playhead, clip edges, other blocks' edges, and click events (small ticks drawn on the zoom lane). Threshold 6 pt; a 1 px accent guide line spans all tracks while snapped; holding `⌘` disables snapping.

**Context menus**: Clip: `Split at Playhead (C) · Speed ▸ · Mute Audio · Remove (⌫)`. Zoom: above. Empty clip-track area: `Restore All Cuts`. Ruler: `Fit (⇧Z) · Zoom to Selection`.

**Undo**: every completed gesture = exactly one undo step (`model.edit` opens on mouseDown, commits on mouseUp; `Esc` during a drag cancels and reverts). `⌘Z` / `⇧⌘Z`.

**Feel**: all drags update at display refresh rate; blocks have 10 pt radius, 1 px inner highlight, hover brightens 8%; block moves/resizes caused by *other* edits animate 0.18 s; nothing animates while the user is dragging that block. Waveform = min/max peaks precomputed once per audio file into a 200 samples/s table (mic preferred, else system).

### 7.3 Keyboard map (editor)

| Key | Action | Key | Action |
|---|---|---|---|
| `Space` | play/pause | `C` | split at playhead |
| `←` `→` | ±1 frame | `⌥` hold / `S` | split mode |
| | | `V` | pointer tool (exit split mode) |
| `⇧←` `⇧→` | ±1 s | `⌫` | remove selection |
| `J` `K` `L` | reverse/stop/forward shuttle | `Z` | add zoom at playhead |
| `Home` `End` | start/end | `⌘Z` `⇧⌘Z` | undo/redo |
| `↑` `↓` | prev/next edit point | `⌘=` `⌘-` `⇧Z` | timeline zoom in/out/fit |
| `Esc` | cancel drag → exit split mode → deselect | `⌘E` `⌘S` `⌘K` `⌘/` | export · save · command menu · cheat sheet |
| `1`–`6` | inspector tabs | `⌘D` | duplicate selected zoom/mask after itself |

### 7.4 `TimelineOps` (Core, pure functions `Project -> Project`)

`split(atOutput:)`, `removeClip(index:)`, `trimClip(index:edge:toSource:)`, `restoreCut(afterClip:)`, `setSpeed(index:_)`,
`addZoom(atSource:)`, `moveZoom(id:toStart:)`, `resizeZoom(id:edge:to:)`, `removeBlock(id:)`, plus `snap(_ x:candidates:threshold:)`.
Invariants (assert in debug, test always): clips sorted by `sourceStart`, non-overlapping in source, each ≥ 0.1 s, speed in 0.25…16, ≥ 1 clip; zooms sorted, non-overlapping, ≥ 0.5 s, within `[0, duration]`.

**AC-TL-1** (unit) Each op preserves the invariants for randomised inputs (property-style loop, 1 000 iterations, fixed seed).
**AC-TL-2** (unit) `split` then `removeClip` then `restoreCut` returns the original project.
**AC-TL-3** Dragging a zoom edge on a 30-minute project with 200 zooms stays at display refresh rate (no dropped frames in Instruments / visibly smooth).
**AC-TL-4** Zoom anchoring: pinch-zooming keeps the time under the mouse within ±1 pt.
**AC-TL-5** `C` during playback splits without pausing or stuttering.
**AC-TL-6** Every gesture is exactly one undo step; `Esc` mid-drag restores the pre-drag state.
**AC-TL-7** Split mode hover shows the correct frame in the preview within 50 ms of the mouse stopping.
**AC-TL-8** VoiceOver: each block is an accessibility element with role, label ("Zoom 2.0×, 3.1 to 7.9 seconds") and increment/decrement actions to move it by 1 frame.

---

## 8. App-level

Menu bar: **Recorder** (About, Settings… ⌘,, Copy State Snapshot ⌃⌥⌘S, Quit) · **File** (New Recording ⌘N, Open… ⌘O, Open Recent ▸, Projects ⇧⌘O, Save ⌘S, Save As… ⇧⌘S, Show Raw Files, Close ⌘W) · **Edit** (Undo, Redo, Split C, Remove ⌫, Add Zoom Z, Regenerate Auto Zooms, Remove All Zooms, Restore All Cuts) · **Record** (Start/Finish, Pause, Restart) · **Export** (Export… ⌘E, Copy Frame as Image ⇧⌘C) · **View** (tabs 1–6, Zoom In/Out/Fit, Crop…, Command Menu… ⌘K, Keyboard Shortcuts ⌘/ — no Help menu exists, so T-311 put both in View's last group) · **Window**.

Settings window (SwiftUI `Form`): General — projects folder, default export settings, "after recording: open editor"; Recording — fps 30/60, countdown, the three toggles from §4.2; Shortcuts (M6) — rebind the global hotkeys (§4.7).

Status item (always present while the app runs). Native `NSMenu`, SF Symbol icons, idle state:

```
 ◉ New Recording…            ⌃⌘↩   → toolbar (§4.2) in the last-used mode
 ─────────────────────────────────
 ▭ Record Display             ⌥⌘3   → toolbar + display picker (§4.3) immediately
 ▢ Record Window              ⌥⌘4   → toolbar + window picker (§4.4)
 ⬚ Record Area                ⌥⌘5   → toolbar + area selection (§4.5)
 ─────────────────────────────────
   Settings…                  ⌘,
   Copy State Snapshot        ⌃⌥⌘S  writes a debugging folder + copies its path (below)
 ✓ Show Recorder in Dock      ⌘D    persisted; off = `.accessory` activation policy (menu-bar-only app)
 ─────────────────────────────────
   Projects                   ⇧⌘O   library window (§5.1)
   Open…                      ⌘O
   Open Last Project          ⌥⌘Z   most recently modified package; disabled when there is none
 ─────────────────────────────────
   Quit Recorder              ⌘Q
```

While recording the menu is replaced by the §4.7 one (Finish · Pause/Resume · Restart · Delete · ─ · Copy State Snapshot · Hide widget) and the title shows `◉ mm:ss`.
UX rules: the three `Record …` items set the mode *and* open its picker in one step (no second click); with permissions missing every
recording item opens onboarding (§4.1) instead; "Show Recorder in Dock" off never hides an open editor window's app — it only takes
effect while no editor/library window is open (`// ponytail`: simplest rule that avoids a dock-less app with windows).
`⌃⌘↩`, `⌥⌘3/4/5`, `⌥⌘Z` and `⌃⌥⌘S` are **global** shortcuts (§4.7); the others are ordinary key equivalents. Closing all windows does **not** quit.

**AC-APP-4** Each global shortcut works while another app is frontmost; `⌥⌘4` shows the window picker within 300 ms; shortcuts are ignored while a recording is in progress (except `⌃⌥⌘R`/`⌃⌥⌘P`/`⌃⌥⌘S`).

**AC-APP-1** `make install` on a clean clone produces `/Applications/Recorder.app` that launches. **AC-APP-2** With the "Recorder Dev" identity, permissions survive `make install` rebuilds. **AC-APP-3** Idle app (toolbar open, not recording) uses < 1% CPU and < 150 MB RAM.

### 8.1 State snapshot (debugging aid)

`Recorder ▸ Copy State Snapshot` (⌃⌥⌘S, global, works mid-recording) writes
`~/Library/Logs/Recorder/Snapshots/<yyyy-MM-dd HH.mm.ss>/` — `snapshot.json` (app/OS/permission/recording/
settings/hotkey/memory state, every window, and one entry per open editor: playhead, selection, undo/redo
names, `TimeMap` output duration, `checkInvariants()`, preview/timeline internals, which inspector
tab/panel is showing, export sheet phase), `editor-<n>-project.json` (each open editor's CURRENT
in-memory `Project`, unsaved edits included), `editor-<n>-events-summary.json` (event-kind counts +
first/last timestamps only), one `window-<n>-<class>.png` per Recorder's own visible window, and a
`README.txt` explaining the above. The folder path is copied to the clipboard and a system sound plays;
the status item flashes "Snapshot copied" for 2 s (no new window). Only the newest 20 snapshot folders
are kept. Privacy: no raw input events, no typed text, no screen contents other than Recorder's own
windows, ever (CLAUDE.md's rule). `scripts/freeze-dump.sh [pid]` is the out-of-process fallback for a
hung main thread: `sample`/`ps` on the running `Recorder` process into a new folder under the same
Snapshots directory, path copied to the clipboard the same way.

**AC-APP-5** `Recorder ▸ Copy State Snapshot` writes the snapshot folder and puts its path on the
clipboard in < 1 s with an editor open; it also works while a recording is in progress.

---

## 9. Milestones

Each milestone ends with: `make test` green, `make install` works, its ACs demonstrated, CLAUDE.md updated only if commands/architecture changed.

| M | Deliverable | ACs |
|---|---|---|
| **M1 Record** | `make cert`; onboarding; toolbar; display/window/area overlays; SCStream → `screen.mov` + mic/system audio; `EventRecorder`; finish → package written to disk and revealed in Finder | ONB, TB, DSP, WIN-1/3, AREA, REC-1/3, APP-1/2 |
| **M2 Record+** | camera bubble + `camera.mov`; countdown; widget (pause/restart/delete); status item; hotkeys; resize presets; hide icons/dock; minimal Settings | CAM, REC-2, WIN-2 |
| **M3 Editor shell** | `Project` model + store + library; editor window; `Compositor` (background/frame/shadow/crop/aspect); preview + transport; Background tab; crop sheet; autosave + undo | PRJ, LIB, ED-1/3, INS, CROP |
| **M4 Timeline** | `TimelineOps`, `TimelineView` (all of §7), `Spring`, `AutoZoom`, `CameraPath`, `CursorPath` basic, cursor rendering, Cursor tab basics, zoom/clip inspectors | TL-*, ZM, AZ, CUR |
| **M5 Ship** | motion blur; Animations tab; camera compositing + layouts track; Audio tab; **export** MP4/GIF/clipboard | EXP, ED-2, REC-4, APP-3 |
| **M6 Polish** | masks/highlights; key overlay; typing speed-up; cursor advanced; presets; import video; command menu; cheat sheet; shortcut settings | remaining |

Open questions to verify during M1 (do not guess — test and record the answer in this file):
1. Does `captureMicrophone` deliver mic samples as a separate `SCStreamOutputType.microphone` on this OS with the chosen device ID? (Expected yes on macOS 15+.) Fallback: `AVCaptureSession` audio.
2. Is `NSCursor.currentSystem` still returning correct images on macOS 26? Fallback: map to bundled arrow/I-beam/hand only.
3. Which Finder windows must be excluded to hide desktop icons on macOS 26?
   **Answer (T-205, verified 2026-09-18 on this machine, macOS 26 / Darwin 25.2, with Recorder's own Screen
   Recording grant via `open -n … --args --selftest finder-windows`):** Finder owns exactly ONE window at
   `CGWindowLevelForKey(.desktopIconWindow)` (layer −2147483603), full-display size (1440×900 pt) — that is the
   desktop-icons window. Its other windows are layer 0 (menu-bar strips, browser windows) or small layer 3/103
   helpers. `CaptureTarget.filter` excludes every Finder window at that level when "Hide desktop icons" is on,
   which matches (a). Still to eyeball in a real recording: (b) icons actually vanish, (c) the wallpaper stays.


### Recording/editor polish (2026-09-19)

- Finish holds the final screen frame through the stop timestamp, including idle content; writer failures retain the recording package and display the error.
- Restore the regular app activation policy and open the loaded editor before generating the thumbnail.
- Aspect and resize menus pair ratios/resolutions with purpose labels (Full HD, Stories/Reels, social square, Mac display). Export is a prominent 112 × 34 pt accent button.
- Drag across an empty zoom, mask, or layout lane to choose the range, in either direction. Existing minimum length, neighbour clamping, snapping, Escape cancellation and one-step undo apply. Click and keyboard insertion remain available.
- New timeline masks default to full-opacity blur. The inspector offers Cover, Blur, and Highlight, plus optional smooth fades (off by default). `Mask.transition` stores fade seconds, defaults to zero for old projects, and survives duplication. Preview and export share the implementation.
- Autosave displays Saving/Saved or an error with retry. Pending saves pause during a gesture and resume on commit/cancel.
- Single-window capture excludes its baked shadow so the compositor applies the calibrated macOS-style shadow once. The analytic profile remains an approximation, not a guaranteed pixel-identical WindowServer shadow.

### Camera editing additions

- Click the camera in the editor preview to open its controls (or its active camera timeline block). Drag to position it continuously within the canvas; a completed drag is one undo step.
- Size spans 10–100% of the canvas short edge. Choose square, 16:9, 4:3 or 9:16 aspect ratios, corner presets or normalized horizontal/vertical placement. Old projects retain square, corner-based placement.
- The camera timeline lane adds visible/size/position blocks by default. Select a block to set its size, aspect and position, switch it to hidden or fullscreen, or remove it. Existing block move, trim, snapping and undo apply. Gaps use the default camera settings; block edges ease in/out over 0.3 seconds.
- The camera texture uses a centered cover crop matched to the current animated rectangle, including fullscreen. It preserves source proportions rather than stretching a square crop. Preview and export share this geometry.

### Overlay settings clips (September 2026)

Camera and keystrokes have a 3×3 position grid (including center), precise normalized position sliders,
and size controls. Keystrokes additionally expose visibility, all-keys/shortcuts filtering, and display duration.
The shared overlay timeline lane is available even without a camera. Settings clips can override camera
layout/style and optionally keystrokes together, or keystrokes alone. Drag/trim/delete uses the existing
source-time block operations and undo. Numeric settings ease from/to project defaults at clip boundaries;
visibility fades, discrete switches apply inside the clip, and transition 0 switches instantly.
Camera roundness/shadow animate alongside size/aspect/position; mirror is a discrete switch.
Display/area capture excludes the Recorder application, including windows opened after capture starts;
Finder desktop-icon exceptions remain independent. Preview and export share the same overlay evaluation.
