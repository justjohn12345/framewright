// Generates the deterministic media files used by the media backend conformance tests.
//
//   swift Scripts/make_test_media.swift <output-directory>
//
// EngineTests runs this itself (see EngineTests/Media/TestMedia.mm) and caches the output in
// the build directory, keyed by a hash of this file, so edit freely: the next test run
// regenerates.
//
// Video burn-in (decoded by EngineTests/Media/BurnIn.h; keep the two in sync):
//   cell = width / 18. Square i (i = 0..15) covers
//     x in [round((i + 1) * cell), round((i + 2) * cell)), y in [round(0.5 * cell), round(1.5 * cell))
//   and is white when bit (15 - i) of the frame index is set (MSB first), black otherwise.
//   The rest of the frame is palette[index % 8] (all mid-luma colours, see `palette`).
// Audio: 0.1 * sin(2 pi f t) (per-file f) on every channel, plus a beep
//   0.7 * sin(2 pi 1000 (t - 2.0)) for 2.000 s <= t < 2.100 s.
// Every file's parameters are also written to manifest.json.

import AVFoundation
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers

let palette: [(r: UInt8, g: UInt8, b: UInt8)] = [
    (180, 60, 60), (60, 150, 60), (60, 60, 200), (170, 150, 40),
    (40, 150, 160), (150, 60, 160), (110, 110, 110), (200, 110, 50),
]

let beepStart = 2.0
let beepDuration = 0.1
let beepFrequency = 1000.0
let beepAmplitude: Float = 0.7
let toneAmplitude: Float = 0.1

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(("make_test_media: " + message + "\n").data(using: .utf8)!)
    exit(1)
}

// MARK: - Burn-in

/// Draws frame `index` into a BGRA buffer (base address, bytes per row, size).
func drawBurnIn(index: Int, base: UnsafeMutableRawPointer, bytesPerRow: Int, width: Int, height: Int) {
    let bg = palette[index % palette.count]
    let cell = Double(width) / 18.0
    var bgRow = [UInt8](repeating: 0, count: width * 4)
    for x in 0..<width {
        bgRow[x * 4 + 0] = bg.b
        bgRow[x * 4 + 1] = bg.g
        bgRow[x * 4 + 2] = bg.r
        bgRow[x * 4 + 3] = 255
    }
    var squareRow = bgRow
    for i in 0..<16 {
        let x0 = Int((Double(i + 1) * cell).rounded())
        let x1 = Int((Double(i + 2) * cell).rounded())
        let bit = (index >> (15 - i)) & 1
        let v: UInt8 = bit == 1 ? 255 : 0
        for x in x0..<min(x1, width) {
            squareRow[x * 4 + 0] = v
            squareRow[x * 4 + 1] = v
            squareRow[x * 4 + 2] = v
        }
    }
    let y0 = Int((0.5 * cell).rounded())
    let y1 = Int((1.5 * cell).rounded())
    bgRow.withUnsafeBytes { bgBytes in
        squareRow.withUnsafeBytes { sqBytes in
            for y in 0..<height {
                let src = (y >= y0 && y < y1) ? sqBytes : bgBytes
                memcpy(base + y * bytesPerRow, src.baseAddress!, width * 4)
            }
        }
    }
}

/// Sets the alpha byte of the left half of a BGRA frame (colour stays straight, unmultiplied:
/// the ProRes 4444 alpha convention).
func setLeftHalfAlpha(_ alpha: UInt8, base: UnsafeMutableRawPointer, bytesPerRow: Int, width: Int, height: Int) {
    for y in 0..<height {
        let row = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
        for x in 0..<(width / 2) { row[x * 4 + 3] = alpha }
    }
}

// MARK: - Audio

func audioSample(frame: Int, rate: Double, frequency: Double) -> Float {
    let t = Double(frame) / rate
    var v = toneAmplitude * Float(sin(2.0 * Double.pi * frequency * t))
    let beepFirst = Int((beepStart * rate).rounded())
    let beepEnd = beepFirst + Int((beepDuration * rate).rounded())
    if frame >= beepFirst && frame < beepEnd {
        v += beepAmplitude * Float(sin(2.0 * Double.pi * beepFrequency * Double(frame - beepFirst) / rate))
    }
    return v
}

final class AudioSource {
    let rate: Double
    let channels: Int
    let frequency: Double
    let totalFrames: Int
    private(set) var written = 0
    private let format: CMAudioFormatDescription

