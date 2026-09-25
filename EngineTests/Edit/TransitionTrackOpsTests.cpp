#include "EditTestSupport.h"

using namespace vetest;

namespace {

// V1: A [0,60) source 30.., B [60,120) source 300.. — both with plenty of handles.
struct CutFixture : Fixture {
    ClipId a, b;
    CutFixture() {
        a = addClip(v1, av30, 0, 60, 30);
        b = addClip(v1, av30, 60, 60, 300);
        requireValid();
    }
};

} // namespace

TEST_CASE("AddTransitionSpans puts a centred dissolve on the outgoing clip's tail") {
    CutFixture fx;
    AddTransitionSpans add(fx.seq, {centredDissolve(fx.a, 10)});
    applyReversible(fx.project, add);
    REQUIRE(add.createdSpanIds().size() == 1);
    const SpanId id = add.createdSpanIds()[0];
    const auto placed = findTransition(fx.sequence(), id);
    REQUIRE(placed.has_value());
    CHECK(placed->owner->id == fx.a);
    CHECK(placed->partner->id == fx.b);
    CHECK(placed->track->id == fx.v1);
    CHECK(placed->role == TransitionRole::CrossDissolve);
    CHECK(placed->range.start == f30(55));
    CHECK(placed->range.end == f30(65));
    const EffectSpan &span = *fx.span(id);
    CHECK(span.lane == kTransitionLane);
    CHECK(span.edge == ClipEdge::Tail);
    CHECK(fx.clip(fx.b).spans.empty()); // the incoming clip owns nothing across the cut
}

TEST_CASE("AddTransitionSpans: asymmetric shares, fades and their rules") {
    CutFixture fx;
    SUBCASE("70/30: seven frames before the cut, three after") {
        AddTransitionSpans add(fx.seq, {tailTransition(fx.a, 7, 3)});
        applyReversible(fx.project, add);
        CHECK(transitionFrames(fx, add.createdSpanIds()[0]) == span(53, 63));
    }
    SUBCASE("all after the cut (starting at it) is a dissolve on the outgoing clip's handles") {
        AddTransitionSpans add(fx.seq, {tailTransition(fx.a, 0, 10)});
        applyReversible(fx.project, add);
        CHECK(findTransition(fx.sequence(), add.createdSpanIds()[0])->role == TransitionRole::CrossDissolve);
    }
    SUBCASE("ending on the cut is a fade out, touching neighbour or not") {
        AddTransitionSpans add(fx.seq, {tailTransition(fx.a, 12, 0)});
        applyReversible(fx.project, add);
        CHECK(findTransition(fx.sequence(), add.createdSpanIds()[0])->role == TransitionRole::FadeOut);
        CHECK(transitionFrames(fx, add.createdSpanIds()[0]) == span(48, 60));
    }
    SUBCASE("a fade out after the last clip, and a fade in where nothing touches the start") {
        AddTransitionSpans add(fx.seq, {tailTransition(fx.b, 15, 0), headFade(fx.a, 20)});
        applyReversible(fx.project, add);
        CHECK(findTransition(fx.sequence(), add.createdSpanIds()[0])->role == TransitionRole::FadeOut);
        CHECK(findTransition(fx.sequence(), add.createdSpanIds()[1])->role == TransitionRole::FadeIn);
        CHECK(transitionFrames(fx, add.createdSpanIds()[1]) == span(0, 20));
    }
    SUBCASE("a fade in on a clip whose start another clip touches is refused: the cut is that clip's") {
        AddTransitionSpans add(fx.seq, {headFade(fx.b, 10)});
        const EditResult r = applyRefused(fx.project, add, EditError::InvalidArgument);
        CHECK(r.message.find("touches the start") != std::string::npos);
    }
    SUBCASE("running past the end with nothing touching it is refused") {
        AddTransitionSpans add(fx.seq, {tailTransition(fx.b, 5, 5)});
        applyRefused(fx.project, add, EditError::NotAdjacent);
    }
    SUBCASE("a dissolve covers whole frames on each side of the cut") {
        TransitionSpanRequest half = tailTransition(fx.a, 5, 5);
        half.end = CMTimeMake(1, 60) + f30(4);
        AddTransitionSpans add(fx.seq, {half});
        applyRefused(fx.project, add, EditError::InvalidArgument);
    }
    SUBCASE("a fade may be any exact length (a migrated audio fade)") {
        const ClipId m = fx.addClip(fx.a1, fx.audioOnly, 0, 60);
        TransitionSpanRequest fade = tailTransition(m, 0, 0);
        fade.start = CMTimeMake(-7, 48000);
        AddTransitionSpans add(fx.seq, {fade});
        applyReversible(fx.project, add);
    }
    SUBCASE("a head fade and the tail span may not meet") {
        AddTransitionSpans tail(fx.seq, {tailTransition(fx.a, 40, 5)});
        applyReversible(fx.project, tail);
        AddTransitionSpans head(fx.seq, {headFade(fx.a, 21)});
        applyRefused(fx.project, head, EditError::Overlap);
        AddTransitionSpans fits(fx.seq, {headFade(fx.a, 20)});
        applyReversible(fx.project, fits);
    }
    SUBCASE("the offsets must be on the right side of the edge") {
        AddTransitionSpans wrongSide(fx.seq, {tailTransition(fx.a, -3, 6)});
        applyRefused(fx.project, wrongSide, EditError::InvalidArgument);
        TransitionSpanRequest shifted = headFade(fx.a, 10);
        shifted.start = f30(2);
        AddTransitionSpans notAtStart(fx.seq, {shifted});
        applyRefused(fx.project, notAtStart, EditError::InvalidArgument);
    }
}

