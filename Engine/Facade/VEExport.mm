#import "VEExport.h"

#import "VEExport+Internal.h"
#import "VETypes+Internal.h"

#include "../Media/FFmpeg/FFVideoEncoder.h"
#include "../Media/HardwareCaps.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <mutex>

using namespace ve;
using namespace ve::facade;

namespace {

constexpr NSInteger kMaxSide = 16384;

NSInteger roundToEven(double value) {
    return static_cast<NSInteger>(std::lround(value / 2.0)) * 2;
}

media::VideoCodec codecOf(VEExportPreset preset) {
    switch (preset) {
    case VEExportPresetH264:
        return media::VideoCodec::H264;
    case VEExportPresetHEVC:
    case VEExportPresetHEVC10Bit:
        return media::VideoCodec::HEVC;
    case VEExportPresetProRes422:
        return media::VideoCodec::ProRes422;
    case VEExportPresetAV1:
        return media::VideoCodec::AV1;
    }
    return media::VideoCodec::H264;
}

media::ContainerFormat containerOf(VEExportContainer container) {
    switch (container) {
    case VEExportContainerMP4:
        return media::ContainerFormat::MP4;
    case VEExportContainerMOV:
        return media::ContainerFormat::MOV;
    case VEExportContainerMKV:
        return media::ContainerFormat::MKV;
    }
    return media::ContainerFormat::MP4;
}

NSArray<NSNumber *> *allPresets() {
    return @[
        @(VEExportPresetH264), @(VEExportPresetHEVC), @(VEExportPresetHEVC10Bit), @(VEExportPresetProRes422),
        @(VEExportPresetAV1)
    ];
}

/// Approximate bits per pixel per frame at `quality` (0...1) for the constant-quality modes, from
/// typical camera footage: H.264 about 0.15 at 0.7, HEVC 60 % of that, AV1 50 %.
double bitsPerPixel(VEExportPreset preset, double quality) {
    const double h264 = 0.15 * std::exp(4.0 * (std::clamp(quality, 0.0, 1.0) - 0.7));
    switch (preset) {
    case VEExportPresetH264:
        return h264;
    case VEExportPresetHEVC:
    case VEExportPresetHEVC10Bit:
        return 0.6 * h264;
    case VEExportPresetAV1:
        return 0.5 * h264;
    case VEExportPresetProRes422:
        break;
    }
    // ProRes 422 has a fixed data rate: 147 Mb/s at 1920x1080 29.97 (Apple's ProRes white paper).
    return 147.2e6 / (1920.0 * 1080.0 * 30000.0 / 1001.0);
}

} // namespace

// MARK: - VEExportSettings

@implementation VEExportSettings

- (instancetype)initWithPreset:(VEExportPreset)preset
                     container:(VEExportContainer)container
                    resolution:(VEExportResolution)resolution
                   customWidth:(NSInteger)customWidth
                   rateControl:(VEExportRateControl)rateControl
                       quality:(double)quality
                  videoBitRate:(int64_t)videoBitRate
                    audioCodec:(VEExportAudioCodec)audioCodec
                  audioBitRate:(NSInteger)audioBitRate {
    if ((self = [super init])) {
        _preset = preset;
        _container = container;
        _resolution = resolution;
        _customWidth = customWidth;
        _rateControl = rateControl;
        _quality = quality;
        _videoBitRate = videoBitRate;
        _audioCodec = audioCodec;
        _audioBitRate = audioBitRate;
        _audioSampleRate = 48000;
        _audioChannels = 2;
    }
    return self;
}

