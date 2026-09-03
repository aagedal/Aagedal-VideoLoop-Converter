# Aagedal Media Converter Improvement Plan

Last reviewed: 2026-09-02

This is the prioritized improvement roadmap. `TODO.md` remains a small historical
feature checklist; new improvement work should be tracked here with an owner or
issue link when it starts.

## Audit snapshot

- The project builds successfully with Xcode 17 and Swift 6 strict concurrency.
- The unit-test baseline is green: 187 tests pass. The
  anamorphic-crop regression was fixed and now has generated-media coverage for
  pixels, square-pixel SAR, and output dimensions; custom-command tokenization now
  has focused coverage for empty quoted arguments and whitespace handling; every
  built-in preset now has default container/codec coverage; audio selection,
  ordering, duplication, downmixing, channel operations, subtitle-container policy,
  and AVC-Intra MCA label generation now have focused command tests. Metadata
  policy, manual/preserved/drop-frame timecode, image-sequence inputs and JPEG
  output, DCP/IMF conformance arguments, and AV2 chunk planning now have direct
  coverage as well.
- The app contains about 88,300 lines of Swift. Several core files are very large:
  `FFMPEGConverter.swift` (3,456 lines), `ConversionManager.swift` (2,891),
  `ContentView.swift` (2,900), `VideoFileListView.swift` (2,240), and
  `ExportPreset.swift` (2,241).
- There are only 187 unit tests. The UI test target now has deterministic smoke
  assertions for empty-queue launch, Settings navigation, generated-fixture import,
  preset selection, conversion success, conversion failure details, and start/cancel
  state transitions.
- GitHub Actions now builds Debug and runs unit tests on pushes and pull requests;
  tagged and scheduled runs also build Release. `main` still needs a branch rule
  that makes the Debug build-and-test job required.
- External tools still have 26 direct `Process` construction sites outside the
  shared runner and UI-test fixtures. Twenty-two are active launches; four are
  configuration-only shims that already hand execution to the shared runner. The
  remaining launch paths do not yet share one cancellation, timeout, pipe-draining,
  and error-reporting layer.
- `SwiftExifMediaProbe.durationSync` still bridges async AVFoundation work through
  a synchronous compatibility wait, now bounded to five seconds while callers are
  migrated.
- The empty queue, imported queue rows, primary conversion toolbar, and Settings
  navigation now have a tested accessibility-identifier contract. Most icon-heavy
  and custom AppKit/SwiftUI controls still need explicit labels, state values, and
  flow coverage.
- The string catalog has 1,197 entries; 87 entries have no Norwegian localization.
  Some are format tokens or App Intent phrases, so they must be classified before
  translating.
- Bundled binaries, frameworks, and resources total roughly 280 MB before the app
  bundle is packaged. Their contents and licenses should be verified as part of a
  release rather than only reviewed manually.

## Priority 0 — Restore a trustworthy baseline

Target: first; approximately 2–4 focused days.

### 0.1 Resolve the failing anamorphic-crop regression test

Status: completed 2026-08-31.

- Create a tiny generated 1440×1080, SAR 4:3 fixture with an unmistakable crop
  target.
- Verify the produced pixels, display aspect ratio, and output dimensions with
  FFmpeg/SwiftExif. Do not decide correctness from the command string alone.
- Fix the filter construction if the output is wrong; otherwise rewrite the stale
  assertion to describe the new “replace desqueeze with crop + setsar” behavior.
- Add square-pixel, anamorphic, inactive-crop, stream-copy, and odd-dimension cases.

Acceptance: all unit tests pass from a clean Derived Data directory, and the test
name/comments match the intended filter behavior.

Completed with explicit post-crop square-pixel normalization, a generated
1440x1080 SAR 4:3 color-band fixture, pixel/SAR/dimension validation, and focused
square-pixel, anamorphic, inactive-crop, stream-copy, missing-PAR, and odd-dimension
tests.

### 0.2 Add build-and-test CI

Status: implemented and validated on GitHub Actions 2026-08-31; required-check
enforcement remains to be configured.

- On every pull request and push, build the Debug app and run unit tests on macOS.
- Add a Release build on tags or a scheduled run so packaging-only problems are
  caught before release day.
- Upload the `.xcresult` when tests fail.
- Keep the appcast publishing job separate from validation.

Acceptance: a change cannot be merged unnoticed with a compile error or failing
unit test.

Implemented in a validation workflow that runs a Debug build and the unit-test
target on every pull request and push. Tagged and weekly scheduled runs also build
Release; manually dispatched runs can validate both configurations on demand.
Failed jobs retain their `.xcresult` bundles for diagnosis. The appcast publisher
remains an independent workflow. The first hosted Debug build and unit-test run
passed on commit `a57ed1d`. The `main` branch currently has no protection rule, so
make `Debug build and unit tests` a required check before marking this item
complete.

