import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

// Usage: grow_avwriter <outPath> <seconds> <fps> <codec:h264|hevc> <tracks:v|va|vat>
//   v=video only, va=video+audio, vat=video+audio+timecode
// Produces a GROWING fragmented QuickTime .mov via AVAssetWriter, mirroring
// LiveProResRef's structure, to find what makes Resolve register it as growing.
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

// --- Growing-file detection experiment flags (see FINDINGS.md §0.2) ---
// Toggle structural differences vs the RefRecorder reference to find what makes
// Resolve show the red "REC" growing overlay. Combine freely, e.g. META=1 NO_TREF=1 ...
let envFlags = ProcessInfo.processInfo.environment
let addMeta  = envFlags["META"]    != nil   // add moov-level meta (manufacturer/software tags)
let noTref   = envFlags["NO_TREF"] != nil   // omit video->timecode tref association
let ts50000  = envFlags["TS50000"] != nil   // drive video media timescale at 50000 (else = fps)
// Vendor-whitelist probe values (override at runtime; neutral defaults so nothing is committed):
let metaManufacturer = envFlags["META_MANUF"] ?? "Aagedal Media Converter"
let metaSoftware     = envFlags["META_SOFT"]  ?? "Aagedal Media Converter"
let vts: Int32 = ts50000 ? 50000 : fps      // video presentation timescale
let vscale: Int64 = Int64(vts / fps)        // ticks per frame (1 when vts==fps)
// THE growing-file trigger (FINDINGS.md §0.3): a Blackmagic xattr on the MAIN file.
// Resolve shows the red REC overlay + fast refresh for files carrying this while
// recording. Removed on stop (a finished file carries no such xattr). On by default.
let noXattr = envFlags["NO_XATTR"] != nil
let recordingXattrName = "com.blackmagicdesign.metadata:recording"
let recordingUUID = UUID().uuidString.replacingOccurrences(of: "-", with: "").uppercased()
func setRecordingXattr(_ path: String, recording: Bool) {
    let json = "{\"r\":\(recording ? 1 : 0), \"uuid\":\"\(recordingUUID)\"}"
    let bytes = Array(json.utf8)
    _ = bytes.withUnsafeBytes { setxattr(path, recordingXattrName, $0.baseAddress, bytes.count, 0, 0) }
}
func clearRecordingXattr(_ path: String) { _ = removexattr(path, recordingXattrName, 0) }

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
// Container chosen from output extension: .mp4 -> isom (Blackmagic-style), else .mov -> qt (LiveProResRef-style)
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
// Add the descriptive atoms LiveProResRef has (colr/pasp/clap) — a real capture carries these.
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
    if !noTref, videoInput.canAddTrackAssociation(withTrackOf: ti, type: AVAssetTrack.AssociationType.timecode.rawValue) {
        videoInput.addTrackAssociation(withTrackOf: ti, type: AVAssetTrack.AssociationType.timecode.rawValue)
    }
    tcInput = ti
}

// ============================================================================
// Live "DaVinci Resolve growing file" sidecar (.X.mov).
// Tails the qt fragmented main this tool writes and produces the hidden
// fMP4 index Resolve polls. Recipe (FINDINGS.md §0.1): ftyp(iso5) + transformed
// moov (drop minf-level hdlr, dref alis->external url "basename") + every moof
// copied VERBATIM (AVAssetWriter already writes absolute base_data_offsets).
// Mirrors tools/gen_sidecar.py, but incremental/live.
// ============================================================================
final class SidecarTailer: @unchecked Sendable {
    private let mainURL: URL
    private let sideURL: URL
    private let basename: [UInt8]
    private let q = DispatchQueue(label: "sidecar.tail")
    private var cursor: UInt64 = 0
    private var wroteInit = false
    private var running = true
    private var fhWrite: FileHandle?
    private(set) var moofCount = 0

    init(mainURL: URL) {
        self.mainURL = mainURL
        let dir = mainURL.deletingLastPathComponent()
        let name = mainURL.lastPathComponent
        self.sideURL = dir.appendingPathComponent("." + name)
        self.basename = Array(name.utf8)
    }