TEST_CASE("AddTransitionSpans refusals") {
    CutFixture fx;
    Project &p = fx.project;
    SUBCASE("outgoing clip has no media after its out point") {
        const ClipId c = fx.addClip(fx.v2, fx.av30, 0, 60, 1740);
        fx.addClip(fx.v2, fx.av30, 60, 60, 300);
        AddTransitionSpans add(fx.seq, {centredDissolve(c, 10)});
        const EditResult r = applyRefused(p, add, EditError::InsufficientHandles);
        CHECK(r.message.find("after its out point") != std::string::npos);
    }
    SUBCASE("incoming clip has no media before its in point") {
        const ClipId c = fx.addClip(fx.v2, fx.av30, 0, 60, 300);
        fx.addClip(fx.v2, fx.av30, 60, 60, 0);
        AddTransitionSpans add(fx.seq, {centredDissolve(c, 10)});
        const EditResult r = applyRefused(p, add, EditError::InsufficientHandles);
        CHECK(r.message.find("before its in point") != std::string::npos);
    }
    SUBCASE("handles too short for the requested length") {
        const ClipId c = fx.addClip(fx.v2, fx.av30, 0, 60, 300);
        fx.addClip(fx.v2, fx.av30, 60, 60, 4);                   // 4 frames of handle
        AddTransitionSpans tooLong(fx.seq, {centredDissolve(c, 10)}); // needs 5 before the cut
        applyRefused(p, tooLong, EditError::InsufficientHandles);
        AddTransitionSpans fits(fx.seq, {centredDissolve(c, 9)}); // needs 4
        applyReversible(p, fits);
    }
    SUBCASE("longer than the clips") {
        AddTransitionSpans add(fx.seq, {centredDissolve(fx.a, 200)});
        applyRefused(p, add, EditError::InvalidArgument);
    }
    SUBCASE("empty or inexact offsets") {
        AddTransitionSpans empty(fx.seq, {tailTransition(fx.a, 0, 0)});
        applyRefused(p, empty, EditError::InvalidArgument);
        TransitionSpanRequest invalid = tailTransition(fx.a, 5, 5);
        invalid.end = kCMTimeInvalid;
        AddTransitionSpans bad(fx.seq, {invalid});
        applyRefused(p, bad, EditError::InvalidTime);
    }
    SUBCASE("already exists") {
        fx.addTransition(fx.v1, fx.a, fx.b, 10);
        AddTransitionSpans add(fx.seq, {centredDissolve(fx.a, 20)});
        applyRefused(p, add, EditError::AlreadyExists);
    }
    SUBCASE("overlaps the neighbouring transition") {
        const ClipId c = fx.addClip(fx.v1, fx.av30, 120, 60, 600);
        fx.addTransition(fx.v1, fx.a, fx.b, 40);                     // [40, 80)
        AddTransitionSpans add(fx.seq, {centredDissolve(fx.b, 90)}); // [75, 165)
        applyRefused(p, add, EditError::Overlap);
        AddTransitionSpans fits(fx.seq, {centredDissolve(fx.b, 80)}); // [80, 160)
        applyReversible(p, fits);
        (void)c;
    }
    SUBCASE("locked or missing") {
        AddTransitionSpans missing(fx.seq, {centredDissolve(ClipId{999}, 10)});
        applyRefused(p, missing, EditError::ClipNotFound);
        lockTrack(fx, fx.v1);
        AddTransitionSpans locked(fx.seq, {centredDissolve(fx.a, 10)});
        applyRefused(p, locked, EditError::TrackLocked);
    }
    SUBCASE("a pair is refused as a whole") {
        const ClipId c = fx.addClip(fx.v2, fx.av30, 0, 60, 1740);
        fx.addClip(fx.v2, fx.av30, 60, 60, 300);
        AddTransitionSpans both(fx.seq, {centredDissolve(fx.a, 10), centredDissolve(c, 10)});
        applyRefused(p, both, EditError::InsufficientHandles);
    }
    SUBCASE("none") {
        AddTransitionSpans none(fx.seq, {});
        applyRefused(p, none, EditError::InvalidArgument);
    }
}

