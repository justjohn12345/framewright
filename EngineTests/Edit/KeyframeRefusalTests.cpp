// Keyframes reaching a clip through the other edit paths (motion/photos review findings 20, 21):
// SetVideoParams, SetClipsParams and placements refuse keyframes on an audio clip with
// TrackKindMismatch (not a late InvariantViolation) and new keyframes outside the clip's used source
// range with InvalidTime, like AddKeyframe and SetMotionTracks; hidden keyframes the clip already has
// stay. Two pieces of an animated still are not a through edit.

#include "EditTestSupport.h"

using namespace vetest;

namespace {

Keyframe key(CMTime time, double value, KeyframeInterpolation interpolation = KeyframeInterpolation::Linear) {
    Keyframe k;
    k.time = time;
    k.value = value;
    k.interpolation = interpolation;
    return k;
}

} // namespace

TEST_CASE("Keyframes through SetVideoParams: audio clips refuse them, and new ones stay inside the clip") {
    Fixture fx;
    // av30 source frames [60, 150) on V1 and A1 from timeline frame 30.
    const auto [video, audio] = fx.addLinkedPair(30, 90, 60);
    VideoParams animated;
    animated.keyframes.x = {key(f30(70), 1), key(f30(100), 2)};

    SetVideoParams onAudio(fx.seq, audio, animated);
    const EditResult audioRefusal = applyRefused(fx.project, onAudio, EditError::TrackKindMismatch);
    CHECK(audioRefusal.message.find("audio track") != std::string::npos);
    // Static values on an audio clip's video parameters are still accepted (nothing to animate).
    SetVideoParams staticOnAudio(fx.seq, audio, VideoParams(1, 2, 1, 0, 1));
    applyReversible(fx.project, staticOnAudio);

    VideoParams outside = animated;
    outside.keyframes.x.push_back(key(f30(200), 3)); // past the out point (150)
    SetVideoParams past(fx.seq, video, outside);
    applyRefused(fx.project, past, EditError::InvalidTime);

    SetVideoParams inside(fx.seq, video, animated);
    applyReversible(fx.project, inside);

    // A keyframe a trim hid may stay (the facade keeps a clip's keyframes when it sets static values).
    TrimOptions alone;
    alone.includeLinked = false;
    TrimClipHead trim(fx.seq, video, f30(50), alone); // source in 80: hides the keyframe at 70
    applyReversible(fx.project, trim);
    VideoParams kept = fx.clip(video).video;
    kept.x = 5;
    SetVideoParams keep(fx.seq, video, kept);
    applyReversible(fx.project, keep);
    CHECK(fx.clip(video).video.keyframes.x == animated.keyframes.x);
    // A new hidden one is refused.
    VideoParams added = kept;
    added.keyframes.x.insert(added.keyframes.x.begin(), key(f30(65), 0));
    SetVideoParams addHidden(fx.seq, video, added);
    applyRefused(fx.project, addHidden, EditError::InvalidTime);
}

TEST_CASE("Keyframes through SetClipsParams and placements follow the same rules") {
    Fixture fx;
    const auto [video, audio] = fx.addLinkedPair(0, 60, 0);
    VideoParams animated;
    animated.keyframes.opacity = {key(f30(10), 0), key(f30(20), 1)};

    ClipParamsChange outside;
    outside.clipId = video;
    outside.video = animated;
    outside.video->keyframes.opacity.push_back(key(f30(61), 1));
    SetClipsParams past(fx.seq, {outside});
    applyRefused(fx.project, past, EditError::InvalidTime);

    ClipParamsChange fine;
    fine.clipId = video;
    fine.video = animated;
    SetClipsParams set(fx.seq, {fine});
    applyReversible(fx.project, set);

    // A placement with keyframes on an audio track is a track-kind refusal.
    ClipPlacement onAudio = place(fx.a2, fx.av30, 0, 30);
    onAudio.video = animated;
    InsertClip audioInsert(fx.seq, f30(100), {onAudio}, false);
    applyRefused(fx.project, audioInsert, EditError::TrackKindMismatch);
    // One whose keyframes lie outside the placed range is refused; inside it is fine.
    ClipPlacement beyond = place(fx.v2, fx.av30, 0, 30);
    beyond.video = animated;
    beyond.video.keyframes.opacity.push_back(key(f30(45), 0.5));
    InsertClip beyondInsert(fx.seq, f30(100), {beyond}, false);
    applyRefused(fx.project, beyondInsert, EditError::InvalidTime);
    ClipPlacement within = place(fx.v2, fx.av30, 0, 30);
    within.video = animated;
    InsertClip insert(fx.seq, f30(100), {within}, false);
    applyReversible(fx.project, insert);
}

TEST_CASE("isThroughEdit: pieces of an animated still are not a through edit, unanimated ones are") {
    Fixture fx;
    const ClipId still = fx.addClip(fx.v1, fx.still, 0, 60);
    SplitClip plain(fx.seq, still, f30(30));
    applyReversible(fx.project, plain);
    CHECK(isThroughEdit(fx.sequence(), still, plain.createdClipIds().front()));

    // Two pieces with identical keyframes (clip-relative for stills): the move restarts at the cut.
    const ClipId left = fx.addClip(fx.v2, fx.still, 0, 30);
    const ClipId right = fx.addClip(fx.v2, fx.still, 30, 30);
    const KeyframeTrack scale{key(f30(0), 1, KeyframeInterpolation::EaseInOut), key(f30(29), 2)};
    fx.sequence().findClip(left)->video.keyframes.scale = scale;
    fx.sequence().findClip(right)->video.keyframes.scale = scale;
    fx.requireValid();
    CHECK_FALSE(isThroughEdit(fx.sequence(), left, right));
}
