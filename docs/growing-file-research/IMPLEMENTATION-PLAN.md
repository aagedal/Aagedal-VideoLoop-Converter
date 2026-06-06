# Implementation plan — true growing-file screen recording

Goal: from the screen recorder, produce **small H.264/HEVC files that truly grow in DaVinci Resolve and Premiere** while recording, are crash-safe, and are written fully in-process. Mechanism is the hidden **`.X.mov` sidecar index** reverse-engineered from Softron MovieRecorder — full spec in **`FINDINGS.md` §0**. This also lets us **delete the broken `.ts` pipe** (original deadlock).

All `ScreenCaptureManager.swift` line numbers are from `Aagedal Media Converter/Logic/ScreenCaptureManager.swift`.

---

## 0. Strategy & phasing (start here tomorrow)

The whole thing hinges on one unproven-by-us step: can *we* generate a sidecar that Resolve accepts? So **prove it before integrating.**

1. **PROOF (do first):** extend the standalone prototype `tools/grow_avwriter.swift` to also emit the `.X.mov` sidecar, run it, import the main `.mov` into Resolve, and confirm it **auto-grows**. This is the go/no-go. Everything else is known-good (the media file already matches Softron byte-for-byte).
2. Decide main-file form (fMP4 vs qt) from the proof — see §3.
3. Integrate into `ScreenCaptureManager` / `ScreenCaptureWriter` (presets, writer, sidecar).
4. Add the CFR pump (fix VFR).
5. Delete the `.ts` path.

If step 1 fails for some reason, fall back to **Plan B** (§11) — small near-growing `.mov` with no sidecar (Premiere live, Resolve ~1 min refresh). Plan B is strictly simpler and already designed.

## 1. Architecture

```
SCStream screen ─► CFR pump ─► AVAssetWriter (segmented) ─► main  X.mov   (encoded media)
SCStream audio/mic ─────────►                            └─► sidecar .X.mov (growing index → X.mov)
```

Two artifacts, same folder:
- **`X.mov`** — the real media (H.264/HEVC + audio + timecode), fragmented, what Resolve decodes.
- **`.X.mov`** — hidden fragmented-MP4 index (`ftyp iso5`), external `dref url = "X.mov"`, one `moof` per ~1 s whose `tfhd base_data_offset` is the absolute byte offset of that fragment's samples **in `X.mov`**. Resolve polls this to grow the clip. (Spec: `FINDINGS.md` §0.)

## 2. Source of truth