### 0.3 Turn the existing TODO into current work

Status: completed 2026-08-31.

- Closed the ambiguous screen-recording item as an implemented CFR baseline:
  growing presets use a fixed frame pump with Auto, integer 50 fps (PAL), or integer
  60 fps (NTSC). Non-growing presets intentionally retain source-timestamp VFR,
  with the selected rate acting as a requested delivery cap. The distinct
  broadcast-grade expansion—25, 29.97, 50, and 59.94, rational timing, drop-frame
  timecode, and explicit CFR/VFR labeling—remains tracked in 4.3.
- Marked the Downloads Homebrew-install-guide item complete: yt-dlp settings show
  a copyable `brew install yt-dlp` command; package-manager installation remains a
  manual Terminal step.
- Kept completed implementation history in the changelog and removed stale open
  wording from the historical checklist.

Acceptance: no open item is ambiguous or already implemented.

## Priority 1 — Protect conversion correctness

Target: next; approximately 1–2 weeks, delivered incrementally.

### 1.1 Build a command-generation test matrix

Status: in progress; default preset matrix added 2026-08-31.

Cover the pure logic before refactoring it:

- every built-in preset and its container/codec pairing;
- trim + crop + anamorphic normalization;
- audio mapping, removal, channel routing, and MCA labels;
- subtitle mapping/OCR/transcription hand-off;
- stream copy incompatibilities;
- metadata, timecode, image-sequence, DCP, IMF, and AV2 special paths;
- custom-argument tokenization, including empty quoted arguments.

Prefer structured expected values and focused assertions over full command-string
snapshots, which are brittle when argument order is irrelevant.

Acceptance: each built-in preset has at least one command test, and every fixed
conversion regression gains a test.

Custom-command tokenization now has direct tests for explicitly empty quoted
arguments, single- and double-quoted whitespace, and escaped whitespace. A
structured default matrix now covers the output extension, video codec, audio
codec, and media shape for every FFmpeg-backed built-in preset. AV2 has a separate
assertion that preserves its dedicated `avmenc` route. Stream Copy now has a
regression test that verifies audio/video copying while excluding subtitles. The
H.264, H.265, and AV1 paths now verify MP4/MOV fallback from incompatible Opus to
AAC and native Opus retention in Matroska. Audio-routing coverage now exercises
selection order, duplicate tracks, removal/fallback behavior, mixed downmix and
pass-through filters, and merge/split/swap/extract channel operations. Subtitle
mapping is tested for MKV, MP4/MOV, disabled preservation, and unsupported output
containers; AVC-Intra MCA tests cover manual overrides, input dual-mono labels,
silent padding, and unknown layouts. Those tests fixed duplicate video mapping
when an audio map appeared first and prevented subtitle arguments from being added
to PNG, AVIF, MXF, IVF, and audio-only outputs.

Metadata/timecode coverage now verifies source-map versus deterministic stripping,
manual replacement without requiring a successful source probe, item-level disable
without silently reloading the global default, trim offsets, 29.97/59.94 drop-frame
minute rules, ten-minute boundaries, and very-low-rate safety. This fixed invalid
drop-frame labels, a possible divide-by-zero, missing timecode on waveform and
synthesized-video command branches, and redundant re-probing when request metadata
is already available. A generated QuickTime fixture now verifies that Stream Copy
preserves source timecode, replaces both the container and video-stream tags for a
manual value, and clears both tags when timecode is disabled so FFmpeg cannot recreate
a stale `tmcd` track. Image-sequence input/range/audio and JPEG quality are tested;
DCP and IMF tests cover geometry, profiles, rational rates, HDR color tags, and
codec choices; AV2 chunk-count policy is covered for CQ, VBR, and short inputs.

Generated fixed-rate media now verifies that AV2 start-only trims plan only the
remaining duration and frame count, preventing parallel chunks from seeking beyond
the source. A generated color-band fixture now verifies that image-sequence exports
retain their selected visual encoder and apply crop filters to the actual output
pixels, rather than losing both behind the embedded-video-track capability. IMF App
2e now retains its exact produced JP2 frame count before optional cleanup and reuses
it for audio padding and CPL duration; App 5 retains a tested duration fallback. The
image-sequence import path now resolves normalized crop geometry from its concrete
first frame rather than attempting to probe the containing directory; a generated
PNG sequence verifies the assembled command and cropped output pixels. The next
slice now uses dummy video/audio essences to exercise DCP and IMF assembly end to
end: essence moves, PKL hashes and sizes, ASSETMAP paths and lengths, CPL timing and
metadata, optional-audio omission, and IMF parser round-trip are covered without
external tools. This exposed
and fixed DCP CPL/PKL generation that ignored the requested content title,
annotation, and audio language.

