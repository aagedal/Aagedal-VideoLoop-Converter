# Implementation plan — true growing-file screen recording

> ✅ **IMPLEMENTED (2026-06-07).** Shipped in `ScreenCaptureManager.swift`: two growing presets (`hevcGrowing` 10-bit, `avcGrowing`), fragmented `.mov` via `movieFragmentInterval`, a CFR pump + per-frame timecode track, and the `com.blackmagicdesign.metadata:recording` xattr set on start / removed on stop (the real Resolve trigger — §0.3 of FINDINGS). The dead FFmpeg-pipe `.ts` path (`FFmpegPipeWriter`, `.x264TS`/`.hevcVTTS`, `usesFFmpegPipe`, `ffmpegVideoArgs`, `CaptureError.ffmpeg*`) was removed. No sidecar needed. Builds clean; **runtime/Resolve verification of the new in-app presets still pending** (CFR A/V sync + 10-bit 4:2:0 SCStream capture are the things to watch). The sections below are the original design record.

Goal: from the screen recorder, produce **small H.264/HEVC files that truly grow in DaVinci Resolve and Premiere** while recording, are crash-safe, and are written fully in-process. Mechanism is the hidden **`.X.mov` sidecar index** reverse-engineered from RefRecorder — full spec in **`FINDINGS.md` §0**. This also lets us **delete the broken `.ts` pipe** (original deadlock).

All `ScreenCaptureManager.swift` line numbers are from `Aagedal Media Converter/Logic/ScreenCaptureManager.swift`.

---

## 0. Strategy & phasing

**★ BREAKTHROUGH (2026-06-07): the growing-file trigger is an extended attribute, not the sidecar (FINDINGS §0.3).** Resolve shows the red REC growing overlay for a MAIN file carrying:

```
xattr  com.blackmagicdesign.metadata:recording = {"r":1, "uuid":"<32 hex, uppercase>"}
```

Confirmed in Resolve: a byte-identical clone got the overlay **only after** this xattr was written + re-imported. All the sidecar reverse-engineering (§3/§4 below, FINDINGS §0/§0.1) was chasing the wrong signal and is **likely unnecessary**.

**Revised recipe (pending one test):**
1. Write a growing media file with `AVAssetWriter` + `movieFragmentInterval` (fragmented `.mov`, HEVC/H.264 + audio + timecode + CFR).
2. On record start, `setxattr` the main with `com.blackmagicdesign.metadata:recording = {"r":1,"uuid":<fresh UUID>}`.
3. On stop, `removexattr` (a finished file carries none) and let `AVAssetWriter` consolidate to a normal flat clip.

**RESOLVED: the sidecar is NOT needed.** Resolve test (our own encoder): xattr + sidecar → REC ✅; xattr, **no sidecar** → REC ✅. So §3/§4 (all sidecar generation) are **dropped**. The feature is just "fragmented `.mov` + xattr".

Remaining phases:
1. Integrate into `ScreenCaptureManager` / `ScreenCaptureWriter`: growing presets, fragmented writer (`movieFragmentInterval`), **xattr set on start / remove on stop** — §5–§7 below (skip §3/§4).
2. Add the CFR pump (fix VFR) — §5.
3. Delete the `.ts` path — §7.

Main-file form: qt fragmented `.mov` via `AVAssetWriter` + `movieFragmentInterval` (carries `tmcd`; consolidates to flat on stop). Plan B (§11) is no longer a fallback so much as essentially the same plan minus the (probably unneeded) sidecar.

---
*(Sections §1–§11 below predate the xattr breakthrough and describe the sidecar approach. Retain for reference; gate on the `NO_SIDECAR` test before implementing any of the sidecar machinery.)*

## 1. Architecture

```
SCStream screen ─► CFR pump ─► AVAssetWriter(.mov, movieFragmentInterval) ─► main  X.mov  (qt frag media)
SCStream audio/mic ─────────►                                              │
                                          tail main, copy moov+moofs ──────┴─► sidecar .X.mov (index → X.mov)
```

Two artifacts, same folder:
- **`X.mov`** — the real media (H.264/HEVC + audio + timecode), fragmented, what Resolve decodes.
- **`.X.mov`** — hidden fragmented-MP4 index (`ftyp iso5`), external `dref url = "X.mov"`, one `moof` per ~1 s whose `tfhd base_data_offset` is the absolute byte offset of that fragment's samples **in `X.mov`**. Resolve polls this to grow the clip. (Spec: `FINDINGS.md` §0.)

## 2. Source of truth

