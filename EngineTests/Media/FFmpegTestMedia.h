// Media derived from the generated conformance media with FFmpeg: Matroska copies of the
// conformance clips, and special-purpose files the AVFoundation-based generator cannot write
// (Matroska/WebM timing variants, AV1, MPEG-4 Part 2 ASP, Opus/Vorbis/FLAC, ADTS, MPEG-TS).
//
// Two tools make them:
// - ve::media::ffmpeg::remux (engine code, always available): pure stream copies, so frames,
//   burn-ins and audio are bit-identical to the source; only the container (and its millisecond
//   time base) differs.
// - The static ffmpeg command-line tool that Scripts/build-ffmpeg.sh builds into
//   ThirdParty/ffmpeg/tools/bin (for re-encodes). Files that need it are unavailable when it was
//   not built (BUILD_TOOLS=0); tests then report XCTSkip, never a silent pass.
#pragma once

#include "TestMedia.h"

#include <string>
#include <vector>

namespace ve::test {

/// Directory holding the .mkv remuxes, a sibling of testMediaDirectory() ("<dir>-mkv<version>").
/// Created on first use (thread-safe); empty with `error` set on failure.
std::string mkvTestMediaDirectory(std::string &error);

/// The clips that are remuxed: h264_1080p30 and hevc_720p2997 as ".mkv", container "mkv",
/// every other property as in testClips().
const std::vector<TestClip> &mkvTestClips();

/// Stream-copies `source` into a Matroska file at `destination` (ffmpeg::remux): AAC encoder delay
/// from the source's edit list becomes CodecDelay.
bool remuxToMatroska(const std::string &source, const std::string &destination, std::string &error);

/// The ffmpeg command-line tool (ThirdParty/ffmpeg/tools/bin/ffmpeg), or "" if it was not built.
std::string ffmpegToolPath();

// Derived special-purpose files (all derived from the generated clips of TestMedia.h):
//   vfr_h264_defaultdur.mkv    vfr_h264.mp4 remuxed with a DefaultDuration (the nominal average
//                              rate) and no BlockDurations: the mkvmerge layout, where a reader
//                              sees only the nominal duration for every frame.
//   vfr_h264_nodefaultdur.mkv  vfr_h264.mp4 remuxed with neither DefaultDuration nor BlockDurations.
//   vfr_h264_blockdur.mkv      vfr_h264.mp4 remuxed by libavformat's defaults: DefaultDuration plus
//                              a BlockDuration on every frame whose duration differs.
//   rotated90_h264.mkv         rotated90_h264.mp4 remuxed (rotation as ProjectionPoseRoll).
//   vfr_av1.webm               vfr_h264.mp4 re-encoded to AV1 (SVT-AV1), timestamps passed through.   [tool]
//   av1_640.mp4 / av1_640.webm the first 4 s of h264_1080p30.mp4 scaled to 640x360, AV1, GOP 30.      [tool]
//   asp_mpeg4.mp4              the same 4 s as MPEG-4 Part 2 Advanced Simple Profile with B-frames in
//                              MP4 (Xvid-style), plus the source's AAC stream-copied: AVFoundation
//                              loads the video but VideoToolbox rejects it (codecBadDataErr), while
//                              the audio is ordinary.                                                [tool]
//   opus.webm                  audio_only.wav as Opus in WebM (native libavcodec encoder).           [tool]
//   vorbis.mkv                 audio_only.wav as Vorbis in Matroska.                                   [tool]
//   flac.mp4                   audio_only.wav as FLAC in MP4 (sample entry 'fLaC').                    [tool]
//   aac_adts.aac               audio_only.m4a's AAC stream copied into a raw ADTS stream.              [tool]
//   h264_offset.ts             h264_1080p30.mp4 copied into MPEG-TS with a 10 s timestamp offset.      [tool]
//   live_no_duration.mkv       h264_1080p30.mp4 in "live" Matroska: no Duration, no DURATION tags,
//                              no Cues (what a crashed recorder leaves behind).                      [tool]
//   audio_gap.mkv              6 s of audio_only.wav as PCM whose timestamps jump by 600 s after
//                              3 s (a discontinuity / damaged timestamp).                            [tool]

/// Whether `file` is made with the command-line tool (see the table above).
bool derivedNeedsTool(const std::string &file);

/// Path of a derived file, generating every derived file on first use into a cached sibling
/// of testMediaDirectory() keyed by the recipes and the tool build. Empty with `error` set if it
/// cannot be made (for [tool] files: also when the tool is missing, see derivedNeedsTool).
std::string derivedMediaPath(const std::string &file, std::string &error);

} // namespace ve::test
