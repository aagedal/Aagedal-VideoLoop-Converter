# TODO and Known Issues – Things I want to fix or improve

> This is the historical feature checklist. The prioritized, evidence-backed
> roadmap is in [IMPROVEMENT_PLAN.md](IMPROVEMENT_PLAN.md).


## General
[x] Settings: Fix UI inconsistencies between subviews.
[x] Fix missing Norwegian translations.


## Main App Window
[x] Improve scrolling performance for long encoding queues.

## Presets
[x] Preset Settings Vew: Fix missing preset descriptions

## Screen Recording
[x] Growing screen-recording presets use constant frame rate at Auto, 50 fps (PAL),
or 60 fps (NTSC); non-growing presets intentionally remain variable frame rate.
Explicit 25/29.97/50/59.94 broadcast rates and drop-frame timecode are tracked in
`IMPROVEMENT_PLAN.md` §4.3.

## Full Screen Player
[x] Full Screen Playback: Fix it so that the Auto Next feature automatically plays next video, instead of the next video starting paused.
[x] Full Screen Playback: Fix issues where Auto Next doesn't always work.


## Metadata View
[x] Metadata view - both: Separate camera metadata from C2PA metadata.
[x] Merge the single and multi metadata view into a single metadata view.


## Downloads
[x] Downloads Overlay View: Make it clearer that the Downloads Overlay automatically copies the clipboard. Small clipboard icon animation next to the text field. 
[x] Downloads Overlay View:Fix an issue where it was possible to enter a long multi-line text into the Download URL input. Filter first line and validate that it is a URL.
[x] Improve the Downloads Homebrew install guide: show a copyable
`brew install yt-dlp` command instead of only linking to the website. Homebrew
installation remains a manual Terminal step.


## GitHub
[x] Update KeyboardShortcuts.md with new keyboard shortcuts: Downloads, Uploads, Full Screen
