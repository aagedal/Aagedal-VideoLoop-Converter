# Growing-file recording — reverse-engineering findings

> Status: **SOLVED.** True growing-in-Resolve with a small codec (H.264/HEVC) is achievable. The signal is a hidden **`.X.mov` sidecar index file**, not anything in the media file — see [§0](#0-solved--the-davinci-resolve-growing-file-mechanism). Captured 2026-06-07.

---

## 0. SOLVED — the "DaVinci Resolve Growing File" mechanism

Resolve recognises a growing file by a **hidden sidecar** written next to the media, discovered by reverse-engineering **Softron MovieRecorder** (whose "DaVinci Resolve Growing File" checkbox toggles exactly this sidecar — confirmed by a controlled ON/OFF diff: the media files are byte-identical; only the sidecar's presence differs).

**The recipe:**
- **Main file** `X.mov` — the real media (Softron writes a fragmented `qt` MOV via AVAssetWriter; H.264 or HEVC, + audio + timecode). Holds the encoded samples.
- **Sidecar** `.X.mov` (hidden, dot-prefixed, **same folder, same basename**) — a tiny **fragmented MP4** index:
  - `ftyp` major `iso5`, compat `iso6`/`mp41`.
  - `moov` = mvhd (timescale 50000, **duration pinned to 1 s**) + the **same 3 tracks** (video/audio/timecode, "Core Media …" handlers) + `mvex`(3×`trex`).
  - Each track's `dref` → **`url ` box with flags = 0 (EXTERNAL) and content = `"X.mov"`** (the main file's basename). This is what ties the index to the media.
  - Then a **`moof` appended per fragment (~1/s)**, each with `traf` for all 3 tracks:
    - `tfhd` flags `0x000011` (base-data-offset-present + default-sample-size-present), **`base_data_offset` = absolute byte offset into the MAIN file** where that fragment's samples live.
    - `trun` = per-sample sizes/durations/flags + `data_offset` relative to `base_data_offset`.
  - The sidecar **grows** (more `moof`) in lockstep with the main file; Resolve polls it.
- Both files in the same directory; Resolve imports `X.mov`, finds `.X.mov`, treats `X` as growing.

**Why we couldn't find it earlier:** it's created only while recording and removed/irrelevant once stopped, and a finalized media file is byte-identical whether the toggle was on or off. The ON-vs-OFF media diff showed *only* `avcC`/SPS differences (normal encoder variation) — proving the signal is non-structural.

**How to reproduce (implementation):**
1. Write the main fragmented `.mov` with `AVAssetWriter` (HEVC/H.264 + audio + timecode + `movieFragmentInterval`), as in the existing prototype `tools/grow_avwriter.swift`.
2. Generate the `.X.mov` sidecar in lockstep. Cleanest path: drive `AVAssetWriter` in **segmented mode** (`preferredOutputSegmentInterval` + `AVAssetWriterDelegate.assetWriter(_:didOutputSegmentData:segmentType:segmentReport:)`). For each delivered media segment (a `moof`+`mdat`):
   - append the segment bytes to the main file at the current offset (so you know exactly where its `mdat` lands), and
   - emit a sidecar `moof` = the segment's `moof` with `tfhd base_data_offset` rewritten to the absolute position in the main file (segment offset + payload offset within segment); the `trun` sample tables copy over unchanged.
   - Write the sidecar init once (ftyp `iso5` + `moov` with `mvex` and external `dref url = "X.mov"`), derived from the init segment.
   Alternative: let AVAssetWriter write the main file normally and **tail/parse its `moof`s** to build the sidecar — same result, just parse instead of using the delegate.
3. Atomically keep `.X.mov` valid after each append (write to temp + rename, or append whole `moof` boxes) so Resolve never reads a torn index.

This yields the original goal: **small (H.264/HEVC) + true-growing in Resolve + Premiere + crash-safe + in-process.** The `.ts` deadlock removal (§2) still applies. The pragmatic fallback (§9) is now only a fallback if the sidecar generator is deferred.

Sidecar evidence (live Recording 7): sidecar `ftyp iso5`, 158 `moof` (≈158 s), `tfhd flags=0x000011 base_data_offset=1128282` (inside main), `url ` flags=0 content `"Untitled Recording 7.mov"`; main + sidecar grew together.

---

> Below: the original investigation that led here (still useful for context / the pragmatic fallback).
> Pragmatic fallback (small near-growing `.mov` via `AVAssetWriter`, no sidecar) — see [§9](#9-pragmatic-fallback-recommended-if-not-resuming-rev-eng).

---

## 1. Goal

From the screen recorder, produce **small files** that pro NLEs (**Resolve** and **Premiere**) can **import and edit while the recording is still being written** ("growing file" / edit-while-record), and that survive a crash mid-record.

- Small files ⇒ long-GOP **H.264/HEVC** (ProRes/MXF rejected for size).
- Targets: **Resolve + Premiere**.
- Must be crash/interruption safe.

## 2. The original bug (why the `.ts` attempts failed)

The hidden `.x264TS` / `.hevcVTTS` capture presets route raw frames to a spawned `ffmpeg` via `FFmpegPipeWriter` in
`Aagedal Media Converter/Logic/ScreenCaptureManager.swift` (class `FFmpegPipeWriter`, ~line 1707).

Root cause of "1 frame then freeze" (H.264) / "empty file" (HEVC):
- **One serial dispatch queue** (`com.aagedal.capture.stream`, ~line 448) delivers screen + audio + mic, and `append()` does **blocking** `Darwin.write()` into named FIFOs.
- `ffmpeg` reads its multiple FIFO inputs in DTS-interleaved order; the single producer thread blocks inside one FIFO write while ffmpeg waits on another ⇒ **classic multi-FIFO deadlock**. Preview also froze because preview is generated on the same queue.
- HEVC produced 0 bytes because `hevc_videotoolbox` inside ffmpeg buffers several frames before the first packet, so the deadlock hits before the first mpegts packet is written.
- Secondary problem: piping **raw BGRA** is ~0.5 GB/s (1080p60) to ~2 GB/s (4K60) — unsustainable through a pipe regardless of the deadlock.

**Lesson:** any real solution must encode in-process (no raw frames over a pipe). `AVAssetWriter` does this for free.

## 3. Results matrix (what Resolve/Premiere actually do)

"Grows" = NLE auto-extends the clip's duration while it's still being written.

| Codec / container | Source | Grows in **Resolve** | Video decodes in **Resolve** | **Premiere** | Size |
|---|---|---|---|---|---|
| **MPEG-2 / TS** | OBS + our `mpeg2-ts` | ✅ yes | ✅ yes (but Resolve **stretches** aspect) | ok | ✗ big |
| **HEVC / TS** | our `hevc-ts` | ✅ yes | ❌ **audio only** (no video) | ✅ both | ✓ small |
| **H.264 / TS** | our `h264-ts` | — | ❌ **won't import at all** | ? | ✓ small |
| **H.264 / MP4** (ffmpeg frag) | our `h264-mp4` | ❌ no | ✅ | imports | ✓ small |
| **H.264 / MOV** (ffmpeg frag) | our `h264-mov` | ❌ no | ✅ | imports | ✓ small |
| **ProRes / MOV** (ffmpeg frag) | our `prores-mov` | ❌ no | ✅ | — | ✗ big |
| **H.264 / MOV** (AVAssetWriter, `v`/`va`/`vat`/`+colr/pasp/clap`) | our prototype | ❌ **no** | ✅ | imports | ✓ small |
| **HEVC / MOV** (AVAssetWriter `vat`) | our prototype | ❌ no | ✅ | imports | ✓ small |
| **ProRes / MOV** (AVAssetWriter `vat`) | our prototype (near-perfect JustInMac twin) | ❌ **no** | ✅ | — | ✗ big |
| **H.264 / MP4 + timecode** (AVAssetWriter) | — | **impossible** — AVAssetWriter throws (see §6) | — | — | — |
| **ProRes / MOV** | **JustInMac (live)** | ✅ **yes** | ✅ | — | ✗ big |
| **H.264 / MP4** | **ATEM Mini Pro** (real workflow, per user) | ✅ **yes** | ✅ | — | ✓ small |

Extra behavior notes:
- **Resolve auto-refreshes any imported clip ~once/minute** regardless of "growing" status — so even a non-growing small clip becomes usable in Resolve with ~1 min latency.
- **Premiere** has a setting to refresh growing media every **10 s** (much better than Resolve for our small files).
- Resolve only gained `.ts` *decode* in 19.0.2 (Oct 2024) and it is **MPEG-2-centric** — it will not decode H.264/HEVC video inside `.ts` (Premiere will). So "growing `.ts`" is only fully usable in Resolve with **MPEG-2 = big**.

## 4. The two known-good growing references (and the killer insight)

### JustInMac (ToolsOnAir "Just In Mac", live capture) — `qt`/ProRes, AVAssetWriter
Live (growing) structure:
```
ftyp 'qt  ' (minor 0, compat 'qt  ')
wide + mdat               <- CLASSIC first segment (~1s, real stbl in moov)
moov = mvhd + 3×trak(video apcs ProRes, audio lpcm PCM, timecode tmcd) + mvex(3×trex)
wide + mdat + moof   × N  <- native QuickTime fragments; EVERY moof has traf for trackIDs [1,2,3]
```
- `mvhd` timescale 50000, **duration pinned to 1.0 s** (sentinel; not the full length).
- `tkhd` flags `0x0f`, durations pinned; video has `tapt`, `edts/elst`, **`tref→tmcd`**; video `stbl` has `colr`/`pasp`/`clap`/`fiel`; timecode track has a **`name`** atom.
- Handler names = "Core Media Video/Audio/Time Code" ⇒ **AVAssetWriter**.
- **On stop it CONSOLIDATES to flat**: `ftyp + mdat(whole) + moov(at END)`, no `mvex`/`moof`. (e.g. finalized Channel_2 = 8.2 GB.) So a *finalized* file tells you nothing about the growing form.

### ATEM Mini Pro ISO (Blackmagic) — `isom`/H.264, custom muxer
Downloaded sample is **finalized/flat** (`ftyp + wide + mdat + moov`, no fragments):
- `ftyp 'isom'` (minor 1, compat `iso4`/`avc1`/`isom`).
- Video **H.264 Main**, `avc1`, 1080p24, "**Apple Video Media Handler**".
- **`tmcd` timecode** track (1920×20), "Time Code Media Handler"; **both video AND audio have `tref→tmcd`**.
- Audio AAC LC `mp4a`, `elst` offset 2048 (priming).
- Handler names are **not** "Core Media" ⇒ **not AVAssetWriter** (Blackmagic custom muxer; needed because AVAssetWriter can't put `tmcd` in MP4 — see §6).

### Killer insight
ATEM (`isom`/H.264/custom-muxer) and JustInMac (`qt`/ProRes/AVAssetWriter) are **radically different files**, yet **both grow in Resolve**. Their only shared traits:
- a **timecode (`tmcd`) track**, and
- the **file growing on disk**.

**Our AVAssetWriter files already have both** — and still don't grow. ⇒ the trigger is **not** codec, container brand, handler names, or (apparently) any structure we can shape.

## 5. What we conclusively RULED OUT as the growing trigger

- **Codec** — ProRes, H.264, HEVC, MPEG-2 each grow in *some* container ⇒ not codec-gated (we even built a near-perfect ProRes twin of JustInMac via AVAssetWriter; it did **not** grow).
- **Container brand** — `qt` and `isom` both grow.
- **Muxer / handler names** — ATEM ("Apple…") vs JustInMac ("Core Media…") differ; both grow.
- **xattrs** — JustInMac's `com.apple.macl` is just macOS file-access bookkeeping; not a signal.
- **Structure we matched and still failed:** classic first segment, `mvex`+`moof`, all-3-tracks-fragmenting (`[1,2,3]` per moof), pinned `mvhd`=1 s, `tkhd` flags, `elst`, `tref→tmcd`, `trex` defaults, a correct **readable** timecode track (verified Resolve reads our time-of-day TC), and `colr`/`pasp`/`clap`.

## 6. Hard constraint discovered

**`AVAssetWriter` cannot write a timecode track into MP4:**
```
*** -[AVAssetWriter addInput:] AVAssetWriter does not support passthrough for media type tmcd to file type public.mpeg-4.
```
⇒ ATEM's exact recipe (H.264 + `tmcd` in `isom` MP4) is **not reproducible via AVAssetWriter**. The only AVAssetWriter route that includes a timecode track is **`.mov`/`qt`** (the JustInMac path). (MP4 without timecode also wrote a `chnl` v1 box ffmpeg flagged as invalid.)

## 7. Crash safety — CONFIRMED ✅

Hard-killed (`kill -9`) the AVAssetWriter prototype mid-write (no finalize) ⇒ the partial fragmented `.mov` is fully **readable and decodable** up to the last flushed fragment (probed: 3 s / 150 frames recovered). So the fragmented `.mov` approach satisfies the crash/interruption requirement for free.

## 8. Remaining unknowns / hypotheses to try when resuming

In rough priority:
1. **`name` (timecode reel/source) atom** — the most semantically meaningful remaining diff; both good files have it, ours doesn't, and **AVAssetWriter has no API to set it**. Test by **post-injecting** a `name` atom into the timecode sample description (hard on a *live-growing* file) or via a **custom muxer**.
2. **`fiel` atom** (field/interlace marker) — also missing from ours.
3. **Non-structural / runtime trigger** — e.g. Resolve keys off an **open file handle / advisory lock** on the file while it's being written, a **watch-folder/bin** workflow, or a Blackmagic↔Resolve integration. Test: hold the file open with a writer process vs not; try importing into a Resolve "live"/watch bin.
4. **Capture a LIVE ATEM/Blackmagic file** (not a finalized download) to see its *growing* structure (the download consolidated to flat). Blackmagic Camera app records H.264/HEVC/BRAW `.mov`.
5. **Blackmagic Cloud** route is almost certainly proprietary cloud sync (chunked upload + project-library sync), **not** local growing-file polling — unlikely to yield a reproducible local recipe, but if it drops a local file in the cloud project's media folder, analyze it.
6. **Custom muxer** that writes fragmented MP4/MOV with the exact atoms incl. `name`/`fiel` (high effort).
7. **Focused web research**: "what makes DaVinci Resolve treat a local file as a growing/recording clip" — Blackmagic forum (403s to bots) / Resolve or DeckLink SDK docs. Earlier broad research only covered format *choice*, not the detection internals.

## 9. Pragmatic fallback (recommended if not resuming rev-eng)

**Small HEVC/H.264 growing-style `.mov` via `AVAssetWriter`** (fragmented, in-process, with audio + timecode tracks):
- `AVAssetWriter(fileType: .mov)`, `movieFragmentInterval ≈ 1 s`, `AVVideoCodecType.hevc` or `.h264`.
- Reuse the existing **`ScreenCaptureWriter`** (already AVAssetWriter-based for `.mov` presets) — add `movieFragmentInterval` + a timecode track.
- **Outcome:** small ✓, in-process ✓ (kills the original deadlock + raw-bandwidth bug), **crash-safe** ✓, decodes in both NLEs ✓. **Premiere** edits while recording (10 s refresh) ✓. **Resolve** is *not* instant-growing but auto-refreshes ~1×/min ✓.
- Also fix the **VFR problem**: SCStream is variable-frame-rate; the encoder should be paced to **CFR** (duplicate the last frame when idle) — VFR misbehaves in NLEs generally. (The prototype is CFR via synthetic source; the real recorder is currently VFR.)
- Optional secondary "Resolve-live" preset using **ProRes** (the JustInMac path that genuinely true-grows today) for users who accept big files.

Implementation touch points: `Aagedal Media Converter/Logic/ScreenCaptureManager.swift` — `ScreenCaptureWriter` (~line 1347), `CapturePreset` enum (~line 32), and delete the dead `FFmpegPipeWriter` + `.x264TS`/`.hevcVTTS` presets.

## 10. Tools (preserved in `tools/`)

- **`grow_avwriter.swift`** — standalone AVAssetWriter prototype. Build & run:
  ```bash
  DD=/Applications/Xcode.app/Contents/Developer
  env DEVELOPER_DIR="$DD" xcrun -sdk macosx swiftc grow_avwriter.swift -o grow_avwriter
  # args: <out> <seconds> <fps> <codec:h264|hevc|prores> <tracks:v|va|vat> [startTC: tod|HH:MM:SS:FF]
  ./grow_avwriter ~/Movies/test.mov 240 50 h264 vat tod      # .mov=qt, .mp4=isom (but tmcd in mp4 THROWS)
  ```
  Produces qt/isom fragmented output matching JustInMac's structure (classic first segment, mvex, per-frame-fragmenting timecode track, pinned mvhd, colr/pasp/clap, time-of-day source TC).
- **`grow_avw.sh`** — runner: `bash grow_avw.sh [codec] [tracks] [seconds] [startTC] [container:mov|mp4]`.
- **`grow_test.sh`** — ffmpeg codec/container matrix: `bash grow_test.sh {h264-ts|h264-mp4|h264-mov|hevc-ts|hevc-mp4|prores-mov|mpeg2-ts} [seconds]`.
- **`movfp.py`** — deep MOV/MP4 fingerprint (top boxes, ftyp brands, mvhd/tkhd/mdhd, elst, tref, trex, per-moof track IDs). `python3 movfp.py <file>`.

Handy probes used during the investigation:
```bash
ffprobe -v error -show_programs -of flat file.ts | grep -Ei 'pid|codec|profile'   # TS PMT/PIDs/codec
ffprobe -v error -show_entries format_tags=timecode -show_entries stream_tags=timecode -of default=nk=1:nw=1 file.mov
xattr -l file.mov
```

## 11. Reference sample files used (outside the repo; may be deleted)

- `~/Movies/2026-06-06 23-09-43.ts` — OBS growing TS = **MPEG-2 video + 2× MP2 audio**, ~9.3 Mbps (the file the user confirmed grows in Resolve — note it's MPEG-2, not HEVC).
- `~/Movies/JustInMacLIte_TestRec_Channel_*.mov` — JustInMac ProRes captures (Channel_2 LT finalized 8.2 GB; Channel_4 Proxy). Live form = fragmented (growing); finalized = flat.
- `~/Downloads/ATEM Mini Pro ISO Demonstration Project/` — Blackmagic ATEM sample project; `Video ISO Files/*.mp4` = H.264 Main `isom`, finalized/flat.
