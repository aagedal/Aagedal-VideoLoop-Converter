# Implementation plan — pragmatic growing-file screen recording

Goal: ship a **small, in-process, crash-safe, growing-style `.mov`** capture path that edits live in **Premiere** (10 s refresh) and refreshes in **Resolve** (~1×/min), and **delete the broken `.ts` pipe** (fixing the original deadlock). See `FINDINGS.md` for why true-instant-growing in Resolve is out of reach without ProRes/proprietary signals.

All line numbers refer to `Aagedal Media Converter/Logic/ScreenCaptureManager.swift` unless noted.

---

## 1. Outcome / scope

In scope:
- New capture presets: **Growing MOV (HEVC)** and **Growing MOV (H.264)** — SDR, hardware-encoded, fragmented `.mov`.
- Fragmented output via `AVAssetWriter.movieFragmentInterval` (crash-safe, growing on disk).
- A **timecode track** (time-of-day by default) — matches pro recorders; verified Resolve/Premiere read it.
- **CFR frame pacing** to fix the known VFR problem (SCStream is variable frame rate).
- `colr`/`pasp`/`clap` descriptive atoms for correct NLE interpretation.
- Remove `FFmpegPipeWriter`, `usesFFmpegPipe`, and the `.x264TS`/`.hevcVTTS` presets.

