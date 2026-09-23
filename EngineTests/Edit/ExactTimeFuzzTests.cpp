// Property test for exact time math (model review finding 1): random edits on a 29.97 fps
// sequence with 44.1 kHz in points and speeds whose denominators go up to 1000, the
// combination whose common timescales overflow CoreMedia's 32-bit timescale. No edit may be
// refused as an InvariantViolation (the old rounding produced off-grid ends and false overlaps),
// no stored time may ever be rounded or carry an epoch, every state must validate, and undo must
// walk back to the start bit for bit. Edits whose exact result has no CMTime form are refused
// explicitly (NotRepresentable); their count is reported.

#include "../../Engine/Edit/UndoStack.h"
#include "EditTestSupport.h"

#include <random>

using namespace vetest;

namespace {

struct NtscFixture {
    Project project;
    SequenceId seq;
    TrackId v1, v2, a1, a2;
    AssetId music44; // audio only, 44.1 kHz, 10 minutes
    AssetId ntsc;    // audio+video, 29.97 fps, 48 kHz, 10 minutes
    const CMTime frame = CMTimeMake(1001, 30000);

    NtscFixture() {
        MediaAsset m;
        m.name = "music.wav";
        m.url = "/media/music.wav";
        m.kind = AssetKind::Audio;
        m.duration = CMTimeMake(600LL * 44100 + 37, 44100);
        m.audioSampleRate = 44100;
        m.audioChannels = 2;
        music44 = project.addAsset(m);
        MediaAsset v;
        v.name = "ntsc.mov";
        v.url = "/media/ntsc.mov";
        v.kind = AssetKind::AudioVideo;
        v.duration = CMTimeMake(1001LL * 17982, 30000);
        v.frameDuration = CMTimeMake(1001, 30000);
        v.width = 1920;
        v.height = 1080;
        v.audioSampleRate = 48000;
        v.audioChannels = 2;
        ntsc = project.addAsset(v);
        seq = project.addSequence("NTSC", CMTimeMake(1001, 30000), 1920, 1080, 2, 2);
        const Sequence &s = *project.findSequence(seq);
        v1 = s.videoTracks[0].id;
        v2 = s.videoTracks[1].id;
        a1 = s.audioTracks[0].id;
        a2 = s.audioTracks[1].id;
    }

    const Sequence &sequence() const {
        return *project.findSequence(seq);
    }
    CMTime frames(std::int64_t n) const {
        return timeForFrame(n, frame);
    }
};

// How the random in points are chosen.
enum class InPoints {
    Samples44k, // any 44.1 kHz sample: adversarial, timescales multiply out past 2^31
    Ui600,      // what the app's source monitor produces (CMTime(seconds:, preferredTimescale: 600))
};

class NtscEditor {
  public:
    NtscEditor(NtscFixture &fx, std::uint64_t seed, InPoints inPoints) : fx_(fx), rng_(seed), inPoints_(inPoints) {}