    init(rate: Double, channels: Int, frequency: Double, totalFrames: Int) {
        self.rate = rate
        self.channels = channels
        self.frequency = frequency
        self.totalFrames = totalFrames
        var asbd = AudioStreamBasicDescription(
            mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(4 * channels), mFramesPerPacket: 1, mBytesPerFrame: UInt32(4 * channels),
            mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 32, mReserved: 0)
        var desc: CMAudioFormatDescription?
        let layout = stereoLayout(channels)
        let status = layout.withUnsafeBytes { raw in
            CMAudioFormatDescriptionCreate(
                allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: raw.count,
                layout: raw.baseAddress!.assumingMemoryBound(to: AudioChannelLayout.self), magicCookieSize: 0,
                magicCookie: nil, extensions: nil, formatDescriptionOut: &desc)
        }
        guard status == noErr, let desc else { fail("CMAudioFormatDescriptionCreate") }
        format = desc
    }

    var done: Bool { written >= totalFrames }

    /// Next chunk of up to `maxFrames` frames as a CMSampleBuffer, or nil when done.
    func next(maxFrames: Int) -> CMSampleBuffer? {
        let n = min(maxFrames, totalFrames - written)
        if n <= 0 { return nil }
        var samples = [Float](repeating: 0, count: n * channels)
        for f in 0..<n {
            let v = audioSample(frame: written + f, rate: rate, frequency: frequency)
            for c in 0..<channels { samples[f * channels + c] = v }
        }
        let bytes = n * channels * 4
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: bytes, blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil, offsetToData: 0, dataLength: bytes, flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &block) == kCMBlockBufferNoErr, let block
        else { fail("CMBlockBufferCreateWithMemoryBlock") }
        samples.withUnsafeBytes { raw in
            _ = CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block, offsetIntoDestination: 0,
                                              dataLength: bytes)
        }
        var sample: CMSampleBuffer?
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: n,
            presentationTimeStamp: CMTime(value: CMTimeValue(written), timescale: CMTimeScale(rate)),
            packetDescriptions: nil, sampleBufferOut: &sample) == noErr, let sample
        else { fail("CMAudioSampleBufferCreateReadyWithPacketDescriptions") }
        written += n
        return sample
    }
}

func stereoLayout(_ channels: Int) -> Data {
    var layout = AudioChannelLayout()
    switch channels {
    case 1: layout.mChannelLayoutTag = kAudioChannelLayoutTag_Mono
    case 2: layout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
    case 6: layout.mChannelLayoutTag = kAudioChannelLayoutTag_MPEG_5_1_D // C L R Ls Rs LFE (AAC order)
    default: fail("no channel layout for \(channels) channels")
    }
    return Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size)
}

enum AudioCodec { case aac, pcm16 }

struct AudioSpec {
    var codec: AudioCodec
    var frequency: Double
    var rate: Double = 48000
    var channels: Int = 2

    var outputSettings: [String: Any] {
        switch codec {
        case .aac:
            return [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate, AVNumberOfChannelsKey: channels,
                    AVEncoderBitRateKey: channels > 2 ? 64_000 * channels : 128_000,
                    AVChannelLayoutKey: stereoLayout(channels)]
        case .pcm16:
            return [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: channels,
                    AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
                    AVLinearPCMIsNonInterleaved: false, AVChannelLayoutKey: stereoLayout(channels)]
        }
    }
}

struct VideoSpec {
    var codec: AVVideoCodecType
    var width: Int
    var height: Int
    var frameDuration: CMTime
    var frames: Int
    var bitRate: Int?
    var keyFrameInterval: Int?
    /// Presentation times of the frames; nil = frame i at i * frameDuration.
    var times: [CMTime]? = nil
    /// End of the last frame (the session end); nil = frames * frameDuration.
    var end: CMTime? = nil
    /// Track display transform (AVAssetWriterInput.transform).
    var transform: CGAffineTransform = .identity
    /// Alpha channel drawn into the source frames (ProRes 4444): the left half of every frame
    /// gets this alpha (straight colour), the right half stays opaque.
    var leftHalfAlpha: UInt8? = nil
    var allowFrameReordering: Bool = true

    func time(_ i: Int) -> CMTime { times?[i] ?? CMTimeMultiply(frameDuration, multiplier: Int32(i)) }
    var endTime: CMTime { end ?? CMTimeMultiply(frameDuration, multiplier: Int32(frames)) }
}