- **Sidecar byte format + exact moov transform:** `FINDINGS.md` §0 / §0.1, and the executable spec **`tools/gen_sidecar.py`** (reproduces RefRecorder byte-for-byte).
- **Media file + timecode + CFR + colr/pasp/clap:** the working prototype `tools/grow_avwriter.swift` (already byte-matches RefRecorder's media file).
- **Fingerprint/diff tool:** `tools/movfp.py`; **sidecar derivation/validation:** `tools/gen_sidecar.py`.

## 3. Component A — main media file (A2-verbatim, DECIDED)

`AVAssetWriter(fileType: .mov)` + `movieFragmentInterval ≈ 1 s` → a **`qt` fragmented main** (exactly RefRecorder's form: `ftyp qt` + classic first `wide`/`mdat`/`moov(+mvex,3×trex)` + `(wide/mdat/moof)×N`). Confirmed empirically (our prototype produces this while growing). This is the only AVAssetWriter route that carries a `tmcd` timecode track (FINDINGS §6).

**We do NOT need to compute offsets.** The main's own `moof` boxes already carry **absolute** `tfhd base_data_offset` values (`flags=0x000011`) pointing into the main file — verified for both RefRecorder and our prototype (FINDINGS §0.1). So sidecar generation is **verbatim moof copy**; the only parsing required is top-level box scanning to find moof boundaries.

To get the moofs in lockstep, **tail the main file** as AVAssetWriter writes it: watch for newly-flushed complete top-level boxes; capture the first `moov` (to build the sidecar moov once) and each subsequent `moof` (to append verbatim). The old fMP4/segmented-delegate path (A1) is dropped (brand change, needs rewriting, no `tmcd`).

**Stop sequence caveat:** `AVAssetWriter.finishWriting` **consolidates** the main to flat (`ftyp+wide+mdat+moov`, no moof) — confirmed. RefRecorder instead leaves its main fragmented. Either is fine for us: during recording the file grows fragmented (Resolve reads live via sidecar); on stop the consolidated flat file is a normal valid clip. **Delete the sidecar on stop** so Resolve doesn't read a now-stale index; it falls back to its ~1 min auto-refresh of the flat clip. (Guard the brief consolidation-rewrite window — see §10.)

## 4. Component B — sidecar generator (`.X.mov`)

Reference implementation: **`tools/gen_sidecar.py`** (offline; reproduces RefRecorder byte-for-byte). The Swift port (e.g. `Logic/Capture/GrowingSidecarWriter.swift`) is a mechanical translation.

- **Init (write once, after the main's first fragment lands so its `moov` exists):** take the main's `moov` bytes and apply the deterministic transform (FINDINGS §0.1):
  - prepend `ftyp` `iso5` (minor 512, compat `iso6`/`mp41`);
  - for each `trak`, inside `mdia/minf`: **drop the minf-level `hdlr`** and **rewrite `dref`** to a single external `url ` box (`flags=0x000000`, content = main basename `"X.mov"`, no trailing NUL);
  - fix up `minf`/`mdia`/`trak`/`moov` box sizes (net −28 B/track);
  - keep `mvhd`(ts 50000, dur pinned 1 s), `tkhd`, `tapt`, `edts`, mdia-level `hdlr`, `stbl`(`stsd`/`avcC`), `gmhd`/`tmcd`, `meta`, `mvex`(3×`trex`) verbatim.
- **Per fragment (append):** copy the main's newly-flushed `moof` box **verbatim** — no `tfhd`/`trun` rewriting (the main already has absolute `base_data_offset`s). Track IDs are already 1/2/3.
- **Atomicity:** append whole `moof` boxes with a single `write()` (a reader must never see a half-written `moof`); `fsync` periodically. Resolve re-reads the small file frequently.

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
6. Stop → main consolidates to flat (AVAssetWriter does this) and remains valid; decide whether to delete `.X.mov` on stop (RefRecorder leaves it; harmless).
7. System audio + mic both present/ordered.

## 11. Risks / decisions

- **Main-file brand (fMP4 vs qt):** ~~unknown~~ **RESOLVED** — qt fragmented `.mov` (A2-verbatim), byte-matches RefRecorder and is the only `tmcd`-capable AVAssetWriter route.
- **Sidecar atomicity:** never expose a partial `moof`; single-write whole boxes.
- **Offset arithmetic:** ~~needed~~ **NOT needed** — moofs copy verbatim (main carries absolute `base_data_offset`s). Sanity-check with `gen_sidecar.py` against any captured RefRecorder pair.
- **Tail/flush timing:** AVAssetWriter flushes a fragment roughly per `movieFragmentInterval`; only act on *complete* top-level boxes (size+type fully present) to avoid copying a torn moof. The mdat precedes its moof on disk, so by the time a `moof` is complete its samples are already written.
- **Stop-time consolidation race:** while `finishWriting` rewrites the main to flat, hold off / delete the sidecar first so Resolve never indexes mid-rewrite.
- **HDR out of scope** for growing presets (SDR H.264/HEVC); existing `.hevc42210Bit` still handles HDR.
- **CFR backpressure** at 4K60: if `isReadyForMoreMediaData` is false on a tick, skip (don't block capture queue); keep the frame clock advancing.

## 12. Plan B — pragmatic fallback (if the sidecar is deferred)

Ship the growing presets **without** the sidecar: small fragmented `.mov` via `AVAssetWriter` (HEVC/H.264 + audio + timecode + `movieFragmentInterval`) + CFR pump, and delete the `.ts` path. Result: small ✓, in-process ✓, crash-safe ✓, decodes in both NLEs ✓, **Premiere** live (10 s refresh) ✓, **Resolve** auto-refreshes ~1×/min (not instant). Everything except the sidecar is shared with Plan A, so Plan B is a strict subset and a safe intermediate milestone.