DCP and IMF audio post-processing now follows the same virtual source as the picture
encode: concat groups extract across the full demuxer list, while image sequences
open their associated audio file directly. Generated PCM fixtures verify the full
concat duration and companion-WAV duration. The audio-only fallback also handles
WAV/AIFF-style inputs whose stream topology is not available through SwiftExif,
instead of silently treating them as mute.

AV2 now follows custom concat and image-sequence sources instead of silently
reopening the representative URL. Concat commands use the full demuxer list and
the queue's known duration/frame rate; image sequences use their first concrete
frame for geometry and preserve their image2 input arguments. Virtual sources stay
on the validated single-process encoder path until independent segment seeking has
generated-media coverage. Matroska audio now follows the same virtual source,
including full concat audio and image-sequence companion files, and item-level mute
suppresses the audio track. Audio-only generated-video requests fail with a clear
unsupported message instead of entering an incompatible AV2 path.

AV2-in-Matroska now writes the same composed comment/date value and resolved
manual or preserved timecode as the generic export path, including global and
primary-video tags. Raw IVF remains metadata-free by design. Arbitrary additional
FFmpeg output arguments now fail with a clear unsupported error instead of being
silently discarded; there are currently no production AV2 callers that supply
them.

AV2-in-Matroska now also consumes the shared audio-routing policy. A routed
audio-only Matroska stage preserves selected order, duplicate tracks, removals,
per-track downmixing, and channel operations before AAC or Opus packets are handed
to the in-app muxer. The muxer writes ordered audio track numbers and block IDs,
marks only the first audio stream as default, and exposes routing only when the AV2
container is Matroska. Generated two-track fixtures cover AAC and Opus staging,
downmixing, duplication, split/extract channel operations, and output channel order;
selected-audio extraction failures now stop the conversion instead of silently
producing video-only output.

The audit identified these remaining high-risk follow-ups:

- generated waveform/synthesized-video AV2 output remains unsupported;
- routed AV2 audio tracks are currently reconstructed from time zero, so differing
  source-track start offsets are not preserved; uncommon AAC program-config-element
  layouts also remain unsupported by the elementary-stream parser;
- generated IMF CPL `SourceEncoding` references need full MXF descriptor and
  subdescriptor coverage plus conformance validation.

### 1.2 Add small media-fixture integration tests

Status: completed 2026-09-01.

- Generate short fixtures in the test setup instead of committing large media.
- Exercise one representative file per major family: video+audio, anamorphic,
  multichannel audio, subtitle, still/image sequence, and malformed input.
- Validate output with in-process metadata where possible and FFmpeg only where the
  app itself depends on FFmpeg behavior.
- Include cancellation, failed-process, missing-binary, existing-output, and
  source-overwrite prevention cases.

Acceptance: the core “import → command → convert → validate output” path runs in CI
in a few minutes and leaves no temporary artifacts behind.

A generated one-second video+audio Matroska fixture now drives
`FFMPEGConverter.convert` through real output naming, process launch, progress
handling, completion, and post-run validation. The test verifies the H.264 result
contains one video and one audio stream with the expected dimensions and duration,
and cleans its temporary directory. Generated follow-up cases now verify that an
existing output is preserved under a unique destination, a same-path request cannot
overwrite its source, malformed input returns an actionable failure, and cancelling a
running FFmpeg process completes promptly. Failed and cancelled ordinary-file exports
now remove partial output and revoke their app-created-file registration, preventing a
stale path from authorizing deletion of a file created there later. Explicit selection
of a missing custom FFmpeg binary also fails before registering or creating an output.
A single completion gate now covers every ordinary-file exit path, including early AV2
rejection and native-waveform failures, so racing auxiliary/FFmpeg exits cannot complete
twice or bypass failed-output cleanup. An AV2 generated-video rejection test verifies the
reserved destination is unregistered even though no encoder process starts.
A generated 5.1 fixture now exercises the core converter's real audio-routing path and
verifies a selected surround track is downmixed to one stereo output stream. A generated
Matroska text-subtitle fixture verifies H.264/MP4 conversion produces a `mov_text` stream
whose subtitle payload can be extracted intact. Together with the existing generated
anamorphic and image-sequence cases, the fixture families and failure/safety cases in
this milestone are now covered without committed media or leftover temporary files.