TEST_CASE("Transitions between stills need no handles; audio tracks crossfade") {
    Fixture fx;
    const ClipId s1 = fx.addClip(fx.v1, fx.still, 0, 60);
    fx.addClip(fx.v1, fx.still, 60, 60);
    AddTransitionSpans dissolve(fx.seq, {centredDissolve(s1, 30)});
    applyReversible(fx.project, dissolve);

    const ClipId m1 = fx.addClip(fx.a1, fx.audioOnly, 0, 60, 30);
    fx.addClip(fx.a1, fx.audioOnly, 60, 60, 300);
    AddTransitionSpans crossfade(fx.seq, {centredDissolve(m1, 20)});
    applyReversible(fx.project, crossfade);
    CHECK(findTransition(fx.sequence(), crossfade.createdSpanIds()[0])->role == TransitionRole::CrossDissolve);
}

TEST_CASE("SetTransitionRanges resizes, slides the split and changes the role; RemoveSpans removes") {
    CutFixture fx;
    const SpanId t = fx.addTransition(fx.v1, fx.a, fx.b, 10);
    fx.requireValid();
    SetTransitionRanges longer(fx.seq, {{t, -f30(20), f30(20)}});
    applyReversible(fx.project, longer);
    CHECK(transitionFrames(fx, t) == span(40, 80));

    SUBCASE("a 70/30 split") {
        SetTransitionRanges slide(fx.seq, {{t, -f30(14), f30(6)}});
        applyReversible(fx.project, slide);
        CHECK(transitionFrames(fx, t) == span(46, 66));
    }
    SUBCASE("ending on the cut: a fade out; past it again: a dissolve") {
        SetTransitionRanges fade(fx.seq, {{t, -f30(12), kCMTimeZero}});
        applyReversible(fx.project, fade);
        CHECK(findTransition(fx.sequence(), t)->role == TransitionRole::FadeOut);
        SetTransitionRanges back(fx.seq, {{t, -f30(12), f30(3)}});
        applyReversible(fx.project, back);
        CHECK(findTransition(fx.sequence(), t)->role == TransitionRole::CrossDissolve);
    }
    SUBCASE("refusals") {
        SetTransitionRanges tooLong(fx.seq, {{t, -f30(61), f30(20)}}); // A is 60 long
        applyRefused(fx.project, tooLong, EditError::InvalidArgument);
        SetTransitionRanges missing(fx.seq, {{SpanId{999}, -f30(5), f30(5)}});
        applyRefused(fx.project, missing, EditError::TransitionNotFound);
        SetTransitionRanges none(fx.seq, {});
        applyRefused(fx.project, none, EditError::InvalidArgument);
        lockTrack(fx, fx.v1);
        SetTransitionRanges locked(fx.seq, {{t, -f30(5), f30(5)}});
        applyRefused(fx.project, locked, EditError::TrackLocked);
        fx.track(fx.v1).locked = false; // for the removal below
    }
    SUBCASE("an effect span is not a transition") {
        const SpanId motion = fx.addSpan(fx.a, SpanKind::Motion, 1, f30(30), f30(60));
        SetTransitionRanges wrong(fx.seq, {{motion, -f30(5), f30(5)}});
        applyRefused(fx.project, wrong, EditError::TransitionNotFound);
    }

    RemoveSpans remove(fx.seq, {t});
    applyReversible(fx.project, remove);
    CHECK(fx.span(t) == nullptr);
    RemoveSpans again(fx.seq, {t});
    applyRefused(fx.project, again, EditError::SpanNotFound);
}

TEST_CASE("SetTransitionRanges refuses a range the handles cannot cover") {
    Fixture fx;
    const ClipId a = fx.addClip(fx.v1, fx.av30, 0, 60, 1730); // 10 frames after its out point
    const ClipId b = fx.addClip(fx.v1, fx.av30, 60, 60, 300);
    const SpanId t = fx.addTransition(fx.v1, a, b, 20); // needs 10 after the cut
    fx.requireValid();
    SetTransitionRanges longer(fx.seq, {{t, -f30(10), f30(11)}});
    applyRefused(fx.project, longer, EditError::InsufficientHandles);
    SetTransitionRanges before(fx.seq, {{t, -f30(30), f30(10)}}); // more before the cut is fine
    applyReversible(fx.project, before);
}