Out of scope (explicitly):
- True instant-growing in Resolve (unsolved — see findings).
- HDR/10-bit for the growing presets (SDR only; the existing `.hevc42210Bit` MOV preset still handles HDR separately).
- A custom muxer / `.ts` / MP4-with-timecode (AVAssetWriter can't do `tmcd` in MP4).

Acceptance: a still-recording file imports in both NLEs, plays, has correct timecode + A/V sync, is CFR, survives `kill -9` mid-record, Premiere extends it at 10 s, Resolve refreshes within ~1 min. Files are small (long-GOP HEVC/H.264).

## 2. Architecture

```
SCStream screen cb ──► latestFrame (CVPixelBuffer + color attachments)   [updated, never blocks]
                          │
CFRFramePump (timer @ fps) ┘──► ScreenCaptureWriter.appendVideoFrame(buf, frameIndex)
                                    ├─ pixelBufferAdaptor.append(buf, pts = frameIndex/fps)
                                    └─ timecodeInput.append(tmcd sample = startTC + frameIndex)
SCStream audio/mic cb ───────────► ScreenCaptureWriter.append(audioSampleBuffer)  (pts rebased to session start)
AVAssetWriter (movieFragmentInterval = 1s, .mov/qt) ──► growing fragmented file on disk
```

The proven reference for every AVFoundation detail (fragmentation, timecode track, colr/pasp/clap, codec settings) is **`tools/grow_avwriter.swift`** in this folder — port from it.

## 3. Component 1 — Capture presets

In `CapturePreset` (enum at line 32):

- Add cases `.hevcGrowingMOV`, `.h264GrowingMOV`.
- `fileExtension` / `fileType` (lines ~75): `"mov"` / `.mov`.
- New property `var isGrowing: Bool` → `true` for the two new cases, else `false`.
- `description` / `fileSuffix`: e.g. "Growing MOV (HEVC, hardware)" / "Growing MOV (H.264)".
- `targetFrameRate` (line ~79): keep 60 (resolved per-display as today via `resolvedFrameRate`).
- `videoSettings(width:height:frameRate:…)` (line ~128) — return for the growing cases:
  ```
  AVVideoCodecKey: .hevc (hvc1) or .h264 (avc1 / High AutoLevel)
  AVVideoCompressionProperties: { AverageBitRate, MaxKeyFrameInterval = frameRate (1s GOP),
                                  AllowFrameReordering = false }
  AVVideoColorProperties: 709 (SDR), AVVideoPixelAspectRatio 1:1, AVVideoCleanAperture = full frame
  ```
  Pick bitrates ~ the old `.ts` presets (H.264 ~20 Mbit, HEVC ~25 Mbit) — tune later.
- `availablePresets` (lines 92–99): add the two growing presets. Keep `.hevc42210Bit`, `.proRes4444`.
- Picker fallback (already exists, see commit d6235e2): stored-preset → `.hevc42210Bit` when not in `availablePresets`. Verify the new cases decode and the removed cases (`.x264TS`/`.hevcVTTS`) fall back cleanly.

## 4. Component 2 — Growing writer (extend `ScreenCaptureWriter`, line 1347)

Reuse the existing AVAssetWriter writer (it already wires video + system-audio + mic inputs, color attachments, HDR). Add a "growing" mode:

- `create(...)`/init: accept `isGrowing: Bool`, `frameRate: Int`, `startTimecodeFrame: Int`.
- In `setupWriterIfNeeded` (line 1518) when `isGrowing`:
  - `writer.movieFragmentInterval = CMTime(value: 1, timescale: 1)` **before** `startWriting()`.
  - Add a **timecode input**: `CMTimeCodeFormatDescriptionCreate(timeCodeFormatType: kCMTimeCodeFormatType_TimeCode32, frameDuration: 1/fps, frameQuanta: fps, flags: 0)`, `AVAssetWriterInput(mediaType: .timecode, sourceFormatHint:)`, `writer.add`, and `videoInput.addTrackAssociation(withTrackOf: tcInput, type: AVAssetTrack.AssociationType.timecode.rawValue)`.
  - Set up the video input via `outputSettings` from the preset (the colr/pasp/clap + 1s GOP + no-reordering settings) rather than the current 422/ProRes settings.
- New method `appendVideoFrame(_ pixelBuffer: CVPixelBuffer, frameIndex: Int, attachments:)`:
  - lazy `startSession(atSourceTime: .zero)` on first frame; record `sessionStartHostTime`.
  - `pixelBufferAdaptor.append(pixelBuffer, withPresentationTime: CMTime(frameIndex, fps))`.
  - append one tmcd sample (4-byte big-endian `startTimecodeFrame + frameIndex`, duration 1/fps, pts frameIndex/fps) — copy `appendTimecode(frame:)` from the prototype.
- Audio path (`append(sampleBuffer:type:)`, line 1387) for `.audio`/`.microphone`: **rebase PTS to the session start** so audio sits on the same zero-based CFR timeline:
  `adjustedPTS = sampleHostPTS - sessionStartHostTime`. Use `CMSampleBufferCreateCopyWithNewTiming` (or set timing on append). Keep existing system-vs-mic routing.
- `finish()` (line 1470): mark video + audio + mic + **timecode** inputs finished, then `finishWriting`. (AVAssetWriter consolidates to flat on finish — same as JustInMac; that's fine/expected.)
- Keep `applyColorAttachments` (1599) for HDR-capable presets; for the SDR growing presets, set 709 color in output settings.

> Decision: keep this inside `ScreenCaptureWriter` behind an `isGrowing` flag rather than a new class — maximal reuse of the audio/mic/color plumbing. If it bloats, split `Logic/Capture/GrowingTimecode.swift` (helper for the tmcd sample) — that needs a **manual `project.pbxproj` ref** (this project uses explicit refs, no synchronized groups).

## 5. Component 3 — CFR frame pump (fix VFR) — the only genuinely new piece

SCStream delivers frames **only on change** (VFR). For clean NLE files + a sane timecode track we need **constant frame rate**:

- Add a `CFRFramePump` (capture side, in `ScreenCaptureManager`), active only for `isGrowing` presets:
  - State guarded by a lock: `latestPixelBuffer: CVPixelBuffer?` + its color attachments, updated in the SCStream `.screen` handler (line ~474) instead of calling `writer.append` directly.
  - A `DispatchSourceTimer` on the capture queue firing at `1/frameRate`.
  - On each tick: if `latestPixelBuffer != nil`, call `writer.appendVideoFrame(buf, frameIndex)` then `frameIndex += 1`. (Re-appends the last frame when the screen is static → true CFR. Long-GOP makes duplicated static frames nearly free.)
  - Start the timer on the first received frame; stop it in `stopRecording` (line 520) before `writer.finish()`.
- Non-growing presets keep the current direct `writer.append(sampleBuffer:type:)` path unchanged.
- Audio continues to flow from SCStream callbacks (audio is already continuous); just rebase PTS (Component 2).

> This also resolves the standing "VFR screen recorder" issue noted by the user — consider applying CFR to the other AVAssetWriter presets later, but keep this PR scoped to the growing presets.

## 6. Component 4 — Timecode

- Default **time-of-day** start (frames since midnight at `frameRate`); allow an override later via settings.
- Implementation = the prototype's `framesFor`, `fmtTC`, format-description creation, and per-frame `appendTimecode(frame:)`. Verified: ffprobe/Resolve/Premiere read the source TC correctly.
- 50/60 fps are non-drop (flags 0). If 29.97/59.94 are ever offered, add drop-frame flag handling.

## 7. Component 5 — Remove the dead `.ts` path

- Delete class `FFmpegPipeWriter` (lines 1707–2173).
- Delete `usesFFmpegPipe` (lines 83–90) and the `preset.usesFFmpegPipe` branch in `startRecording` (lines 406–426) — route all presets through `ScreenCaptureWriter`.
- Delete `ffmpegVideoArgs` (lines 103–126) and the `.x264TS`/`.hevcVTTS` enum cases + their `description`/`pixelFormat`/`videoSettings` arms.
- Remove `CaptureError.ffmpegMissing` if now unused.
- Migration: ensure any persisted `"x264TS"`/`"hevcVTTS"` default decodes to `nil` → picker fallback to `.hevc42210Bit` (already the behavior). Grep the UI/settings for those raw strings.

## 8. Integration points (quick map)

| Concern | Location |
|---|---|
| Preset enum / availablePresets / settings | `CapturePreset` line 32; availablePresets 92 |
| Writer build switch | `startRecording` lines 405–441 |
| SCStream screen handler → pump | line ~474 (route to `latestPixelBuffer` for growing) |
| Stop sequence | `stopRecording` line 520 (stop pump → finish writer) |
| Writer impl | `ScreenCaptureWriter` 1347 / `setupWriterIfNeeded` 1518 / `append` 1387 / `finish` 1470 |
| Protocol | `CaptureOutputWriter` 1339 (add `appendVideoFrame` or keep timecode internal) |
| UI pickers | `UI/SettingsView/ScreenCaptureSettingsView.swift`, `UI/Components/CaptureModeView.swift` / `CaptureControlPanelView.swift` |
| Localizable strings | `Resources/Localizable.xcstrings` (new preset titles) |

## 9. Build / project

- New Swift file(s) → **manual `project.pbxproj`** file-ref + Sources build-phase edit (explicit refs, no synchronized groups, no xcodeproj gem). Prefer editing `ScreenCaptureManager.swift` in place to avoid this.
- Build via the **Xcode `DEVELOPER_DIR` override** (xcode-select points at CommandLineTools); Swift 6 strict concurrency — the new pump/state must be `Sendable`-clean (lock-guarded mutable state, `@unchecked Sendable` writer as today).

## 10. Test & acceptance

1. Build clean (DEVELOPER_DIR override).
2. Record ~30 s with each new preset; while still recording:
   - File grows on disk; `ffprobe` shows fragmented `qt` mov, HEVC/H.264, audio, `tmcd` track.
   - **Premiere**: import mid-record, set growing refresh 10 s → clip extends.
   - **Resolve**: import mid-record → plays; clip length updates within ~1 min.
3. **CFR check**: `ffprobe -show_entries frame=pkt_pts_time` (or r_frame_rate constant) — no VFR; duration matches wall-clock.
4. **Timecode**: `ffprobe` source TC = wall-clock start; matches in both NLEs.
5. **A/V sync** over several minutes; static-screen periods don't desync (CFR duplicates).
6. **Crash safety**: `kill -9` the app mid-record → partial file imports + decodes (matches §7 of findings).
7. System audio + mic both present and ordered; verify with `audioRoutingService` cases if applicable.

## 11. Risks / decisions

- **CFR pump + AVAssetWriter backpressure**: if `videoInput.isReadyForMoreMediaData` is false on a tick, skip that tick (don't block the capture queue) and keep the frame clock advancing — accept an occasional dropped duplicate rather than stall. Validate under load (4K60).
- **Audio PTS rebasing** must use the same `sessionStartHostTime` as the first video frame, or you get a fixed A/V offset. Unit-check the first-frame timing.
- **HDR**: growing presets are SDR; if a user records HDR, either gate the preset to SDR or transcode — don't silently mislabel color. (HDR growing is out of scope.)
- **Resolve latency expectation**: document in the UI that Resolve updates ~1×/min (not instant); Premiere is near-real-time. Set user expectations so this isn't perceived as a bug.
- **Bitrate defaults**: start from the old `.ts` preset values; expose later if needed.

## 12. Suggested phasing

1. Presets + `ScreenCaptureWriter` fragmentation + timecode (no CFR yet, passthrough timestamps) → verify growing/import/crash-safety.
2. Add the CFR pump → verify VFR fixed + sync.
3. Delete the dead `.ts` path + migration.
4. UI strings + expectation note + (optional) timecode-source setting.
