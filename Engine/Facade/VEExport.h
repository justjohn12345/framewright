// Export value types for VEEngine's export API (VEEngine.h, "Export").
//
// VEExportSettings is an immutable value: build it with the designated initializer (or start from
// +defaultSettingsForPreset:). The engine turns it into encoder settings for the active sequence;
// validationMessage says what is wrong with a combination before anything runs.
// Plain Objective-C only: this header is part of the framework's public module.

#import <CoreGraphics/CoreGraphics.h>
#import <CoreMedia/CoreMedia.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// What the video is encoded with.
typedef NS_ENUM(NSInteger, VEExportPreset) {
    /// H.264 High through VideoToolbox (the hardware encoder where it takes the frame size). MP4 or MOV.
    VEExportPresetH264 NS_SWIFT_NAME(h264) = 0,
    /// HEVC Main (8-bit) through VideoToolbox. MP4 or MOV.
    VEExportPresetHEVC NS_SWIFT_NAME(hevc) = 1,
    /// HEVC Main10 (10-bit) through VideoToolbox, where the encoder offers Main10. MP4 or MOV.
    VEExportPresetHEVC10Bit NS_SWIFT_NAME(hevc10Bit) = 2,
    /// Apple ProRes 422 through VideoToolbox (hardware on Macs with ProRes engines). MOV only.
    VEExportPresetProRes422 NS_SWIFT_NAME(proRes422) = 3,
    /// AV1 with the SVT-AV1 software encoder (FFmpeg), where this build includes it. MP4 or MKV.
    VEExportPresetAV1 NS_SWIFT_NAME(av1) = 4,
};

typedef NS_ENUM(NSInteger, VEExportContainer) {
    VEExportContainerMP4 NS_SWIFT_NAME(mp4) = 0,
    VEExportContainerMOV NS_SWIFT_NAME(mov) = 1,
    /// Matroska (AV1 only).
    VEExportContainerMKV NS_SWIFT_NAME(mkv) = 2,
};

typedef NS_ENUM(NSInteger, VEExportResolution) {
    /// The sequence's frame size.
    VEExportResolutionSequence NS_SWIFT_NAME(sequence) = 0,
    /// 1080 lines, width from the sequence's aspect ratio.
    VEExportResolution1080p NS_SWIFT_NAME(hd1080) = 1,
    /// 720 lines, width from the sequence's aspect ratio.
    VEExportResolution720p NS_SWIFT_NAME(hd720) = 2,
    /// `customWidth` columns, height from the sequence's aspect ratio.
    VEExportResolutionCustom NS_SWIFT_NAME(custom) = 3,
};

typedef NS_ENUM(NSInteger, VEExportRateControl) {
    /// Constant quality (`quality` 0...1). ProRes ignores it (its data rate is fixed per profile).
    VEExportRateControlQuality NS_SWIFT_NAME(quality) = 0,
    /// Average bit rate (`videoBitRate`).
    VEExportRateControlBitRate NS_SWIFT_NAME(bitRate) = 1,
};

typedef NS_ENUM(NSInteger, VEExportAudioCodec) {
    VEExportAudioCodecNone NS_SWIFT_NAME(noAudio) = 0,
    /// AAC-LC, 48 kHz stereo at `audioBitRate`.
    VEExportAudioCodecAAC NS_SWIFT_NAME(aac) = 1,
    /// 16-bit linear PCM, 48 kHz stereo (MOV and MKV).
    VEExportAudioCodecPCM NS_SWIFT_NAME(pcm) = 2,
};

/// Everything an export needs besides the output location.
@interface VEExportSettings : NSObject <NSCopying>
@property (nonatomic, readonly) VEExportPreset preset;
@property (nonatomic, readonly) VEExportContainer container;
@property (nonatomic, readonly) VEExportResolution resolution;
/// Output width for VEExportResolutionCustom (rounded down to even).
@property (nonatomic, readonly) NSInteger customWidth;
@property (nonatomic, readonly) VEExportRateControl rateControl;
/// 0...1 for VEExportRateControlQuality.
@property (nonatomic, readonly) double quality;
/// Bits per second for VEExportRateControlBitRate.
@property (nonatomic, readonly) int64_t videoBitRate;
@property (nonatomic, readonly) VEExportAudioCodec audioCodec;
/// Bits per second (AAC).
@property (nonatomic, readonly) NSInteger audioBitRate;
/// 48000.
@property (nonatomic, readonly) NSInteger audioSampleRate;
/// 2.
@property (nonatomic, readonly) NSInteger audioChannels;

- (instancetype)initWithPreset:(VEExportPreset)preset
                     container:(VEExportContainer)container
                    resolution:(VEExportResolution)resolution
                   customWidth:(NSInteger)customWidth
                   rateControl:(VEExportRateControl)rateControl
                       quality:(double)quality
                  videoBitRate:(int64_t)videoBitRate
                    audioCodec:(VEExportAudioCodec)audioCodec
                  audioBitRate:(NSInteger)audioBitRate NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/// The recommended settings of a preset: its first container, the sequence's size, quality 0.7
