// VEEngine (Export): export formats and estimates, and running an export of the active sequence
// (the monitors pause and give up their lookahead while it runs).

#import "VEEngine+Internal.h"

#import "VEExport+Internal.h"

#include "../Export/ExportJob.h"

#include <memory>

using namespace ve;
using namespace ve::facade;

@implementation VEEngine (Export)

// MARK: - Export

- (NSArray<VEExportFormat *> *)exportFormatsForWidth:(NSInteger)width height:(NSInteger)height {
    VE_ASSERT_MAIN();
    return makeExportFormats(width, height);
}

- (void)exportFormatsForWidth:(NSInteger)width
                       height:(NSInteger)height
                   completion:(void (^)(NSArray<VEExportFormat *> *formats))completion {
    VE_ASSERT_MAIN();
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
      NSArray<VEExportFormat *> *formats = makeExportFormats(width, height);
      dispatch_async(dispatch_get_main_queue(), ^{
        completion(formats);
      });
    });
}

- (CGSize)exportSizeForSettings:(VEExportSettings *)settings {
    VE_ASSERT_MAIN();
    const Sequence &sequence = [self activeSequence];
    return [settings outputSizeForSequenceWidth:sequence.width height:sequence.height];
}

- (int64_t)estimatedFileSizeForSettings:(VEExportSettings *)settings {
    VE_ASSERT_MAIN();
    const Sequence &sequence = [self activeSequence];
    const CMTime duration = sequence.duration();
    if (!(duration > kCMTimeZero) || !isPositive(sequence.frameDuration)) {
        return 0;
    }
    const CGSize size = [settings outputSizeForSequenceWidth:sequence.width height:sequence.height];
    return estimatedExportBytes(settings, size, 1.0 / CMTimeGetSeconds(sequence.frameDuration),
                                CMTimeGetSeconds(duration), sequence.audioSampleRate);
}

- (nullable VEExportHandle *)activeExport {
    VE_ASSERT_MAIN();
    return _activeExport;
}

- (BOOL)isExporting {
    VE_ASSERT_MAIN();
    return _activeExport != nil;
}

- (void)stopAccessingExportURL {
    [_exportAccessedURL stopAccessingSecurityScopedResource];
    _exportAccessedURL = nil;
}

