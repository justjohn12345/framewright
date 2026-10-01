// What each output container can hold: one table for every writer (review B12 of the 2026-10-01 general
// review: AppleWriter refused linear PCM in .m4a while FFmpegBackend's validation accepted it, so the router
// could send such an export to FFmpeg, whose muxer then refused the stream when the writer opened; the
// muxer and both validations each had their own copy of the rules). The backends add what their own
// encoders and muxers cannot do (AVAssetWriter: no AV1, no Matroska; libavformat's own codec check).
#pragma once

#include "MediaTypes.h"
#include "Result.h"

#include <optional>

namespace ve::media {

/// okStatus() when `container` can hold a video stream of `codec`; InvalidArgument for an audio-only
/// container, else UnsupportedCodec with the reason.
///   MOV  H.264, HEVC, ProRes (not AV1)     MP4  H.264, HEVC, AV1 (not ProRes)
///   MKV  any                               M4A, WAV  no video
Status checkContainerHoldsVideo(ContainerFormat container, VideoCodec codec);
/// okStatus() when `container` can hold an audio stream of `codec`, else UnsupportedCodec with the reason.
///   MOV, MKV  AAC or linear PCM            MP4, M4A  AAC only            WAV  linear PCM only
Status checkContainerHoldsAudio(ContainerFormat container, AudioCodec codec);
/// Both, for the streams `settings` configures.
Status checkContainerHolds(const EncodeSettings &settings);

/// The codec of a stream given by its fourcc, where the table above names it (nullopt: another codec,
/// which only a muxer's own check can decide).
std::optional<VideoCodec> videoCodecForFourCC(uint32_t fourCC);
std::optional<AudioCodec> audioCodecForFourCC(uint32_t fourCC);

} // namespace ve::media