### 1.3 Replace the placeholder UI test with smoke coverage

Status: completed 2026-09-01.

Start with stable, high-value flows:

1. Launch into an empty queue.
2. Open Settings and move between panes.
3. Import a fixture and select a preset.
4. Start and cancel a conversion.
5. Verify the result/error state is exposed to the UI.

Use accessibility identifiers as the test API rather than coordinates or visible
English text.

Acceptance: the UI suite contains real assertions and is deterministic across two
consecutive clean runs.

The stale UI-test host target name has been corrected. Stable accessibility
identifiers now cover the empty queue, imported queue rows and their state, Import,
Preset, Start/Cancel, Settings, and each Settings sidebar pane. The generated
placeholder test has been replaced with empty-queue/toolbar assertions and a Settings
test that opens the window and moves from General to Presets to Metadata while
checking the exposed pane state. A DEBUG-only launch hook now generates a tiny media
fixture in a caller-owned temporary directory and imports it through the production
URL path, allowing the UI suite to verify queue import and preset selection without
automating the sandboxed system file picker. The generated-fixture import and preset
selection test passed twice consecutively. The same fixture now exercises a successful
H.264 conversion through the production manager, while deleting the imported fixture
before Start produces a deterministic missing-input failure whose technical detail is
exposed through a dedicated accessibility element. Cancellation uses a DEBUG-only,
real-time-paced 15-second fixture so automation observes the real FFmpeg process without
depending on encoder speed. This exposed a batch-lifecycle race: cancellation could
arrive before the completion waiter was installed, and Cancel All did not resume that
waiter. The waiter is now installed before conversion starts and is released on every
batch cancellation. Per-batch and per-process identities also prevent late callbacks
from an older cancelled conversion from clearing or completing newer work, including
cancellation during FFmpeg preflight before the process launches. Start/cancel,
success, and failure UI tests passed together in two consecutive runs; the full
unit target remains green.

## Priority 2 — Make long-running work reliable

Target: after the correctness net; approximately 1–2 weeks.

### 2.1 Introduce one subprocess runner

Status: in progress; shared runner plus yt-dlp, rclone, OCR, Whisper, Parakeet,
analytics, package-version probes, merge preparation, screenshot capture, and the
ordinary FFmpeg conversion path migrated 2026-09-01–03.

Provide an injectable runner that owns:

- cancellation and process-tree termination;
- optional deadlines and a clear timeout error;
- concurrent stdout/stderr draining without deadlocks;
- incremental progress parsing;
- structured exit status and bounded diagnostic output;
- environment construction and redaction of credentials, cookies, and URLs;
- test fakes for success, failure, timeout, and cancellation.

Migrate the highest-risk paths first: FFmpeg conversion, yt-dlp, rclone upload,
Whisper/Parakeet, OCR, and package wrappers. Do not attempt all 50 call sites in one
change.

Acceptance: cancelling a queue item reliably stops its child process, and no tool
invocation can wait forever without an explicit policy.

The first incremental slice introduces an injectable runner with structured exit
results, concurrent stdout/stderr draining, independently bounded capture tails,
stdin delivery, task cancellation, explicit deadlines, TERM-to-KILL escalation,
descendant termination, incremental output events, elapsed timing, and log-safe URL
and sensitive-argument redaction. Focused process tests cover successful and nonzero
exits, stdin, output beyond pipe capacity, capture bounds, timeout, descendant cleanup,
cancellation, TERM-ignoring-child escalation, and redaction. The duplicated yt-dlp
metadata and playlist probes now use the runner with a five-minute deadline, a 16 MB
JSON safety limit, bounded diagnostic stderr, redacted cookie/URL arguments, and
sanitized length-bounded error text. The main yt-dlp download path now uses the same
runner while retaining its activity-based five-minute stall policy for indefinite live
recordings. Incremental output is reassembled across arbitrary byte chunks; the final
output-path line, progress, title, overwrite detection, and concise first error continue
to be parsed without logging URLs or cookie values. Per-item cancellation handles preserve
user-cancel, live-stop, and stall outcomes, cancel the full subprocess tree, and prevent
one concurrent or late download from cancelling or clearing another. Fake-runner tests
cover split output, successful result validation, redacted failures, explicit and parent-task
cancellation, and live-stop behavior; the runner also verifies that every captured byte reaches its
incremental handler, including final-drain bytes. Robust process-group isolation and the
remaining call sites are still open, so this item remains in progress.