TEST_CASE("Edits that break a cut remove its transition; undo restores it") {
    CutFixture fx;
    const SpanId t = fx.addTransition(fx.v1, fx.a, fx.b, 10);
    fx.requireValid();
    SUBCASE("trimming the outgoing clip away from the cut") {
        TrimClipTail trim(fx.seq, fx.a, f30(50));
        const EditResult r = applyReversible(fx.project, trim);
        CHECK(fx.span(t) == nullptr);
        CHECK(r.droppedTransitionIds == std::vector<SpanId>{t});
    }
    SUBCASE("removing a clip") {
        RemoveClips remove(fx.seq, {fx.b});
        applyReversible(fx.project, remove);
        CHECK(fx.span(t) == nullptr);
    }
    SUBCASE("ripple delete keeps transitions whose clips stay adjacent") {
        const ClipId c = fx.addClip(fx.v1, fx.av30, 150, 30, 900);
        RippleDelete ripple(fx.seq, {c});
        applyReversible(fx.project, ripple);
        CHECK(fx.span(t) != nullptr);
    }
    SUBCASE("trimming the incoming clip's head shortens its handle below the transition") {
        TrimClipHead trim(fx.seq, fx.b, f30(70));
        applyReversible(fx.project, trim);
        CHECK(fx.span(t) == nullptr);
    }
    SUBCASE("unrelated edits keep it") {
        SetVideoParams params(fx.seq, fx.a, VideoParams{1, 2, 1, 0, 0.5});
        applyReversible(fx.project, params);
        CHECK(fx.span(t) != nullptr);
    }
    SUBCASE("a fade out stays when the cut breaks: it needs no neighbour") {
        SetTransitionRanges fade(fx.seq, {{t, -f30(10), kCMTimeZero}});
        applyReversible(fx.project, fade);
        RemoveClips remove(fx.seq, {fx.b});
        const EditResult r = applyReversible(fx.project, remove);
        CHECK(r.droppedTransitionIds.empty());
        CHECK(findTransition(fx.sequence(), t)->role == TransitionRole::FadeOut);
    }
    SUBCASE("a fade in goes when a moved clip comes to touch its clip's start") {
        const SpanId in = fx.addFade(fx.a, ClipEdge::Head, f30(10));
        const ClipId c = fx.addClip(fx.v1, fx.av30, 200, 30, 900);
        fx.requireValid();
        TrimClipHead gap(fx.seq, fx.a, f30(30)); // A now starts at 30
        applyReversible(fx.project, gap);
        CHECK(fx.span(in) != nullptr);
        MoveClip touch(fx.seq, c, fx.v1, kCMTimeZero); // [0, 30) touches A's start
        const EditResult r = applyReversible(fx.project, touch);
        CHECK(fx.span(in) == nullptr);
        CHECK(r.droppedTransitionIds == std::vector<SpanId>{in});
    }
}

TEST_CASE("A fade in goes, reported, when an insert, ripple, overwrite or tail extension touches its start") {
    // V1: A [0,30), a gap, B [60,120) with a 10-frame fade in; V2: G [30,60).
    Fixture fx;
    const ClipId a = fx.addClip(fx.v1, fx.av30, 0, 30, 0);
    const ClipId b = fx.addClip(fx.v1, fx.av30, 60, 60, 300);
    const ClipId g = fx.addClip(fx.v2, fx.av30, 30, 30, 600);
    const SpanId fade = fx.addFade(b, ClipEdge::Head, f30(10));
    fx.requireValid();
    auto droppedOnly = [&](const EditResult &r) {
        CHECK(fx.span(fade) == nullptr);
        CHECK(r.droppedTransitionIds == std::vector<SpanId>{fade});
    };
    SUBCASE("an insert at B's start: the new clip touches it") {
        InsertClip insert(fx.seq, f30(60), {place(fx.v1, fx.av30, 900, 930)});
        droppedOnly(applyReversible(fx.project, insert));
    }
    SUBCASE("a ripple delete on another track closes the gap") {
        RippleDelete ripple(fx.seq, {g});
        const EditResult r = applyReversible(fx.project, ripple);
        CHECK(fx.clip(b).timelineStart == f30(30));
        droppedOnly(r);
    }
    SUBCASE("an overwrite into the gap up to B's start") {
        OverwriteClip overwrite(fx.seq, f30(40), {place(fx.v1, fx.av30, 900, 920)});
        droppedOnly(applyReversible(fx.project, overwrite));
    }
    SUBCASE("extending A's tail to B's start") {
        TrimClipTail extend(fx.seq, a, f30(60));
        droppedOnly(applyReversible(fx.project, extend));
    }
}