- **Sidecar byte format:** `FINDINGS.md` §0 + the live evidence there (`ftyp iso5`, pinned `mvhd`, 3 tracks, `mvex`/`trex`, external `url ` flags=0, per-fragment `moof` with `tfhd flags=0x000011` + absolute `base_data_offset`, `trun` sample tables).
- **Media file + timecode + CFR + colr/pasp/clap:** the working prototype `tools/grow_avwriter.swift` (already byte-matches Softron's media file).
- **Fingerprint/diff tool:** `tools/movfp.py`.

## 3. Component A — main media file + knowing sample byte offsets

The sidecar needs the **absolute byte offset of every fragment's samples inside `X.mov`**. Two ways:

- **A1 — segmented delegate (recommended; cleanest offset control).** Run `AVAssetWriter` with `outputFileTypeProfile = .mpeg4AppleHLS` (or `.mpeg4CMAFCompliant`), `preferredOutputSegmentInterval = CMTime(1s)`, `initialSegmentStartTime`, and an `AVAssetWriterDelegate`. The delegate's `assetWriter(_:didOutputSegmentData:segmentType:segmentReport:)` hands you each segment as `Data`:
  - `.initialization` segment = `ftyp`+`moov` → start of `X.mov`.
  - `.separable` segment = (`styp`)+`moof`+`mdat` → append to `X.mov`; **you wrote it, so you know its file offset.**
  - Build the sidecar `moof` by copying the segment's `moof` and rewriting `tfhd base_data_offset` to `segmentFileOffset + (mdat-payload offset within segment)`; `trun` tables copy unchanged. (`AVAssetSegmentReport.trackReports` gives timing/sync info if needed; sample sizes/offsets come straight from the copied `moof`.)
  - **Caveat:** this makes `X.mov` an **fMP4 (isom)**, whereas Softron's proven main file is **`qt`**. The PROOF step must confirm Resolve accepts an fMP4 main via the sidecar. If yes → A1 (much simpler). If no → A2.

- **A2 — normal writer + tail/parse (matches Softron exactly).** `AVAssetWriter(fileType: .mov)` + `movieFragmentInterval` → `qt` fragmented main (exactly Softron's form). Separately **tail `X.mov`**, parse each new `wide`/`mdat`/`moof` as it appears, read sample offsets, and emit sidecar `moof`s. More parsing, but reproduces the known-good reference.

Recommendation: try **A1** in the proof; fall back to **A2** if the main-file brand matters.

## 4. Component B — sidecar generator (`.X.mov`)

New type (e.g. `Logic/Capture/GrowingSidecarWriter.swift`):
- **Init (write once):** `ftyp` `iso5`/`iso6`/`mp41`; `moov` = `mvhd`(timescale 50000, **duration pinned to 1 s**) + the **same 3 track definitions** as the main (video/audio/timecode `trak`s: `tkhd`/`edts`/`mdia`/`minf`/`stbl`/`stsd`), but with each `dref` → **`url ` flags=0, content = main basename `"X.mov"`**; `mvex` + 3 `trex`. Derive track defs from the init segment's `moov` (A1) or the main file's `moov` (A2).
- **Per fragment (append):** `moof` = `mfhd`(seq++) + `traf`×3, each `tfhd` flags `0x000011` with absolute `base_data_offset` into `X.mov`, `trun` = per-sample size/duration/flags (+ `data_offset`). Mirror the source `moof`.
- **Atomicity:** append whole `moof` boxes with a single `write()` (a reader must never see a half-written `moof`); `fsync` periodically. Resolve re-reads the small file frequently.
- Keep video/audio/timecode track IDs = 1/2/3 (as Softron).

## 5. Component C — CFR frame pump (fix the VFR problem)

SCStream is variable-frame-rate. For clean NLE files + a sane timecode track, pace the encoder to CFR: a timer at `fps` re-appends the latest `CVPixelBuffer` (duplicate on a static screen). Active only for the growing presets. (Detail unchanged from the prior plan; prototype is already CFR.) Lock-guarded `latestPixelBuffer`, timer on the capture queue, start on first frame, stop in `stopRecording` (line 520) before finishing the writer.

## 6. Component D — timecode track

Port from `tools/grow_avwriter.swift`: `kCMTimeCodeFormatType_TimeCode32`, per-frame `tmcd` sample, time-of-day start (configurable). Verified Resolve/Premiere read it.

## 7. Component E — presets + remove the `.ts` path

- Add `CapturePreset` cases `.hevcGrowingMOV`, `.h264GrowingMOV` (enum line 32): `fileType .mov`, `isGrowing = true`, SDR video settings (1 s GOP = `MaxKeyFrameInterval = fps`, `AllowFrameReordering = false`, `colr`/`pasp`/`clap`, target bitrate). Add to `availablePresets` (line 92).
- Delete `FFmpegPipeWriter` (1707–2173), `usesFFmpegPipe` (83–90), the pipe branch in `startRecording` (405–426), `ffmpegVideoArgs` (103–126), and `.x264TS`/`.hevcVTTS`. Migration → picker fallback to `.hevc42210Bit` (already exists). Remove now-unused `CaptureError.ffmpegMissing`.

## 8. Integration points

| Concern | Location |
|---|---|
| Presets / availablePresets | `CapturePreset` line 32 / 92 |
| Writer build switch | `startRecording` 405–441 |
| Screen handler → CFR pump | line ~474 (route to `latestPixelBuffer`) |
| Stop sequence | `stopRecording` 520 (stop pump → finish writer → finalize/flush sidecar) |
| Writer impl | `ScreenCaptureWriter` 1347 (+ segmented/delegate or fragmentation) |
| New sidecar writer | `Logic/Capture/GrowingSidecarWriter.swift` (new — needs manual `project.pbxproj` ref) |
| UI pickers | `ScreenCaptureSettingsView.swift`, `CaptureModeView.swift`/`CaptureControlPanelView.swift` |
| Strings | `Resources/Localizable.xcstrings` |

## 9. Build / project

- New Swift file(s) → **manual `project.pbxproj`** file-ref + Sources entry (explicit refs; no synchronized groups; no xcodeproj gem).
- Build with the **Xcode `DEVELOPER_DIR` override**; Swift 6 strict concurrency → sidecar/pump state must be `Sendable`-clean (lock-guarded; `@unchecked Sendable` as the writer is today).

## 10. Test & acceptance

1. **Proof:** prototype emits `X.mov` + `.X.mov`; import `X.mov` mid-write into Resolve → **clip auto-grows**. Repeat in Premiere.
2. Both files grow together; `.X.mov` gains ~1 `moof`/s; `tfhd base_data_offset` values are `< X.mov` size and resolve to valid samples.
3. CFR (constant `r_frame_rate`, duration = wall-clock); timecode = wall-clock start in both NLEs.
4. A/V sync over minutes incl. static-screen periods.
5. **Crash safety:** `kill -9` mid-record → `X.mov` decodes up to last fragment; `.X.mov` is valid up to its last whole `moof` (proven for the media file in `FINDINGS.md` §7; verify the sidecar too).
6. Stop → main consolidates to flat (AVAssetWriter does this) and remains valid; decide whether to delete `.X.mov` on stop (Softron leaves it; harmless).
7. System audio + mic both present/ordered.

## 11. Risks / decisions

- **Main-file brand (fMP4 vs qt):** the one real unknown — resolved by the proof (§3 A1/A2).
- **Sidecar atomicity:** never expose a partial `moof`; single-write whole boxes.
- **Offset arithmetic** (A1): absolute offset = segment file offset + mdat-payload offset within segment; unit-test against `movfp.py` (base_data_offset must land on real sample data in `X.mov`).
- **HDR out of scope** for growing presets (SDR H.264/HEVC); existing `.hevc42210Bit` still handles HDR.
- **CFR backpressure** at 4K60: if `isReadyForMoreMediaData` is false on a tick, skip (don't block capture queue); keep the frame clock advancing.

## 12. Plan B — pragmatic fallback (if the sidecar is deferred)

Ship the growing presets **without** the sidecar: small fragmented `.mov` via `AVAssetWriter` (HEVC/H.264 + audio + timecode + `movieFragmentInterval`) + CFR pump, and delete the `.ts` path. Result: small ✓, in-process ✓, crash-safe ✓, decodes in both NLEs ✓, **Premiere** live (10 s refresh) ✓, **Resolve** auto-refreshes ~1×/min (not instant). Everything except the sidecar is shared with Plan A, so Plan B is a strict subset and a safe intermediate milestone.
