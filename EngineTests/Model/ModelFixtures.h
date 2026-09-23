// Shared fixtures for the model, edit, serialization and scheduler tests.

#pragma once

#include "../../Engine/Edit/Command.h"
#include "../../Engine/Edit/EditOps.h"
#include "../../Engine/Model/Project.h"
#include "../../Engine/Model/Validation.h"
#include "../../Engine/Serialize/ProjectJSON.h"

#include <doctest.h>

#include <memory>
#include <string>

// Readable CMTime values in doctest failure messages.
template <> struct doctest::StringMaker<CMTime> {
    static doctest::String convert(const CMTime &t) {
        return ve::describe(t).c_str();
    }
};

template <> struct doctest::StringMaker<ve::Ratio> {
    static doctest::String convert(const ve::Ratio &r) {
        return (std::to_string(r.num) + "/" + std::to_string(r.den)).c_str();
    }
};

template <class Tag> struct doctest::StringMaker<ve::Id<Tag>> {
    static doctest::String convert(const ve::Id<Tag> &id) {
        return ("#" + std::to_string(id.value())).c_str();
    }
};

namespace vetest {

using namespace ve;

// `frames` at 30 fps (the fixture sequence's rate).
inline CMTime f30(std::int64_t frames) {
    return CMTimeMake(frames, 30);
}

inline std::string toJsonString(const Project &project) {
    return serializeProject(project, -1);
}

inline std::string problemOf(const Project &project) {
    return validateProject(project).value_or("");
}

// True if any stored time of the project carries kCMTimeFlags_HasBeenRounded or an epoch.
inline bool hasInexactTime(const Project &project) {
    auto inexact = [](CMTime t) { return isRounded(t) || t.epoch != 0; };
    for (const MediaAsset &asset : project.assets) {
        if (inexact(asset.duration) || inexact(asset.frameDuration)) {
            return true;
        }
    }
    for (const Sequence &sequence : project.sequences) {
        if (inexact(sequence.frameDuration)) {
            return true;
        }
        for (const TrackKind kind : {TrackKind::Video, TrackKind::Audio}) {
            for (const Track &track : sequence.tracks(kind)) {
                for (const Clip &clip : track.clips) {
                    for (const CMTime t : {clip.timelineStart, clip.timelineDuration, clip.sourceIn,
                                           clip.audio.fadeInDuration, clip.audio.fadeOutDuration}) {
                        if (inexact(t)) {
                            return true;
                        }
                    }
                }
            }
        }
        for (const Transition &transition : sequence.transitions) {
            if (inexact(transition.duration)) {
                return true;
            }
        }
    }
    return false;
}

// A project with one 30 fps 1920x1080 sequence (V1, V2, A1, A2) and a set of assets.
struct Fixture {
    Project project;
    SequenceId seq;
    TrackId v1, v2, a1, a2;
    AssetId av30;      // audio+video, 60 s, 30 fps (timescale 600)
    AssetId av24;      // audio+video, 20 s, 23.976 fps (timescale 24000)
    AssetId video60;   // video only, 10 s, 60 fps
    AssetId audioOnly; // audio only, 30 s, 48 kHz
    AssetId still;     // still image

    Fixture() {
        project.name = "Fixture";
        MediaAsset a;
        a.name = "av30.mov";
        a.url = "file:///media/av30.mov";
        a.kind = AssetKind::AudioVideo;
        a.duration = CMTimeMake(60 * 600, 600);
        a.width = 1920;
        a.height = 1080;
        a.frameDuration = CMTimeMake(20, 600);
        a.audioSampleRate = 48000;
        a.audioChannels = 2;
        a.backendHint = "apple";
        a.hardwareDecode = true;
        av30 = project.addAsset(a);

        MediaAsset b;
        b.name = "av24.mp4";
        b.url = "file:///media/av24.mp4";
        b.kind = AssetKind::AudioVideo;
        b.duration = CMTimeMake(20 * 24000, 24000);
        b.width = 3840;
        b.height = 2160;
        b.frameDuration = CMTimeMake(1001, 24000);
        b.audioSampleRate = 48000;
        b.audioChannels = 2;
        av24 = project.addAsset(b);

        MediaAsset c;
        c.name = "video60.mkv";
        c.url = "file:///media/video60.mkv";
        c.kind = AssetKind::Video;
        c.duration = CMTimeMake(10 * 60, 60);
        c.width = 1280;
        c.height = 720;
        c.frameDuration = CMTimeMake(1, 60);
        c.backendHint = "ffmpeg";
        video60 = project.addAsset(c);

        MediaAsset d;
        d.name = "music.m4a";
        d.url = "file:///media/music.m4a";
        d.kind = AssetKind::Audio;
        d.duration = CMTimeMake(30 * 48000, 48000);
        d.audioSampleRate = 48000;
        d.audioChannels = 2;
        audioOnly = project.addAsset(d);

        MediaAsset e;
        e.name = "title.png";
        e.url = "file:///media/title.png";
        e.kind = AssetKind::Still;
        e.width = 1920;
        e.height = 1080;
        still = project.addAsset(e);

        seq = project.addSequence("Main", CMTimeMake(1, 30), 1920, 1080, 2, 2);
        Sequence &s = sequence();
        v1 = s.videoTracks[0].id;
        v2 = s.videoTracks[1].id;
        a1 = s.audioTracks[0].id;
        a2 = s.audioTracks[1].id;
    }