TEST_CASE("A dissolve whose partner clip changes is removed and reported, not moved (review M2)") {
    // V1: A [0,60) | B [60,120) | C [120,180), an A -> B dissolve of 10 frames; the same on A1 with
    // a crossfade (linked pairs, so ripple and insert move both).
    CutFixture fx;
    const ClipId c = fx.addClip(fx.v1, fx.av30, 120, 60, 900);
    const SpanId t = fx.addTransition(fx.v1, fx.a, fx.b, 10);
    fx.requireValid();
    SUBCASE("ripple deleting B: C comes to touch A, and the dissolve does not become A -> C") {
        RippleDelete ripple(fx.seq, {fx.b});
        const EditResult r = applyReversible(fx.project, ripple);
        CHECK(fx.clip(c).timelineStart == f30(60));
        CHECK(fx.span(t) == nullptr);
        CHECK(r.droppedTransitionIds == std::vector<SpanId>{t});
    }
    SUBCASE("inserting at the cut: the new clip touches A") {
        InsertClip insert(fx.seq, f30(60), {place(fx.v1, fx.av30, 600, 630)});
        const EditResult r = applyReversible(fx.project, insert);
        CHECK(fx.span(t) == nullptr);
        CHECK(r.droppedTransitionIds == std::vector<SpanId>{t});
    }
    SUBCASE("overwriting the start of B: the new clip touches A") {
        OverwriteClip overwrite(fx.seq, f30(60), {place(fx.v1, fx.av30, 600, 630)});
        const EditResult r = applyReversible(fx.project, overwrite);
        CHECK(fx.span(t) == nullptr);
        CHECK(r.droppedTransitionIds == std::vector<SpanId>{t});
    }
    SUBCASE("splitting B keeps it: B's left piece keeps B's id") {
        SplitClip split(fx.seq, fx.b, f30(90));
        const EditResult r = applyReversible(fx.project, split);
        REQUIRE(fx.span(t) != nullptr);
        CHECK(findTransition(fx.sequence(), t)->partner->id == fx.b);
        CHECK(r.droppedTransitionIds.empty());
    }
    SUBCASE("splitting A keeps it: its right piece owns it, the partner is still B") {
        SplitClip split(fx.seq, fx.a, f30(30));
        const EditResult r = applyReversible(fx.project, split);
        REQUIRE(fx.span(t) != nullptr);
        CHECK(findTransition(fx.sequence(), t)->partner->id == fx.b);
        CHECK(r.droppedTransitionIds.empty());
    }
    SUBCASE("a linked crossfade goes with its dissolve") {
        const ClipId aa = fx.addClip(fx.a1, fx.av30, 0, 60, 30);
        const ClipId ab = fx.addClip(fx.a1, fx.av30, 60, 60, 300);
        const ClipId ac = fx.addClip(fx.a1, fx.av30, 120, 60, 900);
        fx.link(fx.a, aa);
        fx.link(fx.b, ab);
        fx.link(c, ac);
        const SpanId crossfade = fx.addTransition(fx.a1, aa, ab, 10);
        fx.requireValid();
        RippleDelete ripple(fx.seq, {fx.b});
        const EditResult r = applyReversible(fx.project, ripple);
        CHECK(fx.span(t) == nullptr);
        CHECK(fx.span(crossfade) == nullptr);
        CHECK(r.droppedTransitionIds.size() == 2);
    }
}

TEST_CASE("ClipIndex finds each transition's linked one as linkedTransition does (review L9)") {
    Fixture fx;
    const auto [va, aa] = fx.addLinkedPair(0, 60, 30);
    const auto [vb, ab] = fx.addLinkedPair(60, 60, 300);
    const ClipId lone = fx.addClip(fx.v2, fx.av30, 0, 60, 600);
    const SpanId dissolve = fx.addTransition(fx.v1, va, vb, 10);
    const SpanId crossfade = fx.addTransition(fx.a1, aa, ab, 10);
    const SpanId fadeOut = fx.addFade(vb, ClipEdge::Tail, f30(12));
    const SpanId audioFadeOut = fx.addFade(ab, ClipEdge::Tail, f30(12));
    const SpanId loneFade = fx.addFade(lone, ClipEdge::Head, f30(5));
    fx.addSpan(va, SpanKind::Motion, 1, f30(30), f30(60));
    fx.requireValid();
    const Sequence &sequence = fx.sequence();
    const ClipIndex index(sequence);
    CHECK(index.find(vb).first == sequence.findClip(vb));
    CHECK(index.find(ClipId{9999}).first == nullptr);
    std::size_t transitions = 0;
    for (const std::vector<Track> *list : {&sequence.videoTracks, &sequence.audioTracks}) {
        for (const Track &track : *list) {
            for (const Clip &clip : track.clips) {
                for (const EffectSpan &span : clip.spans) {
                    CHECK(index.linkedTransition(track, clip, span) == linkedTransition(sequence, span.id));
                    transitions += span.isTransition() ? 1 : 0;
                }
            }
        }
    }
    CHECK(transitions == 5);
    CHECK(linkedTransition(sequence, dissolve) == crossfade);
    CHECK(linkedTransition(sequence, crossfade) == dissolve);
    CHECK(linkedTransition(sequence, fadeOut) == audioFadeOut);
    CHECK_FALSE(linkedTransition(sequence, loneFade).has_value());
}

// ---------------------------------------------------------------------------------------------
// Links

TEST_CASE("LinkClips and UnlinkClip") {
    Fixture fx;
    const ClipId v = fx.addClip(fx.v1, fx.av30, 0, 30);
    const ClipId a = fx.addClip(fx.a1, fx.av30, 0, 30);
    const ClipId other = fx.addClip(fx.v1, fx.av30, 30, 30);
    const ClipId audio2 = fx.addClip(fx.a2, fx.audioOnly, 0, 30);

    LinkClips link(fx.seq, v, a);
    applyReversible(fx.project, link);
    CHECK(fx.clip(v).linkedClipId == a);
    CHECK(fx.clip(a).linkedClipId == v);

    {
        LinkClips self(fx.seq, v, v);
        applyRefused(fx.project, self, EditError::InvalidArgument);
        LinkClips sameTrack(fx.seq, other, v);
        applyRefused(fx.project, sameTrack, EditError::InvalidArgument);
        LinkClips already(fx.seq, v, audio2);
        applyRefused(fx.project, already, EditError::AlreadyLinked);
        LinkClips missing(fx.seq, other, ClipId{999});
        applyRefused(fx.project, missing, EditError::ClipNotFound);
    }

    UnlinkClip unlink(fx.seq, a);
    applyReversible(fx.project, unlink);
    CHECK_FALSE(fx.clip(v).linkedClipId.has_value());
    CHECK_FALSE(fx.clip(a).linkedClipId.has_value());

    UnlinkClip again(fx.seq, a);
    applyRefused(fx.project, again, EditError::NotLinked);

    lockTrack(fx, fx.a2);
    LinkClips locked(fx.seq, other, audio2);
    applyRefused(fx.project, locked, EditError::TrackLocked);
}