/// Frame times of the variable-frame-rate clip: durations cycle through `vfrPattern` (units
/// of 1/600 s), starting at 0. Keep in sync with EngineTests/Media/TestMedia.mm.
let vfrPattern: [Int64] = [20, 20, 60, 20, 10, 10, 20, 100, 20, 30, 20, 15]

func vfrTimes(frames: Int) -> (times: [CMTime], end: CMTime) {
    var t: Int64 = 0
    var times: [CMTime] = []
    for i in 0..<frames {
        times.append(CMTime(value: t, timescale: 600))
        t += vfrPattern[i % vfrPattern.count]
    }
    return (times, CMTime(value: t, timescale: 600))
}

func waitReady(_ input: AVAssetWriterInput, _ writer: AVAssetWriter) {
    while !input.isReadyForMoreMediaData {
        if writer.status == .failed { fail("writer failed: \(String(describing: writer.error))") }
        usleep(500)
    }
}

func finish(_ writer: AVAssetWriter) {
    let done = DispatchSemaphore(value: 0)
    writer.finishWriting { done.signal() }
    done.wait()
    if writer.status != .completed { fail("finishWriting: \(String(describing: writer.error))") }
}

func makeWriter(_ url: URL, _ type: AVFileType) -> AVAssetWriter {
    try? FileManager.default.removeItem(at: url)
    do { return try AVAssetWriter(outputURL: url, fileType: type) } catch { fail("AVAssetWriter: \(error)") }
}

func addAudioInput(_ writer: AVAssetWriter, _ spec: AudioSpec) -> AVAssetWriterInput {
    let input = AVAssetWriterInput(mediaType: .audio, outputSettings: spec.outputSettings)
    input.expectsMediaDataInRealTime = false
    guard writer.canAdd(input) else { fail("cannot add audio input") }
    writer.add(input)
    return input
}

func writeVideo(_ url: URL, type: AVFileType, video v: VideoSpec, audio a: AudioSpec?, fastStart: Bool) {
    let writer = makeWriter(url, type)
    writer.shouldOptimizeForNetworkUse = fastStart
    var settings: [String: Any] = [
        AVVideoCodecKey: v.codec, AVVideoWidthKey: v.width, AVVideoHeightKey: v.height,
        AVVideoColorPropertiesKey: [
            AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
            AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
            AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
        ],
    ]
    if v.codec != .proRes422 && v.codec != .proRes4444 {
        var compression: [String: Any] = [AVVideoExpectedSourceFrameRateKey: Int((1 / v.frameDuration.seconds).rounded())]
        if let bitRate = v.bitRate { compression[AVVideoAverageBitRateKey] = bitRate }
        if let key = v.keyFrameInterval { compression[AVVideoMaxKeyFrameIntervalKey] = key }
        compression[AVVideoAllowFrameReorderingKey] = v.allowFrameReordering
        settings[AVVideoCompressionPropertiesKey] = compression
    }
    let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
    videoInput.expectsMediaDataInRealTime = false
    videoInput.transform = v.transform
    var timescale = v.frameDuration.timescale
    while timescale < 600 { timescale *= 2 }
    videoInput.mediaTimeScale = timescale
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
        assetWriterInput: videoInput,
        sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: v.width, kCVPixelBufferHeightKey as String: v.height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ])
    guard writer.canAdd(videoInput) else { fail("cannot add video input") }
    writer.add(videoInput)
    let end = v.endTime
    var audioInput: AVAssetWriterInput?
    var source: AudioSource?
    if let a {
        audioInput = addAudioInput(writer, a)
        source = AudioSource(rate: a.rate, channels: a.channels, frequency: a.frequency,
                             totalFrames: Int((end.seconds * a.rate).rounded()))
    }
    guard writer.startWriting() else { fail("startWriting: \(String(describing: writer.error))") }
    writer.startSession(atSourceTime: .zero)
    // AVAssetWriter interleaves the tracks and stops accepting video until the audio has run
    // far enough ahead (about a second for PCM in QuickTime) or is marked finished, so feed
    // whichever input is ready, keeping the audio between 0 and 2 s ahead of the video.
    let maxAudioLead = 2.0
    var i = 0
    var audioFinished = audioInput == nil
    while i < v.frames || !audioFinished {
        if writer.status == .failed { fail("writer failed: \(String(describing: writer.error))") }
        var progressed = false
        let pts = i < v.frames ? v.time(i) : end
        let audioTime = source.map { Double($0.written) / $0.rate } ?? .infinity
        if i < v.frames, videoInput.isReadyForMoreMediaData, audioFinished || audioTime >= pts.seconds {
            guard let pool = adaptor.pixelBufferPool else { fail("no pixel buffer pool") }
            var pb: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb) == kCVReturnSuccess, let pb else { fail("pool") }
            CVPixelBufferLockBaseAddress(pb, [])
            drawBurnIn(index: i, base: CVPixelBufferGetBaseAddress(pb)!, bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
                       width: v.width, height: v.height)
            if let alpha = v.leftHalfAlpha {
                setLeftHalfAlpha(alpha, base: CVPixelBufferGetBaseAddress(pb)!, bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
                                 width: v.width, height: v.height)
            }
            CVPixelBufferUnlockBaseAddress(pb, [])
            if !adaptor.append(pb, withPresentationTime: pts) { fail("video append: \(String(describing: writer.error))") }
            i += 1
            if i == v.frames { videoInput.markAsFinished() }
            progressed = true
        }
        if let audioInput, let source, !audioFinished, audioInput.isReadyForMoreMediaData,
           i >= v.frames || audioTime < pts.seconds + maxAudioLead {
            if let sample = source.next(maxFrames: 1024) {
                if !audioInput.append(sample) { fail("audio append: \(String(describing: writer.error))") }
            }
            if source.done {
                audioInput.markAsFinished()
                audioFinished = true
            }
            progressed = true
        }
        if !progressed { usleep(200) }
    }
    writer.endSession(atSourceTime: end)
    finish(writer)
}