    func start() { q.async { [self] in
        try? FileManager.default.removeItem(at: sideURL)
        FileManager.default.createFile(atPath: sideURL.path, contents: nil)
        fhWrite = try? FileHandle(forWritingTo: sideURL)
        while running { poll(); usleep(100_000) }
        poll()  // final pass
        try? fhWrite?.close()
    } }

    func stop() { running = false; q.sync {} }   // drain

    // --- minimal box helpers over an in-memory Data slice ---
    private struct Box { let type: String; let off: Int; let size: Int; let hdr: Int }
    private func u32(_ d: Data, _ o: Int) -> Int {
        return (Int(d[o])<<24)|(Int(d[o+1])<<16)|(Int(d[o+2])<<8)|Int(d[o+3])
    }
    private func be32(_ v: Int) -> [UInt8] { [UInt8((v>>24)&0xff),UInt8((v>>16)&0xff),UInt8((v>>8)&0xff),UInt8(v&0xff)] }
    private func children(_ d: Data, _ s: Int, _ e: Int) -> [Box] {
        var out=[Box](); var o=s
        while o < e-8 {
            let sz=u32(d,o); let t=String(bytes:d[o+4..<o+8],encoding:.ascii) ?? "????"; var hs=8; var size=sz
            if sz==1 { // 64-bit
                var v=0; for i in 0..<8 { v=(v<<8)|Int(d[o+8+i]) }; size=v; hs=16
            } else if sz==0 { size=e-o }
            out.append(Box(type:t,off:o,size:size,hdr:hs))
            if size<=0 { break }; o+=size
        }
        return out
    }
    private func box(_ type: String, _ payload: [UInt8]) -> [UInt8] {
        return be32(payload.count+8) + Array(type.utf8) + payload
    }
    private func raw(_ d: Data, _ b: Box) -> [UInt8] { Array(d[b.off..<b.off+b.size]) }

    private func buildDref() -> [UInt8] {
        // url entry: ver/flags=0 (external) + basename (no NUL)
        let urlBox = box("url ", be32(0) + basename)
        let drefPayload = be32(0) + be32(1) + urlBox   // ver/flags, entry_count=1
        return box("dref", drefPayload)
    }
    private func transformMinf(_ d: Data, _ minf: Box) -> [UInt8] {
        var out=[UInt8]()
        for c in children(d, minf.off+minf.hdr, minf.off+minf.size) {
            if c.type == "hdlr" { continue }               // drop data-info handler
            if c.type == "dinf" {
                var din=[UInt8]()
                for g in children(d, c.off+c.hdr, c.off+c.size) {
                    din += (g.type=="dref") ? buildDref() : raw(d,g)
                }
                out += box("dinf", din)
            } else { out += raw(d,c) }
        }
        return box("minf", out)
    }
    private func transformContainer(_ d: Data, _ parent: Box, _ childType: String, _ rebuild: (Box)->[UInt8]) -> [UInt8] {
        var out=[UInt8]()
        for c in children(d, parent.off+parent.hdr, parent.off+parent.size) {
            out += (c.type==childType) ? rebuild(c) : raw(d,c)
        }
        return box(parent.type, out)
    }
    private func transformTrak(_ d: Data, _ trak: Box) -> [UInt8] {
        transformContainer(d, trak, "mdia") { mdia in
            self.transformContainer(d, mdia, "minf") { minf in self.transformMinf(d, minf) }
        }
    }
    private func buildInit(_ d: Data, _ moov: Box) {
        let ftyp = box("ftyp", Array("iso5".utf8) + be32(512) + Array("iso6".utf8) + Array("mp41".utf8))
        var moovOut=[UInt8]()
        for c in children(d, moov.off+moov.hdr, moov.off+moov.size) {
            moovOut += (c.type=="trak") ? transformTrak(d,c) : raw(d,c)
        }
        let initData = ftyp + box("moov", moovOut)
        fhWrite?.write(Data(initData))
        wroteInit = true
    }

