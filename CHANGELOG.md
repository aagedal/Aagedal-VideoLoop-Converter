# v.4.0.0 — DRAFT

This is the biggest release yet, rolling up everything from the 3.9 beta plus a lot of polish since. Highlights up top; bug fixes at the bottom.

## Encoding Groups & Camera Card Import

### Encoding Groups
A new item type in the encoding queue. An Encoding Group can have its own encoding settings, separate from the rest of the queue. This was primarily built to work together with the new Card Import dialogue, but you can also create a group on its own with **⌘N** and drag items from the queue into it.

Groups can be placed anywhere in the queue, and you can now edit a group in a dedicated editor window.

### Camera Card Import
A new memory-card import dialogue (**⌘⇧I**) lets you select a camera folder and automatically extract videos from subfolders into an Encoding Group. You can name the card, and output files will be numbered sequentially after the card name.

Combined with Encoding Groups, you can now import and queue media from multiple cameras in one batch while still using the Stream Copy preset per-group.

## Redesigned Queue (much faster scrolling)

The queue rows have been rebuilt from SwiftUI to AppKit. Scrolling stays smooth even with hundreds of items, thumbnails decode off the main thread, and progress updates no longer thrash the UI.

While we were in there we also redesigned the cell layout for 4.0:

- New liquid-glass circular thumbnail badges with a blurred toolbar overlay.
- Filmstrip thumbnails and waveforms generate on demand as you scroll into view.
- Expanded row metadata, larger badges, and a persistent timecode badge.
- Status text moved below the progress bar so nothing shifts around during encoding.
- Hover actions and **Shift+⌘** modifier shortcuts directly on queue rows.
- Right-click context menu for quick actions (Show in Finder, Preview, Trim, Metadata, Audio Routing, Attach Subtitle, Rename, Reset, Remove).
- Drag encoded files out to any app, and drag them back into the queue to re-encode.

## Region-based Screen Recording

Record a specific area of your screen instead of the full display. An interactive full-screen overlay lets you draw and resize a selection rectangle, then captures only that region at native resolution with a floating control panel.

You can also **schedule a recording** from the same overlay, and hover the audio meters in the preview for level tooltips.

## Subtitles & Transcription

### Parakeet transcription engine
Added Parakeet (NeMo ASR via MLX) as a second speech-to-text engine alongside Whisper, optimized for Apple Silicon — potentially much faster transcription. Requires Python and `parakeet-mlx` to be installed manually.

### Tesseract OCR
New OCR engine for turning PGS/VOBSUB subtitle image files (common in DVD/Blu-ray) into SRT by reading text from image frames. Generally faster and better timed than re-transcribing, with the caveat that characters can occasionally be misread (e.g. `I` vs. `|`).

### Subtitle embedding
Automatically embed generated SRT subtitles into the output video after transcription or OCR.

### Attach subtitle files
Attach external SRT/ASS/SSA files to queue items and optionally mux them into an already-encoded output.

## Video Quality Analytics

Run analytics to compare the quality of an encode against its source, view the results in a new UI overlay, and manually or automatically export the report to JSON or PDF.

Supported metrics:

- **VMAF**
- **PSNR**
- **XPSNR**
- **SSIMULACRA2** (requires `cargo install`; flagged with a performance warning in settings)

## Metadata & C2PA

Metadata reading has been migrated from ExifTool to a bundled SwiftExif, which is much faster and means one less external dependency.

- Expanded metadata window with a source ↔ output comparison view.
- Export full metadata reports as JSON or PDF.
- C2PA content credentials support, with correct handling when credentials aren't present.
- Chapter data now read directly via SwiftExif.
- Faster imports overall, thanks to deduped probes and a cap on concurrent probing.

## Unified Audio Only preset

The three separate audio presets (WAV, AAC, MP4) have been consolidated into a single **Audio Only** preset with configurable format, codec, bit depth, and bitrate.

## Encoding options

- **More CRF options** for finer quality control.
- **AV1 tune modes** with new tuning options, including SVT-AV1-PSY "Subjective Quality" tuning.
- Updated FFMPEG binary with **SVT-AV1 4.1.0** for faster, higher-quality AV1 and AVIF encoding.
- **Subtitle preservation toggle** — choose whether to keep existing subtitles in the output.
- Improved help descriptions throughout the preset settings.

## Crop & Preview

- Redesigned crop handles: L-shaped corner brackets and rectangular edge handles for a more professional look.
- Crop corner cursors now have a white outline so they're visible on dark backgrounds.
- Throttled trim drag seeks and added cursor affordances for the different trim modes.
- HDR thumbnails are now correctly tone-mapped for SDR display.
- Filmstrip thumbnails use AVFoundation (with an FFMPEG fallback) for faster generation and instant tooltips.
- Fullscreen player adopts the cleaner design from Aagedal Media Player.

## Settings & UI

- **New Settings layout** — redesigned from a tab bar to a collapsible sidebar with an icon-only mode. The per-tab pages have also been reorganized for a more consistent layout.
- **Searchable keyboard shortcuts** — filter shortcuts by key combo, description, or group name.
- **Auto-delete old encodes** — optional setting to automatically clean up encoded files older than a configurable number of days from the default output folder.
- **Confirmation dialogs** for destructive actions (removing items, resetting, etc.).
- **Norwegian Bokmål translations**.
- Expanded About page with links and licenses for bundled dependencies.

## Downloads (yt-dlp)

- Surfaces the first real yt-dlp error when a download fails, with a stall watchdog to catch frozen downloads.
- SHA256 verification for downloaded yt-dlp and deno binaries.
- Hardened argument handling and tighter output-path parsing.
- Cancel button and polished status UI for yt-dlp and deno downloads.
- Download overlay now only appears when yt-dlp is actually configured, with cleaner URL validation and Tab focus handling.

## Watch Folder

- Watch Folder auto-activates on launch if it was enabled when you quit.
- Unified Upload and folder layouts.

## Bug fixes

- Fixed merge/concat stripping audio across all presets.
- Fixed Stream Copy dropping audio in certain cases.
- Fixed concat merge using the sequential file name instead of the encoding group name.
- Fixed encoding group item actions, metadata view, and single-file card import.
- Fixed missing metadata for encoding group items and stale merge temp files.
- Fixed the encoding queue not updating when files were added via drag-and-drop.
- Fixed batch conversion ordering when encoding groups are interleaved with regular items.
- Fixed subtitle cancellation showing a spurious error.
- Fixed missing and incorrect entries in the Keyboard settings view, and made the shortcut search match group titles.
- Fixed analytics cancellation and routed the button to the results view.
- Fixed black frames when combining trim with the Stream Copy preset (particularly nasty when also merging).
- Fixed the ETA calculation to use FFMPEG's `speed=` field instead of a broken formula.
- Surfaced FFMPEG error reasons in the UI when conversion fails, with better error pattern matching.
- Fixed long filenames breaking queue row layout and yt-dlp status strings.
- Fixed layout shifts in the toggle buttons and status area during encoding.
- Fixed the fullscreen player's Space key being swallowed by the queue's keyboard monitor.
- Fixed several crash risks: replaced `fatalError` and force-casts with safe error handling, and closed security-scoped resource leaks in the conversion pipeline and preview generator.
- Fixed C2PA false positives and hid C2PA UI when credentials aren't available.
- Mitigated the MPV Metal validation crash when toggling crop mode during a seek.
- Guarded the update-notification against cancellation errors.