func writeAudioOnly(_ url: URL, type: AVFileType, audio a: AudioSpec, seconds: Double) {
    let writer = makeWriter(url, type)
    let input = addAudioInput(writer, a)
    let source = AudioSource(rate: a.rate, channels: a.channels, frequency: a.frequency,
                             totalFrames: Int((seconds * a.rate).rounded()))
    guard writer.startWriting() else { fail("startWriting: \(String(describing: writer.error))") }
    writer.startSession(atSourceTime: .zero)
    while let sample = source.next(maxFrames: 4096) {
        waitReady(input, writer)
        if !input.append(sample) { fail("audio append: \(String(describing: writer.error))") }
    }
    input.markAsFinished()
    finish(writer)
}

func writeStill(_ url: URL, type: UTType, width: Int, height: Int, index: Int) {
    let bytesPerRow = width * 4
    var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
    pixels.withUnsafeMutableBytes { raw in
        drawBurnIn(index: index, base: raw.baseAddress!, bytesPerRow: bytesPerRow, width: width, height: height)
    }
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
    guard let provider = CGDataProvider(data: Data(pixels) as CFData),
          let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                              bytesPerRow: bytesPerRow, space: space, bitmapInfo: info, provider: provider,
                              decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    else { fail("CGImage") }
    try? FileManager.default.removeItem(at: url)
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
        fail("CGImageDestination for \(type.identifier)")
    }
    CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
    if !CGImageDestinationFinalize(dest) { fail("CGImageDestinationFinalize \(url.lastPathComponent)") }
}

// MARK: - Main

guard CommandLine.arguments.count == 2 else { fail("usage: make_test_media.swift <output-directory>") }
let outDir = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
do {
    try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
} catch { fail("cannot create \(outDir.path): \(error)") }

var manifest: [[String: Any]] = []
func record(_ name: String, _ fields: [String: Any]) {
    var entry = fields
    entry["file"] = name
    manifest.append(entry)
    print("wrote \(name)")
}

let h264 = VideoSpec(codec: .h264, width: 1920, height: 1080, frameDuration: CMTime(value: 1, timescale: 30),
                     frames: 300, bitRate: 6_000_000, keyFrameInterval: 30)
writeVideo(outDir.appendingPathComponent("h264_1080p30.mp4"), type: .mp4, video: h264,
           audio: AudioSpec(codec: .aac, frequency: 440), fastStart: true)
record("h264_1080p30.mp4", ["codec": "avc1", "width": 1920, "height": 1080, "fdValue": 1, "fdTimescale": 30,
                            "frames": 300, "audio": "aac", "toneHz": 440])

let hevc = VideoSpec(codec: .hevc, width: 1280, height: 720, frameDuration: CMTime(value: 1001, timescale: 30000),
                     frames: 300, bitRate: 3_000_000, keyFrameInterval: 60)