The rclone upload, connection-test, and password-obscuring paths now use the shared
runner with six-hour, one-minute, and five-second deadlines respectively, bounded
stdout/stderr capture, stdin-only password delivery, and redacted paths, destinations,
key files, and credentials. Inherited rclone configuration variables are scrubbed before
the request-specific in-memory remote is installed. Arbitrary output chunks are
reassembled into complete progress/error lines, including final unterminated output.
Upload cancellation now follows each item's Swift task instead of a single mutable
`Process`, so cancelling one concurrent
upload cannot terminate another; execution identities also prevent late progress,
completion, or cleanup from an older attempt from overwriting a retry. Fake-runner tests
cover split/final progress, request construction, diagnostic redaction, connection error
classification, password timeout/stdin behavior, and isolated concurrent cancellation.

Per-frame Tesseract OCR now uses the shared runner instead of a detached task around
`Process.waitUntilExit`. Its existing ten-second limit is enforced by the runner with
process-tree termination, stdout/stderr are drained concurrently into bounded captures,
input paths are redacted from diagnostics, and parent-task cancellation propagates through
the shared cancellation path. Focused fake-runner tests cover request construction and
environment, timeout mapping, redacted failures, truncated-output rejection, and
cancellation.

The OCR pipeline's FFmpeg subtitle-stream extraction now uses the shared runner as well.
Its thirty-minute deadline terminates the process tree, stderr capture is bounded, source
and scratch paths are redacted from concise failure details, and user or parent-task
cancellation reaches the runner through run-keyed extraction tasks. Concurrent OCR runs
retain independent task slots, while per-attempt operation IDs ensure a row-level cancel
stops only that item's current extraction or recognition tasks; a cancellation dispatched
before actor registration is retained for that attempt, and an explicit cancel-all path
remains available for batch shutdown. Incremental FFmpeg progress is reassembled across
arbitrary output chunks without treating partial records as real progress. Fake-runner
tests cover request construction, deadline/capture policy, split progress, timeout mapping,
bounded redacted failures, early/direct task cancellation, and isolated overlapping service
cancellation.
The FFmpeg Whisper-filter transcription path now uses the shared runner with a generous
twelve-hour deadline, bounded stderr capture, process-tree cancellation, and redacted
input, model, output, and filter paths. Its progress parser reassembles arbitrary stderr
chunks and final unterminated records before interpreting duration and timestamp updates.
The actor no longer blocks in `waitUntilExit`, and per-attempt operation IDs keep overlapping
transcription cancellation isolated without poisoning a later retry. A cancellation dispatched
before actor registration is remembered for that attempt; parent-task cancellation follows the
same path and is rechecked before publication. Each run writes a short UUID-only staged SRT and
replaces its reserved destination only after success, so cancellation and failed reruns preserve
an existing valid subtitle. Concurrent same-basename runs reserve distinct final names instead
of overwriting one another. Queue progress, completion, and embedding publication are fenced by
the same attempt ID, preventing a cancelled or superseded run from mutating the current row;
grouped queue children use the same targeted cancellation route. The guarded embedding commit
uses atomic replacement so a publication failure preserves the original video. The raw filter
string, including private model and output paths, is no longer logged, and its values now use
both required FFmpeg escaping layers. Focused fake-runner
tests cover request construction, stream selection, deadline and capture policy, split progress,
timeout mapping, bounded redacted diagnostics, early/direct/late task cancellation, isolated
overlapping cancellation, long filenames, concurrent destination reservation, and staged
publication. A bundled-FFmpeg parser test also round-trips paths containing colons, commas,
semicolons, brackets, backslashes, and apostrophes without loading a real model.

The Parakeet pipeline now uses the shared runner for both selected-track FFmpeg extraction
and parakeet-mlx transcription. Both stages have process-tree cancellation, bounded output,
redacted private paths, and explicit two- and twelve-hour deadlines. Progress parsing keeps
stdout and stderr records separate while reassembling arbitrary chunks and final unterminated
records. Per-attempt operation IDs isolate overlapping and grouped queue cancellation, including
cancel-before-registration and parent-task cancellation, and fence stale progress, completion,
and subtitle embedding. Each run transcribes through a short UUID staging directory and atomically
publishes to a reserved destination only after its final cancellation check, preserving an existing
subtitle on failure and preventing concurrent same-basename runs from colliding. Focused fake-runner
tests cover request construction, environment and selected-stream mapping, deadlines and capture
policy, split/final progress, timeout and redacted failure mapping, isolated overlapping and early
cancellation, late parent cancellation, staging cleanup, failed-rerun preservation, and concurrent
publication.

