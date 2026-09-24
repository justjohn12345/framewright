// Property-style test: long random sequences of edits through the UndoStack must be exactly
// reversible. Every intermediate state is recorded (structurally and as JSON); undoing all the
// way must visit the same states in reverse and end at the original project, redoing must
// reproduce them, and a random undo/redo walk must always land on a recorded state.

#include "../../Engine/Edit/UndoStack.h"
#include "EditTestSupport.h"

#include <random>

using namespace vetest;

namespace {

class RandomEditor {
  public:
    RandomEditor(Fixture &fx, std::uint64_t seed) : fx_(fx), rng_(seed) {}

    std::unique_ptr<Command> next() {
        const Sequence &s = fx_.sequence();
        switch (pick(24)) {
        case 0:
        case 1:
            return insertOrOverwrite(true);
        case 2:
        case 3:
            return insertOrOverwrite(false);
        case 4:
        case 5: {
            const ClipId c = anyClip();
            const Track *track = s.trackOfClip(c);
            if (!track) {
                return nullptr;
            }
            const TrackId dest = pick(3) == 0 ? anyTrack(track->kind) : track->id;
            return std::make_unique<MoveClip>(fx_.seq, c, dest, f30(frame(400)), pick(4) != 0);
        }
        case 6:
            return std::make_unique<TrimClipHead>(fx_.seq, anyClip(), f30(frame(400)),
                                                  TrimOptions{pick(3) != 0, pick(2) == 0});
        case 7:
            return std::make_unique<TrimClipTail>(fx_.seq, anyClip(), f30(frame(400)),
                                                  TrimOptions{pick(3) != 0, pick(2) == 0});
        case 8:
        case 9: {
            const ClipId c = anyClip();
            const Clip *clip = s.findClip(c);
            if (!clip) {
                return nullptr;
            }
            const std::int64_t start = frameIndexAt(clip->timelineStart, f30(1), SnapMode::Round);
            const std::int64_t end = frameIndexAt(clip->timelineEnd(), f30(1), SnapMode::Round);
            return std::make_unique<SplitClip>(fx_.seq, c, f30(start + frame(end - start + 1)),
                                               SplitOptions{pick(4) != 0, pick(2) == 0});
        }
        case 10:
            return std::make_unique<RemoveClips>(fx_.seq, std::vector<ClipId>{anyClip()}, pick(2) == 0);
        case 11:
            return std::make_unique<RippleDelete>(fx_.seq, std::vector<ClipId>{anyClip()},
                                                  RippleOptions{pick(2) == 0, anyScope()});
        case 12:
            return std::make_unique<SetVideoParams>(fx_.seq, anyClip(),
                                                    VideoParams{double(frame(200)) - 100, double(frame(200)) - 100,
                                                                0.25 * double(1 + pick(8)), double(frame(360)),
                                                                0.1 * pick(11)});
        case 13: {
            // Gain and lane-0 fades (refused on video clips, on touched starts and crossfaded ends).
            ClipParamsChange change;
            change.clipId = anyClip();
            change.audio = AudioParams{-double(pick(24))};
            if (pick(2) == 0) {
                change.fadeIn = f30(frame(20));
            }
            if (pick(2) == 0) {
                change.fadeOut = f30(frame(20));
            }
            return std::make_unique<SetClipsParams>(fx_.seq, std::vector<ClipParamsChange>{change});
        }
        case 14: {
            static const double speeds[] = {0.25, 0.5, 1.0, 1.5, 2.0, 3.0, 1.0 / 3.0};
            return std::make_unique<SetClipSpeed>(fx_.seq, anyClip(), speeds[pick(7)],
                                                  SpeedOptions{pick(2) == 0, pick(2) == 0, anyScope()});
        }
        case 15: {
            // A transition on a random existing cut.
            std::vector<std::pair<ClipId, ClipId>> cuts;
            for (const TrackKind kind : {TrackKind::Video, TrackKind::Audio}) {
                for (const Track &track : s.tracks(kind)) {
                    for (std::size_t i = 0; i + 1 < track.clips.size(); ++i) {
                        if (track.clips[i].timelineEnd() == track.clips[i + 1].timelineStart) {
                            cuts.emplace_back(track.clips[i].id, track.clips[i + 1].id);
                        }
                    }
                }
            }
            TransitionSpanRequest request;
            if (!cuts.empty() && pick(3) != 0) {
                // A dissolve with an uneven split, or a fade out ending on the cut.
                request.clipId = cuts[pick(cuts.size())].first;
                request.start = -f30(frame(20));
                request.end = f30(pick(4) == 0 ? 0 : frame(20));
            } else {
                request.clipId = anyClip();
                request.edge = pick(2) == 0 ? ClipEdge::Head : ClipEdge::Tail;
                const CMTime length = f30(1 + frame(20));
                request.start = request.edge == ClipEdge::Head ? kCMTimeZero : -length;
                request.end = request.edge == ClipEdge::Head ? length : kCMTimeZero;
            }
            return std::make_unique<AddTransitionSpans>(fx_.seq, std::vector<TransitionSpanRequest>{request});
        }
        case 16: {
            const SpanId t = anySpan(true);
            if (!t) {
                return nullptr;
            }
            if (pick(2) == 0) {
                return std::make_unique<RemoveSpans>(fx_.seq, std::vector<SpanId>{t});
            }
            const bool head = s.findSpan(t)->edge == ClipEdge::Head;
            const CMTime length = f30(1 + frame(30));
            return std::make_unique<SetTransitionRanges>(
                fx_.seq, std::vector<TransitionRangeChange>{
                             {t, head ? kCMTimeZero : -f30(frame(20)), head ? length : f30(frame(20))}});
        }
        case 17: {
            const ClipId a = anyClip();
            if (pick(2) == 0) {
                return std::make_unique<UnlinkClip>(fx_.seq, a);
            }
            return std::make_unique<LinkClips>(fx_.seq, a, anyClip());
        }
        case 18: {
            const TrackKind kind = pick(2) == 0 ? TrackKind::Video : TrackKind::Audio;
            if (pick(2) == 0 && s.tracks(kind).size() < 5) {
                return std::make_unique<AddTrack>(fx_.seq, kind, "", pick(s.tracks(kind).size() + 1));
            }
            if (s.tracks(kind).size() > 1) {
                return std::make_unique<RemoveTrack>(fx_.seq, anyTrack(kind));
            }
            return nullptr;
        }
        case 19: {
            // An effect span over part of a clip (of the clip's kind, or refused).
            const ClipId c = anyClip();
            const Clip *clip = s.findClip(c);
            if (!clip) {
                return nullptr;
            }
            static const SpanKind kinds[] = {SpanKind::Motion, SpanKind::Opacity, SpanKind::Gain};
            const std::int64_t start = frameIndexAt(clip->timelineStart, f30(1), SnapMode::Round);
            const std::int64_t length = frameIndexAt(clip->duration(), f30(1), SnapMode::Round);
            const std::int64_t from = start + frame(length);
            return std::make_unique<AddSpan>(fx_.seq, c, kinds[pick(3)], 1 + static_cast<int>(pick(3)), f30(from),
                                             f30(from + 1 + frame(length)));
        }
        case 20: {
            const SpanId id = anySpan(false);
            const Clip *clip = nullptr;
            if (!id || !s.findSpan(id, &clip)) {
                return nullptr;
            }
            const std::int64_t start = frameIndexAt(clip->timelineStart, f30(1), SnapMode::Round);
            const std::int64_t length = frameIndexAt(clip->duration(), f30(1), SnapMode::Round);
            const std::int64_t from = start + frame(length);
            return std::make_unique<SetSpanRange>(fx_.seq, id, f30(from), f30(from + 1 + frame(length)));
        }
        case 21: {
            const SpanId id = anySpan(false);
            if (!id) {
                return nullptr;
            }
            const EffectSpan &span = *s.findSpan(id);
            std::vector<SpanValueChange> changes;
            for (const SpanParameter parameter : parametersOf(span.kind)) {
                const double scale = parameter == SpanParameter::Opacity ? 0.1 : parameter == SpanParameter::Scale ? 0.25 : 10.0;
                changes.push_back(SpanValueChange{parameter, scale * double(pick(9)), scale * double(pick(9))});
            }
            static const KeyframeInterpolation easings[] = {KeyframeInterpolation::Linear, KeyframeInterpolation::Hold,
                                                            KeyframeInterpolation::EaseIn, KeyframeInterpolation::EaseOut,
                                                            KeyframeInterpolation::EaseInOut};
            if (pick(3) == 0) {
                return std::make_unique<SetSpanInterpolation>(fx_.seq, id, easings[pick(5)]);
            }
            return std::make_unique<SetSpanValues>(fx_.seq, id, changes);
        }
        case 22: {
            const SpanId id = anySpan(false);
            if (!id) {
                return nullptr;
            }
            if (pick(2) == 0) {
                return std::make_unique<RemoveSpans>(fx_.seq, std::vector<SpanId>{id});
            }
            return std::make_unique<MoveSpanLane>(fx_.seq, id, 1 + static_cast<int>(pick(3)));
        }
        default: {
            const TrackKind kind = pick(2) == 0 ? TrackKind::Video : TrackKind::Audio;
            TrackFlagsUpdate update;
            update.muted = pick(2) == 0;
            update.solo = pick(4) == 0;
            update.locked = pick(5) == 0;
            return std::make_unique<SetTrackFlags>(fx_.seq, anyTrack(kind), update);
        }
        }
    }

