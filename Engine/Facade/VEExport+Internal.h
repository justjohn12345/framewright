// Obj-C++ bridges between the facade's export types (VEExport.h) and the engine's ExportJob.
// Private to the facade implementation: excluded from the framework's headers (project.yml).

#pragma once

#import "VEExport.h"

#include "../Export/ExportJob.h"
#include "../Media/MediaTypes.h"

#include <memory>

namespace ve::facade {

/// Encoder settings for `settings` at the output size `size` (see VEExportSettings); the bit
/// depth the job renders at goes to `bitDepth`.
media::EncodeSettings makeEncodeSettings(VEExportSettings *settings, CGSize size, int &bitDepth);

/// Availability of every preset at `width` x `height` (probes VideoToolbox; cached per size).
NSArray<VEExportFormat *> *makeExportFormats(NSInteger width, NSInteger height);

/// Approximate output size in bytes for `settings` at `size`, `frameRate` and `seconds`.
int64_t estimatedExportBytes(VEExportSettings *settings, CGSize size, double frameRate, double seconds);

VEExportProgress *makeExportProgress(const exporting::ExportProgress &progress);
VEExportSummary *makeExportSummary(const exporting::ExportSummary &summary);
VEExportHandle *makeExportHandle(NSURL *outputURL, VEExportSettings *settings);
/// Attaches the running job to its handle (after ExportJob::start succeeded).
void attachExportJob(VEExportHandle *handle, std::shared_ptr<exporting::ExportJob> job);
std::shared_ptr<exporting::ExportJob> exportJobOf(VEExportHandle *handle);

} // namespace ve::facade
