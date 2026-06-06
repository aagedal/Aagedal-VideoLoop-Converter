import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

// Usage: grow_avwriter <outPath> <seconds> <fps> <codec:h264|hevc> <tracks:v|va|vat>
//   v=video only, va=video+audio, vat=video+audio+timecode
// Produces a GROWING fragmented QuickTime .mov via AVAssetWriter, mirroring
// JustInMac's structure, to find what makes Resolve register it as growing.
let a = CommandLine.arguments
let outPath = a.count > 1 ? a[1] : NSHomeDirectory() + "/Movies/grow_avwriter.mov"
let seconds = a.count > 2 ? (Double(a[2]) ?? 30) : 30
let fps = a.count > 3 ? (Int32(a[3]) ?? 50) : 50
let codecArg = a.count > 4 ? a[4].lowercased() : "h264"
let tracksArg = a.count > 5 ? a[5].lowercased() : "vat"
let useHEVC = codecArg == "hevc" || codecArg == "h265"
let useProRes = codecArg.contains("prores")
let wantAudio = tracksArg.contains("a")
let wantTimecode = tracksArg.contains("t")
let width = 1920, height = 1080
let audioRate = 48000.0

// Starting timecode: default = wall-clock time of day (so Resolve clearly shows it
// read OUR timecode rather than counting from zero). Override with arg6 "HH:MM:SS:FF".
func framesFor(_ h: Int, _ m: Int, _ s: Int, _ fr: Int) -> Int { ((h*3600)+(m*60)+s)*Int(fps)+fr }
func fmtTC(_ frames: Int) -> String {
    let q = Int(fps); return String(format: "%02d:%02d:%02d:%02d", frames/(q*3600), (frames/(q*60))%60, (frames/q)%60, frames%q)
}
let tcArg = a.count > 6 ? a[6] : "tod"
let tcStart: Int
if tcArg.contains(":") {
    let p = tcArg.split(separator: ":").map { Int($0) ?? 0 }
    tcStart = framesFor(p.count>0 ? p[0]:0, p.count>1 ? p[1]:0, p.count>2 ? p[2]:0, p.count>3 ? p[3]:0)
} else {
    let c = Calendar.current.dateComponents([.hour,.minute,.second,.nanosecond], from: Date())
    tcStart = framesFor(c.hour ?? 0, c.minute ?? 0, c.second ?? 0, Int(Double(c.nanosecond ?? 0)/1e9 * Double(fps)))
}

let url = URL(fileURLWithPath: outPath)
try? FileManager.default.removeItem(at: url)
// Container chosen from output extension: .mp4 -> isom (Blackmagic-style), else .mov -> qt (JustInMac-style)
let fileType: AVFileType = url.pathExtension.lowercased() == "mp4" ? .mp4 : .mov
guard let writer = try? AVAssetWriter(outputURL: url, fileType: fileType) else { fatalError("no writer") }
print(">>> container=\(fileType.rawValue)")
writer.movieFragmentInterval = CMTime(value: 1, timescale: 1)   // fragmented (growing) output

// --- video ---
let codecType: AVVideoCodecType = useProRes ? .proRes422LT : (useHEVC ? .hevc : .h264)
var vsettings: [String: Any] = [
    AVVideoCodecKey: codecType, AVVideoWidthKey: width, AVVideoHeightKey: height
]
if !useProRes {   // ProRes is intra-only: no bitrate / profile / reordering keys
    var comp: [String: Any] = [
        AVVideoAverageBitRateKey: 12_000_000,
        AVVideoMaxKeyFrameIntervalKey: Int(fps),
        AVVideoAllowFrameReorderingKey: false
    ]
    if !useHEVC { comp[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel }
    vsettings[AVVideoCompressionPropertiesKey] = comp
}
// Add the descriptive atoms JustInMac has (colr/pasp/clap) — a real capture carries these.
vsettings[AVVideoColorPropertiesKey] = [
    AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
    AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
    AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
]
vsettings[AVVideoPixelAspectRatioKey] = [
    AVVideoPixelAspectRatioHorizontalSpacingKey: 1,
    AVVideoPixelAspectRatioVerticalSpacingKey: 1
]
vsettings[AVVideoCleanApertureKey] = [
    AVVideoCleanApertureWidthKey: width, AVVideoCleanApertureHeightKey: height,
    AVVideoCleanApertureHorizontalOffsetKey: 0, AVVideoCleanApertureVerticalOffsetKey: 0
]
let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: vsettings)
videoInput.expectsMediaDataInRealTime = true
let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
    kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height
])
writer.add(videoInput)

// --- audio (silent LPCM) ---
var audioInput: AVAssetWriterInput?
var audioFormat: CMAudioFormatDescription?
if wantAudio {
    var asbd = AudioStreamBasicDescription(mSampleRate: audioRate, mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
        mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 2,
        mBitsPerChannel: 16, mReserved: 0)
    CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil,
        magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &audioFormat)
    let ai = AVAssetWriterInput(mediaType: .audio, outputSettings: [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: audioRate, AVNumberOfChannelsKey: 2,
        AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false
    ])
    ai.expectsMediaDataInRealTime = true
    writer.add(ai); audioInput = ai
}

