// VEExporter: the running export of the facade. It starts an ExportJob for a project snapshot,
// keeps the job's handle and the security-scoped access to its output URL while it runs, and
// reports the job's progress and end through the blocks each start is given. It knows nothing of
// the engine that owns it: the engine checks its own rules before a start (a coalescing gesture),
// passes the shared media services and the routing in, turns a refusal into its NSError and pauses
// the monitors around the export.
// Private to the facade implementation: excluded from the framework's headers (project.yml).

#pragma once

#import "VEExport.h"

#include "../Export/ExportJob.h"
#include "../Media/MediaTypes.h"
#include "../Model/Project.h"

namespace ve::facade {

/// Why VEExporter did not start an export (the engine maps it to its own error code).
enum class ExportRefusalReason {
    Busy,              ///< another export is running
    Unsupported,       ///< invalid settings or frame size, no encoder takes them, an empty sequence, ...
    OutputNotWritable, ///< not a file URL, or the output cannot be written
    MissingMedia,      ///< media a clip uses is missing or unreadable
};

/// A refused start: the reason and the sentence to show.
struct ExportRefusal {
    ExportRefusalReason reason = ExportRefusalReason::Unsupported;
    NSString *_Nonnull message = @"";
};

} // namespace ve::facade

NS_ASSUME_NONNULL_BEGIN

/// Called on the main thread with each progress report of the running export (at most 10 Hz).
typedef void (^VEExporterProgressBlock)(VEExportProgress *progress);
/// Called once on the main thread when the export ends: `result` is the job's summary, or its
/// error (MediaErrorCode::Cancelled after a cancel). `endedRunningExport` is YES when the export
/// was still the exporter's running export: the exporter has just cleared it (isExporting is NO).
/// It is NO when the exporter is gone. Either way the access to the output URL has ended.
typedef void (^VEExporterFinishBlock)(const ve::media::Result<ve::exporting::ExportSummary> &result,
                                      BOOL endedRunningExport);

/// Main thread only. At most one export runs at a time.
@interface VEExporter : NSObject

/// The running export, or nil.
@property (nonatomic, readonly, nullable) VEExportHandle *activeExport;
@property (nonatomic, readonly) BOOL isExporting;

/// Starts exporting the active sequence of `project` (a snapshot is taken: later edits do not
/// affect it) with `settings` to `outputURL`, decoding through `services` with `options`. Refused,
/// returning nil with `refusal` filled in and no file created, while another export runs, for
/// invalid settings or an unusable frame size, a URL that is not a file URL, and whatever
/// ExportJob::start refuses. `progress` and `finish` run on the main thread (finish exactly once
/// per started export). A security-scoped `outputURL` is accessed until the export ends: the
/// job's completion ends the access (after a cancelled job deleted its partial file), also when the
/// exporter was released while the export ran.
- (nullable VEExportHandle *)beginExportOfProject:(const ve::Project &)project
                                         settings:(VEExportSettings *)settings
                                        outputURL:(NSURL *)outputURL
                                         services:(ve::exporting::ExportServices)services
                                          options:(ve::exporting::ExportOptions)options
                                         progress:(VEExporterProgressBlock)progress
                                           finish:(VEExporterFinishBlock)finish
                                          refusal:(ve::facade::ExportRefusal *_Nullable)refusal;

/// Cancels the running export, if any (non-blocking: it ends through its finish block, and the job
/// deletes its partial file on its own queue). Also done when the exporter is deallocated.
- (void)cancel;

/// Passes memory pressure to the running export's job, if any.
- (void)handleMemoryPressure:(BOOL)critical;

@end

NS_ASSUME_NONNULL_END
