import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Media of the two-hour stress project (`TwoHourProjectStressTests`), written at test time into the
/// test's scratch directory (nothing is kept in the repository). Movies show a background that changes
/// colour every second with a white bar sweeping across (so thumbnails differ along a clip), and carry
/// an AAC stereo tone whose level swells and fades over 7 s (so waveforms have a shape).
enum StressMediaFactory {
    struct Movie {
        var codec: AVVideoCodecType
        var fileType: AVFileType
        var width: Int
        var height: Int
        var frameDuration: CMTime
        var frames: Int
        /// AAC stereo at this rate; nil: no audio track.
        var audioRate: Double?
        var toneHz: Double = 440

        var duration: CMTime { CMTimeMultiply(frameDuration, multiplier: Int32(frames)) }
    }

    private static let palette: [(r: UInt8, g: UInt8, b: UInt8)] = [
        (180, 60, 60), (60, 150, 60), (60, 60, 200), (170, 150, 40),
        (40, 150, 160), (150, 60, 160), (110, 110, 110), (200, 110, 50),
    ]

    enum Failure: Error, CustomStringConvertible {
        case writer(String)

        var description: String {
            switch self {
            case let .writer(message): return message
            }
        }
    }

    static func writeMovie(_ movie: Movie, to url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: movie.fileType)
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: movie.codec,
            AVVideoWidthKey: movie.width,
            AVVideoHeightKey: movie.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: movie.width * movie.height * 2,
                AVVideoMaxKeyFrameIntervalKey: 30,
            ],
        ])
        video.expectsMediaDataInRealTime = false
        var timescale = movie.frameDuration.timescale
        while timescale < 600 { timescale *= 2 }
        video.mediaTimeScale = timescale
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: movie.width,
            kCVPixelBufferHeightKey as String: movie.height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ])
        guard writer.canAdd(video) else { throw Failure.writer("cannot add a video input to \(url.lastPathComponent)") }
        writer.add(video)
        var audio: AudioWriter?
        if let rate = movie.audioRate {
            audio = try AudioWriter(writer: writer, rate: rate, toneHz: movie.toneHz,
                                    frames: Int((movie.duration.seconds * rate).rounded()))
        }
        guard writer.startWriting() else { throw Failure.writer("startWriting: \(String(describing: writer.error))") }
        writer.startSession(atSourceTime: .zero)
        let framesPerSecond = max(1, Int((1 / movie.frameDuration.seconds).rounded()))
        var row = [UInt8](repeating: 0, count: movie.width * 4)
        var frame = 0
        // AVAssetWriter interleaves the tracks: feed whichever input is ready, keeping the audio at
        // most 2 s ahead of the video.
        while frame < movie.frames || !(audio?.finished ?? true) {
            if writer.status == .failed { throw Failure.writer("writer failed: \(String(describing: writer.error))") }
            var progressed = false
            let pts = CMTimeMultiply(movie.frameDuration, multiplier: Int32(frame))
            let audioSeconds = audio?.writtenSeconds ?? .infinity
            let audioAhead = (audio?.finished ?? true) || audioSeconds >= pts.seconds
            if frame < movie.frames, video.isReadyForMoreMediaData, audioAhead {
                guard let pool = adaptor.pixelBufferPool else { throw Failure.writer("no pixel buffer pool") }
                var buffer: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
                guard let buffer else { throw Failure.writer("no pixel buffer") }
                draw(frame: frame, framesPerSecond: framesPerSecond, into: buffer, row: &row, width: movie.width,
                     height: movie.height)
                guard adaptor.append(buffer, withPresentationTime: pts) else {
                    throw Failure.writer("video append: \(String(describing: writer.error))")
                }
                frame += 1
                if frame == movie.frames { video.markAsFinished() }
                progressed = true
            }
            if let audio, !audio.finished, audio.isReady, frame >= movie.frames || audioSeconds < pts.seconds + 2 {
                try audio.appendNext()
                progressed = true
            }
            if !progressed { usleep(200) }
        }
        writer.endSession(atSourceTime: movie.duration)
        try finish(writer)
    }

    /// An M4A (AAC stereo) of the swelling tone.
    static func writeAudio(to url: URL, seconds: Double, rate: Double, toneHz: Double) throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
        let audio = try AudioWriter(writer: writer, rate: rate, toneHz: toneHz, frames: Int((seconds * rate).rounded()))
        guard writer.startWriting() else { throw Failure.writer("startWriting: \(String(describing: writer.error))") }
        writer.startSession(atSourceTime: .zero)
        while !audio.finished {
            if writer.status == .failed { throw Failure.writer("writer failed: \(String(describing: writer.error))") }
            if audio.isReady {
                try audio.appendNext()
            } else {
                usleep(200)
            }
        }
        try finish(writer)
    }

    /// A PNG still: a gradient with a block of colour, `width` x `height`.
    static func writeStill(to url: URL, width: Int, height: Int) throws {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw Failure.writer("CGContext")
        }
        for band in 0 ..< 16 {
            let shade = CGFloat(band) / 15
            context.setFillColor(CGColor(red: 0.2 + 0.6 * shade, green: 0.3, blue: 0.8 - 0.5 * shade, alpha: 1))
            context.fill(CGRect(x: CGFloat(band) * CGFloat(width) / 16, y: 0, width: CGFloat(width) / 16 + 1,
                                height: CGFloat(height)))
        }
        context.setFillColor(CGColor(red: 0.95, green: 0.9, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: CGFloat(width) * 0.1, y: CGFloat(height) * 0.4, width: CGFloat(width) * 0.8,
                            height: CGFloat(height) * 0.2))
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw Failure.writer("PNG destination") }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw Failure.writer("PNG finalize") }
    }

    // MARK: Pictures

    private static func draw(frame: Int, framesPerSecond: Int, into buffer: CVPixelBuffer, row: inout [UInt8],
                             width: Int, height: Int) {
        let colour = palette[(frame / framesPerSecond) % palette.count]
        let barWidth = max(4, width / 40)
        let barX = (frame * 7) % max(1, width - barWidth)
        for x in 0 ..< width {
            let inBar = x >= barX && x < barX + barWidth
            row[x * 4] = inBar ? 255 : colour.b
            row[x * 4 + 1] = inBar ? 255 : colour.g
            row[x * 4 + 2] = inBar ? 255 : colour.r
            row[x * 4 + 3] = 255
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        row.withUnsafeBytes { bytes in
            for y in 0 ..< height {
                memcpy(base + y * stride, bytes.baseAddress!, width * 4)
            }
        }
    }

    private static func finish(_ writer: AVAssetWriter) throws {
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        guard writer.status == .completed else {
            throw Failure.writer("finishWriting: \(String(describing: writer.error))")
        }
    }
}