The ordinary single-process FFmpeg conversion path now uses the shared runner with a
seven-day safety deadline, bounded stderr capture, redacted command/error paths,
process-tree cancellation, and CR/LF progress-record reassembly across arbitrary output
chunks. Per-conversion task and progress gates prevent late output from a cancelled or
superseded encode from mutating the next attempt. Per-attempt output reservations also
keep delayed cleanup away from a same-destination retry, and conversion-ID ownership keeps
stale handlers from clearing a newer AV2 process handle. Timeout, cancellation, nonzero
exit, launch failure, output validation, and failed-output cleanup continue through the
same single completion gate. Fake-runner tests cover request policy, split progress,
diagnostic redaction, timeout mapping, task cancellation, and same-destination
superseded-retry isolation; the generated-media conversion, file-safety, malformed-input,
and real cancellation fixtures remain green. AV2 source decoding still uses its explicit
avmdec-to-FFmpeg pipe until the runner supports streaming stdin.

The one-shot FFmpeg decoders used by native waveform export analysis and preview waveform
images now use the shared runner with twelve-hour deadlines, bounded stderr capture,
private-path redaction, process-tree cancellation, and injectable test fakes. Native
waveform analysis is tracked as part of the active conversion, so queue cancellation can
stop it before the streaming video encoder starts. Conversion-identity checks fence every
async hand-off into that encoder, its progress and termination callbacks cannot mutate a
newer attempt, its frame writer is cancelled with the conversion, and FFT work checks
cancellation periodically. Focused tests cover mono and per-channel PCM/image output,
request policy, redacted bounded failures (including custom executable paths), timeout
mapping, direct cancellation, and converter-level cancellation. Those tests also exposed
and fixed a short-audio FFT range crash by zero-padding requested frames beyond the
available PCM samples.

Rclone package resolution now uses the shared runner for both custom-binary identity
validation and the active-version query. The duplicated direct `Process` launches and
hand-rolled watchdog were replaced by one injectable five-second probe with bounded stdout
and stderr, process-tree cancellation, structured exit checking, and executable-path
redaction. Focused fake-runner tests cover request policy, accepted and rejected output,
nonzero exit, cancellation, and the update service's injected active-version path.

Video-quality analytics now uses the shared runner for VMAF, PSNR, XPSNR, per-frame
FFmpeg extraction, and SSIMULACRA2 comparison. The actor no longer blocks in
`waitUntilExit`; each tool has an explicit deadline, bounded output capture,
process-tree cancellation, and private-path redaction. FFmpeg progress is reassembled
across arbitrary CR/LF chunks, VMAF scratch logs are removed on every exit, and an
attempt identity prevents a superseded analysis from clearing or cancelling its
replacement. Injectable media metadata and subprocess seams provide focused coverage
for request policy, split progress, result parsing, scratch cleanup, SSIMULACRA2's
three-stage tool flow, timeout/nonzero diagnostics, direct cancellation, and overlapping
attempt isolation.

BMX package rewrapping and MXF metadata/MCA-label probes now use the shared runner.
`bmxtranswrap` has a twelve-hour deadline, process-tree cancellation, bounded and
redacted diagnostics, split-record-safe progress parsing, serialized execution, and
nonempty-output validation. Conversion-scoped cancellation is retained when it wins
the race before subprocess registration, without affecting another conversion. The
`mxf2raw` probes have five-minute deadlines and bounded output, reject truncated or
nonzero results instead of parsing partial metadata, and keep their existing MCA
cache and security-scope lifetime. Operation-aware queue cancellation removes a
waiting rewrap immediately, and post-processing ownership prevents a cancelled or
superseded conversion from reporting late success. Fake-runner tests cover request
policy, progress, redaction, timeout, direct, queued, and pre-registration cancellation,
serialization, missing and partial outputs, OP1a detection, MCA parsing, and
truncated-probe rejection.

Preview thumbnail and legacy waveform subprocesses now use the shared runner instead
of the centralized wait-before-drain `Process` helper. Each file-producing invocation
has a thirty-minute deadline, bounded stderr, no stdout retention, private-path
redaction, process-tree cancellation, nonempty-output validation, and partial-file
cleanup. Per-URL cancellation and app termination cancel tracked runner tasks; fallback
loops no longer turn cancellation into retries or apparent success. Attempt ownership
also prevents cleanup from an older cancelled generation removing a replacement.
Focused fake-runner tests cover request policy, bounded redacted failures, timeout
mapping, targeted cancellation, and cancellation of every tracked process.

The yt-dlp updater's active yt-dlp and Deno version probes now use the shared runner
instead of a polling loop with manual TERM/KILL handling. Both probes have a
three-second deadline, bounded stdout and stderr, executable-path redaction,
process-tree cancellation, structured exit checking, and truncated-output rejection.
Focused fake-runner tests cover request construction, tool-specific parsing, nonzero
exit, launch failure, timeout, truncation, and parent-task cancellation. The existing
Homebrew/Python resolver remains a configuration-only shim until it exposes runner
request components directly.