    Sequence &sequence() {
        return *project.findSequence(seq);
    }
    const Sequence &sequence() const {
        return *project.findSequence(seq);
    }
    Track &track(TrackId id) {
        return *sequence().findTrack(id);
    }
    const Clip &clip(ClipId id) const {
        const Clip *c = sequence().findClip(id);
        REQUIRE_MESSAGE(c != nullptr, doctest::String(("missing clip " + std::to_string(id.value())).c_str()));
        return *c;
    }
    bool hasClip(ClipId id) const {
        return sequence().findClip(id) != nullptr;
    }

    // Places a clip directly in the model (bypassing commands). Times are 30 fps frames.
    ClipId addClip(TrackId trackId, AssetId assetId, std::int64_t startFrame, std::int64_t durationFrames,
                   std::int64_t sourceInFrame = 0, double speed = 1.0) {
        const MediaAsset &asset = *project.findAsset(assetId);
        Clip clip;
        clip.id = project.ids.make<ClipId>();
        clip.assetId = assetId;
        clip.trackId = trackId;
        clip.timelineStart = f30(startFrame);
        clip.isStill = asset.isStill();
        clip.speed = clip.isStill ? Ratio{1, 1} : speedFromDouble(speed);
        clip.sourceIn = clip.isStill ? kCMTimeZero : f30(sourceInFrame);
        clip.timelineDuration = f30(durationFrames);
        Track &t = track(trackId);
        t.clips.push_back(clip);
        t.sortClips();
        return clip.id;
    }

    void link(ClipId a, ClipId b) {
        sequence().findClip(a)->linkedClipId = b;
        sequence().findClip(b)->linkedClipId = a;
    }

    // A linked A/V pair from av30 on V1 + A1.
    std::pair<ClipId, ClipId> addLinkedPair(std::int64_t startFrame, std::int64_t durationFrames,
                                            std::int64_t sourceInFrame = 0, TrackId video = {}, TrackId audio = {}) {
        const ClipId v = addClip(video ? video : v1, av30, startFrame, durationFrames, sourceInFrame);
        const ClipId a = addClip(audio ? audio : a1, av30, startFrame, durationFrames, sourceInFrame);
        link(v, a);
        return {v, a};
    }

    TransitionId addTransition(TrackId trackId, ClipId from, ClipId to, std::int64_t frames) {
        Transition t;
        t.id = project.ids.make<TransitionId>();
        t.trackId = trackId;
        t.fromClipId = from;
        t.toClipId = to;
        t.duration = f30(frames);
        sequence().transitions.push_back(t);
        return t.id;
    }

    void requireValid() const {
        const auto problem = validateProject(project);
        REQUIRE_MESSAGE(!problem, doctest::String(problem.value_or("").c_str()));
    }
};

// Applies `command`, which must succeed, and checks that revert restores the previous project
// bit for bit (structurally and as JSON) and that re-applying reproduces the edit exactly (and
// reports the same dropped transitions). Leaves the project in the edited state and returns
// the first apply's result.
inline EditResult applyReversible(Project &project, Command &command) {
    const Project before = project;
    const std::string beforeJson = toJsonString(project);
    const EditResult result = command.apply(project);
    const std::string refusal = command.name() + " refused: " + result.message;
    REQUIRE_MESSAGE(result.ok(), doctest::String(refusal.c_str()));
    const auto problem = validateProject(project);
    REQUIRE_MESSAGE(!problem, doctest::String(problem.value_or("").c_str()));
    CHECK_FALSE(hasInexactTime(project));
    const Project after = project;
    const std::string afterJson = toJsonString(project);

    REQUIRE(command.canRevert(project));
    command.revert(project);
    CHECK(project == before);
    CHECK(toJsonString(project) == beforeJson);

    const EditResult again = command.apply(project);
    REQUIRE(again.ok());
    CHECK(again.droppedTransitionIds == result.droppedTransitionIds);
    CHECK(project == after);
    CHECK(toJsonString(project) == afterJson);
    return result;
}

// Applies `command`, which must be refused with `expected`, and checks nothing changed.
inline EditResult applyRefused(Project &project, Command &command, EditError expected) {
    const Project before = project;
    const EditResult result = command.apply(project);
    const std::string mismatch = command.name() + ": expected \"" + nameOf(expected) + "\", got \"" +
                                 nameOf(result.error) + "\": " + result.message;
    CHECK_MESSAGE(result.error == expected, doctest::String(mismatch.c_str()));
    CHECK_FALSE(result.message.empty());
    CHECK(project == before);
    return result;
}

} // namespace vetest