    std::unique_ptr<Command> next() {
        const Sequence &s = fx_.sequence();
        const ClipId clip = anyClip();
        const Clip *c = s.findClip(clip);
        const CMTime at = fx_.frames(frame(900));
        switch (c ? pick(12) : 0) {
        case 0:
        case 1:
            return std::make_unique<InsertClip>(fx_.seq, at, placements(),
                                                InsertOptions{true, pick(2) == 0 ? RippleScope::AllUnlockedTracks
                                                                                 : RippleScope::SyncedTracks});
        case 2:
            return std::make_unique<OverwriteClip>(fx_.seq, at, placements());
        case 3:
        case 4:
            return std::make_unique<SplitClip>(fx_.seq, clip, inside(*c), SplitOptions{pick(3) != 0, pick(2) == 0});
        case 5:
            return std::make_unique<TrimClipHead>(fx_.seq, clip, inside(*c), TrimOptions{pick(2) == 0, pick(2) == 0});
        case 6:
            return std::make_unique<TrimClipTail>(fx_.seq, clip, fx_.frames(frame(1200)),
                                                  TrimOptions{pick(2) == 0, true});
        case 7:
        case 8:
            return std::make_unique<SetClipSpeed>(fx_.seq, clip, speed(),
                                                  SpeedOptions{pick(2) == 0, pick(2) == 0,
                                                               pick(2) == 0 ? RippleScope::AllUnlockedTracks
                                                                            : RippleScope::SyncedTracks});
        case 9:
            return std::make_unique<MoveClip>(fx_.seq, clip, s.trackOfClip(clip)->id, at, pick(2) == 0);
        case 10:
            return std::make_unique<RippleDelete>(fx_.seq, std::vector<ClipId>{clip},
                                                  RippleOptions{true, RippleScope::SyncedTracks});
        default: {
            const Track &track = *s.trackOfClip(clip);
            const std::size_t index = *track.indexOf(clip);
            if (index + 1 >= track.clips.size() || track.clips[index + 1].timelineStart != c->timelineEnd()) {
                return nullptr;
            }
            return std::make_unique<AddTransition>(fx_.seq, clip, track.clips[index + 1].id,
                                                   fx_.frames(2 + frame(12)));
        }
        }
    }

  private:
    std::size_t pick(std::size_t n) {
        return std::uniform_int_distribution<std::size_t>(0, n - 1)(rng_);
    }
    std::int64_t frame(std::int64_t n) {
        return static_cast<std::int64_t>(pick(static_cast<std::size_t>(n)));
    }
    Ratio speed() {
        static const Ratio speeds[] = {Ratio{123, 1000}, Ratio{37, 100}, Ratio{999, 1000}, Ratio{1, 1}, Ratio{1, 2}};
        return speeds[pick(5)];
    }
    ClipId anyClip() {
        std::vector<ClipId> ids;
        for (const TrackKind kind : {TrackKind::Video, TrackKind::Audio}) {
            for (const Track &track : fx_.sequence().tracks(kind)) {
                for (const Clip &clip : track.clips) {
                    ids.push_back(clip.id);
                }
            }
        }
        return ids.empty() ? ClipId{} : ids[pick(ids.size())];
    }
    // A frame strictly inside the clip when it has one, else its start.
    CMTime inside(const Clip &clip) {
        const std::int64_t start = frameIndexAt(clip.timelineStart, fx_.frame, SnapMode::Round);
        const std::int64_t length = frameIndexAt(clip.timelineDuration, fx_.frame, SnapMode::Round);
        return fx_.frames(start + (length > 1 ? 1 + frame(length - 1) : 0));
    }
    // A random source time in [0, seconds) on the in-point grid.
    CMTime sourceTime(std::int64_t seconds) {
        const std::int32_t scale = inPoints_ == InPoints::Samples44k ? 44100 : 600;
        return CMTimeMake(frame(seconds * scale), scale);
    }

    std::vector<ClipPlacement> placements() {
        ClipPlacement p;
        if (pick(2) == 0) {
            // Audio with a sample-accurate (or UI-grid) range.
            const CMTime in = sourceTime(300);
            p.trackId = pick(2) == 0 ? fx_.a1 : fx_.a2;
            p.assetId = fx_.music44;
            p.sourceIn = in;
            p.sourceOut = in + CMTimeMake(1, 10) + sourceTime(10);
            p.speed = speed();
            return {p};
        }
        // A 29.97 A/V pair.
        const CMTime in = sourceTime(200);
        p.trackId = pick(2) == 0 ? fx_.v1 : fx_.v2;
        p.assetId = fx_.ntsc;
        p.sourceIn = in;
        p.sourceOut = in + CMTimeMake(1, 1) + sourceTime(5);
        p.speed = speed();
        ClipPlacement a = p;
        a.trackId = pick(2) == 0 ? fx_.a1 : fx_.a2;
        return {p, a};
    }

