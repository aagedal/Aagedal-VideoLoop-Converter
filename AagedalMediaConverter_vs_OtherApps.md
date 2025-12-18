# Why chose Aagedal Media Encoder?
The reason I made Aagedal Media Converter was because I found a lot of them to be too complex for normal non-technical users. But I also needed some specific features and presets.
Initially the only preset in the app was the VideoLoop preset, that was intended to solve the problem where I need a high quality animated image for a web site, but every mainstream NLE creates a file that is too large with low quality. The obvious solution was using the x264 encoder.

In addition there is the unique features like the ability to quickly add a comment to the metadata. Such as preserving information about the photographer without having to add an overlay to the image itself.

## vs. Shutter Encoder
[Shutter Encoder](https://www.shutterencoder.com/) is probably the most feature rich media encoding software out there. If you are missing some features in Aagedal Media Converter, you could try that.
Shutter Encoder is a great app with tons of features, and unlike Aagedal Media Converter it is available on Linux and Windows.

The downside of Shutter encoder is that it is slow to launch, and the UI feels slow, dated and complex.

Unlike Shutter Encoder it is also possible in Aagedal Media Converter to do merging at the same time as trimming and cropping (the first clip in the queue is the master for the crop). Merge in Shutter Encoder cannot be combined with trim and crop.

#### Launch Times
Shutter Encoder: 3s – 4s

Aagedal Media Converter: 0,5s – 1s

_Tested on M1 Max with macOS 26.2, 18. des. 2025. Shutter Encoder 19.7 and Aagedal Media Converter 3.0.1_

#### Idle RAM use
Shutter Encoder: 240MB

Aagedal Media Converter: 97MB

_Tested on M1 Max with macOS 26.2, 18. des. 2025. Shutter Encoder 19.7 and Aagedal Media Converter 3.0.1_


## vs. Handbrake
[Handbrake](https://handbrake.fr/)'s UI feels better to me than Shutter Encoder, and it is better for ripping DVDs and manually selecting compression settings, but still feels too complex.
Aagedal Media Converter is simpler to start using.
I also find that batch converting in Handbrake is less intuitive, and as far as I know it does not have a Watch Folder feature.

#### Launch Times
Handbrake: 2s - 3s

Aagedal Media Converter: 0,5s – 1s

_Tested on M1 Max with macOS 26.2, 18. des. 2025. Handbrake 1.10.2 and Aagedal Media Converter 3.0.1_

#### Idle RAM use
Handbrake: 57,6MB

Aagedal Media Converter: 97MB

_Tested on M1 Max with macOS 26.2, 18. des. 2025. Handbrake 1.10.2 and Aagedal Media Converter 3.0.1_


### vs. DaVinci Resolve
Blackmagic Design's [DaVinci Resolve](https://www.blackmagicdesign.com/products/davinciresolve) is also a great piece of software. The fact that this professional software can be used for free is amazing!
But as with the other apps compared here, this too is too complex for most users and it is slow to launch. Also DaVinci Resolve has a worse H.264 encoder, resulting in either larger files or worse quality. It does not have a watch folder feature for automatic encoding. And it doesn't support all the codecs that Aagedal Media Converter (FFMPEG) supports.

I think Aagedal Media Converter is a good app to use in tandem with Resolve; for converting files not supported by Resolve to a format that Resolve supports.

#### Launch Times
DaVinci Resolve Studio: 6s - 12s

Aagedal Media Converter: 0,5s – 1s

_Tested on M1 Max with macOS 26.2, 18. des. 2025. Handbrake 1.10.2 and Aagedal Media Converter 3.0.1_

#### Idle RAM use
DaVinci Resolve Studio: 1340MB (project picker)

DaVinci Resolve Studio: 1500MB (empty timeline)

Aagedal Media Converter: 97MB

_Tested on M1 Max with macOS 26.2, 18. des. 2025. Handbrake 1.10.2 and Aagedal Media Converter 3.0.1_



### vs. FFMPEG (CLI)
Aagedal Media Converter is like many other apps powered by [FFMPEG](https://www.ffmpeg.org/) and would not be possible without the existence of FFMPEG. If you are comfortable with the terminal and only need to convert a few files from time to time, then FFMPEG CLI may be just as easy to use.
The benefit of Aagedal Media Converter here is that it can store a number of FFMPEG commands in addition to the hardcoded presets. This in addition to the batch conversion feature and the watch folder makes it easy to use.

FFMPEG has unbeatable launchtime and RAM usage, and is not tested.


## Downsides of Aagedal Media Converter?

#### Lack of features
It is obviously not as feature rich as Shutter Encoder, and doesn't have all the settings that Handbrake has.
More features will likely be added, but the core app should always be easy to understand and use, with good default settings and few presets.
The last thing I want is for my app to feel overwhelming for new users. There is a high bar for adding new featurs to the main app window, and perhaps I have added too much already.

#### Multiple playback engines
There is also an issue that Aagedal Media Converter uses 3 different processing paths to play files: AVPlayer, VLCKit, and ffmpeg chunk rendering feeded into a dynamic AVPlayer item. This causes inconsistent playback performance. The worst experience is the chunk based player.
Ideally all codecs should be supported natively by AVPlayer, as this is the smoothest engine with native support for reverse playback. I assume VVC will be added in the future to both VLCKit and to AVPlayer. The question is when.
I have been looking in to using mpv instead of VLCKit, but I failed to make it work when I last tried.

#### List scroll performance
In addition there is also a known issue with lag when scrolling in the main window. This _may_ be an issue with SwiftUI itself. This is usually only a problem when scrolling a large number of files, but I don't consider it very problematic even if it is annoying.
I will be looking into improving this, but it is not my top priority.