Merge trim and conformance preparation now uses the shared runner instead of an
untracked continuation around `Process`. Each one-shot FFmpeg run has a twelve-hour
safety deadline, concurrent pipe draining with bounded stderr, private-path redaction,
process-tree cancellation, and nonempty-output validation. Batch cancellation stops
the active preparation task, while cancelling any constituent row invalidates the stale
merge snapshot and lets the remaining rows continue individually; operation and batch
identities prevent an older completion from clearing or publishing over a replacement.
Failed, timed-out, and cancelled runs remove partial prepared clips. Fake-runner tests
cover request policy, redaction, missing and empty output validation, failure and timeout
cleanup, and parent-task cancellation.

The shared FFmpeg/Parakeet and Tesseract version helpers now use the shared runner
instead of waiting synchronously and draining one pipe only after exit. Both variants
have a five-second deadline, concurrent bounded capture, executable-path redaction,
structured exit checking, selected-stream truncation rejection, and parent-task
cancellation. Focused fake-runner tests cover stdout/stderr parsing, request policy,
nonzero, truncated, and empty results, timeout mapping, and cancellation.
Tesseract's selected version stream now matches the current CLI's stdout behavior.

Interactive screenshot capture now uses the shared runner instead of a detached
task that waited indefinitely before draining FFmpeg's error pipe. Captures have a
thirty-minute deadline, discard stdout, retain bounded stderr, redact executable and
media paths, propagate cancellation, reject missing or empty output, and remove
partial files after every failed exit. Each attempt writes a UUID-owned staging file
and uses an exclusive atomic rename to publish a collision-free destination without
replacing an earlier screenshot. The controller owns and identifies the active
capture so preview teardown stops it and rejects a late success. The two player UIs
no longer publish the same success state and overlay twice or log expected teardown
cancellation as an error. Focused fake-runner tests cover request policy, redacted
nonzero diagnostics, timeout and parent cancellation, late success, atomic
publication, and missing or empty output cleanup.

Remaining package extraction/warm-up, native-waveform streaming encoder, AV2 pipe,
DCP/IMF wrapper, ConversionManager subtitle embedding, and specialty helper call
sites are still open. The refreshed audit counts 22 direct production launches plus
four configuration-only `Process` shims. The synchronous Whisper capability/version
cache needs an async state redesign.
DCP/IMF post-processing and subtitle embedding need explicit task ownership as part of
their migration; native-waveform streaming and AV2 pipelines should wait for
incremental stdin and coordinated multi-process support.

### 2.2 Remove sync-over-async waits

Status: in progress; image-sequence duration compatibility bridge bounded 2026-09-02.

- Make image-sequence duration probing async end-to-end, or give the compatibility
  bridge a bounded timeout while callers are migrated.
- Audit `waitUntilExit`, `DispatchGroup.wait`, and semaphore waits for cancellation
  and actor/thread assumptions.
- Add cancellation checks around metadata probing, thumbnails, downloads, uploads,
  and conversion post-processing.

Acceptance: Thread Sanitizer smoke runs show no new races, and stalled media probes
cannot indefinitely block an import.

The synchronous image-sequence audio-duration compatibility bridge now limits its
AVFoundation fallback to five seconds and cancels the detached load on timeout. Its
shared result is lock-protected so a late completion cannot race the caller after the
deadline. Deterministic tests cover successful delivery and a stalled async probe
returning promptly; migrating image-sequence detection async end-to-end and the wider
wait/cancellation audit remain open.

Virtual-display configuration now has a real ten-second deadline around the blocking
WindowServer `applySettings` call. The former task-group race still implicitly joined
the non-cooperative blocking child after its timeout won, so a stalled WindowServer
could keep creation suspended indefinitely. An exactly-once, lock-protected
continuation now returns on operation completion, timeout, or parent cancellation
without waiting for the losing blocking call; the background closure retains its
private display objects until any late completion. Deterministic tests cover immediate
success, prompt timeout, and a late result being ignored without double-resuming the
caller.

### 2.3 Standardize user-visible errors

- Keep `try?` for best-effort cleanup only. Log or surface failures for directory
  creation, bookmark access, file moves, settings import, and result validation.
- Give every queue failure a concise message plus expandable technical details.
- Add a “Copy diagnostics” action with app/tool versions and redacted commands.

Acceptance: each failed long-running operation ends in success, cancellation, or a
specific actionable error—never a silent return or permanently busy state.

## Priority 3 — Reduce change risk in architecture

