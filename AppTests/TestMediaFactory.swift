import AVFoundation
import CoreVideo
import Foundation
import XCTest

/// Writes small media files for app-level tests into the (sandboxed) temporary directory.
enum TestMediaFactory {
    static func scratchDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FramewrightAppTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A 16-bit stereo 48 kHz WAV with a sine tone.
    static func writeWAV(to url: URL, seconds: Double = 2, frequency: Double = 440) throws {
        let rate = 48000
        let channels = 2
        let frames = Int(Double(rate) * seconds)
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        let payload = frames * channels * 2
        data.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36 + payload))
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        append(UInt32(16))
        append(UInt16(1))
        append(UInt16(channels))
        append(UInt32(rate))
        append(UInt32(rate * channels * 2))
        append(UInt16(channels * 2))
        append(UInt16(16))
        data.append(contentsOf: Array("data".utf8))
        append(UInt32(payload))
        for i in 0 ..< frames {
            let sample = Int16(sin(2 * .pi * frequency * Double(i) / Double(rate)) * 0.5 * Double(Int16.max))
            for _ in 0 ..< channels { append(sample) }
        }
        try data.write(to: url)
    }

    /// An H.264 .mov of `frames` solid-colour frames at 30 fps.
    static func writeMovie(to url: URL, frames: Int = 60, width: Int = 320, height: Int = 180) throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? CocoaError(.fileWriteUnknown)
        }
        writer.startSession(atSourceTime: .zero)
        for frame in 0 ..< frames {
            while !input.isReadyForMoreMediaData {
                Thread.sleep(forTimeInterval: 0.002)
            }
            guard let pool = adaptor.pixelBufferPool else { throw CocoaError(.fileWriteUnknown) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { throw CocoaError(.fileWriteUnknown) }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer) {
                let bytes = base.assumingMemoryBound(to: UInt8.self)
                let stride = CVPixelBufferGetBytesPerRow(buffer)
                let shade = UInt8(40 + (frame * 3) % 200)
                for y in 0 ..< height {
                    for x in 0 ..< width {
                        let p = bytes + y * stride + x * 4
                        p[0] = shade
                        p[1] = 90
                        p[2] = 200 - shade / 2
                        p[3] = 255
                    }
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30))
        }
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        if writer.status != .completed {
            throw writer.error ?? CocoaError(.fileWriteUnknown)
        }
    }
}