  private:
    std::size_t pick(std::size_t n) {
        return n == 0 ? 0 : std::uniform_int_distribution<std::size_t>(0, n - 1)(rng_);
    }
    std::int64_t frame(std::int64_t n) {
        return static_cast<std::int64_t>(pick(static_cast<std::size_t>(n)));
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

    // A random transition span (`transitions`) or effect span, or an invalid id when there is none.
    SpanId anySpan(bool transitions) {
        std::vector<SpanId> ids;
        for (const TrackKind kind : {TrackKind::Video, TrackKind::Audio}) {
            for (const Track &track : fx_.sequence().tracks(kind)) {
                for (const Clip &clip : track.clips) {
                    for (const EffectSpan &span : clip.spans) {
                        if (span.isTransition() == transitions) {
                            ids.push_back(span.id);
                        }
                    }
                }
            }
        }
        return ids.empty() ? SpanId{} : ids[pick(ids.size())];
    }

    RippleScope anyScope() {
        return pick(2) == 0 ? RippleScope::AllUnlockedTracks : RippleScope::SyncedTracks;
    }

    TrackId anyTrack(TrackKind kind) {
        const auto &tracks = fx_.sequence().tracks(kind);
        return tracks.empty() ? TrackId{} : tracks[pick(tracks.size())].id;
    }

    std::unique_ptr<Command> insertOrOverwrite(bool insert) {
        std::vector<ClipPlacement> placements;
        const TrackId video = anyTrack(TrackKind::Video);
        const TrackId audio = anyTrack(TrackKind::Audio);
        const std::int64_t in = frame(600);
        const std::int64_t length = 1 + frame(90);
        switch (pick(4)) {
        case 0:
            placements = {place(video, fx_.av30, in, in + length), place(audio, fx_.av30, in, in + length)};
            break;
        case 1:
            placements = {place(audio, fx_.audioOnly, in, in + length, pick(2) == 0 ? 1.0 : 2.0)};
            break;
        case 2:
            placements = {place(video, fx_.still, 0, length)};
            break;
        default:
            placements = {place(video, fx_.video60, in / 3, in / 3 + length, pick(2) == 0 ? 1.0 : 0.5)};
            break;
        }
        const CMTime at = f30(frame(300));
        if (insert) {
            return std::make_unique<InsertClip>(fx_.seq, at, placements, InsertOptions{pick(3) != 0, anyScope()});
        }
        return std::make_unique<OverwriteClip>(fx_.seq, at, placements);
    }

    Fixture &fx_;
    std::mt19937_64 rng_;
};

void runRandomEdits(std::uint64_t seed, int steps) {
    CAPTURE(seed);
    Fixture fx;
    UndoStack stack(100000);
    RandomEditor editor(fx, seed);
    std::vector<Project> states{fx.project};
    std::vector<std::string> jsonStates{toJsonString(fx.project)};

    int applied = 0;
    for (int i = 0; i < steps; ++i) {
        std::unique_ptr<Command> command = editor.next();
        if (!command) {
            continue;
        }
        const std::string name = command->name();
        const std::size_t undoCountBefore = stack.undoCount();
        const EditResult result = stack.push(fx.project, std::move(command));
        if (!result) {
            CHECK_MESSAGE(result.error != EditError::InvariantViolation, doctest::String(result.message.c_str()));
            CHECK(fx.project == states.back()); // refused edits change nothing
            continue;
        }
        if (fx.project == states.back()) {
            CHECK(stack.undoCount() == undoCountBefore); // a no-op is not an undo step
            continue;
        }
        ++applied;
        const auto problem = validateProject(fx.project);
        REQUIRE_MESSAGE(!problem, doctest::String((name + ": " + problem.value_or("")).c_str()));
        CHECK_FALSE(hasInexactTime(fx.project));
        for (const SpanId dropped : result.droppedTransitionIds) {
            const EffectSpan *before = states.back().findSequence(fx.seq)->findSpan(dropped);
            REQUIRE(before != nullptr);
            CHECK(before->isTransition());
            CHECK(fx.sequence().findSpan(dropped) == nullptr);
        }
        for (const SpanId dropped : result.droppedSpanIds) {
            const EffectSpan *before = states.back().findSequence(fx.seq)->findSpan(dropped);
            REQUIRE(before != nullptr);
            CHECK_FALSE(before->isTransition());
            CHECK(fx.sequence().findSpan(dropped) == nullptr);
        }
        states.push_back(fx.project);
        jsonStates.push_back(toJsonString(fx.project));
    }
    CHECK(applied >= steps / 5);
    REQUIRE(stack.undoCount() == states.size() - 1);

    // Undo everything, checking every intermediate state.
    for (std::size_t i = states.size() - 1; i > 0; --i) {
        REQUIRE(stack.undo(fx.project));
        REQUIRE(fx.project == states[i - 1]);
        REQUIRE(toJsonString(fx.project) == jsonStates[i - 1]);
    }
    CHECK_FALSE(stack.canUndo());

    // Redo everything.
    for (std::size_t i = 1; i < states.size(); ++i) {
        REQUIRE(stack.redo(fx.project));
        REQUIRE(fx.project == states[i]);
        REQUIRE(toJsonString(fx.project) == jsonStates[i]);
    }

    // Random walk.
    std::mt19937_64 walk(seed * 7919);
    std::size_t position = states.size() - 1;
    for (int i = 0; i < 4 * steps; ++i) {
        if (walk() % 2 == 0) {
            if (stack.undo(fx.project)) {
                --position;
            }
        } else if (stack.redo(fx.project)) {
            ++position;
        }
        REQUIRE(fx.project == states[position]);
    }
    CHECK(toJsonString(fx.project) == jsonStates[position]);

    // And the JSON of every state reloads to the same project.
    for (std::size_t i = 0; i < states.size(); i += 7) {
        const ProjectLoadResult loaded = parseProject(jsonStates[i]);
        REQUIRE_MESSAGE(loaded.ok(), doctest::String(loaded.error.c_str()));
        REQUIRE(*loaded.project == states[i]);
    }
}

} // namespace

TEST_CASE("Property: random edit chains undo and redo exactly") {
    for (std::uint64_t seed = 1; seed <= 8; ++seed) {
        runRandomEdits(seed, 250);
    }
}