// ---------------------------------------------------------------------------------------------
// Tracks

TEST_CASE("AddTrack inserts named tracks at an index") {
    Fixture fx;
    AddTrack top(fx.seq, TrackKind::Video);
    applyReversible(fx.project, top);
    REQUIRE(fx.sequence().videoTracks.size() == 3);
    CHECK(fx.sequence().videoTracks[2].id == top.createdTrackId());
    CHECK(fx.sequence().videoTracks[2].name == "V3");

    AddTrack bottom(fx.seq, TrackKind::Audio, "Music", 0);
    applyReversible(fx.project, bottom);
    CHECK(fx.sequence().audioTracks[0].id == bottom.createdTrackId());
    CHECK(fx.sequence().audioTracks[0].name == "Music");
    CHECK(fx.sequence().audioTracks[0].kind == TrackKind::Audio);

    AddTrack outOfRange(fx.seq, TrackKind::Video, "", 7);
    applyRefused(fx.project, outOfRange, EditError::InvalidArgument);
}

TEST_CASE("RemoveTrack removes clips and transitions and unlinks partners") {
    CutFixture fx;
    const ClipId audio = fx.addClip(fx.a1, fx.av30, 0, 60, 30);
    fx.link(fx.a, audio);
    fx.addTransition(fx.v1, fx.a, fx.b, 10);
    fx.requireValid();

    RemoveTrack remove(fx.seq, fx.v1);
    const EditResult r = applyReversible(fx.project, remove);
    CHECK(fx.sequence().videoTracks.size() == 1);
    CHECK(fx.sequence().videoTracks[0].id == fx.v2);
    CHECK(r.droppedTransitionIds.empty()); // removed on purpose with the track
    CHECK_FALSE(fx.clip(audio).linkedClipId.has_value());

    RemoveTrack missing(fx.seq, TrackId{999});
    applyRefused(fx.project, missing, EditError::TrackNotFound);
    lockTrack(fx, fx.a1);
    RemoveTrack locked(fx.seq, fx.a1);
    applyRefused(fx.project, locked, EditError::TrackLocked);
}

TEST_CASE("SetTrackFlags works on locked tracks and unlocking re-enables edits") {
    Fixture fx;
    const ClipId c = fx.addClip(fx.v1, fx.av30, 0, 30);
    SetTrackFlags lock(fx.seq, fx.v1, TrackFlagsUpdate{true, std::nullopt, true, std::string("Main")});
    applyReversible(fx.project, lock);
    CHECK(fx.track(fx.v1).muted);
    CHECK_FALSE(fx.track(fx.v1).solo);
    CHECK(fx.track(fx.v1).locked);
    CHECK(fx.track(fx.v1).name == "Main");

    MoveClip blocked(fx.seq, c, fx.v1, f30(10));
    applyRefused(fx.project, blocked, EditError::TrackLocked);

    SetTrackFlags unlock(fx.seq, fx.v1, TrackFlagsUpdate{std::nullopt, true, false, std::nullopt});
    applyReversible(fx.project, unlock);
    CHECK(fx.track(fx.v1).muted); // untouched
    CHECK(fx.track(fx.v1).solo);
    CHECK_FALSE(fx.track(fx.v1).locked);

    MoveClip allowed(fx.seq, c, fx.v1, f30(10));
    applyReversible(fx.project, allowed);

    SetTrackFlags missing(fx.seq, TrackId{999}, TrackFlagsUpdate{});
    applyRefused(fx.project, missing, EditError::TrackNotFound);
}

namespace {

// V1: A [0,60) source 30.., B [60,120) source 300..; A1: their linked audio (same times and
// sources); a 10-frame dissolve on V1 and a 16-frame crossfade on A1.
struct LinkedPairFixture : Fixture {
    ClipId a, b, aa, ba;
    SpanId dissolve, crossfade;
    LinkedPairFixture() {
        a = addClip(v1, av30, 0, 60, 30);
        b = addClip(v1, av30, 60, 60, 300);
        aa = addClip(a1, av30, 0, 60, 30);
        ba = addClip(a1, av30, 60, 60, 300);
        link(a, aa);
        link(b, ba);
        dissolve = addTransition(v1, a, b, 10);
        crossfade = addTransition(a1, aa, ba, 16);
        requireValid();
    }
};

} // namespace