writeVideo(outDir.appendingPathComponent("hevc_720p2997.mov"), type: .mov, video: hevc,
           audio: AudioSpec(codec: .aac, frequency: 550), fastStart: false)
record("hevc_720p2997.mov", ["codec": "hvc1", "width": 1280, "height": 720, "fdValue": 1001, "fdTimescale": 30000,
                             "frames": 300, "audio": "aac", "toneHz": 550])

let prores = VideoSpec(codec: .proRes422, width: 960, height: 540, frameDuration: CMTime(value: 1, timescale: 25),
                       frames: 75, bitRate: nil, keyFrameInterval: nil)
writeVideo(outDir.appendingPathComponent("prores_540p25.mov"), type: .mov, video: prores,
           audio: AudioSpec(codec: .pcm16, frequency: 660), fastStart: false)
record("prores_540p25.mov", ["codec": "apcn", "width": 960, "height": 540, "fdValue": 1, "fdTimescale": 25,
                             "frames": 75, "audio": "lpcm", "toneHz": 660])

writeAudioOnly(outDir.appendingPathComponent("audio_only.m4a"), type: .m4a,
               audio: AudioSpec(codec: .aac, frequency: 330), seconds: 10)
record("audio_only.m4a", ["audio": "aac", "toneHz": 330, "seconds": 10])

writeAudioOnly(outDir.appendingPathComponent("audio_only.wav"), type: .wav,
               audio: AudioSpec(codec: .pcm16, frequency: 770), seconds: 10)
record("audio_only.wav", ["audio": "lpcm", "toneHz": 770, "seconds": 10])

writeStill(outDir.appendingPathComponent("still.png"), type: .png, width: 1280, height: 720, index: 0x1234)
record("still.png", ["width": 1280, "height": 720, "burnIn": 0x1234])
writeStill(outDir.appendingPathComponent("still.heic"), type: .heic, width: 1024, height: 576, index: 0xBEEF)
record("still.heic", ["width": 1024, "height": 576, "burnIn": 0xBEEF])

// Variable frame rate: irregular frame durations (vfrPattern), B-frames, keyframe every 30.
let vfr = vfrTimes(frames: 150)
writeVideo(outDir.appendingPathComponent("vfr_h264.mp4"), type: .mp4,
           video: VideoSpec(codec: .h264, width: 640, height: 360, frameDuration: CMTime(value: 1, timescale: 30),
                            frames: 150, bitRate: 2_000_000, keyFrameInterval: 30, times: vfr.times, end: vfr.end),
           audio: nil, fastStart: true)
record("vfr_h264.mp4", ["codec": "avc1", "width": 640, "height": 360, "frames": 150, "vfrPattern600": vfrPattern])

// Display rotation: stored landscape, shown rotated 90 degrees clockwise (an iPhone portrait clip).
writeVideo(outDir.appendingPathComponent("rotated90_h264.mp4"), type: .mp4,
           video: VideoSpec(codec: .h264, width: 640, height: 360, frameDuration: CMTime(value: 1, timescale: 30),
                            frames: 30, bitRate: 1_000_000, keyFrameInterval: 30,
                            transform: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 360, ty: 0)),
           audio: nil, fastStart: true)
record("rotated90_h264.mp4", ["codec": "avc1", "width": 640, "height": 360, "frames": 30, "rotation": 90])

// Slow motion as Photos hands over an iPhone clip: HEVC, portrait (stored landscape, shown rotated
// 90 degrees clockwise), 30 fps around a 240 fps section: 30 frames of 1/30 s, 120 of 1/240 s,
// 30 of 1/30 s (variable frame rate). The frame times are also written to the manifest
// ("frameTicks960"), which EngineTests checks slowmoFrameTime in TestMedia.mm against.
var slowmoTimes: [CMTime] = []
var slowmoTick: Int64 = 0 // 1/960 s
for i in 0..<180 {
    slowmoTimes.append(CMTime(value: slowmoTick, timescale: 960))
    slowmoTick += (i >= 30 && i < 150) ? 4 : 32
}
writeVideo(outDir.appendingPathComponent("slowmo_hevc_portrait.mov"), type: .mov,
           video: VideoSpec(codec: .hevc, width: 640, height: 360, frameDuration: CMTime(value: 1, timescale: 240),
                            frames: 180, bitRate: 2_000_000, keyFrameInterval: 30, times: slowmoTimes,
                            end: CMTime(value: slowmoTick, timescale: 960),
                            transform: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 360, ty: 0)),
           audio: nil, fastStart: false)
