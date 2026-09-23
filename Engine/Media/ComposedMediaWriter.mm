#include "ComposedMediaWriter.h"

#include <vector>

namespace ve::media {

ComposedMediaWriter::ComposedMediaWriter(std::unique_ptr<IVideoEncoder> videoEncoder,
                                         std::unique_ptr<IAudioEncoder> audioEncoder, std::unique_ptr<IMuxer> muxer)
    : videoEncoder_(std::move(videoEncoder)), audioEncoder_(std::move(audioEncoder)), muxer_(std::move(muxer)) {}

ComposedMediaWriter::~ComposedMediaWriter() {
    if (state_ == State::Writing) {
        muxer_->cancel();
    }
}

Status ComposedMediaWriter::fail(MediaError error) {
    if (state_ == State::Writing) {
        muxer_->cancel();
    }
    state_ = State::Failed;
    return error;
}

PacketSink ComposedMediaWriter::sinkFor(int streamIndex) {
    return [this, streamIndex](EncodedPacket &&packet) -> Status {
        packet.streamIndex = streamIndex;
        return muxer_->writePacket(std::move(packet));
    };
}

Status ComposedMediaWriter::open(const std::string &path, const EncodeSettings &settings) {
    if (state_ != State::Idle) {
        return makeError(MediaErrorCode::InvalidState, "open() called twice");
    }
    if (!muxer_) {
        return makeError(MediaErrorCode::InvalidArgument, "no muxer");
    }
    if (!settings.video && !settings.audio) {
        return makeError(MediaErrorCode::InvalidArgument, "no video or audio stream configured");
    }
    if ((settings.video && !videoEncoder_) || (settings.audio && !audioEncoder_)) {
        return makeError(MediaErrorCode::UnsupportedCodec, "no encoder for a configured stream");
    }
    settings_ = settings;
    VE_MEDIA_TRY(muxer_->open(path, settings.container));
    state_ = State::Writing;
    if (settings.video) {
        if (Status s = videoEncoder_->open(*settings.video); !s.ok()) {
            return fail(std::move(s).error());
        }
        auto format = videoEncoder_->outputFormat();
        if (!format.ok()) {
            return fail(std::move(format).error());
        }
        auto index = muxer_->addStream(format.value());
        if (!index.ok()) {
            return fail(std::move(index).error());
        }
        videoStream_ = index.value();
        const VideoEncodeSettings &v = *settings.video;
        auto pool = PixelBufferPool::create(v.inputPixelFormat, static_cast<size_t>(v.width),
                                            static_cast<size_t>(v.height));
        if (!pool.ok()) {
            return fail(std::move(pool).error());
        }
        pool_ = std::move(pool).value();
    }
    if (settings.audio) {
        if (Status s = audioEncoder_->open(*settings.audio); !s.ok()) {
            return fail(std::move(s).error());
        }
        auto format = audioEncoder_->outputFormat();
        if (!format.ok()) {
            return fail(std::move(format).error());
        }
        auto index = muxer_->addStream(format.value());
        if (!index.ok()) {
            return fail(std::move(index).error());
        }
        audioStream_ = index.value();
    }
    if (Status s = muxer_->begin(); !s.ok()) {
        return fail(std::move(s).error());
    }
    return okStatus();
}

Result<PixelBuffer> ComposedMediaWriter::makePixelBuffer() {
    if (state_ != State::Writing || !pool_) {
        return makeError(MediaErrorCode::InvalidState, "makePixelBuffer() needs an open writer with video");
    }
    return pool_.makeBuffer();
}

Status ComposedMediaWriter::appendVideo(const PixelBuffer &image, CMTime pts) {
    if (state_ != State::Writing || videoStream_ < 0 || videoEnded_) {
        return makeError(MediaErrorCode::InvalidState, "appendVideo() needs an open writer with video");
    }
    if (!image || !CMTIME_IS_NUMERIC(pts) ||
        (CMTIME_IS_NUMERIC(lastVideoPts_) && CMTimeCompare(pts, lastVideoPts_) <= 0)) {
        return makeError(MediaErrorCode::InvalidArgument, "video needs an image and strictly increasing pts");
    }
    if (Status s = videoEncoder_->encode(image, pts, sinkFor(videoStream_)); !s.ok()) {
        return fail(std::move(s).error());
    }
    lastVideoPts_ = pts;
    return okStatus();
}

Status ComposedMediaWriter::appendAudio(const float *interleaved, int frames) {
    if (state_ != State::Writing || audioStream_ < 0 || audioEnded_) {
        return makeError(MediaErrorCode::InvalidState, "appendAudio() needs an open writer with audio");
    }
    if (frames < 0 || (frames > 0 && interleaved == nullptr)) {
        return makeError(MediaErrorCode::InvalidArgument, "appendAudio() needs data");
    }
    if (frames == 0) {
        return okStatus();
    }
    if (Status s = audioEncoder_->encode(interleaved, frames, sinkFor(audioStream_)); !s.ok()) {
        return fail(std::move(s).error());
    }
    audioFrames_ += frames;
    return okStatus();
}

Status ComposedMediaWriter::endStream(TrackKind kind) {
    if (state_ != State::Writing) {
        return makeError(MediaErrorCode::InvalidState, "endStream() needs an open writer");
    }
    if (kind == TrackKind::Video && videoStream_ >= 0) {
        if (!videoEnded_) {
            videoEnded_ = true;
            if (Status s = videoEncoder_->flush(sinkFor(videoStream_)); !s.ok()) {
                return fail(std::move(s).error());
            }
        }
        return okStatus();
    }
    if (kind == TrackKind::Audio && audioStream_ >= 0) {
        if (!audioEnded_) {
            audioEnded_ = true;
            if (Status s = audioEncoder_->flush(sinkFor(audioStream_)); !s.ok()) {
                return fail(std::move(s).error());
            }
        }
        return okStatus();
    }
    return makeError(MediaErrorCode::InvalidArgument, "endStream() for a stream that is not configured");
}

Status ComposedMediaWriter::runPull(const VideoPullFn &video, const AudioPullFn &audio) {
    if (state_ != State::Writing) {
        return makeError(MediaErrorCode::InvalidState, "runPull() needs an open writer");
    }
    if ((videoStream_ >= 0 && !video) || (audioStream_ >= 0 && !audio)) {
        return makeError(MediaErrorCode::InvalidArgument, "runPull() needs a callback for every configured stream");
    }
    bool videoDone = videoStream_ < 0;
    bool audioDone = audioStream_ < 0;
    std::vector<float> chunk;
    if (!audioDone) {
        chunk.resize(static_cast<size_t>(kPullAudioChunkFrames * settings_.audio->channels));
    }
    CMTime nextVideo = kCMTimeZero;
    while (!videoDone || !audioDone) {
        const CMTime audioTime =
            audioDone ? kCMTimePositiveInfinity
                      : CMTimeMake(audioFrames_, static_cast<int32_t>(settings_.audio->sampleRate));
        const bool pullVideo = !videoDone && (audioDone || CMTimeCompare(nextVideo, audioTime) <= 0);
        if (pullVideo) {
            auto frame = video();
            if (!frame.ok()) {
                return fail(std::move(frame).error());
            }
            if (!frame.value()) {
                // Flush the encoder now: the muxer interleaves by time and would otherwise hold
                // every later audio packet back waiting for video that never comes.
                videoDone = true;
                VE_MEDIA_TRY(endStream(TrackKind::Video));
                continue;
            }
            VE_MEDIA_TRY(appendVideo(frame.value()->image, frame.value()->pts));
            nextVideo = CMTimeAdd(frame.value()->pts, settings_.video->frameDuration);
        } else {
            auto n = audio(chunk.data(), kPullAudioChunkFrames);
            if (!n.ok()) {
                return fail(std::move(n).error());
            }
            if (n.value() <= 0) {
                audioDone = true;
                VE_MEDIA_TRY(endStream(TrackKind::Audio));
                continue;
            }
            if (n.value() > kPullAudioChunkFrames) {
                return fail(makeError(MediaErrorCode::InvalidArgument, "audio pull returned more than maxFrames"));
            }
            VE_MEDIA_TRY(appendAudio(chunk.data(), n.value()));
        }
    }
    return okStatus();
}

Status ComposedMediaWriter::finish() {
    if (state_ != State::Writing) {
        return makeError(MediaErrorCode::InvalidState, "finish() needs an open writer");
    }
    if (videoStream_ >= 0) {
        VE_MEDIA_TRY(endStream(TrackKind::Video));
    }
    if (audioStream_ >= 0) {
        VE_MEDIA_TRY(endStream(TrackKind::Audio));
    }
    if (Status s = muxer_->finish(); !s.ok()) {
        state_ = State::Failed;
        return s;
    }
    state_ = State::Finished;
    return okStatus();
}

void ComposedMediaWriter::cancel() {
    if (state_ == State::Writing) {
        muxer_->cancel();
    }
    state_ = State::Failed;
}

bool ComposedMediaWriter::usesHardwareVideoEncoder() const {
    return videoEncoder_ && videoEncoder_->usesHardware();
}

std::string ComposedMediaWriter::videoEncoderName() const {
    if (!videoEncoder_ || !settings_.video || state_ == State::Idle) {
        return {};
    }
    return videoEncoder_->name();
}

} // namespace ve::media