+ (instancetype)defaultSettingsForPreset:(VEExportPreset)preset {
    int64_t bitRate = 20'000'000;
    if (preset == VEExportPresetHEVC || preset == VEExportPresetHEVC10Bit) {
        bitRate = 12'000'000;
    } else if (preset == VEExportPresetAV1) {
        bitRate = 8'000'000;
    }
    const bool prores = preset == VEExportPresetProRes422;
    return [[VEExportSettings alloc] initWithPreset:preset
                                          container:VEExportContainer([self containersForPreset:preset].firstObject.integerValue)
                                         resolution:VEExportResolutionSequence
                                        customWidth:1280
                                        rateControl:VEExportRateControlQuality
                                            quality:0.7
                                       videoBitRate:bitRate
                                         audioCodec:prores ? VEExportAudioCodecPCM : VEExportAudioCodecAAC
                                       audioBitRate:256'000];
}

- (id)copyWithZone:(nullable NSZone *)zone {
    (void)zone;
    return self; // immutable
}

- (BOOL)isEqual:(id)object {
    if (![object isKindOfClass:[VEExportSettings class]]) {
        return NO;
    }
    VEExportSettings *o = object;
    return o.preset == _preset && o.container == _container && o.resolution == _resolution &&
           o.customWidth == _customWidth && o.rateControl == _rateControl && o.quality == _quality &&
           o.videoBitRate == _videoBitRate && o.audioCodec == _audioCodec && o.audioBitRate == _audioBitRate;
}

- (NSUInteger)hash {
    return NSUInteger(_preset) * 31 + NSUInteger(_container) * 7 + NSUInteger(_resolution) * 131 +
           NSUInteger(_videoBitRate) + NSUInteger(_audioCodec) * 17 + NSUInteger(_customWidth);
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<VEExportSettings %@ %@ res=%ld q=%.2f rate=%lld audio=%ld@%ld>",
                                      [VEExportSettings nameForPreset:_preset], self.fileExtension,
                                      long(_resolution), _quality, _videoBitRate, long(_audioCodec), long(_audioBitRate)];
}

+ (NSArray<NSNumber *> *)containersForPreset:(VEExportPreset)preset {
    switch (preset) {
    case VEExportPresetH264:
    case VEExportPresetHEVC:
    case VEExportPresetHEVC10Bit:
        return @[ @(VEExportContainerMP4), @(VEExportContainerMOV) ];
    case VEExportPresetProRes422:
        return @[ @(VEExportContainerMOV) ];
    case VEExportPresetAV1:
        return @[ @(VEExportContainerMP4), @(VEExportContainerMKV) ];
    }
    return @[ @(VEExportContainerMP4) ];
}

+ (NSArray<NSNumber *> *)audioCodecsForContainer:(VEExportContainer)container {
    if (container == VEExportContainerMP4) {
        return @[ @(VEExportAudioCodecNone), @(VEExportAudioCodecAAC) ];
    }
    return @[ @(VEExportAudioCodecNone), @(VEExportAudioCodecAAC), @(VEExportAudioCodecPCM) ];
}

+ (NSString *)nameForPreset:(VEExportPreset)preset {
    switch (preset) {
    case VEExportPresetH264:
        return @"H.264";
    case VEExportPresetHEVC:
        return @"HEVC";
    case VEExportPresetHEVC10Bit:
        return @"HEVC 10-bit";
    case VEExportPresetProRes422:
        return @"ProRes 422";
    case VEExportPresetAV1:
        return @"AV1";
    }
    return @"";
}

+ (NSString *)nameForContainer:(VEExportContainer)container {
    switch (container) {
    case VEExportContainerMP4:
        return @"MP4";
    case VEExportContainerMOV:
        return @"QuickTime (MOV)";
    case VEExportContainerMKV:
        return @"Matroska (MKV)";
    }
    return @"";
}

+ (NSString *)fileExtensionForContainer:(VEExportContainer)container {
    switch (container) {
    case VEExportContainerMP4:
        return @"mp4";
    case VEExportContainerMOV:
        return @"mov";
    case VEExportContainerMKV:
        return @"mkv";
    }
    return @"mp4";
}

- (NSString *)fileExtension {
    return [VEExportSettings fileExtensionForContainer:_container];
}

- (CGSize)outputSizeForSequenceWidth:(NSInteger)width height:(NSInteger)height {
    if (width <= 0 || height <= 0) {
        return CGSizeZero;
    }
    const double aspect = double(width) / double(height);
    NSInteger w = 0;
    NSInteger h = 0;
    switch (_resolution) {
    case VEExportResolutionSequence:
        w = roundToEven(double(width));
        h = roundToEven(double(height));
        break;
    case VEExportResolution1080p:
        h = 1080;
        w = roundToEven(1080.0 * aspect);
        break;
    case VEExportResolution720p:
        h = 720;
        w = roundToEven(720.0 * aspect);
        break;
    case VEExportResolutionCustom:
        w = (_customWidth / 2) * 2;
        h = roundToEven(double(w) / aspect);
        break;
    }
    if (w < 2 || h < 2 || w > kMaxSide || h > kMaxSide) {
        return CGSizeZero;
    }
    return CGSizeMake(CGFloat(w), CGFloat(h));
}