/// (ProRes: fixed), a bit rate suggestion of 20 Mb/s (H.264), 12 Mb/s (HEVC), 8 Mb/s (AV1), and
/// AAC at 256 kb/s (ProRes: PCM).
+ (instancetype)defaultSettingsForPreset:(VEExportPreset)preset;

/// Containers a preset can be written to, in order of preference (NSNumber of VEExportContainer).
+ (NSArray<NSNumber *> *)containersForPreset:(VEExportPreset)preset;
/// Audio codecs a container can hold (NSNumber of VEExportAudioCodec, None first).
+ (NSArray<NSNumber *> *)audioCodecsForContainer:(VEExportContainer)container;
/// "H.264", "HEVC", "HEVC 10-bit", "ProRes 422", "AV1".
+ (NSString *)nameForPreset:(VEExportPreset)preset;
/// "MP4", "QuickTime (MOV)", "Matroska (MKV)".
+ (NSString *)nameForContainer:(VEExportContainer)container;
/// "mp4", "mov", "mkv".
+ (NSString *)fileExtensionForContainer:(VEExportContainer)container;
@property (nonatomic, readonly, copy) NSString *fileExtension;

/// The output frame size for a sequence of `width` x `height` (even sides, at most 16384; zero
/// when the sequence size or the custom width is not usable).
- (CGSize)outputSizeForSequenceWidth:(NSInteger)width height:(NSInteger)height;

/// Why this combination cannot be exported ("ProRes is written to QuickTime (MOV) files only."),
/// or nil. Does not check the machine's encoders (see VEExportFormat).
@property (nonatomic, readonly, copy, nullable) NSString *validationMessage;
@end

/// Whether a preset can be exported on this machine at a frame size, and how.
@interface VEExportFormat : NSObject
@property (nonatomic, readonly) VEExportPreset preset;
/// VEExportSettings nameForPreset:.
@property (nonatomic, readonly, copy) NSString *name;
@property (nonatomic, readonly) NSInteger width;
@property (nonatomic, readonly) NSInteger height;
@property (nonatomic, readonly) BOOL available;
/// The encoder runs in hardware (VideoToolbox's answer for this size).
@property (nonatomic, readonly) BOOL hardware;
/// "VideoToolbox (hardware)", "VideoToolbox (software)", "SVT-AV1 (software)".
@property (nonatomic, readonly, copy) NSString *encoderDescription;
/// Why it is not available ("" when it is).
@property (nonatomic, readonly, copy) NSString *unavailableReason;
- (instancetype)init NS_UNAVAILABLE;
@end

/// A progress report of a running export (VEEngineExportDidProgressNotification).
@interface VEExportProgress : NSObject
@property (nonatomic, readonly) int64_t framesCompleted;
@property (nonatomic, readonly) int64_t totalFrames;
/// 0...1.
@property (nonatomic, readonly) double fractionCompleted;
/// Over the last second.
@property (nonatomic, readonly) double framesPerSecond;
/// -1 while unknown.
@property (nonatomic, readonly) double estimatedSecondsRemaining;
/// Size of the output file so far; 0 while the writer stages the media elsewhere (MP4 through
/// AVAssetWriter appears when it is finished).
@property (nonatomic, readonly) uint64_t bytesWritten;
@property (nonatomic, readonly) double elapsedSeconds;
- (instancetype)init NS_UNAVAILABLE;
@end

/// What a finished export produced.
@interface VEExportSummary : NSObject
@property (nonatomic, readonly, copy) NSURL *outputURL;
/// The exported sequence duration (frames x frame duration).
@property (nonatomic, readonly) CMTime duration;
@property (nonatomic, readonly) int64_t frameCount;
@property (nonatomic, readonly) uint64_t fileSize;
@property (nonatomic, readonly) NSInteger width;
@property (nonatomic, readonly) NSInteger height;
/// "VideoToolbox HEVC (hardware)", "libsvtav1", ... ("" for audio-only exports).
@property (nonatomic, readonly, copy) NSString *encoderName;
@property (nonatomic, readonly) BOOL hardwareAccelerated;
/// Writer backend: "apple" (AVAssetWriter) or "ffmpeg".
@property (nonatomic, readonly, copy) NSString *backendName;
/// Seconds from start to finish.
@property (nonatomic, readonly) double wallSeconds;
@property (nonatomic, readonly) double averageFramesPerSecond;
- (instancetype)init NS_UNAVAILABLE;
@end

/// A running (or finished) export. Thread-safe.
@interface VEExportHandle : NSObject
@property (nonatomic, readonly, copy) NSURL *outputURL;
@property (nonatomic, readonly, copy) VEExportSettings *settings;
/// The export has ended (written, failed or cancelled); its completion runs next on the main queue.
@property (nonatomic, readonly, getter=isFinished) BOOL finished;
@property (nonatomic, readonly) VEExportProgress *progress;
/// Stops the export and deletes the partial file; the completion reports
/// VEEngineErrorExportCancelled. Returns at once.
- (void)cancel;
/// Cancels and waits (at most `timeout` seconds) until the export has ended and its partial
/// file is gone. For quitting the app with an export running. Returns whether it ended.
- (BOOL)cancelAndWaitWithTimeout:(NSTimeInterval)timeout;
- (instancetype)init NS_UNAVAILABLE;
@end

NS_ASSUME_NONNULL_END
