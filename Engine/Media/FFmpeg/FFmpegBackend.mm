#include "FFmpegBackend.h"

#include "../ComposedMediaWriter.h"
#include "FFAudioDecoder.h"
#include "FFAudioEncoder.h"
#include "FFMuxer.h"
#include "FFProber.h"
#include "FFVideoDecoder.h"
#include "FFVideoEncoder.h"
#include "FFmpegSupport.h"

#include <algorithm>
#include <string_view>

namespace ve::media::ffmpeg {

namespace {

bool contains(std::initializer_list<std::string_view> list, std::string_view value) {
    return std::find(list.begin(), list.end(), value) != list.end();
}

bool stillCodecSupported(uint32_t code) {
    const AVCodecID id = codecIdForFourCC(code);
    return (id == AV_CODEC_ID_PNG || id == AV_CODEC_ID_MJPEG || id == AV_CODEC_ID_BMP || id == AV_CODEC_ID_TIFF ||
            id == AV_CODEC_ID_WEBP || id == AV_CODEC_ID_GIF) &&
           canDecode(id);
}

} // namespace

FFmpegBackend::FFmpegBackend() {
    initializeFFmpegOnce();
}

std::string FFmpegBackend::name() const {
    return "ffmpeg";
}

std::unique_ptr<IMediaProber> FFmpegBackend::makeProber() {
    return std::make_unique<FFProber>();
}

std::unique_ptr<IVideoDecoder> FFmpegBackend::makeVideoDecoder() {
    return std::make_unique<FFVideoDecoder>();
}

std::unique_ptr<IAudioDecoder> FFmpegBackend::makeAudioDecoder() {
    return std::make_unique<FFAudioDecoder>();
}

std::unique_ptr<IVideoEncoder> FFmpegBackend::makeVideoEncoder() {
    return std::make_unique<FFVideoEncoder>();
}

std::unique_ptr<IAudioEncoder> FFmpegBackend::makeAudioEncoder() {
    return std::make_unique<FFAudioEncoder>();
}

std::unique_ptr<IMuxer> FFmpegBackend::makeMuxer() {
    return std::make_unique<FFMuxer>();
}

std::unique_ptr<IMediaWriter> FFmpegBackend::makeWriter() {
    return std::make_unique<ComposedMediaWriter>(makeVideoEncoder(), makeAudioEncoder(), makeMuxer());
}

bool FFmpegBackend::canHandle(const MediaInfo &info) const {
    if (info.tracks.empty()) {
        return false;
    }
    const bool stillContainer = contains({"png", "jpeg", "bmp", "tiff", "webp", "gif"}, info.container);
    const bool avContainer = contains({"mov", "mp4", "m4a", "m4v", "mkv", "webm", "avi", "mpegts", "flv", "ogg",
                                       "wav", "w64", "aiff", "caf", "mp3", "flac", "aac", "mxf"},
                                      info.container);
    if (!stillContainer && !avContainer) {
        return false; // Includes "heic" and "avif".
    }
    const bool ownProbe = info.backend == "ffmpeg"; // Then TrackInfo::decodable is our measurement.
    for (const TrackInfo &t : info.tracks) {
        if (ownProbe && !t.decodable) {
            return false;
        }
        switch (t.kind) {
        case TrackKind::Still:
            if (!stillContainer || !stillCodecSupported(t.codec.fourCC)) {
                return false;
            }
            break;
        case TrackKind::Video:
        case TrackKind::Audio: {
            if (!avContainer) {
                return false;
            }
            const AVCodecID id = codecIdForFourCC(t.codec.fourCC);
            const AVMediaType type = avcodec_get_type(id);
            if (!canDecode(id) || type != (t.kind == TrackKind::Video ? AVMEDIA_TYPE_VIDEO : AVMEDIA_TYPE_AUDIO)) {
                return false;
            }
            break;
        }
        }
    }
    return true;
}

Status FFmpegBackend::validate(const EncodeSettings &s) {
    if (!s.video && !s.audio) {
        return makeError(MediaErrorCode::InvalidArgument, "no video or audio stream configured");
    }
    if (s.video) {
        VE_MEDIA_TRY(FFVideoEncoder::validate(*s.video));
        if (s.container == ContainerFormat::WAV || s.container == ContainerFormat::M4A) {
            return makeError(MediaErrorCode::InvalidArgument, "container cannot hold video");
        }
        if (s.container == ContainerFormat::MP4 && s.video->codec == VideoCodec::ProRes422) {
            return makeError(MediaErrorCode::UnsupportedCodec, "ProRes requires a QuickTime (.mov) container");
        }
    }
    if (s.audio) {
        VE_MEDIA_TRY(FFAudioEncoder::validate(*s.audio));
        if (s.container == ContainerFormat::WAV && s.audio->codec != AudioCodec::LinearPCM) {
            return makeError(MediaErrorCode::UnsupportedCodec, "WAV holds linear PCM only");
        }
        if (s.container == ContainerFormat::MP4 && s.audio->codec == AudioCodec::LinearPCM) {
            return makeError(MediaErrorCode::UnsupportedCodec, "MP4 cannot hold linear PCM");
        }
    }
    return okStatus();
}

bool FFmpegBackend::canWrite(const EncodeSettings &settings) const {
    return validate(settings).ok();
}

std::shared_ptr<IMediaBackend> makeFFmpegBackend() {
    return std::make_shared<FFmpegBackend>();
}

} // namespace ve::media::ffmpeg
