# Aagedal Media Converter

A lightweight minimal-ish macOS application for simple batch encoding of video files. Powered by FFMPEG, FFPROBE and VLCKit under the hood and written entirely in Swift / SwiftUI.

Fully private and local. Completely free and open source. No subscriptions or paid add-ons.

A passion project; I made this for myself, I just wanted to share.

Note that most of this app is vibe-coded.


<img width="1161" height="990" alt="SCR-20251110-buqk" src="https://github.com/user-attachments/assets/60eb33ed-786a-4f57-b26c-81d9dc0db51a" />



---

## Installation

### Homebrew
```bash
brew tap aagedal/casks && brew install --cask aagedal-media-converter
```

### Manual download
[Latest version (3.0)](https://github.com/aagedal/Aagedal-Media-Converter/releases/download/v.3.0/Aagedal-Media-Converter_3-0.zip)


---


## Key Features

### General
- Launches quickly
- Can encode almost every file format that exists (FFMPEG 8.0.1 backend)
- Minimal and easy to understand
- Advanced features easily accessible
- Trim, crop

### Batch conversion
- Automatically encode all the files in the queue
- Reorder files by drag and drop to reorder encoding queue
- Delete files from the queue while encoding

### Watch folder
- Automatically import files from a specified folder
- Works along the manual drag and drop window, collecting all encodes into one window
- Optional auto-delete and ignore files in the watch folder
- Activate by pressing the eye-icon in the main window toolbar

### Preview files
- Common NLE shortcuts like JKL and arrow keys
- A simple audio meter (CMD + A)
- Uses native macOS player for compatible files, for smooth playback even in reverse
- Invisible fallback to VLCKit player for files not supported by macOS natively (though reverse playback is less reliable)
- A second fallback for VVC and APV files, using FFMPEG to generate cached chunks to allow previews without encoding the entire file. With automatic cache deletion.


### Quick adjustments
- Trim using UI handles or I/O keyboard shortcut
- Timecode can be copied from the source, set manually or be removed
- Crop the video with on screen controls – accessible in the trim view by pressing C or the crop icon.
    - Does not work with the Stream Copy preset
- Audio Track deletion and rearrangement
    - Does not work with the Stream Copy preset

### Merge queued files
- Merge files into one if they are the same codec, resolution, frame rate, bit depth, and audio tracks.
- The first clip in the queue works as a master for timecode and crop.
- Allows trimming and Copy Stream at the same time, allowing you to trim and merge files without any quality loss. (Some metadata may be lost)

### Generate Audio Waveform Animation
- Generate Audio Waveform Animations for audio only files
- 5 different presets, with color and normalization options

### Quickly Grab Screenshots at source resoltuion and bit depth
In the trim player there is a camera button that allows capturing still images. Images will automatically be captured at source resolution. By default the app will capture screenshots in JPEG XL. Format for screenshots and can be changed in the settings on a per bit-depth basis. Also a setting to specify what to do with alpha-channel video.


### Export and file-naming
- By default the app will remove spaces and special characters. æ, ø, å is replaced with ae, o and aa.
- The app will preview the filename after processing
- Warning if file already exists, 
- After encoding there is an icon to show the converted file in the export directory
- After encoding there is a draggable icon, making it possible to drag and open the encoded file directly in another app to copy to a new directory.

- Set default preset in the settings menu
- Set default export location


### Metadata
- Per file comment field, to add an optional comment to the file metadata. Useful for embedding credit information
- Optional date tag (Generated [YYYYMMDD]) in the comment field before the comment.
- Language support: English and Norwegian
- Automatically check for updates with a subtle update notification, can be turned off.


## Export Presets
  
#### Video Loop
x264 very slow 1080p max resolution, keeping original aspect ratio, removing all audio channels, nice for compact web distribution such as GIF-replacements, slow export.
Automatic duration warning if a VideoLoop clip exceeds 15s (short videos are best for auto-playing and looping on webpages)
  
#### Video Loop w/ Audio
same as above but keeping a stereo AAC track

#### TV Quality HD / 4K
HEVC hardware encoding for fast high quality exports, compatible with most editing software, 10-bit 4:2:2, limit short side resolution to either 1080p or 2160p.

#### Stream copy
Copy the input codecs into a new file, most useful when combined with merge or trim as it will keep the same file extension as the source. Keeps extra metadata. Compatible with trimming, timecode adjustments and merging, but not cropping.

### ProRes
High quality file maintaining original resolution. The default ProRes version can be set in the Preset Settings Menu

#### Animated AVIF
Another GIF-alternative without sound. Doesn't need special web-code to loop, but less hardware and software compatibility than VideoLoops

#### HEVC Proxy 1080p
Compact proxy file format, 10-bit 4:2:0, can be used fast file sharing

#### Audio Only AAC
Extract a small stereo audio file from video

#### Audio Only WAV
Extract uncompressed audio from video, keeping all audio channels

#### 3 Custom FFMPEG presets
If you don't like my presets you can make your own and give them a name. There is a toggle to apply crop and audio routing, but -copy won't work.
  


![SCR-20251110-bulz](https://github.com/user-attachments/assets/b1aba332-0058-480a-8f29-5f7ce5da07c0)
<img width="642" height="594" alt="SCR-20251110-bvdx" src="https://github.com/user-attachments/assets/58504f3c-0e28-41d1-af37-4f109aff96af" />
<img width="642" height="594" alt="SCR-20251110-bvgm" src="https://github.com/user-attachments/assets/209d09ab-ff89-4436-957f-72c01763c0c0" />



---

## Keyboard shortcuts
Command + Enter → Start Encoding

Command + Backspace → Remove current clip from encoding queue

Tab → Select metadata comment text field of the first clip, or cycle to the next clip if a clip is already selected

Shift + Tab → Select metadata comment text field of the last clip, or cycle to the previous clip if a clip is already selected

Command + , → Open Settings

---

## Requirements

|                | Minimum |
|----------------|---------|
| macOS          | 15.0 (Sequoia) or later |
| Hardware       | Apple Silicon (M1 or later) |


---

## Usage

1. Launch the app.
2. Drag video files onto the window **or** click the plus button to import files.
3. Select an **Export Preset** from the toolbar menu.
4. Hit the green *Convert* button or press ⌘⏎.



### 15-Second Autoplay Warning

Web browsers often refuse to autoplay long, looping videos with sound. The app shows a yellow ⚠️ icon when the VideoLoop presets are applied to clips longer than 15 seconds, encouraging you to trim the video or pick another preset.

### App Intents

Not tested with macOS 26 Tahoe, but in macOS 15 you have two available App Shortcuts available in the macOS Shortcuts app:
1. Add to Encode Cue
2. Convert Video Immediately (using the default VideoLoop-preset).

---

## Known issues
– Lagging scrolling when many items are queued. Seems to maybe be an issue with SwiftUI
- Sometimes when using Keyboard shortcuts to open crop, timecode or audio settings for the first item after launch you get a small gray box. (Can be closed with Esc.)

---

## Future ideas
1. Per item preset adjustment.
2. Add more / improve app intents.
3. Replace current fallback player solution with libmpv or similar. Probably a target for version 3.


Note that this is a sparetime project. I this is a passion project I don't get paid for.

---

## License

This project is distributed under the **GNU General Public License, version 3.0**. See the [LICENSE](LICENSE) file for the complete text.

The bundled FFmpeg binary is compiled with `--enable-gpl` and is therefore also licensed under **GPL v2 or later**. This project chooses GPL v3 for all code, satisfying that requirement. See the original FFmpeg license in [Licenses/ffmpeg-LICENSE.txt](Licenses/ffmpeg-LICENSE.txt).

---

PS! This app was previously called Aagedal VideoLoop Converter. Aagedal Media Converter is the same app, just with a new name that better reflects what it has become.