- (nullable NSString *)validationMessage {
    NSString *name = [VEExportSettings nameForPreset:_preset];
    if (name.length == 0) {
        return @"Choose a format.";
    }
    NSArray<NSNumber *> *containers = [VEExportSettings containersForPreset:_preset];
    if (![containers containsObject:@(_container)]) {
        NSMutableArray<NSString *> *names = [NSMutableArray array];
        for (NSNumber *c in containers) {
            [names addObject:[VEExportSettings nameForContainer:VEExportContainer(c.integerValue)]];
        }
        return [NSString stringWithFormat:@"%@ is written to %@ files only.", name,
                                          [names componentsJoinedByString:@" or "]];
    }
    if (![[VEExportSettings audioCodecsForContainer:_container] containsObject:@(_audioCodec)]) {
        return [NSString stringWithFormat:@"%@ files cannot hold PCM audio; choose AAC.",
                                          [VEExportSettings nameForContainer:_container]];
    }
    if (_resolution == VEExportResolutionCustom && (_customWidth < 16 || _customWidth > kMaxSide)) {
        return [NSString stringWithFormat:@"The width must be between 16 and %ld pixels.", long(kMaxSide)];
    }
    if (_preset != VEExportPresetProRes422) {
        if (_rateControl == VEExportRateControlQuality && !(_quality >= 0.0 && _quality <= 1.0)) {
            return @"The quality must be between 0 and 100 %.";
        }
        if (_rateControl == VEExportRateControlBitRate && (_videoBitRate < 100'000 || _videoBitRate > 800'000'000)) {
            return @"The video bit rate must be between 0.1 and 800 Mb/s.";
        }
    }
    if (_audioCodec == VEExportAudioCodecAAC && (_audioBitRate < 64'000 || _audioBitRate > 320'000)) {
        return @"The AAC bit rate must be between 64 and 320 kb/s.";
    }
    return nil;
}

@end

// MARK: - VEExportFormat, VEExportProgress, VEExportSummary

@interface VEExportFormat ()
@property (nonatomic, readwrite) VEExportPreset preset;
@property (nonatomic, readwrite, copy) NSString *name;
@property (nonatomic, readwrite) NSInteger width;
@property (nonatomic, readwrite) NSInteger height;
@property (nonatomic, readwrite) BOOL available;
@property (nonatomic, readwrite) BOOL hardware;
@property (nonatomic, readwrite, copy) NSString *encoderDescription;
@property (nonatomic, readwrite, copy) NSString *unavailableReason;
- (instancetype)initInternal;
@end

@implementation VEExportFormat
- (instancetype)initInternal {
    return [super init];
}
- (NSString *)description {
    return [NSString stringWithFormat:@"<VEExportFormat %@ %ldx%ld %@%@>", _name, long(_width), long(_height),
                                      _available ? _encoderDescription : @"unavailable: ",
                                      _available ? @"" : _unavailableReason];
}
@end

@interface VEExportProgress ()
@property (nonatomic, readwrite) int64_t framesCompleted;
@property (nonatomic, readwrite) int64_t totalFrames;
@property (nonatomic, readwrite) double fractionCompleted;
@property (nonatomic, readwrite) double framesPerSecond;
@property (nonatomic, readwrite) double estimatedSecondsRemaining;
@property (nonatomic, readwrite) uint64_t bytesWritten;
@property (nonatomic, readwrite) double elapsedSeconds;
- (instancetype)initInternal;
@end

@implementation VEExportProgress
- (instancetype)initInternal {
    return [super init];
}
@end

@interface VEExportSummary ()
@property (nonatomic, readwrite, copy) NSURL *outputURL;
@property (nonatomic, readwrite) CMTime duration;
@property (nonatomic, readwrite) int64_t frameCount;
@property (nonatomic, readwrite) uint64_t fileSize;
@property (nonatomic, readwrite) NSInteger width;
@property (nonatomic, readwrite) NSInteger height;
@property (nonatomic, readwrite, copy) NSString *encoderName;
@property (nonatomic, readwrite) BOOL hardwareAccelerated;
@property (nonatomic, readwrite, copy) NSString *backendName;
@property (nonatomic, readwrite) double wallSeconds;
@property (nonatomic, readwrite) double averageFramesPerSecond;
- (instancetype)initInternal;
@end

@implementation VEExportSummary
- (instancetype)initInternal {
    return [super init];
}
@end

// MARK: - VEExportHandle

@interface VEExportHandle ()
- (instancetype)initWithURL:(NSURL *)url settings:(VEExportSettings *)settings;
- (std::shared_ptr<exporting::ExportJob>)job;
- (void)setJob:(std::shared_ptr<exporting::ExportJob>)job;
@end

@implementation VEExportHandle {
    std::mutex _mutex;
    std::shared_ptr<exporting::ExportJob> _job;
    NSURL *_outputURL;
    VEExportSettings *_settings;
}

- (instancetype)initWithURL:(NSURL *)url settings:(VEExportSettings *)settings {
    if ((self = [super init])) {
        _outputURL = [url copy];
        _settings = settings;
    }
    return self;
}

- (NSURL *)outputURL {
    return _outputURL;
}

- (VEExportSettings *)settings {
    return _settings;
}

- (std::shared_ptr<exporting::ExportJob>)job {
    std::lock_guard<std::mutex> lock(_mutex);
    return _job;
}

- (void)setJob:(std::shared_ptr<exporting::ExportJob>)job {
    std::lock_guard<std::mutex> lock(_mutex);
    _job = std::move(job);
}

- (BOOL)isFinished {
    auto job = [self job];
    return job == nullptr || job->isFinished();
}

- (VEExportProgress *)progress {
    auto job = [self job];
    return makeExportProgress(job ? job->progress() : exporting::ExportProgress{});
}

- (void)cancel {
    if (auto job = [self job]) {
        job->cancel();
    }
}

- (BOOL)cancelAndWaitWithTimeout:(NSTimeInterval)timeout {
    auto job = [self job];
    if (!job) {
        return YES;
    }
    job->cancel();
    return job->waitUntilFinished(std::chrono::milliseconds(static_cast<int64_t>(std::max(0.0, timeout) * 1000.0)));
}

@end

// MARK: - Bridges

namespace ve::facade {

media::EncodeSettings makeEncodeSettings(VEExportSettings *settings, CGSize size, int &bitDepth) {
    media::EncodeSettings encode;
    encode.container = containerOf(settings.container);
    media::VideoEncodeSettings video;
    video.codec = codecOf(settings.preset);
    video.width = static_cast<int>(size.width);
    video.height = static_cast<int>(size.height);
    if (settings.preset != VEExportPresetProRes422) {
        if (settings.rateControl == VEExportRateControlBitRate) {
            video.averageBitRate = settings.videoBitRate;
        } else {
            video.quality = std::clamp(settings.quality, 0.0, 1.0);
        }
    }
    video.color = media::ColorInfo::bt709();
    encode.video = video;
    bitDepth = settings.preset == VEExportPresetHEVC10Bit ? 10 : 8;
    if (settings.audioCodec != VEExportAudioCodecNone) {
        media::AudioEncodeSettings audio;
        audio.codec = settings.audioCodec == VEExportAudioCodecPCM ? media::AudioCodec::LinearPCM : media::AudioCodec::AAC;
        audio.sampleRate = double(settings.audioSampleRate);
        audio.channels = int(settings.audioChannels);
        audio.bitRate = int(settings.audioBitRate);
        audio.pcmBitDepth = 16;
        encode.audio = audio;
    }
    return encode;
}

NSArray<VEExportFormat *> *makeExportFormats(NSInteger width, NSInteger height) {
    NSMutableArray<VEExportFormat *> *formats = [NSMutableArray array];
    for (NSNumber *number in allPresets()) {
        const auto preset = VEExportPreset(number.integerValue);
        VEExportFormat *format = [[VEExportFormat alloc] initInternal];
        format.preset = preset;
        format.name = [VEExportSettings nameForPreset:preset];
        format.width = width;
        format.height = height;
        format.unavailableReason = @"";
        format.encoderDescription = @"";
        if (width < 2 || height < 2) {
            format.unavailableReason = @"Choose a frame size first.";
        } else if (preset == VEExportPresetAV1) {
            format.available = media::ffmpeg::FFVideoEncoder::isAvailable(media::VideoCodec::AV1);
            format.encoderDescription = @"SVT-AV1 (software)";
            if (!format.available) {
                format.unavailableReason = @"This build has no AV1 encoder (FFmpeg built without SVT-AV1).";
            }
        } else {
            const uint32_t type = media::codecType(codecOf(preset));
            const media::EncoderAvailability a = media::HardwareCaps::encoderAvailability(
                type, int(width), int(height), preset == VEExportPresetHEVC10Bit);
            format.available = a.hardware || a.software;
            format.hardware = a.hardware;
            format.encoderDescription = a.hardware ? @"VideoToolbox (hardware)" : @"VideoToolbox (software)";
            if (!format.available) {
                format.unavailableReason = toNS(a.reason);
            }
        }
        [formats addObject:format];
    }
    return formats;
}

int64_t estimatedExportBytes(VEExportSettings *settings, CGSize size, double frameRate, double seconds) {
    if (seconds <= 0 || size.width <= 0 || size.height <= 0 || frameRate <= 0) {
        return 0;
    }
    double videoBits = 0;
    if (settings.preset != VEExportPresetProRes422 && settings.rateControl == VEExportRateControlBitRate) {
        videoBits = double(settings.videoBitRate);
    } else {
        videoBits = bitsPerPixel(settings.preset, settings.quality) * double(size.width) * double(size.height) * frameRate;
    }
    double audioBits = 0;
    if (settings.audioCodec == VEExportAudioCodecAAC) {
        audioBits = double(settings.audioBitRate);
    } else if (settings.audioCodec == VEExportAudioCodecPCM) {
        audioBits = double(settings.audioSampleRate) * double(settings.audioChannels) * 16.0;
    }
    // About 1 % container overhead plus the header.
    return static_cast<int64_t>((videoBits + audioBits) * seconds / 8.0 * 1.01) + 32 * 1024;
}

VEExportProgress *makeExportProgress(const exporting::ExportProgress &p) {
    VEExportProgress *progress = [[VEExportProgress alloc] initInternal];
    progress.framesCompleted = p.framesDone;
    progress.totalFrames = p.totalFrames;
    progress.fractionCompleted =
        p.totalFrames > 0 ? std::clamp(double(p.framesDone) / double(p.totalFrames), 0.0, 1.0) : 0.0;
    progress.framesPerSecond = p.framesPerSecond;
    progress.estimatedSecondsRemaining = p.etaSeconds;
    progress.bytesWritten = p.bytesWritten;
    progress.elapsedSeconds = p.elapsedSeconds;
    return progress;
}

VEExportSummary *makeExportSummary(const exporting::ExportSummary &s) {
    VEExportSummary *summary = [[VEExportSummary alloc] initInternal];
    summary.outputURL = [NSURL fileURLWithPath:toNS(s.path)];
    summary.duration = s.duration;
    summary.frameCount = s.frames;
    summary.fileSize = s.bytes;
    summary.width = s.width;
    summary.height = s.height;
    summary.encoderName = toNS(s.videoEncoder);
    summary.hardwareAccelerated = s.hardwareEncoder;
    summary.backendName = toNS(s.writerBackend);
    summary.wallSeconds = s.wallSeconds;
    summary.averageFramesPerSecond = s.averageFps;
    return summary;
}

VEExportHandle *makeExportHandle(NSURL *outputURL, VEExportSettings *settings) {
    return [[VEExportHandle alloc] initWithURL:outputURL settings:settings];
}

void attachExportJob(VEExportHandle *handle, std::shared_ptr<exporting::ExportJob> job) {
    [handle setJob:std::move(job)];
}

std::shared_ptr<exporting::ExportJob> exportJobOf(VEExportHandle *handle) {
    return [handle job];
}

} // namespace ve::facade
