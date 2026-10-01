// VEExporter: see VEExporter+Internal.h.

#import "VEExporter+Internal.h"

#import "VEExport+Internal.h"
#import "VEFacadeSupport+Internal.h"
#import "VETypes+Internal.h"

#include <memory>
#include <utility>

// This class knows nothing of the engine (VEEngine+Internal.h, "Facade layout"): neither its header nor
// this file may bring in the engine's headers, directly or through another header.
#if defined(VE_ENGINE_HEADER_INCLUDED) || defined(VE_ENGINE_INTERNAL_HEADER_INCLUDED)
#error "VEExporter must not depend on VEEngine: it reaches it only through what the engine passes in"
#endif

using namespace ve;
using namespace ve::facade;

@implementation VEExporter {
    VEExportHandle *_active; // the running export
}

- (void)dealloc {
    [_active cancel]; // the job deletes its partial file on its own queue
}

- (nullable VEExportHandle *)activeExport {
    VE_ASSERT_MAIN();
    return _active;
}

- (BOOL)isExporting {
    VE_ASSERT_MAIN();
    return _active != nil;
}

- (nullable VEExportHandle *)beginExportOfProject:(const Project &)project
                                         settings:(VEExportSettings *)settings
                                        outputURL:(NSURL *)outputURL
                                         services:(exporting::ExportServices)services
                                          options:(exporting::ExportOptions)options
                                         progress:(VEExporterProgressBlock)progress
                                           finish:(VEExporterFinishBlock)finish
                                          refusal:(ExportRefusal *_Nullable)refusal {
    VE_ASSERT_MAIN();
    auto refuse = [&](ExportRefusalReason reason, NSString *message) -> VEExportHandle * {
        if (refusal != nullptr) {
            *refusal = ExportRefusal{reason, message};
        }
        return nil;
    };
    if (_active != nil) {
        return refuse(ExportRefusalReason::Busy, @"An export is already running.");
    }
    if (NSString *invalid = settings.validationMessage) {
        return refuse(ExportRefusalReason::Unsupported, invalid);
    }
    if (!outputURL.isFileURL) {
        return refuse(ExportRefusalReason::OutputNotWritable, @"The export needs a file location.");
    }
    const Sequence *sequence = project.activeSequence();
    if (sequence == nullptr) {
        return refuse(ExportRefusalReason::Unsupported, @"The project has no sequence to export.");
    }
    const CGSize size = [settings outputSizeForSequenceWidth:sequence->width height:sequence->height];
    if (size.width < 2 || size.height < 2) {
        return refuse(ExportRefusalReason::Unsupported, @"The export frame size is not usable.");
    }
    exporting::ExportRequest request;
    request.project = std::make_shared<const Project>(project);
    request.sequenceId = project.activeSequenceId;
    request.encode = makeEncodeSettings(settings, size, sequence->audioSampleRate, request.videoBitDepth);
    request.outputPath = outputURL.path.fileSystemRepresentation ?: "";
    // The sequence's audio rate is what the export writes (8 to 192 kHz); AAC takes fewer rates than PCM
    // (Apple's encoder 22.05 to 48 kHz at most bit rates, FFmpeg's, the router's fallback, its standard rates up
    // to 96 kHz). Refused here with what to do, rather than failing once the job opens its writer.
    if (request.encode.audio && request.encode.audio->codec == media::AudioCodec::AAC && services.router &&
        services.router->writerBackendFor(request.encode).empty()) {
        media::EncodeSettings withoutAudio = request.encode;
        withoutAudio.audio.reset();
        if (!services.router->writerBackendFor(withoutAudio).empty()) {
            return refuse(ExportRefusalReason::Unsupported,
                          [NSString stringWithFormat:@"AAC audio cannot be written at %g kHz, the sequence's audio "
                                                     @"rate. Choose PCM audio in a QuickTime (MOV) file, or set the "
                                                     @"sequence's audio to 48 kHz in Sequence Settings.",
                                                     double(sequence->audioSampleRate) / 1000.0]);
        }
    }

    const BOOL accessing = [outputURL startAccessingSecurityScopedResource];
    VEExportHandle *handle = makeExportHandle(outputURL, settings);
    __weak VEExporter *weakSelf = self;
    __weak VEExportHandle *weakHandle = handle;
    VEExporterProgressBlock progressBlock = [progress copy];
    VEExporterFinishBlock finishBlock = [finish copy];
    auto onProgress = [progressBlock](const exporting::ExportProgress &p) {
        progressBlock(makeExportProgress(p));
    };
    // The completion owns the output URL's security-scoped access: it runs once per started job, after
    // the job tore its run down (a cancelled job has deleted its partial file by then, which needs the
    // access), and ends the access whether or not this exporter still exists (released mid-export, it
    // cannot end it: the job still works on its own queue when dealloc cancels it).
    NSURL *accessedURL = accessing ? outputURL : nil;
    auto onCompletion = [weakSelf, weakHandle, finishBlock,
                         accessedURL](media::Result<exporting::ExportSummary> result) {
        [accessedURL stopAccessingSecurityScopedResource];
        VEExporter *strongSelf = weakSelf;
        BOOL endedRunningExport = NO;
        if (strongSelf != nil && strongSelf->_active == weakHandle) {
            strongSelf->_active = nil;
            endedRunningExport = YES;
        }
        finishBlock(result, endedRunningExport);
    };
    auto started = exporting::ExportJob::start(std::move(request), std::move(services), options,
                                               dispatch_get_main_queue(), onProgress, onCompletion);
    if (!started.ok()) {
        if (accessing) {
            [outputURL stopAccessingSecurityScopedResource];
        }
        const media::MediaError &e = started.error();
        ExportRefusalReason reason = ExportRefusalReason::Unsupported;
        if (e.code == media::MediaErrorCode::FileNotFound) {
            reason = ExportRefusalReason::MissingMedia;
        } else if (e.code == media::MediaErrorCode::PermissionDenied) {
            reason = ExportRefusalReason::OutputNotWritable;
        }
        return refuse(reason, toNS(e.message));
    }
    attachExportJob(handle, std::move(started).value());
    _active = handle;
    return handle;
}

// No main-thread check: the engine's dealloc calls it, and the engine only logs a fault when its
// last reference goes away off the main thread (cancelling is thread safe).
- (void)cancel {
    [_active cancel]; // the job deletes its partial file on its own queue
}

- (void)handleMemoryPressure:(BOOL)critical {
    VE_ASSERT_MAIN();
    if (auto job = exportJobOf(_active)) {
        job->handleMemoryPressure(critical);
    }
}

@end
