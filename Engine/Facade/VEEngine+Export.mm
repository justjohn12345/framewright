// VEEngine (Export): export formats and estimates, and running an export of the active sequence
// (the monitors pause and give up their lookahead while it runs).

#import "VEEngine+Internal.h"

#import "VEExport+Internal.h"
#import "VEExporter+Internal.h"
#import "VEMediaLibrary+Internal.h"

#include "../Export/ExportJob.h"

#include <memory>

using namespace ve;
using namespace ve::facade;

namespace {

/// The engine's error code for a refused export start.
VEEngineErrorCode errorCodeFor(ExportRefusalReason reason) {
    switch (reason) {
    case ExportRefusalReason::Busy:
        return VEEngineErrorBusy;
    case ExportRefusalReason::Unsupported:
        return VEEngineErrorExportUnsupported;
    case ExportRefusalReason::OutputNotWritable:
        return VEEngineErrorOutputNotWritable;
    case ExportRefusalReason::MissingMedia:
        return VEEngineErrorMissingMedia;
    }
    return VEEngineErrorExportUnsupported;
}

} // namespace

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
    return _exporter.activeExport;
}

- (BOOL)isExporting {
    VE_ASSERT_MAIN();
    return _exporter.isExporting;
}

- (nullable VEExportHandle *)beginExportWithSettings:(VEExportSettings *)settings
                                           outputURL:(NSURL *)outputURL
                                            progress:(nullable void (^)(VEExportProgress *progress))progress
                                          completion:(void (^)(VEExportSummary *_Nullable summary,
                                                               NSError *_Nullable error))completion
                                               error:(NSError *_Nullable *_Nullable)error {
    VE_ASSERT_MAIN();
    // Another export running is the exporter's refusal (it comes first); a gesture in progress
    // is the engine's.
    if (!_exporter.isExporting && _undo.coalescingKey != nil) {
        if (error != nullptr) {
            *error = makeError(VEEngineErrorBusy, @"Finish the current edit (a drag or slider) before exporting.");
        }
        return nil;
    }
    exporting::ExportServices services;
    services.router = _services.router;
    services.cache = _services.frameCache;
    services.epoch = _services.epoch;
    services.routing = _media.routing;
    exporting::ExportOptions options;
    options.poolBudgetFraction = kExportPoolBudgetShare;

    __weak VEEngine *weakSelf = self;
    void (^progressBlock)(VEExportProgress *) = [progress copy];
    void (^completionBlock)(VEExportSummary *, NSError *) = [completion copy];
    VEExporterProgressBlock onProgress = ^(VEExportProgress *report) {
      VEEngine *strongSelf = weakSelf;
      if (strongSelf != nil) {
          [NSNotificationCenter.defaultCenter postNotificationName:VEEngineExportDidProgressNotification
                                                            object:strongSelf
                                                          userInfo:@{VEEngineExportProgressKey : report}];
      }
      if (progressBlock) {
          progressBlock(report);
      }
    };
    VEExporterFinishBlock onFinish = ^(const media::Result<exporting::ExportSummary> &result, BOOL endedRunningExport) {
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
          if (endedRunningExport) {
              // The monitors' stopped lookahead resumes at their paused frames (the source
              // monitor's only while it is on screen).
              strongSelf->_program.playback->setIdleLookahead(true);
              [strongSelf updateSourceIdleLookahead];
          }
          [NSNotificationCenter.defaultCenter
              postNotificationName:VEEngineExportDidFinishNotification
                            object:strongSelf
                          userInfo:summary ? @{VEEngineExportSummaryKey : summary} : @{VEEngineExportErrorKey : failure}];
      }
      completionBlock(summary, failure);
    };
    ExportRefusal refusal;
    VEExportHandle *handle = [_exporter beginExportOfProject:_project
                                                    settings:settings
                                                   outputURL:outputURL
                                                    services:std::move(services)
                                                     options:options
                                                    progress:onProgress
                                                      finish:onFinish
                                                     refusal:&refusal];
    if (handle == nil) {
        if (error != nullptr) {
            *error = makeError(errorCodeFor(refusal.reason), refusal.message);
        }
        return nil;
    }
    // The monitors pause (the export gets the decoders and the GPU); they keep their own pools,
    // and both stop decoding their stopped lookahead (their decoders are released) until the
    // export ends. The paused pictures still come through the scrub path.
    _program.playback->pause();
    _program.playback->setIdleLookahead(false);
    if (_source.playback) {
        _source.playback->pause();
    }
    [self updateSourceIdleLookahead];
    return handle;
}

@end

@implementation VEEngine (ExportInternal)

// MARK: - Private (VEEngine+Internal.h declares what other files call)

/// Playback does not start while an export runs (the export has the decoders and the GPU; the
/// monitors were paused when it began).
- (BOOL)refusesPlaybackForExport {
    return _exporter.isExporting;
}

@end
