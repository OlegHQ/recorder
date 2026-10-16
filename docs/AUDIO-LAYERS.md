# Audio lanes, voiceover and media layers: implementation plan

Status: **decided 2026-10-16** (user accepted every default below). Tasks T-640…T-650 are tracked in `docs/PLAN.md`
("Audio & layers roadmap"); their full Do/Verify text is §6 here. SPEC §"Audio lanes and layers (October 2026)" is the
short normative summary; this file holds the detail.

Prototype (interactive, for humans): https://claude.ai/artifact/J2AhVTkaGo2CcbUfViHFFH. This file is self-contained;
an implementing agent does not need the prototype.

Read first: `CLAUDE.md` (protocol, ponytail rules, toolchain), SPEC §5 (project format), §6.2 (render pipeline),
§7 (timeline), §"Editor roadmap (October 2026)". Code: `RecorderCore/Project.swift` (`CameraClip` is the template for
audio clips and video layers), `RecorderCore/TimelineOps.swift` (`editLinkedLayers`, `useOutputClock`, `TimedBlock`,
`placeClip`), `Recorder/Render/FrameSource.swift` (`makeComposition`, `makeAudioMix`, `isolateTrack`),
`Recorder/Render/Exporter.swift` (camera reader + `FrameHold`), `Recorder/Editor/PreviewView.swift` (`attachCamera`),
`Recorder/Editor/TimelineView.swift` (`Lane`), `Recorder/Render/Compositor.swift`, `Recorder/Render/Waveform.swift`,
`Recorder/Recording/SelectionRectView.swift`.

---

## 1. What the user asked for

1. Several audio tracks. The original recording's audio is its own clip on the timeline, so it can be split and moved
   apart from the screen video.
2. Audio recorded with the webcam stays linked to the webcam footage. The user can link the original audio to the
   screen recording instead, or unlink it.
3. Record a voiceover inside the editor to replace or fill a part of the narration.
4. Media layers over the recording, for stretches where the screen shows an idle terminal while the user talks:
   - **images** (repository screenshot, diagram) with fade in/out;
   - **video files**, whose sound comes in as a linked audio clip that can be detached like any other.
5. **Audio files** (music, sound effects, a narration recorded elsewhere) placed on audio lanes.

## 2. Decisions (all closed)

| # | Decision |
|---|---|
| D1 | Link model: a per-clip link target on each audio clip (`screen`, `camera`, `layer`, or none). Chain badge on the clip. |
| D2 | Mic links to `camera` when the recording has a camera, else `screen`. System audio → `screen`. A video layer's sound → `layer` (its own video). Voiceover takes and imported audio files start unlinked. |
| D3 | Unlinked means **connected** (Final Cut style): unlinked audio, voiceover takes, imported audio and every media layer ride the video clock. Ripple and clip moves carry them; video splits and trims never cut them. |
| D4 | `screen`-linked audio always follows video edits (sync lock), even with the global "Link layers" toggle off. `camera`-linked audio follows the camera clip. `layer`-linked audio follows its video layer. The global toggle keeps governing camera and effect lanes. |
| D5 | Voiceover records at the playhead, or **re-records the selected audio clip** (its range): 1.5 s pre-roll, auto-stop 0.4 s after the range, the original piece set to gain 0 (hatched). Ranges come from existing splits (`C`, *Split at Pauses*); no in/out marks. |
| D6 | Project audio muted while recording; "Hear project" toggle in the recording HUD. |
| D7 | A new take over the same range replaces the previous take clip; old take files stay in the package, so undo restores them. No take switcher. |
| D8 | New image or video layer: Card (centred, 64 % of canvas width, rounded/shadowed like the screen frame) with the screen behind dimmed; fade 0.3 s. Full, Corner and Free are one click away. |
| D9 | Layer order: background → screen → cursor → backdrop → layer lanes (Layer 1 under Layer 2…) → camera → layers marked "In front of camera" → text → keys. |
| D10 | Idle spans (no key/click for ≥ 3 s) show as dashed slots on Layer 1; clicking one adds an image that fills it. |
| D11 | Track headers: name + mute + live meter (132 pt), collapsible to the 16 pt icon gutter. |
| D12 | Image and video layers share one block type and one set of lanes ("Layer n"). A video layer plays at 1× from its in-point; its length is capped by the file. |
| D13 | Imported media (image, video, audio) is copied into the package `media/` folder (`FileManager.copyItem`, which clones on APFS, so large videos cost no extra disk). The package stays self-contained. |
| D14 | Audio files land on the first free extra track ("Audio n", created when needed); they never land on Mic or System. |