TEST_CASE("linkedTransition finds the transition on the linked partners' cut, either way round") {
    LinkedPairFixture fx;
    CHECK(linkedTransition(fx.sequence(), fx.dissolve) == fx.crossfade);
    CHECK(linkedTransition(fx.sequence(), fx.crossfade) == fx.dissolve);
    CHECK_FALSE(linkedTransition(fx.sequence(), SpanId{999}).has_value());
    SUBCASE("no transition on the partners' cut") {
        std::erase_if(fx.sequence().findClip(fx.aa)->spans, [&](const EffectSpan &s) { return s.id == fx.crossfade; });
        CHECK_FALSE(linkedTransition(fx.sequence(), fx.dissolve).has_value());
    }
    SUBCASE("an unlinked clip") {
        fx.sequence().findClip(fx.b)->linkedClipId.reset();
        fx.sequence().findClip(fx.ba)->linkedClipId.reset();
        CHECK_FALSE(linkedTransition(fx.sequence(), fx.dissolve).has_value());
        CHECK_FALSE(linkedTransition(fx.sequence(), fx.crossfade).has_value());
    }
    SUBCASE("fades at the same edge of linked clips are linked; a fade and a dissolve are not") {
        LinkedPairFixture other;
        const SpanId videoFade = other.addFade(other.b, ClipEdge::Tail, f30(10));
        const SpanId audioFade = other.addFade(other.ba, ClipEdge::Tail, f30(20));
        other.requireValid();
        CHECK(linkedTransition(other.sequence(), videoFade) == audioFade);
        CHECK(linkedTransition(other.sequence(), audioFade) == videoFade);
        std::erase_if(other.sequence().findClip(other.aa)->spans, [&](const EffectSpan &s) { return s.id == other.crossfade; });
        other.addTailTransition(other.aa, 8, 0); // a fade out under a dissolve
        other.requireValid();
        CHECK_FALSE(linkedTransition(other.sequence(), other.dissolve).has_value());
    }
}

TEST_CASE("RemoveSpans removes a linked pair as one reversible step") {
    LinkedPairFixture fx;
    RemoveSpans both(fx.seq, {fx.dissolve, fx.crossfade});
    applyReversible(fx.project, both);
    CHECK(both.name() == "Remove Transitions");
    CHECK(fx.span(fx.dissolve) == nullptr);
    CHECK(fx.span(fx.crossfade) == nullptr);
    SUBCASE("refused as a whole") {
        LinkedPairFixture other;
        RemoveSpans missing(other.seq, {other.dissolve, SpanId{999}});
        applyRefused(other.project, missing, EditError::SpanNotFound);
        lockTrack(other, other.a1);
        RemoveSpans locked(other.seq, {other.dissolve, other.crossfade});
        applyRefused(other.project, locked, EditError::TrackLocked);
        RemoveSpans none(other.seq, {});
        applyRefused(other.project, none, EditError::InvalidArgument);
    }
}

TEST_CASE("SetTransitionRanges resizes a linked pair as one step and refuses it as a whole") {
    LinkedPairFixture fx;
    SetTransitionRanges both(fx.seq, {{fx.dissolve, -f30(10), f30(10)}, {fx.crossfade, -f30(12), f30(12)}});
    CHECK(both.name() == "Change Transitions");
    applyReversible(fx.project, both);
    CHECK(transitionFrames(fx, fx.dissolve) == span(50, 70));
    CHECK(transitionFrames(fx, fx.crossfade) == span(48, 72));

    // One of them too long for its clips: nothing changes.
    SetTransitionRanges tooLong(fx.seq, {{fx.dissolve, -f30(15), f30(15)}, {fx.crossfade, -f30(61), f30(61)}});
    applyRefused(fx.project, tooLong, EditError::InvalidArgument);
    CHECK(transitionFrames(fx, fx.dissolve) == span(50, 70));

    SUBCASE("successive steps merge (an Accumulate group of nudges)") {
        SetTransitionRanges first(fx.seq, {{fx.dissolve, -f30(11), f30(11)}, {fx.crossfade, -f30(11), f30(11)}});
        SetTransitionRanges second(fx.seq, {{fx.dissolve, -f30(12), f30(12)}, {fx.crossfade, -f30(12), f30(12)}});
        REQUIRE(first.apply(fx.project));
        REQUIRE(second.apply(fx.project));
        CHECK(first.mergeWith(second));
        CHECK(first.coalescingKey() == second.coalescingKey());
        first.revert(fx.project);
        CHECK(transitionFrames(fx, fx.dissolve) == span(50, 70));
        CHECK(transitionFrames(fx, fx.crossfade) == span(48, 72));
    }
}