// --- timecode track ---
var tcInput: AVAssetWriterInput?
var tcFormat: CMTimeCodeFormatDescription?
if wantTimecode {
    CMTimeCodeFormatDescriptionCreate(allocator: kCFAllocatorDefault,
        timeCodeFormatType: kCMTimeCodeFormatType_TimeCode32,
        frameDuration: CMTime(value: 1, timescale: fps), frameQuanta: UInt32(fps),
        flags: 0, extensions: nil, formatDescriptionOut: &tcFormat)
    let ti = AVAssetWriterInput(mediaType: .timecode, outputSettings: nil, sourceFormatHint: tcFormat)
    ti.expectsMediaDataInRealTime = true
    writer.add(ti)
    if videoInput.canAddTrackAssociation(withTrackOf: ti, type: AVAssetTrack.AssociationType.timecode.rawValue) {
        videoInput.addTrackAssociation(withTrackOf: ti, type: AVAssetTrack.AssociationType.timecode.rawValue)
    }
    tcInput = ti
}

guard writer.startWriting() else { fatalError("startWriting: \(String(describing: writer.error))") }
writer.startSession(atSourceTime: .zero)
print(">>> \(useProRes ? "ProRes422LT" : (useHEVC ? "HEVC" : "H.264")) tracks=\(tracksArg) startTC=\(fmtTC(tcStart)) -> \(outPath)")

// Append one timecode sample PER FRAME so the tmcd track keeps fragmenting like
// JustInMac (trackID 3 in every moof) and mvhd stays pinned to the first segment.
func appendTimecode(frame: Int) {
    guard let ti = tcInput, let fmt = tcFormat, ti.isReadyForMoreMediaData else { return }
    var fn = UInt32(tcStart + frame).bigEndian
    var block: CMBlockBuffer?
    CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: 4,
        blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: 4,
        flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
    withUnsafeBytes(of: &fn) { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block!, offsetIntoDestination: 0, dataLength: 4) }
    var sample: CMSampleBuffer?
    var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: fps),
        presentationTimeStamp: CMTime(value: Int64(frame), timescale: fps), decodeTimeStamp: .invalid)
    var sz = 4
    CMSampleBufferCreate(allocator: nil, dataBuffer: block, dataReady: true,
        makeDataReadyCallback: nil, refcon: nil, formatDescription: fmt, sampleCount: 1,
        sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1,
        sampleSizeArray: &sz, sampleBufferOut: &sample)
    if let s = sample { ti.append(s) }
}

let totalFrames = Int(seconds * Double(fps))
let frameDur = 1.0 / Double(fps)
let audioPerFrame = Int(audioRate) / Int(fps)   // 960 @ 48k/50
let start = Date()
var frame = 0
while frame < totalFrames {
    if !videoInput.isReadyForMoreMediaData { usleep(2000); continue }
    if let pool = adaptor.pixelBufferPool {
        var pbo: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pbo)
        if let pb = pbo {
            CVPixelBufferLockBaseAddress(pb, [])
            if let base = CVPixelBufferGetBaseAddress(pb) {
                let bpr = CVPixelBufferGetBytesPerRow(pb)
                let p = base.assumingMemoryBound(to: UInt8.self)
                for y in 0..<height { memset(p + y*bpr, Int32(UInt8((y + frame*3) & 0xFF)), bpr) }
            }
            CVPixelBufferUnlockBaseAddress(pb, [])
            adaptor.append(pb, withPresentationTime: CMTime(value: Int64(frame), timescale: fps))
        }
    }
    // silent audio for this frame
    if let ai = audioInput, let fmt = audioFormat, ai.isReadyForMoreMediaData {
        let bytes = audioPerFrame * 4
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes,
            blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: bytes,
            flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
        CMBlockBufferFillDataBytes(with: 0, blockBuffer: block!, offsetIntoDestination: 0, dataLength: bytes)
        var sample: CMSampleBuffer?
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: Int32(audioRate)),
            presentationTimeStamp: CMTime(value: Int64(frame * audioPerFrame), timescale: Int32(audioRate)),
            decodeTimeStamp: .invalid)
        CMSampleBufferCreate(allocator: nil, dataBuffer: block, dataReady: true,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: fmt, sampleCount: audioPerFrame,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 0,
            sampleSizeArray: nil, sampleBufferOut: &sample)
        if let s = sample { ai.append(s) }
    }
    appendTimecode(frame: frame)
    frame += 1
    let target = start.addingTimeInterval(Double(frame) * frameDur)
    if target > Date() { Thread.sleep(until: target) }
}
videoInput.markAsFinished()
audioInput?.markAsFinished()
tcInput?.markAsFinished()
let sem = DispatchSemaphore(value: 0)
writer.finishWriting { sem.signal() }
sem.wait()
print(">>> done status=\(writer.status.rawValue)")