Out of scope (don't build): automatic ducking of music under narration, solo, per-track effects, volume keyframes,
take switcher, Ken Burns/keyframed layer motion, speed changes on layers or unlinked audio, video-layer transitions other
than the three motions, trimming the source file on import.

## 3. Data model (normative signatures, all in `RecorderCore/Project.swift`)

```swift
public struct AudioTrack: Codable, Equatable, Sendable {
    public var id: String
    public var name: String            // "Mic", "System", "Voiceover 1", "Audio 1"…
    public var volume: Double = 1      // linear 0…2
    public var muted: Bool = false
}

public struct AudioClip: Codable, Equatable, Sendable {
    public enum Link: String, Codable, Sendable { case screen, camera, layer }
    public var id: String
    public var start: Double           // timeline clock, like CameraClip
    public var end: Double             // screen/camera-linked: timeline clock. otherwise: start + output seconds (§4.2)
    public var mediaStart: Double      // seconds into `file`
    public var mediaRate: Double? = nil
    public var file: String            // package-relative: "mic.m4a", "system.m4a", "voice/<id>.m4a", "media/<id>.<ext>"
    public var track: Int              // index into Project.audioTracks
    public var link: Link? = nil       // nil = unlinked (connected, D3)
    public var layer: String? = nil    // LayerBlock.id when link == .layer
    public var gain: Double = 1        // linear 0…2; 0 = muted piece (drawn hatched)
    public var fadeIn: Double? = nil   // output seconds; nil/0 = off
    public var fadeOut: Double? = nil
}

public struct LayerBlock: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case image, video }
    public enum Backdrop: String, Codable, Sendable { case none, dim, blur }
    public enum Motion: String, Codable, Sendable { case fade, scale, slide }
    public var id: String
    public var kind: Kind
    public var start: Double           // timeline clock anchor; end - start = output seconds (connected)
    public var end: Double
    public var file: String            // "media/<id>.<ext>"
    public var mediaStart: Double = 0  // video only: in-point in the file
    public var track: Int              // layer lane; higher draws in front
    public var rect: NormRect          // normalised to the OUTPUT canvas; aspect locked to the media
    public var backdrop: Backdrop = .dim
    public var motion: Motion = .fade
    public var fadeIn: Double? = 0.3
    public var fadeOut: Double? = 0.3
    public var aboveCamera: Bool = false
}

// Project gains (decodeIfPresent ?? default):
public var audioTracks: [AudioTrack]
public var audioClips: [AudioClip]
public var layers: [LayerBlock]
```

Rules:
- **Legacy derivation** when `audioClips` is absent: tracks `[Mic]` / `[System]` / both from `source.hasMic` /
  `hasSystemAudio`; one `AudioClip` per non-gap video clip, `start = clip.sourceStart`, `end = clip.sourceEnd`,
  `mediaStart = clip.mediaIn`, `mediaRate = clip.speed / clip.timeScale`, link per D2. Track volume/muted come from
  `audio.micVolume/micMuted/systemVolume/systemMuted`. After derivation the old fields are no longer read (keep decoding
  them, keep `denoise`). This reproduces today's sound exactly (AC-AU-1).
- `currentVersion` stays 3: the keys are additive and old builds ignore them (they then play the legacy mic/system
  mapping, wrong after detaching; acceptable, same as texts/windows).
- Package gains `voice/<id>.m4a` and `media/<id>.<ext>`. Existing media files are still never modified. Files are deleted
  only with the project; undo can always restore a clip.
- Invariants (add to `checkInvariants`): audio clips per track sorted and non-overlapping **in output time**, each
  ≥ 0.1 s, `track` in range, `0 ≤ gain ≤ 2`, media range inside the file's duration when known, `layer` set iff
  `link == .layer` and naming an existing video layer. Layers per lane non-overlapping in output time, ≥ 0.5 s,
  `rect` inside 0…1 with positive size, video layers' media range inside the file.

## 4. Behaviour

### 4.1 Linked audio

`screen`/`camera`-linked clips are stored and composed exactly like `CameraClip` (timeline clock, `mediaRate`, sliced by
video edits, sped with the clip).
- `screen`: every video op (`split`, `placeClip` trim/move, `deleteClips`, `liftClip`, speed, `useOutputClock`) edits it
  like `editLinkedLayers` edits camera, **even when `linkVideoEdits` is false** (D4).
- `camera`: edited whenever a camera clip is edited (camera ops, plus video ops that reach the camera through
  `linkVideoEdits`). Bidirectional: moving/trimming/splitting/deleting a `camera`-linked audio clip applies the same op
  to the overlapping camera clip(s), which then apply it to their other linked audio.
- `layer`: moves, trims, splits and deletes with its video layer (`layer` id), both directions. A split gives the right
  audio piece the right layer piece's id. Connected, like the layer (§4.2).
- Partner = target blocks overlapping the clip's range (for `layer`: the block with that id). Refactor the generic `edit`
  closure inside `editLinkedLayers` into one private generic `applyLinkedEdit(_:in:moveBy:)` and call it for camera- and
  layer-driven edits too. No second slicing implementation.
- ⌥ while dragging/trimming/deleting applies the op to the grabbed clip only. That breaks sync; the clip keeps its link.
  Exception: deleting a video layer with ⌥ preserves its audio and detaches it, because a link cannot name a deleted layer.
- `syncOffset(_ clip) -> Double?` (Core): output-time difference between the clip's media clock and its reference's
  media clock. Reference: link target; for unlinked mic → overlapping camera, unlinked system → overlapping screen,
  detached video-layer sound → the video layer with the same file. nil for voiceover and audio files.
  |offset| ≥ 1 frame → red chip `+0.42 s` on the clip, context menu **Move into Sync** (moves the clip by −offset).
- **Unlink** (context menu, `⌘L` toggles; video layer inspector **Detach Audio**) sets `link = nil` and converts to the
  connected representation (§4.2): `end = start + output duration`, `mediaRate` = current effective playback rate.
  **Link to Screen / Camera** slices the clip at the target's block edges and sets `link`; **Link to Its Video** relinks
  detached layer sound to the overlapping layer with the same file. Linking moves nothing; an offset shows as the chip.

### 4.2 Connected blocks (unlinked or layer-linked audio, takes, audio files, all layers), D3

- Output start = `TimeMap.outputTime(atSource: start)`; output length = `end - start` seconds; media plays at
  `mediaRate ?? 1`. Video splits, trims and speed changes never cut or retime them.
- Ripple is free: they are stored on the video clock, so removing earlier video moves them left.
- A clip move (`placeClip(moving: true)`) carries connected blocks whose anchor lies in the moved clip, when
  `linkVideoEdits` is on.
- `settleConnected()` (Core, at the end of every video op): (1) an anchor whose source time is no longer visible (inside
  a removed range) moves to the deletion point; (2) if two blocks on one lane now overlap in output time, the later one
  moves to the next lane of the same kind with free space (audio: extra tracks only, never Mic/System); a new lane/track
  is created if none exists. Never deletes.
  Reused audio tracks must have the same volume/mute settings; new tracks inherit them. Layer-linked sound is carried
  with its video layer even when its own anchor is outside the moved screen clip.

### 4.3 Timeline (TimelineView)

- `Lane` gains `.layer(Int)` and `.audio(Int)`. Order top→bottom: Video, Camera, Layer lanes (highest first), Zoom,
  Keys, Layout, Mask, Text, Window, then audio lanes (Mic, System, Voiceover n, Audio n). Layer and audio lanes appear only
  when they hold something, plus one empty "drop here" layer lane while dragging media.
- Colours (Theme): audio `#D3DEE8`, voiceover `#E9D8CF`, image layer `#E5DCEC` (mask lavender), video layer `#D7EAF0`
  (zoom ice). Dark labels.
- Audio lane height 36 pt. Each clip draws its own waveform from `Waveform.peaks(file)` over its media range (sqrt scale,
  2 px bars / 1 px gap, as T-626), gain-scaled; gain 0 pieces hatched. `Waveform` accepts any package-relative audio or
  video file (AVAssetReader on its first audio track). The 48 pt video-lane waveform from T-626 moves to the Mic lane;
  silent-span hatching moves with it; *Split at Pauses* still splits video (linked audio follows).
- Layer blocks show a thumbnail strip (images: the image; videos: frames at block-width intervals via
  `AVAssetImageGenerator`, cached per file).
- Fade handles: 6 pt squares in the top inner corners of audio clips and layers, on hover/selection. Dragging inward
  sets `fadeIn`/`fadeOut` (0.1 s steps; chip `fade 0.30 s`); a diagonal ramp is drawn over the block.
- Drag body = move in time; dragging vertically onto another lane of the same kind changes `track` if the spot is free.
  Horizontal moves clamp at neighbours. Edges trim within the media range (images: unlimited). Snapping (§7.2) also
  snaps to idle-slot edges and other audio/layer edges. ⌘ disables snapping, ⌥ ignores links.
- Chain badge at the clip's left edge: `⛓ Cam`, `⛓ Scr`, `⛓ Clip` (layer). Selecting a linked block outlines its
  partners at 50 %.
- Track header (D11): icon + name + mute (M) + 3 px live meter; voiceover lanes add a record button. Clicking the name
  opens a volume popover. View ▸ Compact Track Headers collapses the column.
- Context menus. Audio clip: `Split at Playhead (C) · Unlink / Link to Screen / Link to Camera / Link to Its Video ·
  Move into Sync · Mute Clip · Re-record… (⇧R) · Remove (⌫)`. Layer: `Placement ▸ Card/Full/Corner · Backdrop ▸ ·
  In Front of Camera · Detach Audio (video) · Replace Media… · Duplicate (⌘D) · Remove (⌫)`.
- Every gesture is one undo step via `model.edit` / `beginGesture`/`commitGesture` (unchanged).

### 4.4 Voiceover recording

- Entry: transport ● button, `⇧R`, a voiceover lane's record button, or Re-record on a selected audio clip.
- Microphone permission check first (`AVCaptureDevice.authorizationStatus(for: .audio)`), with the onboarding
  "Open Settings" route on denial. Never start without it.
- Flow: HUD over the preview (input level, device name, "Hear project" toggle, Stop, Discard) → silent 3-2-1 countdown
  in the preview → playback starts at the playhead (re-record: 1.5 s pre-roll before the range) → the take grows live on
  the first voiceover lane free from that time (new "Voiceover n" track if none). Stop: Space, `⇧R`, Stop button, the next
  clip on the lane, or 0.4 s after a re-record range. `Esc` discards (no undo entry, file deleted).
- Commit = one undo step: add the take clip (unlinked, connected). For re-record, also split the original audio at the
  range edges if needed and set that piece's gain to 0 (hatched, label "Replaced by Take n"), and remove a previous take
  in exactly the same range (D7).
- Capture: `AVCaptureSession` + `AVCaptureDeviceInput` (the mic chosen in the recording toolbar) +
  `AVCaptureAudioFileOutput` writing AAC `.m4a` to `voice/<id>.m4a`. **Sync**: start the session, wait for the first
  sample buffer, then `player.setRate(1, time: start, atHostTime: t0)`; take position = playhead output time +
  (first sample host time − t0). Pure Core function `takePlacement(playheadOutput:firstSampleHost:playbackHost:) -> Double`.
- Voiceover audio stays in the package like every other recording. Nothing is uploaded or logged.

### 4.5 Media import (images, videos, audio files)

- Entry points: drag files onto the preview or the timeline (drop on a lane = that time; on the preview = playhead);
  `⌘V` with an image on the pasteboard; Edit ▸ Add Media… (`NSOpenPanel`, `UTType.image`, `.movie`, `.audio`); clicking
  an idle slot (image picker). Validate with `AVURLAsset`/`CGImageSource` before copying; unreadable files show an alert
  naming the file and nothing is added.
- Copy into `media/<id>.<ext>` (D13), then add in one undo step:
  - **Image** → `LayerBlock(kind: .image)`, timing = idle slot under the playhead, else 4 s from the playhead.
  - **Video** → `LayerBlock(kind: .video, mediaStart: 0)`, length = file duration (clamped to the timeline end); if
    the file has an audio track, also an `AudioClip(file: same, link: .layer, layer: block.id)` on the first free extra
    track. Default look per D8.
  - **Audio** → unlinked `AudioClip` at the playhead, length = file duration, on the first free extra track (D14).
- Occupied spot → next lane/track of the same kind (create if needed).
- `idleRanges(events:minDuration:) -> [TimeRange]` (Core, beside `typingRanges`): spans with no key and no mouse-down
  for ≥ 3 s, padded inward 0.25 s.

### 4.6 Layer rendering

- LayerPanel in the inspector: thumbnail + Replace, Placement (Card / Full / Corner via the 3×3 position grid / Free),
  Backdrop (None / Dim / Blur), Motion (Fade / Scale / Slide), Fade in / Fade out (0–3 s), In front of camera; video adds
  "Sound: linked on Audio 1 · Detach Audio" (or "Detached · Link Back"). Selected layer in the preview gets the
  `SelectionRectView` handles (aspect locked, T-632 snapping, T-620 Esc chain); editing the rect switches to Free.
- Compositor pass after cursor, before camera (`aboveCamera` layers after camera). Opacity = the existing clip-fade
  smoothstep over `fadeIn`/`fadeOut`. Motion: scale 0.94→1, slide +4 % of canvas height → 0, same ramp. Backdrop: `dim`
  = black quad α 0.5 × opacity over screen/cursor; `blur` = the existing background blur kernel on the screen layer, mixed
  by opacity. Card radius/shadow reuse `frame.cornerRadius`/`frame.shadow`.
- Image textures: decoded once per file with `kCGImageSourceThumbnailMaxPixelSize` = 2 × output long edge, cached.
- Video textures: **one composition video track per layer lane**, built like the camera track (segments at their output
  times, 1×). Preview: `isolateTrack` + its own player/`AVPlayerItemVideoOutput`, as `PreviewView.attachCamera`. Export:
  an `AVAssetReaderTrackOutput` per lane with `FrameHold`, as the camera. FrameState gets the layer's texture by lane.
  ponytail: a ceiling of 4 layer lanes with video (decoder budget); a 5th video goes on a lane with a free spot or is
  refused with an alert, upgrade = merge non-overlapping lanes into one track.
- A missing `media/` file draws a hatched "Missing media" block and nothing in the render.

### 4.7 Composition and export (FrameSource / Exporter)

- Replace the per-video-clip mic/system insertion with one `AVMutableCompositionTrack` per **audio track**:
  screen/camera-linked clips use the camera loop (intersect with video clips, map through `TimeMap`, `scaleTimeRange` by
  `clip.timeScale`); connected clips (takes, audio files, layer sound, unlinked) insert
  `[mediaStart, mediaStart + (end-start)·rate]` from their file's first audio track at their output start, scaled to
  `end - start`. Assets are opened once per file and kept alive (see the T-502 comment in `makeComposition`).
- `makeAudioMix`: per-track input parameters, `volume × gain` per clip, `setVolumeRamp` for fades, 0 for muted tracks.
  Gain/fade/mute edits use `refreshAudioMix` (no rebuild); moves rebuild.
- `exportDuration` includes audio clip and layer ends. Export denoise applies to `mic.m4a` only.
- The state snapshot (§8.1) lists audio tracks/clips and layers (with file names and missing-file flags).

## 5. Acceptance criteria

- **AC-AU-1** (unit) A legacy project (no `audioClips`) with cuts, a 2× clip and a gap derives audio clips whose composed
  segments equal the old per-clip insertion (same media ranges at the same output times).
- **AC-AU-2** (unit) After any random sequence of video/camera/layer ops (fixed seed, 500 iterations) every linked audio
  clip has `syncOffset == 0` and invariants hold.
- **AC-AU-3** (unit) Deleting/moving video never deletes a connected block, never leaves an overlap on a lane, and keeps
  a block's anchor offset from its video content.
- **AC-AU-4** (unit) Unlink → relink round-trips output position and media range for screen, camera and layer links.
- **AC-AU-5** (selftest `audio-lanes`) Preview and export compose identical audio: same track count and segment list;
  the export decodes a tone at the expected output times after a detach-and-move and with an imported audio file.
- **AC-VO-1** (unit) `takePlacement` puts a take recorded with 120 ms device latency within 1 ms of the playhead.
- **AC-VO-2** (HUMAN) Re-record a range with a real mic: countdown, live clip, auto-stop, original piece hatched, one ⌘Z
  removes the take and restores the original.
- **AC-LY-1** (selftest `parity` on `make-layers-fixture`) maxDelta = 0 at 10 times, covering mid-fade, Scale, Slide, Dim,
  Blur, an above-camera image and a video layer with an in-point > 0.
- **AC-LY-2** (unit) `idleRanges` on a fixture with typing/clicks returns the expected spans.
- **AC-LY-3** (selftest `media-import`) Importing a PNG, a .mov with sound, a .mov without sound and an .m4a yields the
  expected blocks/clips/tracks, copies four files into `media/`, and is one undo step each; a corrupt file adds nothing.
- **AC-LY-4** Dragging 10 layers on two lanes over a 30-minute project stays at display refresh rate.

## 6. Tasks (tracked in PLAN.md; IDs follow T-635)

Lanes for parallel work: **A** T-640→T-641→T-642→T-643→T-644→T-645 · **L** T-646→T-647→T-648→T-649 (L starts once
T-640 merges; T-648 needs T-643). T-650 last.

- [x] **T-640 Audio/layer model + legacy derivation (Core)**
  - Do: `AudioTrack`, `AudioClip`, `LayerBlock`, `Project.audioTracks/audioClips/layers` per §3; legacy derivation;
    invariants; conform `AudioClip` and `LayerBlock` to `TimedBlock` (`advanceMedia` like `CameraClip`).
  - Verify: `make test FILTER=audioModel` (round-trip fully populated; legacy derivation incl. 2× clip and gap; invariants
    reject overlap, out-of-range track, dangling `layer`); AC-PRJ-1/2 still pass; `make test`.
- [x] **T-641 Linked audio edits (Core)**
  - Do: §4.1: extract `applyLinkedEdit`; `screen` audio in every video op regardless of `linkVideoEdits`; camera ops
    propagate to `camera` audio; layer ops propagate to `layer` audio (split re-points the right piece); audio ops on
    linked clips propagate to partners; `unlinkAudio`, `linkAudio(_:to:)`, `syncOffset`, `moveIntoSync`; ⌥ variant =
    `propagate: false`.
  - Verify: `make test FILTER=linkedAudio` (AC-AU-2 property loop, AC-AU-4, split/delete/move/speed cases); `timeline-ops`.
- [x] **T-642 Connected blocks settle (Core)**
  - Do: §4.2 `settleConnected()` at the end of `split`, `placeClip`, `deleteClips`, `liftClip`, `setSpeed`,
    `useOutputClock`; connected blocks carried by clip moves; lane push creates lanes/tracks (never Mic/System).
  - Verify: `make test FILTER=connected` (AC-AU-3: ripple delete under a take, a clip move carrying a video layer and its
    sound, collision push to a new lane, nothing deleted).
- [ ] **T-643 Composition + mix for N audio tracks**
  - Do: §4.7 in `FrameSource.makeComposition`/`makeAudioMix` (any package-relative audio/video file); `exportDuration`;
    PreviewView rebuilds on clip changes and refreshes the mix on gain/fade/mute.
  - Verify: new `--selftest audio-lanes` (AC-AU-1 segment equality on a legacy fixture + AC-AU-5); existing `audio-mix`,
    `export-range`, `parity` M6 maxDelta=0.
- [ ] **T-644 Audio lanes UI**
  - Do: §4.3 for audio: lanes, per-clip waveform (moved from the video lane; `Waveform` takes any file), headers with
    mute/meter/volume, move/trim/lane change, fade handles, chain badges, partner outline, red sync chip, ⌥ override,
    context menu, ⌘L, AudioPanel (link segment, sync readout + Move into Sync, gain dB slider, fades, mute), compact
    headers. VoiceOver: "Mic audio, linked to camera, 3.1 to 7.9 seconds".
  - Verify: `timeline-png` inspected (Mic/System/Voiceover/Audio lanes, badges, sync chip, fade ramp); `timeline-ops`
    and `menu-actions` extended (detach+move = 1 undo; ⌥-drag leaves the camera; Move into Sync zeroes the chip);
    `inspector-panels`; `waveform`; `timeline-clipboard` loops over the new lanes.
- [ ] **T-645 Voiceover recording**
  - Do: §4.4 in new `Editor/VoiceoverRecorder.swift` and the HUD in `PreviewView`; Core `takePlacement`; re-record flow;
    take replacement; `Esc` discard.
  - Verify: `make test FILTER=takePlacement` (AC-VO-1); `--selftest voiceover <m4a>` feeds a synthetic file through the
    commit path (placement, original gain 0, one undo step, take replaced on re-record); HUMAN: AC-VO-2 via LaunchServices.
- [ ] **T-646 Media import + layer lanes (Core + UI)**
  - Do: Core `idleRanges`, layer add/move/resize ops on the generic block engine; §4.5 import for all three kinds
    (drop, ⌘V, Add Media…, idle slot), copy into `media/`, video sound as a `layer`-linked clip, audio files on extra
    tracks; layer lanes with thumbnail strips, fade handles, idle slots, vertical lane change, missing-file state.
  - Verify: `make test FILTER=idleRanges` (AC-LY-2) and `FILTER=layerBlocks`; `--selftest media-import` (AC-LY-3);
    `timeline-png` with an image, a video + its linked sound, an audio file and slots, inspected; `timeline-ops`.
- [ ] **T-647 Image layer render pass**
  - Do: §4.6 for images: texture cache, Card/Full/Corner/Free rect, motion, backdrop dim/blur, aboveCamera ordering;
    FrameState gains `layers` (active blocks + progress + texture).
  - Verify: `--selftest make-layers-fixture` (images only for now) + `parity` maxDelta=0; `editor-png` mid-fade inspected;
    `export`.
- [ ] **T-648 Video layer playback**
  - Do: §4.6 video: one composition track per layer lane, preview via `isolateTrack` players, export via per-lane reader
    + `FrameHold`; 4-lane ceiling.
  - Verify: `make-layers-fixture` gains a video layer with in-point > 0; `parity` maxDelta=0 (AC-LY-1); `export` decodes
    the layer frames at the right times; `audio-lanes` with the layer's sound detached and moved.
- [ ] **T-649 Layer inspector + direct manipulation**
  - Do: LayerPanel; `SelectionRectView` on the selected layer in `PreviewView`; layer context menu incl. Detach Audio.
  - Verify: `inspector-panels`; new selftest `layer-rect` (drag, resize, Esc reverts, one undo); HUMAN: judge Card + Dim
    and a playing video layer against the prototype.
- [ ] **T-650 Docs + snapshot**
  - Do: SPEC §5 package listing gains `voice/`, `media/` and the new keys; state snapshot lists audio and layers;
    tick the roadmap block in PLAN.md.
  - Verify: `--selftest snapshot`; `make test`; `make app`.

## 7. Risks

- **Audio composition rewrite (T-643)** touches every export. AC-AU-1 segment equality is the guard; land it before UI.
- **Voiceover sync** depends on device latency: `takePlacement` + a HUMAN clap test before calling T-645 done.
- **Decoder budget**: every video layer lane is one more decoder in preview and export (plus screen and camera). The
  4-lane ceiling keeps it bounded; check AC-LY-4 and export speed with 2 video layers on an Intel Mac.
- **Large imports**: copying a multi-GB video is instant on APFS (clone) but not across volumes; show progress in the
  autosave status line and keep the add as a single undo step after the copy completes.