TEST_CASE("transitionLimit and transitionSideLimits: what each side of a cut allows, and why") {
    Fixture fx;
    // A has 10 frames of media after its out point; B has 6 before its in point.
    const ClipId a = fx.addClip(fx.v1, fx.av30, 0, 60, 1730);
    const ClipId b = fx.addClip(fx.v1, fx.av30, 60, 40, 6);
    fx.requireValid();
    EditResult why = EditResult::success();
    const auto sides = transitionSideLimits(fx.project, fx.seq, a, SpanId{}, why);
    REQUIRE(sides.has_value());
    CHECK(sides->maxBeforeFrames == 6);
    CHECK(sides->beforeError == EditError::InsufficientHandles);
    CHECK(sides->beforeLimitingClip == b);
    CHECK(sides->beforeReason.find("before its in point") != std::string::npos);
    CHECK(sides->maxAfterFrames == 10);
    CHECK(sides->afterError == EditError::InsufficientHandles);
    CHECK(sides->afterLimitingClip == a);
    // Centred: floor(n/2) <= 6 and ceil(n/2) <= 10 -> 13 (6 before, 7 after).
    const TransitionLimit limit = transitionLimit(fx.project, fx.seq, a, b);
    CHECK(limit.maximumFrames == 13);
    CHECK(limit.limitError == EditError::InsufficientHandles);
    CHECK(limit.limitingClip == b);
    // Each limit is exact: one frame more is refused, the limit itself fits.
    AddTransitionSpans fits(fx.seq, {tailTransition(a, 6, 10)});
    applyReversible(fx.project, fits);
    fits.revert(fx.project);
    AddTransitionSpans before(fx.seq, {tailTransition(a, 7, 10)});
    applyRefused(fx.project, before, EditError::InsufficientHandles);
    AddTransitionSpans after(fx.seq, {tailTransition(a, 6, 11)});
    applyRefused(fx.project, after, EditError::InsufficientHandles);
    SUBCASE("the clips' lengths and neighbouring transitions limit too") {
        Fixture g;
        const ClipId x = g.addClip(g.v1, g.av30, 0, 20, 30);
        const ClipId y = g.addClip(g.v1, g.av30, 20, 12, 300);
        g.addClip(g.v1, g.av30, 32, 30, 600);
        g.addFade(x, ClipEdge::Head, f30(5));
        g.addTailTransition(y, 4, 4); // y's own dissolve into the third clip
        g.requireValid();
        const auto s = transitionSideLimits(g.project, g.seq, x, SpanId{}, why);
        REQUIRE(s.has_value());
        CHECK(s->maxBeforeFrames == 15); // x is 20 long, less its 5-frame fade in
        CHECK(s->beforeError == EditError::Overlap);
        CHECK(s->maxAfterFrames == 8); // y is 12 long, less its own dissolve's 4 frames
        CHECK(s->afterError == EditError::Overlap);
    }
    SUBCASE("structural refusals") {
        CHECK_FALSE(transitionSideLimits(fx.project, fx.seq, b, SpanId{}, why).has_value());
        CHECK(why.error == EditError::NotAdjacent);
        fx.addTransition(fx.v1, a, b, 4);
        CHECK_FALSE(transitionSideLimits(fx.project, fx.seq, a, SpanId{}, why).has_value());
        CHECK(why.error == EditError::AlreadyExists);
        CHECK(transitionLimit(fx.project, fx.seq, a, b).limitError == EditError::AlreadyExists);
        lockTrack(fx, fx.v1);
        CHECK(transitionLimit(fx.project, fx.seq, a, b, fx.clip(a).transitionAt(ClipEdge::Tail)->id).limitError ==
              EditError::TrackLocked);
    }
}

TEST_CASE("isThroughEdit: a plain split versus cuts between different media") {
    Fixture fx;
    // A [0,60) source 30.., B [60,120) source 90..: B continues where A stops.
    const ClipId a = fx.addClip(fx.v1, fx.av30, 0, 60, 30);
    const ClipId b = fx.addClip(fx.v1, fx.av30, 60, 60, 90);
    fx.requireValid();
    CHECK(isThroughEdit(fx.sequence(), a, b));
    CHECK_FALSE(isThroughEdit(fx.sequence(), b, a));
    SUBCASE("a slipped side") {
        fx.sequence().findClip(b)->sourceIn = f30(91);
        CHECK_FALSE(isThroughEdit(fx.sequence(), a, b));
    }
    SUBCASE("different media") {
        fx.sequence().findClip(b)->assetId = fx.av24;
        CHECK_FALSE(isThroughEdit(fx.sequence(), a, b));
    }
    SUBCASE("a different speed") {
        fx.sequence().findClip(b)->speed = Ratio{2, 1};
        CHECK_FALSE(isThroughEdit(fx.sequence(), a, b));
    }
    SUBCASE("different picture parameters show through the dissolve") {
        fx.sequence().findClip(b)->video.scale = 1.5;
        CHECK_FALSE(isThroughEdit(fx.sequence(), a, b));
    }
    SUBCASE("two copies of one still") {
        const ClipId s1 = fx.addClip(fx.v2, fx.still, 0, 60);
        const ClipId s2 = fx.addClip(fx.v2, fx.still, 60, 60);
        CHECK(isThroughEdit(fx.sequence(), s1, s2));
        fx.addSpan(s2, SpanKind::Motion, 1, kCMTimeZero, f30(30));
        CHECK_FALSE(isThroughEdit(fx.sequence(), s1, s2));
    }
    SUBCASE("an effect span on either side makes the pictures differ in the handles") {
        fx.addSpan(a, SpanKind::Opacity, 1, f30(40), f30(90));
        CHECK_FALSE(isThroughEdit(fx.sequence(), a, b));
    }
}