Target: continuous work after Priority 1 tests exist.

### 3.1 Split orchestration from state and views

- Move import, queue commands, window/overlay presentation, and App Intent hand-off
  out of `ContentView` into small coordinators or observable models.
- Split `ConversionManager` into queue scheduling, conversion execution, upload
  follow-up, and item state transitions.
- Split `VideoFileListView`/`VideoFileCellView` by behavior rather than adding more
  extensions to already-large views.

Acceptance: view bodies describe presentation, state transitions can be unit
tested without launching the app, and each extraction is behavior-preserving.

### 3.2 Make conversion plans typed

- Replace repeated mutation of raw `[String]` arguments with a typed conversion
  plan: inputs, video filters, audio routes, maps, codecs, metadata, and outputs.
- Render the plan to arguments at the process boundary.
- Detect incompatible options during preflight instead of silently ignoring them.

Acceptance: filter ordering and map ownership are explicit, and invalid
combinations produce a preflight explanation before encoding starts.

### 3.3 Centralize settings access

- Wrap `UserDefaults` keys in feature-scoped settings types with defaults and
  migrations.
- Inject settings into logic under test rather than reading global defaults inside
  command builders and services.
- Keep machine-specific paths, bookmarks, and credentials outside synced settings.

Acceptance: tests do not mutate the user's defaults, and a settings schema change
has an explicit migration test.

## Priority 4 — Accessibility, localization, and product polish

Target: parallelizable once stable identifiers are introduced.

### 4.1 Audit the primary flows with VoiceOver and keyboard-only input

- Queue import/reorder/remove, preset selection, conversion controls, progress and
  errors, trim/crop, metadata, downloads/uploads, screen capture, and Settings.
- Label icon-only controls, expose state/value changes, define logical focus order,
  and provide identifiers for automated tests.
- Verify custom timeline, crop, audio meter, and AppKit bridge controls provide a
  useful accessibility representation.

Acceptance: all primary flows are completable without a pointer and have no
unlabeled interactive controls in Accessibility Inspector.

### 4.2 Close the localization gap

- Classify the 87 Norwegian-missing entries as user-facing text, intentional
  format tokens, or App Intent phrases.
- Translate user-facing text and validate interpolation/plural variants.
- Add a catalog check to CI and capture screenshots in English and Norwegian for
  the main window and every Settings pane.

Acceptance: CI reports no unclassified user-facing strings missing Norwegian, and
both locales fit without clipped controls.

### 4.3 Finish broadcast-grade screen-recording rates

- Offer explicit 25, 29.97, 50, and 59.94 choices if professional PAL/NTSC delivery
  is the goal; keep display-native Auto separate.
- Use rational frame durations rather than representing every rate as an integer.
- Add drop-frame timecode for 29.97/59.94 and verify midnight rollover behavior.
- State clearly which presets are CFR and which intentionally remain VFR.

Acceptance: `avg_frame_rate`, `r_frame_rate`, duration, frame count, and timecode
match the selected rate in generated validation recordings.

### 4.4 Improve first-run and dependency diagnostics

- Provide one Tools/Diagnostics view for bundled, Homebrew, and custom binaries,
  including version, architecture, executable status, and a test action.
- Keep copyable Homebrew commands and explain when the bundled tool is sufficient.
- Warn before a conversion when a selected feature depends on a missing or
  incompatible optional tool.

Acceptance: users can diagnose a missing tool without reading logs or opening
Terminal unless installation itself requires it.

## Priority 5 — Release and dependency hygiene

Target: before the next public release, then automate.

- Inventory bundled executables and dylibs; remove anything unreachable from the
  shipping app after dependency verification.
- Generate a version/checksum/license manifest for bundled tools.
- In the release script, verify architectures, dynamic-library resolution,
  executable permissions, code signatures, notarization, Sparkle signature, and
  appcast contents.
- Run a clean-machine smoke test for direct-download and Homebrew installations,
  including update behavior.
- Measure compressed download size and launch/import memory before and after binary
  cleanup; optimize only with measured evidence.

Acceptance: a release fails early when a binary, license, signature, architecture,
or update artifact is inconsistent.

## Suggested delivery sequence

1. Green the failing crop test with fixture-backed expected behavior.
2. Add CI and the first command/file-safety test matrix.
3. Introduce accessibility identifiers while replacing the placeholder UI test.
4. Add the subprocess runner and migrate one tool path at a time.
5. Extract architectural seams under the new tests.
6. Complete accessibility/localization and rational screen-recording rates.
7. Automate the release/dependency audit.

Every milestone should update this document, record tests run, and move shipped
user-visible changes into `CHANGELOG.md`.