    NtscFixture &fx_;
    std::mt19937_64 rng_;
    InPoints inPoints_;
};

struct FuzzStats {
    int pushed = 0;
    int applied = 0;
    int noOps = 0;
    int invariantViolations = 0;
    int notRepresentable = 0;
    int inexactStates = 0;
    int otherRefusals = 0;
};

void runNtscFuzz(std::uint64_t seed, int steps, InPoints inPoints, FuzzStats &stats) {
    CAPTURE(seed);
    NtscFixture fx;
    UndoStack stack(100000);
    NtscEditor editor(fx, seed, inPoints);
    std::vector<Project> states{fx.project};
    for (int i = 0; i < steps; ++i) {
        std::unique_ptr<Command> command = editor.next();
        if (!command) {
            continue;
        }
        ++stats.pushed;
        const std::string name = command->name();
        const EditResult result = stack.push(fx.project, std::move(command));
        if (!result) {
            if (result.error == EditError::InvariantViolation) {
                ++stats.invariantViolations;
                FAIL_CHECK(name << " refused as an invariant violation: " << result.message);
            } else if (result.error == EditError::NotRepresentable) {
                ++stats.notRepresentable;
            } else {
                ++stats.otherRefusals;
            }
            CHECK(fx.project == states.back());
            continue;
        }
        if (fx.project == states.back()) {
            ++stats.noOps;
            continue;
        }
        ++stats.applied;
        const auto problem = validateProject(fx.project);
        REQUIRE_MESSAGE(!problem, doctest::String((name + ": " + problem.value_or("")).c_str()));
        if (hasInexactTime(fx.project)) {
            ++stats.inexactStates;
            FAIL_CHECK(name << " left a rounded time or an epoch in the model");
        }
        states.push_back(fx.project);
    }
    REQUIRE(stack.undoCount() == states.size() - 1);
    for (std::size_t i = states.size() - 1; i > 0; --i) {
        REQUIRE(stack.undo(fx.project));
        REQUIRE(fx.project == states[i - 1]);
    }
    for (std::size_t i = 1; i < states.size(); ++i) {
        REQUIRE(stack.redo(fx.project));
        REQUIRE(fx.project == states[i]);
    }
    // The saved form reloads to the same project.
    const ProjectLoadResult loaded = parseProject(serializeProject(fx.project, -1));
    REQUIRE_MESSAGE(loaded.ok(), doctest::String(loaded.error.c_str()));
    CHECK(*loaded.project == fx.project);
}

} // namespace

TEST_CASE("Property: NTSC + 44.1 kHz + speed/1000 edits stay exact (review finding 1)") {
    FuzzStats stats;
    for (std::uint64_t seed = 1; seed <= 64; ++seed) {
        runNtscFuzz(seed, 200, InPoints::Samples44k, stats);
    }
    MESSAGE("44.1 kHz in points: pushed " << stats.pushed << ", applied " << stats.applied << ", no-ops "
                                          << stats.noOps << ", refused: not representable " << stats.notRepresentable
                                          << ", other " << stats.otherRefusals << ", invariant violations "
                                          << stats.invariantViolations << "; states with inexact times "
                                          << stats.inexactStates);
    CHECK(stats.invariantViolations == 0);
    CHECK(stats.inexactStates == 0);
    CHECK(stats.applied >= stats.pushed / 3);
}

TEST_CASE("Property: with the app's 1/600 s in points NTSC edits are never refused as not representable") {
    FuzzStats stats;
    for (std::uint64_t seed = 101; seed <= 132; ++seed) {
        runNtscFuzz(seed, 200, InPoints::Ui600, stats);
    }
    MESSAGE("1/600 s in points: pushed " << stats.pushed << ", applied " << stats.applied << ", refused: not "
                                         << "representable " << stats.notRepresentable << ", other "
                                         << stats.otherRefusals);
    CHECK(stats.invariantViolations == 0);
    CHECK(stats.inexactStates == 0);
    CHECK(stats.notRepresentable == 0);
    CHECK(stats.applied >= stats.pushed / 3);
}