/// Appends the swelling tone to an AAC stereo input of `writer`, a chunk at a time.
private final class AudioWriter {
    private let input: AVAssetWriterInput
    private let format: CMAudioFormatDescription
    private let rate: Double
    private let toneHz: Double
    private let total: Int
    private(set) var written = 0
    private(set) var finished = false

    init(writer: AVAssetWriter, rate: Double, toneHz: Double, frames: Int) throws {
        self.rate = rate
        self.toneHz = toneHz
        total = frames
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
        let layoutData = Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size)
        input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate, AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 128_000, AVChannelLayoutKey: layoutData,
        ])
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else { throw StressMediaFactory.Failure.writer("cannot add an audio input") }
        writer.add(input)
        var description = AudioStreamBasicDescription(
            mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 8, mFramesPerPacket: 1,
            mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        var created: CMAudioFormatDescription?
        let status = layoutData.withUnsafeBytes { raw in
            CMAudioFormatDescriptionCreate(
                allocator: kCFAllocatorDefault, asbd: &description, layoutSize: raw.count,
                layout: raw.baseAddress!.assumingMemoryBound(to: AudioChannelLayout.self), magicCookieSize: 0,
                magicCookie: nil, extensions: nil, formatDescriptionOut: &created)
        }
        guard status == noErr, let created else { throw StressMediaFactory.Failure.writer("audio format \(status)") }
        format = created
    }

    var isReady: Bool { input.isReadyForMoreMediaData }
    var writtenSeconds: Double { Double(written) / rate }

    func appendNext() throws {
        let count = min(4096, total - written)
        if count > 0 {
            var samples = [Float](repeating: 0, count: count * 2)
            for i in 0 ..< count {
                let t = Double(written + i) / rate
                let level = 0.1 + 0.3 * (0.5 + 0.5 * sin(2 * Double.pi * t / 7))
                let value = Float(level * sin(2 * Double.pi * toneHz * t))
                samples[i * 2] = value
                samples[i * 2 + 1] = value
            }
            let bytes = count * 8
            var block: CMBlockBuffer?
            guard CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: bytes,
                blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0, dataLength: bytes,
                flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == kCMBlockBufferNoErr, let block
            else { throw StressMediaFactory.Failure.writer("CMBlockBuffer") }
            _ = samples.withUnsafeBytes { raw in
                CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block, offsetIntoDestination: 0,
                                              dataLength: bytes)
            }
            var buffer: CMSampleBuffer?
            guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(
                allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: count,
                presentationTimeStamp: CMTime(value: CMTimeValue(written), timescale: CMTimeScale(rate)),
                packetDescriptions: nil, sampleBufferOut: &buffer) == noErr, let buffer
            else { throw StressMediaFactory.Failure.writer("audio sample buffer") }
            guard input.append(buffer) else { throw StressMediaFactory.Failure.writer("audio append") }
            written += count
        }
        if written >= total {
            input.markAsFinished()
            finished = true
        }
    }
}