    private func poll() {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: mainURL.path),
              let fileSize = (attrs[.size] as? NSNumber)?.uint64Value else { return }
        guard let fh = try? FileHandle(forReadingFrom: mainURL) else { return }
        defer { try? fh.close() }
        while cursor + 8 <= fileSize {
            try? fh.seek(toOffset: cursor)
            guard let hdr = try? fh.read(upToCount: 16), hdr.count >= 8 else { break }
            let h = [UInt8](hdr)
            var size = (Int(h[0])<<24)|(Int(h[1])<<16)|(Int(h[2])<<8)|Int(h[3])
            let type = String(bytes: h[4..<8], encoding: .ascii) ?? "????"
            if size == 1 { guard h.count>=16 else { break }
                size = 0; for i in 0..<8 { size=(size<<8)|Int(h[8+i]) } }
            if size <= 0 { break }
            guard cursor + UInt64(size) <= fileSize else { break }   // box not fully flushed yet
            if type == "moov" || type == "moof" {
                try? fh.seek(toOffset: cursor)
                if let body = try? fh.read(upToCount: size), body.count == size {
                    let boxes = children(body, 0, size)
                    if type == "moov", !wroteInit, let m = boxes.first(where: {$0.type=="moov"}) {
                        buildInit(body, m)
                    } else if type == "moof", wroteInit, let mf = boxes.first(where: {$0.type=="moof"}) {
                        fhWrite?.write(Data(raw(body, mf)))   // verbatim copy
                        moofCount += 1
                    }
                }
            }
            cursor += UInt64(size)
        }
        try? fhWrite?.synchronize()
    }
}

// Optional moov-level metadata (manufacturer/software) — vendor-whitelist probe.
if addMeta {
    func mdItem(_ key: String, _ val: String) -> AVMetadataItem {
        let it = AVMutableMetadataItem()
        it.keySpace = .quickTimeMetadata
        it.key = key as NSString
        it.value = val as NSString
        return it
    }
    writer.metadata = [
        mdItem("com.apple.proapps.manufacturer", metaManufacturer),
        mdItem("com.apple.quicktime.software", metaSoftware)
    ]
    print(">>> meta: manufacturer=\(metaManufacturer) software=\(metaSoftware)")
}
if noTref  { print(">>> NO_TREF: video↔timecode association omitted") }
if ts50000 { print(">>> TS50000: video media timescale = 50000") }

let writeSidecar = !ProcessInfo.processInfo.environment.keys.contains("NO_SIDECAR")
let sidecar = writeSidecar ? SidecarTailer(mainURL: url) : nil

guard writer.startWriting() else { fatalError("startWriting: \(String(describing: writer.error))") }
writer.startSession(atSourceTime: .zero)
if !noXattr { setRecordingXattr(outPath, recording: true); print(">>> xattr \(recordingXattrName) = {\"r\":1, uuid \(recordingUUID)}") }
sidecar?.start()
print(">>> \(useProRes ? "ProRes422LT" : (useHEVC ? "HEVC" : "H.264")) tracks=\(tracksArg) startTC=\(fmtTC(tcStart)) -> \(outPath)")
if writeSidecar { print(">>> sidecar: .\(url.lastPathComponent) (set NO_SIDECAR=1 to disable)") }

// Append one timecode sample PER FRAME so the tmcd track keeps fragmenting like
// LiveProResRef (trackID 3 in every moof) and mvhd stays pinned to the first segment.
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
            adaptor.append(pb, withPresentationTime: CMTime(value: Int64(frame) * vscale, timescale: vts))
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
// Stop the sidecar tailer BEFORE finishWriting consolidates the main to flat
// (consolidation invalidates the sidecar's offsets). Real app behavior: delete
// the sidecar on stop. Here we leave it for inspection but warn it's now stale.
sidecar?.stop()
if let s = sidecar { print(">>> sidecar finalized: \(s.moofCount) moof (valid only while the main was fragmented; main now consolidates to flat)") }
let sem = DispatchSemaphore(value: 0)
writer.finishWriting { sem.signal() }
sem.wait()
if !noXattr { clearRecordingXattr(outPath); print(">>> cleared recording xattr (finished file)") }
print(">>> done status=\(writer.status.rawValue)")
print(">>> NOTE: import the growing .mov into Resolve DURING recording to see it grow; after stop the main is a normal flat clip.")