record("slowmo_hevc_portrait.mov", ["codec": "hvc1", "width": 640, "height": 360, "frames": 180, "rotation": 90,
                                    "slowmo": "30x1/30, 120x1/240, 30x1/30",
                                    "frameTicks960": slowmoTimes.map { $0.value } + [slowmoTick]])

// Long GOP: one keyframe every 5 s (150 frames), for seeks deep into a GOP.
writeVideo(outDir.appendingPathComponent("gop5s_h264_1080p30.mp4"), type: .mp4,
           video: VideoSpec(codec: .h264, width: 1920, height: 1080, frameDuration: CMTime(value: 1, timescale: 30),
                            frames: 300, bitRate: 8_000_000, keyFrameInterval: 150),
           audio: nil, fastStart: true)
record("gop5s_h264_1080p30.mp4", ["codec": "avc1", "width": 1920, "height": 1080, "frames": 300, "gop": 150])

// Leading empty edit: the first video frame is presented at 0.5 s.
let gapStart = CMTime(value: 1, timescale: 2)
writeVideo(outDir.appendingPathComponent("leading_gap_h264.mov"), type: .mov,
           video: VideoSpec(codec: .h264, width: 640, height: 360, frameDuration: CMTime(value: 1, timescale: 30),
                            frames: 60, bitRate: 1_000_000, keyFrameInterval: 30,
                            times: (0..<60).map { CMTimeAdd(gapStart, CMTime(value: CMTimeValue($0), timescale: 30)) },
                            end: CMTimeAdd(gapStart, CMTime(value: 60, timescale: 30))),
           audio: nil, fastStart: false)
record("leading_gap_h264.mov", ["codec": "avc1", "width": 640, "height": 360, "frames": 60, "firstFrame": 0.5])

// ProRes 4444 with alpha: left half 50 % transparent with straight (unpremultiplied) colour.
writeVideo(outDir.appendingPathComponent("prores4444_alpha.mov"), type: .mov,
           video: VideoSpec(codec: .proRes4444, width: 576, height: 324, frameDuration: CMTime(value: 1, timescale: 25),
                            frames: 10, bitRate: nil, keyFrameInterval: nil, leftHalfAlpha: 128),
           audio: nil, fastStart: false)
record("prores4444_alpha.mov", ["codec": "ap4h", "width": 576, "height": 324, "frames": 10, "leftHalfAlpha": 128])

// Audio variants: 44.1 kHz (AAC and PCM), mono AAC, 5.1 AAC.
writeAudioOnly(outDir.appendingPathComponent("audio_44k.m4a"), type: .m4a,
               audio: AudioSpec(codec: .aac, frequency: 880, rate: 44100), seconds: 6)
record("audio_44k.m4a", ["audio": "aac", "toneHz": 880, "rate": 44100, "seconds": 6])
writeAudioOnly(outDir.appendingPathComponent("audio_44k.wav"), type: .wav,
               audio: AudioSpec(codec: .pcm16, frequency: 990, rate: 44100), seconds: 6)
record("audio_44k.wav", ["audio": "lpcm", "toneHz": 990, "rate": 44100, "seconds": 6])
writeAudioOnly(outDir.appendingPathComponent("audio_mono.m4a"), type: .m4a,
               audio: AudioSpec(codec: .aac, frequency: 660, channels: 1), seconds: 4)
record("audio_mono.m4a", ["audio": "aac", "toneHz": 660, "channels": 1, "seconds": 4])
writeAudioOnly(outDir.appendingPathComponent("audio_51.m4a"), type: .m4a,
               audio: AudioSpec(codec: .aac, frequency: 520, channels: 6), seconds: 4)
record("audio_51.m4a", ["audio": "aac", "toneHz": 520, "channels": 6, "seconds": 4])

let manifestData = try! JSONSerialization.data(withJSONObject: ["files": manifest, "beepStart": beepStart,
                                                                "beepHz": beepFrequency], options: [.prettyPrinted, .sortedKeys])
try! manifestData.write(to: outDir.appendingPathComponent("manifest.json"))
// AVAssetWriter's fast-start (moov relocation) temporary may outlive finishWriting briefly.
for leftover in (try? FileManager.default.contentsOfDirectory(atPath: outDir.path)) ?? [] where leftover.contains(".sb-") {
    try? FileManager.default.removeItem(at: outDir.appendingPathComponent(leftover))
}
print("done")
