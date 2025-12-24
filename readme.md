# Aagedal Media Converter

A lightweight minimalist macOS application that is simple on the surface, but with powerful features baked in. Powered by FFMPEG, FFPROBE and MPV under the hood and written entirely in Swift / SwiftUI.

Completely free and open source. Sandboxed, private and local. (An optional update checker is activated by default, but it can be turned off.)

A passion project; I made this for myself, I just wanted to share.

Note that most of this app is vibe-coded.

<img width="1062" height="575" alt="SCR-20251217-npcv-2" src="https://github.com/user-attachments/assets/1ae1a20d-ed3b-4e86-8b64-9b02ba79344c" />


---

## Installation

### Homebrew
```bash
brew tap aagedal/casks && brew install --cask aagedal-media-converter
```

### Manual download
[Latest version (3.3.0)](https://github.com/aagedal/Aagedal-Media-Converter/releases/download/v.3.3.0/Aagedal-Media-Converter_3-3-0.zip)


---


## Key Features

### General
- Launches quickly and is lightweight
- Can play and encode almost every video file that exists (VLC and FFMPEG backend)
- Minimalist and easy to understand
- Advanced features available if you need it
- Batch conversion, watch folder, progress bar, 
- Trim, crop, reroute or remove audio tracks, merge clips (if in the same format)
- Metadata comparison
- Lots of shortcuts: most features are accessible without using a mouse
- Lots of settings if you want to customize
- Language support: English and Norwegian
- Automatically check for updates with a subtle update notification, can be turned off.

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
- Invisible fallback to MPVKit player for files not supported by macOS natively (though reverse playback is less reliable)


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
- Optional date tag (Generated [YYYYMMDD]), prefix and suffix in the comment field before the comment.
- View and compare metadata

### 15-Second Autoplay Warning for VideoLoop presets
Web browsers often refuse to autoplay long, looping videos with sound. The app shows a yellow ⚠️ icon when the VideoLoop presets are applied to clips longer than 15 seconds, encouraging you to trim the video or pick another preset.

### App Intents
1. Add to Encode Cue
2. Convert Video Immediately (using the default preset).


## Export Presets
All presets can be set as default on launch, and all except the default can be hidden from the preset selector.

#### Video Loop
x264 very slow 1080p max resolution, keeping original aspect ratio, removing all audio channels, nice for compact web distribution such as GIF-replacements, slow export.
Automatic duration warning if a VideoLoop clip exceeds 15s (short videos are best for auto-playing and looping on webpages)
  
#### Video Loop w/ Audio
Same as above but keeping a stereo AAC track.

#### H.264 / AVC
Generic H.264 codec, with lots of options to change quality and chose between software or hardware encoding. Container and audio format is also adjustable.

#### H.265 / HEVC
Generic H.264 codec, with lots of options to change quality and chose between software or hardware encoding. Container and audio format is also adjustable.

#### AV1
Generic H.264 codec, with lots of options to change quality. Container and audio format is also adjustable.

#### TV (HEVC 10-bit 4:2:2)
HEVC hardware encoding for fast high quality exports, compatible with most editing software, 10-bit 4:2:2, limit short side resolution to either 1080p or 2160p.

#### TV (AVC-Intra)
Limits the aspect ratio to 16:9, with options for resolution, frame rate and audio channels.

#### Stream copy
Copy the input codecs into a new file, most useful when combined with merge or trim as it will keep the same file extension as the source. Keeps extra metadata. Compatible with trimming, timecode adjustments and merging, but not cropping.

#### ProRes
High quality file maintaining original resolution. The default ProRes version can be set in the Preset Settings Menu.

#### Proxy
Make edit proxies in ProRes Proxy, DNxHR, or HEVC. Tips: Useful if combined with the option to export in a "Proxy" sub-folder next to originals.

#### Animated Stills
Option to chose between AVIF, GIF and Animated PNG.

#### HEVC Proxy 1080p
Compact proxy file format, 10-bit 4:2:0, can be used fast file sharing

#### Audio Only AAC
Extract a small stereo audio file from video

#### Audio Only WAV
Extract uncompressed audio from video, keeping all audio channels

#### 10 Custom FFMPEG presets
If you don't like my presets you can make your own and give them a name. There is a toggle to apply crop and audio routing, but -copy won't work with those features.



## Screenshots

#### Main window
<img width="1124" height="1037" alt="SCR-20251217-novq" src="https://github.com/user-attachments/assets/14a6506b-528b-4573-ba3e-14d64c240b70" />

#### Trim View
![SCR-20251217-npls](https://github.com/user-attachments/assets/fb6bf721-66d9-445d-97eb-ffd1334deadc)

#### Crop view
![SCR-20251217-nptb](https://github.com/user-attachments/assets/97745a95-7bda-43bf-873a-bd865e886690)

#### Audio rerouting
<img width="702" height="535" alt="SCR-20251217-nqcb" src="https://github.com/user-attachments/assets/b7f0ab61-a6f1-4f90-8ec6-2f90b05c6022" />


#### Metadata view
<img width="522" height="522" alt="SCR-20251217-nqgb" src="https://github.com/user-attachments/assets/bb8bfbba-0cf2-4387-a750-53367951ec8c" />


#### Timecode override view
<img width="522" height="402" alt="SCR-20251217-nqlo" src="https://github.com/user-attachments/assets/7c3d951d-9bbb-402c-9984-2fe46fa7d713" />


#### Settings view
<img width="642" height="650" alt="SCR-20251217-nokk" src="https://github.com/user-attachments/assets/e5dd5a16-a052-45a5-8a12-8b529ecbe1b5" />

#### Full screen player
![SCR-20251217-nrlx](https://github.com/user-attachments/assets/832317e5-17ad-4063-9a36-dc1b5c510b22)



---

## Keyboard shortcuts


#### Main Window
Command + I to open import dialogue

Command + Enter → Start Encoding

Command + Backspace → Remove current clip from encoding queue

Tab → Select metadata comment text field of the first clip, or cycle to the next clip if a clip is already selected

Shift + Tab → Select metadata comment text field of the last clip, or cycle to the previous clip if a clip is already selected

Command + , → Open Settings

Arrow Up/Down to move between items

Hold Command while pressing Up/Down to move the selected item(s) up or down in the queue

Command + Backspace removes selected items from the queue

Comand + R resets the conversion status of the selected items.

Command + Shift + R resets conversion status of all items in the queue

Option + W toggles watch folder (if no watch folder is selected you will be asked for one)

Option + M toggles merging of clips (only available if all input files are in the same format)

Command + , opens Settings


#### Single item selected in main window
CMD + T opens trim view

Option + T opens Timecode override view

Option + A opens Audio Rerouting view

Option + I opens metadata view

F opens full screen player

Tab activates focus on the commend field

CMD + D toggles the metadata date tag

#### Trim view
I/O to set in and out point

JKL to play backwards, play/pause, play forwards (like in most NLEs)

Space also toggles play/pause

Arrow left/right, goes to previous/next frame

Command + L toggles loop mode (only available for the native AVPlayer for technical reasons)

Command + A toggles audio meter

C enters crop tool

+ / - before a number jumps that many seconds back/forward when pressing enter, full timecode input is also possible if you want to jump a specific number of hours, minutes, seconds and frames forward, 

Starting to write any number activates timecode input, press enter to jump to the entered timecode


### Any overlay view
Esc to close the overlay (settings are automatically saved)


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


---

## Known issues
- Lagging scrolling when many items are queued. Seems to maybe be an issue with SwiftUI.
- Some UI differences in the trim view if using macOS 15 (renders correctly in macOS 26)

---

## Future ideas (under consideration, no promises)
1. yt-dlp video downloader with built in yt-dlp updater
2. Add option to download whisper binary + model for transcribing audio to srt.
3. Per item preset adjustment?
4. Save/export encoding queue with settings as json/yaml
5. Import/Export app settings as json/yaml
6. Auto upload to server after export? RCLONE?



Note that this is a sparetime project. I this is a passion project I don't get paid for.

---

## License

This project is distributed under the **GNU General Public License, version 3.0**. See the [LICENSE](LICENSE) file for the complete text.

The bundled FFmpeg binary is compiled with `--enable-gpl` and is therefore also licensed under **GPL v2 or later**. This project chooses GPL v3 for all code, satisfying that requirement. See the original FFmpeg license in [Licenses/ffmpeg-LICENSE.txt](Licenses/ffmpeg-LICENSE.txt).

---

PS! This app was previously called Aagedal VideoLoop Converter. Aagedal Media Converter is the same app, just with a new name that better reflects what it has become.