- (nullable VEExportHandle *)beginExportWithSettings:(VEExportSettings *)settings
                                           outputURL:(NSURL *)outputURL
                                            progress:(nullable void (^)(VEExportProgress *progress))progress
                                          completion:(void (^)(VEExportSummary *_Nullable summary,
                                                               NSError *_Nullable error))completion
                                               error:(NSError *_Nullable *_Nullable)error {
    VE_ASSERT_MAIN();
    auto refuse = [&](VEEngineErrorCode code, NSString *message) -> VEExportHandle * {
        if (error != nullptr) {
            *error = makeError(code, message);
        }
        return nil;
    };
    if (_activeExport != nil) {
        return refuse(VEEngineErrorBusy, @"An export is already running.");
    }
    if (_coalescingKey != nil) {
        return refuse(VEEngineErrorBusy, @"Finish the current edit (a drag or slider) before exporting.");
    }
    if (NSString *invalid = settings.validationMessage) {
        return refuse(VEEngineErrorExportUnsupported, invalid);
    }
    if (!outputURL.isFileURL) {
        return refuse(VEEngineErrorOutputNotWritable, @"The export needs a file location.");
    }
    const Sequence &sequence = [self activeSequence];
    const CGSize size = [settings outputSizeForSequenceWidth:sequence.width height:sequence.height];
    if (size.width < 2 || size.height < 2) {
        return refuse(VEEngineErrorExportUnsupported, @"The export frame size is not usable.");
    }
    exporting::ExportRequest request;
    request.project = std::make_shared<const Project>(_project);
    request.sequenceId = _project.activeSequenceId;
    request.encode = makeEncodeSettings(settings, size, sequence.audioSampleRate, request.videoBitDepth);
    request.outputPath = outputURL.path.fileSystemRepresentation ?: "";
    exporting::ExportServices services;
    services.router = _router;
    services.cache = _frameCache;
    services.epoch = _mediaEpoch;
    services.routing = _routing;
    exporting::ExportOptions options;
    options.poolBudgetFraction = kExportPoolBudgetShare;

    const BOOL accessing = [outputURL startAccessingSecurityScopedResource];
    VEExportHandle *handle = makeExportHandle(outputURL, settings);
    __weak VEEngine *weakSelf = self;
    __weak VEExportHandle *weakHandle = handle;
    void (^progressBlock)(VEExportProgress *) = [progress copy];
    void (^completionBlock)(VEExportSummary *, NSError *) = [completion copy];
    auto onProgress = [weakSelf, progressBlock](const exporting::ExportProgress &p) {
        VEEngine *strongSelf = weakSelf;
        VEExportProgress *report = makeExportProgress(p);
        if (strongSelf != nil) {
            [NSNotificationCenter.defaultCenter postNotificationName:VEEngineExportDidProgressNotification
                                                              object:strongSelf
                                                            userInfo:@{VEEngineExportProgressKey : report}];
        }
        if (progressBlock) {
            progressBlock(report);
        }
    };
    auto onCompletion = [weakSelf, weakHandle, completionBlock](media::Result<exporting::ExportSummary> result) {
        VEEngine *strongSelf = weakSelf;
        VEExportSummary *summary = nil;
        NSError *failure = nil;
        if (result.ok()) {
            summary = makeExportSummary(result.value());
        } else {
            const media::MediaError &e = result.error();
            failure = makeError(e.code == media::MediaErrorCode::Cancelled ? VEEngineErrorExportCancelled
                                                                           : VEEngineErrorExportFailed,
                                toNS(e.message.empty() ? e.description() : e.message));
        }
        if (strongSelf != nil) {
            if (strongSelf->_activeExport == weakHandle) {
                strongSelf->_activeExport = nil;
                [strongSelf stopAccessingExportURL];
                // The monitors' stopped lookahead resumes at their paused frames (the source
                // monitor's only while it is on screen).
                strongSelf->_playback->setIdleLookahead(true);
                [strongSelf updateSourceIdleLookahead];
            }
            [NSNotificationCenter.defaultCenter
                postNotificationName:VEEngineExportDidFinishNotification
                              object:strongSelf
                            userInfo:summary ? @{VEEngineExportSummaryKey : summary} : @{VEEngineExportErrorKey : failure}];
        }
        completionBlock(summary, failure);
    };
    auto started = exporting::ExportJob::start(std::move(request), std::move(services), options,
                                               dispatch_get_main_queue(), onProgress, onCompletion);
    if (!started.ok()) {
        if (accessing) {
            [outputURL stopAccessingSecurityScopedResource];
        }
        const media::MediaError &e = started.error();
        VEEngineErrorCode code = VEEngineErrorExportUnsupported;
        if (e.code == media::MediaErrorCode::FileNotFound) {
            code = VEEngineErrorMissingMedia;
        } else if (e.code == media::MediaErrorCode::PermissionDenied) {
            code = VEEngineErrorOutputNotWritable;
        }
        return refuse(code, toNS(e.message));
    }
    attachExportJob(handle, std::move(started).value());
    _activeExport = handle;
    _exportAccessedURL = accessing ? outputURL : nil;
    // The monitors pause (the export gets the decoders and the GPU); they keep their own pools,
    // and both stop decoding their stopped lookahead (their decoders are released) until the
    // export ends. The paused pictures still come through the scrub path.
    _playback->pause();
    _playback->setIdleLookahead(false);
    if (_sourcePlayback) {
        _sourcePlayback->pause();
    }
    [self updateSourceIdleLookahead];
    return handle;
}

@end

@implementation VEEngine (ExportInternal)

/// Playback does not start while an export runs (the export has the decoders and the GPU; the
/// monitors were paused when it began).
- (BOOL)refusesPlaybackForExport {
    return _activeExport != nil;
}

@end
