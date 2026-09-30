// Sequence settings (Sequence.h SequenceFormat, EditOps.h SetSequenceFormat): the standard frame rates
// and what a source's rate maps to, the settings a new sequence adopts from its first video clip, and
// the conform of a sequence's clips when its size or frame rate changes (placements scaled with the
// frame, clip edges on the new grid, transitions keeping their frame counts or shortened with a
// sentence, effect spans on their pictures), undo as one step, refusals, and the project's sharpening
// setting.

#include "../../Engine/Edit/EditOps.h"
#include "../../Engine/Edit/UndoStack.h"
#include "../../Engine/Facade/VEFacadeCommands+Internal.h"
#include "../../Engine/Render/Scheduler.h"
#include "EditTestSupport.h"

#include <algorithm>
#include <cmath>

using namespace vetest;

namespace {

bool anyContains(const std::vector<std::string> &sentences, const std::string &part) {
    return std::any_of(sentences.begin(), sentences.end(),
                       [&](const std::string &s) { return s.find(part) != std::string::npos; });
}

std::string joined(const std::vector<std::string> &sentences) {
    std::string text;
    for (const std::string &s : sentences) {
        text += s + "\n";
    }
    return text;
}

SequenceFormat formatWith(const Sequence &sequence, std::int32_t width, std::int32_t height, CMTime frameDuration) {
    SequenceFormat format = sequence.format();
    format.width = width;
    format.height = height;
    format.frameDuration = frameDuration;
    return format;
}

CMTime f25(std::int64_t frames) {
    return CMTimeMake(frames, 25);
}

// A movie asset of `frames` frames at 30 fps (video only; with `audioExtraFrames` its sound, and so an
// audio clip of it, runs that many frames past the video), for clips that use the whole media.
AssetId addWholeMedia(Fixture &fx, const std::string &name, std::int64_t frames, std::int64_t audioExtraFrames = -1) {
    MediaAsset asset = *fx.project.findAsset(fx.video60);
    asset.name = name;
    asset.url = "file:///media/" + name;
    asset.frameDuration = CMTimeMake(1, 30);
    asset.duration = f30(frames);
    if (audioExtraFrames >= 0) {
        asset.kind = AssetKind::AudioVideo;
        asset.videoDuration = f30(frames);
        asset.duration = f30(frames + audioExtraFrames);
        asset.audioSampleRate = 48000;
        asset.audioChannels = 2;
    }
    return fx.project.addAsset(asset);
}

// Whether every clip of every track ends where the next one on its track starts, where they touched.
bool clipsTouch(const Sequence &sequence, const std::vector<std::pair<ClipId, ClipId>> &cuts) {
    return std::all_of(cuts.begin(), cuts.end(), [&](const auto &cut) {
        return sequence.findClip(cut.first)->timelineEnd() == sequence.findClip(cut.second)->timelineStart;
    });
}

} // namespace

TEST_CASE("SequenceFormat: the standard frame rates and what a source's rate maps to") {
    const std::vector<CMTime> &standard = standardFrameDurations();
    REQUIRE(standard.size() == 8);
    const std::vector<std::string> names{"23.976", "24", "25", "29.97", "30", "50", "59.94", "60"};
    for (std::size_t i = 0; i < standard.size(); ++i) {
        CHECK(frameRateName(standard[i]) == names[i]);
        // Every standard rate maps to itself, exactly.
        const double rate = double(standard[i].timescale) / double(standard[i].value);
        const auto mapped = standardFrameDurationFor(rate);
        REQUIRE(mapped.has_value());
        CHECK(identical(*mapped, standard[i]));
    }
    CHECK(frameRateName(CMTimeMake(1, 15)) == "15");
    CHECK(frameRateName(CMTimeMake(2, 25)) == "12.5");
    struct Case {
        double rate;
        CMTime expected;
    };
    const Case cases[] = {
        // Near a standard rate: the nearest (on a log scale).
        {30.01, CMTimeMake(1, 30)},
        {29.98, CMTimeMake(1001, 30000)},
        {59.8, CMTimeMake(1001, 60000)},
        {60.03, CMTimeMake(1, 60)},
        {48.0, CMTimeMake(1, 50)},
        {26.0, CMTimeMake(1, 25)},
        {27.5, CMTimeMake(1001, 30000)},
        // Slow rates: the slowest standard rate that shows each frame a whole number of times.
        {15.0, CMTimeMake(1, 30)},
        {14.985, CMTimeMake(1001, 30000)},
        {12.5, CMTimeMake(1, 25)},
        {10.0, CMTimeMake(1, 30)},
        {20.0, CMTimeMake(1, 60)},
        {7.0, CMTimeMake(1, 30)}, // no standard rate is a multiple: 30
        // Above 60: the standard rate it is a multiple of, else 60.
        {120.0, CMTimeMake(1, 60)},
        {240.0, CMTimeMake(1, 60)},
        {119.88, CMTimeMake(1001, 60000)},
        {100.0, CMTimeMake(1, 50)},
        {90.0, CMTimeMake(1, 60)},
        {72.0, CMTimeMake(1, 60)},
    };
    for (const Case &c : cases) {
        const auto mapped = standardFrameDurationFor(c.rate);
        REQUIRE(mapped.has_value());
        CHECK_MESSAGE(identical(*mapped, c.expected),
                      doctest::String((std::to_string(c.rate) + " fps -> " + describe(*mapped)).c_str()));
    }
    CHECK_FALSE(standardFrameDurationFor(0).has_value());
    CHECK_FALSE(standardFrameDurationFor(-30).has_value());
    CHECK_FALSE(standardFrameDurationFor(INFINITY).has_value());
    CHECK_FALSE(standardFrameDurationFor(NAN).has_value());
}

TEST_CASE("SequenceFormat: what a sequence adopts from its first video clip's asset") {
    const Fixture fx;
    const SequenceFormat current = fx.sequence().format();
    CHECK(current.width == 1920);
    CHECK(current.height == 1080);
    // A 3840x2160 23.976 A/V asset: its size and rate, the current sample rate, configured.
    SequenceFormat unconfigured = current;
    unconfigured.configured = false;
    unconfigured.audioSampleRate = 44100;
    const auto uhd = formatAdoptedFrom(*fx.project.findAsset(fx.av24), unconfigured);
    REQUIRE(uhd.has_value());
    CHECK(uhd->width == 3840);
    CHECK(uhd->height == 2160);
    CHECK(identical(uhd->frameDuration, CMTimeMake(1001, 24000)));
    CHECK(uhd->audioSampleRate == 44100);
    CHECK(uhd->configured);
    // Stills and sound never count.
    CHECK_FALSE(formatAdoptedFrom(*fx.project.findAsset(fx.still), unconfigured).has_value());
    CHECK_FALSE(formatAdoptedFrom(*fx.project.findAsset(fx.audioOnly), unconfigured).has_value());
    // The displayed size (MediaAsset keeps it after the rotation), odd sides rounded down to even (the
    // compositor draws the picture pixel exact, its spare column and row cropped).
    MediaAsset odd = *fx.project.findAsset(fx.video60);
    odd.width = 1081;
    odd.height = 1921;
    odd.rotationDegrees = 90;
    const auto portrait = formatAdoptedFrom(odd, unconfigured);
    REQUIRE(portrait.has_value());
    CHECK(portrait->width == 1080);
    CHECK(portrait->height == 1920);
    MediaAsset window = odd;
    window.width = 1273;
    window.height = 815;
    window.rotationDegrees = 0;
    const auto recording = formatAdoptedFrom(window, unconfigured);
    REQUIRE(recording.has_value());
    CHECK(recording->width == 1272);
    CHECK(recording->height == 814);
    CHECK(identical(portrait->frameDuration, CMTimeMake(1, 60)));
    // A variable frame rate: the rate of its shortest frame interval, rounded to a standard rate.
    MediaAsset vfr = odd;
    vfr.width = 3832;
    vfr.height = 2154;
    vfr.isVFR = true;
    vfr.frameDuration = CMTimeMake(1001, 59900); // 59.84 fps
    const auto screen = formatAdoptedFrom(vfr, unconfigured);
    REQUIRE(screen.has_value());
    CHECK(identical(screen->frameDuration, CMTimeMake(1001, 60000)));
    CHECK(screen->width == 3832);
    CHECK(screen->height == 2154);
    vfr.frameDuration = CMTimeMake(1, 240); // a slow-motion section
    CHECK(identical(formatAdoptedFrom(vfr, unconfigured)->frameDuration, CMTimeMake(1, 60)));
    // No frame duration at all (a variable-rate file that states none): the current rate.
    vfr.frameDuration = kCMTimeInvalid;
    CHECK(identical(formatAdoptedFrom(vfr, unconfigured)->frameDuration, current.frameDuration));
    // A size the sequence cannot take keeps the current size (the rate is still taken).
    MediaAsset huge = *fx.project.findAsset(fx.av24);
    huge.width = 20000;
    const auto kept = formatAdoptedFrom(huge, unconfigured);
    REQUIRE(kept.has_value());
    CHECK(kept->width == 1920);
    CHECK(kept->height == 1080);
    CHECK(identical(kept->frameDuration, CMTimeMake(1001, 24000)));
}

TEST_CASE("SequenceFormat: settings out of range are refused") {
    Fixture fx;
    const Sequence &sequence = fx.sequence();
    const SequenceFormat valid = sequence.format();
    CHECK_FALSE(sequenceFormatProblem(valid).has_value());
    auto problem = [&](auto change) {
        SequenceFormat format = valid;
        change(format);
        return sequenceFormatProblem(format).value_or("");
    };
    CHECK(problem([](SequenceFormat &f) { f.width = 1921; }).find("even") != std::string::npos);
    CHECK(problem([](SequenceFormat &f) { f.height = 8; }).find("between 16 and 16384") != std::string::npos);
    CHECK(problem([](SequenceFormat &f) { f.width = 16386; }).find("between 16 and 16384") != std::string::npos);
    CHECK(problem([](SequenceFormat &f) { f.frameDuration = CMTimeMake(1, 300); }).find("frame rate") !=
          std::string::npos);
    CHECK(problem([](SequenceFormat &f) { f.frameDuration = CMTimeMake(2, 1); }).find("frame rate") !=
          std::string::npos);
    CHECK(problem([](SequenceFormat &f) { f.frameDuration = kCMTimeInvalid; }).find("frame rate") !=
          std::string::npos);
    CHECK(problem([](SequenceFormat &f) { f.audioSampleRate = 4000; }).find("sample rate") != std::string::npos);
    // The command refuses them too, changing nothing.
    fx.addLinkedPair(0, 60);
    const Project before = fx.project;
    SequenceFormat odd = valid;
    odd.width = 1001;
    SetSequenceFormat command(fx.seq, odd);
    const EditResult result = command.apply(fx.project);
    CHECK(result.error == EditError::InvalidArgument);
    CHECK(fx.project == before);
}

TEST_CASE("SetSequenceFormat: a size change scales every placement with the frame") {
    Fixture fx;
    // A picture in picture with a static offset and a Motion span moving it; a full-frame clip on V2
    // with a 4:3 still; a sound clip (no placement).
    const auto [v, a] = fx.addLinkedPair(0, 90);
    Clip &clip = *fx.sequence().findClip(v);
    clip.video = VideoParams{100.0, -50.0, 0.5, 15.0, 0.75};
    SpanTracks move;
    move.x = {key(kCMTimeZero, 0), key(f30(30), 240)};
    move.y = {key(kCMTimeZero, -30), key(f30(30), 60)};
    move.scale = {key(kCMTimeZero, 1), key(f30(30), 1.5)};
    move.rotation = {key(kCMTimeZero, 0), key(f30(30), 10)};
    const SpanId span = fx.addSpan(v, SpanKind::Motion, 1, f30(10), f30(40), move);
    MediaAsset photo = *fx.project.findAsset(fx.still);
    photo.name = "photo.jpg";
    photo.width = 1440;
    photo.height = 1080;
    const AssetId photoId = fx.project.addAsset(photo);
    const ClipId still = fx.addClip(fx.v2, photoId, 0, 60);
    fx.sequence().findClip(still)->video = VideoParams{-20, 40, 0.8, 0, 1};
    fx.requireValid();
    const std::uint64_t idsBefore = fx.project.ids.nextValue();

    SUBCASE("the same shape: positions double, scales stay") {
        SetSequenceFormat command(fx.seq, formatWith(fx.sequence(), 3840, 2160, CMTimeMake(1, 30)));
        const EditResult result = applyReversible(fx.project, command);
        CHECK(result.droppedTransitionIds.empty());
        const SequenceConformReport &report = command.report();
        CHECK(report.placementScale == 2.0);
        CHECK(report.clipsRescaled == 2);
        CHECK(report.clipsRetimed == 0);
        const Clip &after = fx.clip(v);
        CHECK(after.video == VideoParams{200.0, -100.0, 0.5, 15.0, 0.75});
        const EffectSpan &moved = *fx.span(span);
        CHECK(moved.tracks.x[1].value == 480.0);
        CHECK(moved.tracks.y[0].value == -60.0);
        CHECK(moved.tracks.y[1].value == 120.0);
        CHECK(moved.tracks.scale[1].value == 1.5); // factors and degrees do not change
        CHECK(moved.tracks.rotation[1].value == 10.0);
        CHECK(identical(moved.start, f30(10)));
        CHECK(fx.clip(still).video == VideoParams{-40, 80, 0.8, 0, 1});
        CHECK(fx.clip(a).video == VideoParams{}); // sound: untouched
        CHECK(fx.sequence().width == 3840);
        CHECK(fx.sequence().height == 2160);
        CHECK(fx.sequence().configured);
        CHECK(fx.project.ids.nextValue() == idsBefore);
        CHECK(anyContains(report.sentences, "The frame becomes 3840×2160 (from 1920×1080): positions, sizes and "
                                            "Motion spans are scaled ×2 with it, so every picture stays the same."));
    }
    SUBCASE("another shape: the old frame fitted inside the new one") {
        SetSequenceFormat command(fx.seq, formatWith(fx.sequence(), 1080, 1080, CMTimeMake(1, 30)));
        applyReversible(fx.project, command);
        const double k = 1080.0 / 1920.0;
        CHECK(command.report().placementScale == k);
        // The 16:9 movie filled the old frame's width: its fitted size scales with the fitted old frame,
        // so its scale stays; the 4:3 photo was fitted by height (1440x1080 in 1920x1080), now by width
        // (1080x810), so its scale grows by k * 1 / 0.75 = 0.75 ... of its new fit to keep 810 x k.
        const Clip &after = fx.clip(v);
        CHECK(after.video.x == doctest::Approx(100.0 * k));
        CHECK(after.video.y == doctest::Approx(-50.0 * k));
        CHECK(after.video.scale == 0.5);
        const Clip &photoClip = fx.clip(still);
        CHECK(photoClip.video.scale == doctest::Approx(0.8 * k * 1.0 / 0.75));
        CHECK(anyContains(command.report().sentences, "another shape: the old frame is fitted inside the new one"));
    }
}

TEST_CASE("SetSequenceFormat: a frame-rate change moves clip edges to the new grid and keeps transitions' frames") {
    Fixture fx;
    // V1: A [0, 45) | B [45, 100) with a 10-frame dissolve centred on the cut (5 + 5); B fades out over
    // its last 15 frames. A1: A's sound with a 9-frame fade in. V2: a still [7, 52) with a Motion span.
    const auto [va, aa] = fx.addLinkedPair(0, 45, 30);
    const ClipId vb = fx.addClip(fx.v1, fx.av30, 45, 55, 300);
    const SpanId dissolve = fx.addTransition(fx.v1, va, vb, 10);
    const SpanId fadeOut = fx.addFade(vb, ClipEdge::Tail, f30(15));
    const SpanId fadeIn = fx.addFade(aa, ClipEdge::Head, f30(9));
    const ClipId still = fx.addClip(fx.v2, fx.still, 7, 45);
    SpanTracks zoom;
    zoom.scale = {key(kCMTimeZero, 1), key(f30(20), 2)};
    const SpanId motion = fx.addSpan(still, SpanKind::Motion, 1, f30(5), f30(25), zoom);
    const SpanId bMotion = fx.addSpan(vb, SpanKind::Motion, 1, f30(310), f30(340), zoom); // B's source times
    fx.requireValid();
    const Clip bBefore = fx.clip(vb);

    SetSequenceFormat command(fx.seq, formatWith(fx.sequence(), 1920, 1080, CMTimeMake(1, 25)));
    const EditResult result = applyReversible(fx.project, command);
    CHECK(result.droppedTransitionIds.empty());
    const SequenceConformReport &report = command.report();
    INFO(joined(report.sentences));
    CHECK(identical(fx.sequence().frameDuration, CMTimeMake(1, 25)));
    // Edges to the nearest 25 fps frame: 45/30 s = 37.5 frames -> 38 (a half goes up), 100/30 s = 83.33 -> 83,
    // 7/30 s = 5.83 -> 6, 52/30 s = 43.33 -> 43. Touching clips stay touching.
    CHECK(fx.clip(va).timelineStart == f25(0));
    CHECK(fx.clip(va).timelineEnd() == f25(38));
    CHECK(fx.clip(vb).timelineStart == f25(38));
    CHECK(fx.clip(vb).timelineEnd() == f25(83));
    CHECK(fx.clip(aa).timelineEnd() == f25(38));
    CHECK(fx.clip(still).timelineStart == f25(6));
    CHECK(fx.clip(still).timelineEnd() == f25(43));
    // The media in points move with the starts: B starts 1/50 s later in time, and so in its media.
    CHECK(fx.clip(vb).sourceIn == bBefore.sourceIn + (f25(38) - f30(45)));
    CHECK(report.clipsRetimed == 4);
    CHECK(report.largestShift == CMTimeMake(1, 50)); // 45/30 = 1.5 s -> 38/25 = 1.52 s
    // Transitions keep their frame counts: 5 + 5, 15 and 9 frames at 25 fps.
    CHECK(report.transitionsKept == 3);
    CHECK(report.transitionsShortened.empty());
    CHECK(report.transitionsRemoved.empty());
    CHECK(identical(fx.span(dissolve)->start, -f25(5)));
    CHECK(identical(fx.span(dissolve)->end, f25(5)));
    CHECK(identical(fx.span(fadeOut)->start, -f25(15)));
    CHECK(identical(fx.span(fadeIn)->end, f25(9)));
    // An effect span stays on its pictures. A still's "source" time is the time into the clip, so when
    // its start moves (7/30 s -> 6/25 s, 1/150 s earlier) its span's times move the other way and it
    // keeps its timeline frames; a movie clip's spans keep their source times (see the next case).
    const CMTime moved = f30(7) - f25(6);
    CHECK(fx.span(motion)->start == f30(5) + moved);
    CHECK(fx.span(motion)->end == f30(25) + moved);
    CHECK(fx.clip(still).timelineStart + fx.span(motion)->start == f30(7) + f30(5));
    CHECK(identical(fx.span(bMotion)->start, f30(310)));
    CHECK(identical(fx.span(bMotion)->end, f30(340)));
    CHECK(anyContains(report.sentences, "The frame rate becomes 25 fps (from 30): 4 clips move their start or end "
                                        "to the nearest frame, by at most 0.02 s."));
    CHECK(anyContains(report.sentences, "3 transitions keep their frame counts, so their length in seconds changes"));
    CHECK(anyContains(report.sentences, "Motion, Opacity and Gain spans stay on their pictures"));
    CHECK(report.sentences.size() == 3);

    // Every sequence frame of the dissolve shows both clips, as before: 10 frames at 25 fps.
    const auto placed = findTransition(fx.sequence(), dissolve);
    REQUIRE(placed.has_value());
    CHECK(placed->range.start == f25(33));
    CHECK(placed->range.end == f25(43));
}

TEST_CASE("SetSequenceFormat: transitions that no longer fit are shortened or removed, with a sentence") {
    Fixture fx;
    // At 60 fps: A [0, 120) | B [120, 240) with a 20-frame dissolve (10 + 10) where A's media ends
    // 12 frames (0.2 s) after its out point. At 24 fps 10 frames after the cut need 0.417 s: only 4 fit.
    // B ends where its media ends; its fade out (30 frames) stays inside it.
    fx.sequence().frameDuration = CMTimeMake(1, 60);
    auto add60 = [&](TrackId track, AssetId asset, std::int64_t start, std::int64_t length, CMTime in) {
        const ClipId id = fx.addClip(track, asset, 0, 1);
        Clip &c = *fx.sequence().findClip(id);
        c.timelineStart = CMTimeMake(start, 60);
        c.timelineDuration = CMTimeMake(length, 60);
        c.sourceIn = in;
        fx.track(track).sortClips();
        return id;
    };
    MediaAsset shortMedia = *fx.project.findAsset(fx.video60);
    shortMedia.name = "short.mov";
    shortMedia.duration = CMTimeMake(132, 60); // 2.2 s: A uses [0, 2) and has 0.2 s after its out point
    const AssetId shortId = fx.project.addAsset(shortMedia);
    const ClipId a = add60(fx.v1, shortId, 0, 120, kCMTimeZero);
    const ClipId b = add60(fx.v1, fx.video60, 120, 120, CMTimeMake(360, 60)); // media [6, 8) of 10 s
    EffectSpan span;
    span.id = fx.project.ids.make<SpanId>();
    span.lane = kTransitionLane;
    span.kind = SpanKind::Transition;
    span.edge = ClipEdge::Tail;
    span.start = CMTimeMake(-10, 60);
    span.end = CMTimeMake(10, 60);
    fx.sequence().findClip(a)->spans.push_back(span);
    const SpanId dissolve = span.id;
    // V2: C [0, 6) at 60 fps (0.1 s) with a fade in of 5 frames and nothing after it.
    const ClipId c = add60(fx.v2, fx.video60, 0, 6, kCMTimeZero);
    EffectSpan fade;
    fade.id = fx.project.ids.make<SpanId>();
    fade.lane = kTransitionLane;
    fade.kind = SpanKind::Transition;
    fade.edge = ClipEdge::Head;
    fade.start = kCMTimeZero;
    fade.end = CMTimeMake(5, 60);
    fx.sequence().findClip(c)->spans.push_back(fade);
    fx.requireValid();

    SetSequenceFormat command(fx.seq, formatWith(fx.sequence(), 1920, 1080, CMTimeMake(1, 24)));
    applyReversible(fx.project, command);
    const SequenceConformReport &report = command.report();
    INFO(joined(report.sentences));
    // A and B: 2 s = 48 frames each at 24 fps (on the grid already).
    CHECK(fx.clip(a).timelineEnd() == CMTimeMake(48, 24));
    CHECK(fx.clip(b).timelineEnd() == CMTimeMake(96, 24));
    // The dissolve: 10 frames before the cut fit, after it A's 0.2 s of media give 4 whole frames.
    REQUIRE(fx.span(dissolve) != nullptr);
    CHECK(identical(fx.span(dissolve)->start, CMTimeMake(-10, 24)));
    CHECK(identical(fx.span(dissolve)->end, CMTimeMake(4, 24)));
    CHECK(report.transitionsShortened == std::vector<SpanId>{dissolve, fade.id});
    CHECK(anyContains(report.sentences, "The cross dissolve between “short.mov” and “video60.mkv” is shortened "
                                        "from 20 frames to 14 frames: “short.mov” has no more media after its out "
                                        "point."));
    // C: 0.1 s is 2.4 frames at 24 fps -> 2 frames; its 5-frame fade in keeps 2 (the clip's length).
    CHECK(fx.clip(c).timelineDuration == CMTimeMake(2, 24));
    const EffectSpan *fadeIn = fx.clip(c).transitionAt(ClipEdge::Head);
    REQUIRE(fadeIn != nullptr);
    CHECK(identical(fadeIn->end, CMTimeMake(2, 24)));
    CHECK(anyContains(report.sentences, "The fade in at the start of “video60.mkv” is shortened from 5 frames to 2 "
                                        "frames"));
}

TEST_CASE("SetSequenceFormat: an end on the media's end takes the cut to the frame before; its fade keeps its frames") {
    Fixture fx;
    // A [0, 45) ends exactly where its media ends (1.5 s). At 25 fps the cut (37.5 frames) would round up to
    // 38/25 = 1.52 s, past A's media: the cut goes down to 37/25 instead, for B too (B has media before its in
    // point), so the clips still touch (no black frame between them). A's 6-frame fade out keeps its 6 frames.
    MediaAsset shortMedia = *fx.project.findAsset(fx.video60);
    shortMedia.name = "ends.mov";
    shortMedia.duration = CMTimeMake(45, 30);
    shortMedia.frameDuration = CMTimeMake(1, 30);
    const AssetId shortId = fx.project.addAsset(shortMedia);
    const ClipId a = fx.addClip(fx.v1, shortId, 0, 45, 0);
    const ClipId b = fx.addClip(fx.v1, fx.av30, 45, 45, 300);
    const Clip bBefore = fx.clip(b);
    const SpanId fade = fx.addFade(a, ClipEdge::Tail, f30(6));
    fx.requireValid();
    SetSequenceFormat command(fx.seq, formatWith(fx.sequence(), 1920, 1080, CMTimeMake(1, 25)));
    applyReversible(fx.project, command);
    INFO(joined(command.report().sentences));
    CHECK(fx.clip(a).timelineEnd() == f25(37));
    CHECK(fx.clip(b).timelineStart == f25(37));
    CHECK(fx.clip(b).sourceIn == bBefore.sourceIn + (f25(37) - f30(45))); // a trim: B's head shows 0.02 s more
    CHECK(command.report().clipsMoved == 0);
    REQUIRE(fx.span(fade) != nullptr);
    CHECK(identical(fx.span(fade)->start, -f25(6)));
    CHECK(command.report().transitionsKept == 1);
}

TEST_CASE("SetSequenceFormat: a start on the media's start takes the cut to the frame after") {
    Fixture fx;
    // A [0, 46) has media after its out point; B [46, 91) starts on its media's start. At 25 fps the cut
    // (46/30 s = 38.33 frames) rounds down to 38/25 s, before B's media: the cut goes up to 39/25 s for
    // both (A shows 0.027 s more of its media), and B's end on its media's end rounds inward (75.83 -> 75).
    const AssetId whole = addWholeMedia(fx, "starts.mov", 45);
    const ClipId a = fx.addClip(fx.v1, fx.av30, 0, 46, 0);
    const ClipId b = fx.addClip(fx.v1, whole, 46, 45, 0);
    fx.requireValid();
    SetSequenceFormat command(fx.seq, formatWith(fx.sequence(), 1920, 1080, CMTimeMake(1, 25)));
    applyReversible(fx.project, command);
    INFO(joined(command.report().sentences));
    CHECK(fx.clip(a).timelineEnd() == f25(39));
    CHECK(fx.clip(b).timelineStart == f25(39));
    CHECK(fx.clip(b).sourceIn == f25(39) - f30(46)); // B's head is trimmed by 0.027 s
    CHECK(fx.clip(b).timelineEnd() == f25(75));
    CHECK(command.report().clipsMoved == 0);
}

TEST_CASE("SetSequenceFormat: whole clips back to back stay touching; the later ones move with their media") {
    // Clips that each use their whole media (each ends on its media's end and starts on its media's start):
    // no cut between them can move to either neighbouring frame by a trim. The cut goes to the frame before it
    // and the next clip moves there with its media (its in point stays 0), so there is no black frame between
    // them; each clip then shows the whole frames its media fills.
    SUBCASE("the cut would round up") {
        Fixture fx;
        // Three clips of 45 frames at 30 fps (1.5 s = 37.5 frames at 25 fps): each keeps 37 frames.
        const ClipId a = fx.addClip(fx.v1, addWholeMedia(fx, "a.mov", 45), 0, 45, 0);
        const ClipId b = fx.addClip(fx.v1, addWholeMedia(fx, "b.mov", 45), 45, 45, 0);
        const ClipId c = fx.addClip(fx.v1, addWholeMedia(fx, "c.mov", 45), 90, 45, 0);
        fx.requireValid();
        SetSequenceFormat command(fx.seq, formatWith(fx.sequence(), 1920, 1080, CMTimeMake(1, 25)));
        applyReversible(fx.project, command);
        const SequenceConformReport &report = command.report();
        INFO(joined(report.sentences));
        CHECK(fx.clip(a).timelineStart == f25(0));
        CHECK(fx.clip(a).timelineEnd() == f25(37));
        CHECK(fx.clip(b).timelineStart == f25(37));
        CHECK(fx.clip(b).timelineEnd() == f25(74));
        CHECK(fx.clip(c).timelineStart == f25(74));
        CHECK(fx.clip(c).timelineEnd() == f25(111));
        for (const ClipId id : {a, b, c}) {
            CHECK(fx.clip(id).sourceIn == kCMTimeZero); // every clip still starts on its first picture
        }
        CHECK(report.clipsMoved == 2);
        CHECK(report.largestMove == CMTimeMake(1, 25)); // C: 3 s -> 74/25 s
        CHECK(anyContains(report.sentences, "2 clips move earlier with their media, by at most 0.04 s, to keep "
                                            "touching the clip before: neither side of the cut has media to spare."));
    }
    SUBCASE("the cut would round down") {
        Fixture fx;
        // A has 46 frames (38.33 at 25 fps), B 45: the cut at 46/30 s rounds down to 38/25 s, before B's media.
        const ClipId a = fx.addClip(fx.v1, addWholeMedia(fx, "a.mov", 46), 0, 46, 0);
        const ClipId b = fx.addClip(fx.v1, addWholeMedia(fx, "b.mov", 45), 46, 45, 0);
        fx.requireValid();
        SetSequenceFormat command(fx.seq, formatWith(fx.sequence(), 1920, 1080, CMTimeMake(1, 25)));
        applyReversible(fx.project, command);
        const SequenceConformReport &report = command.report();
        INFO(joined(report.sentences));
        CHECK(fx.clip(a).timelineEnd() == f25(38));
        CHECK(fx.clip(b).timelineStart == f25(38));
        CHECK(fx.clip(b).sourceIn == kCMTimeZero);
        // B moved 1/75 s earlier (46/30 -> 38/25 s); its end, on its media's end at 3.02 s now, is 75/25 s.
        CHECK(fx.clip(b).timelineEnd() == f25(75));
        CHECK(report.clipsMoved == 1);
        CHECK(report.largestMove == CMTimeMake(1, 75));
    }
}

TEST_CASE("SetSequenceFormat: linked picture and sound of whole clips stay touching, aligned and in sync") {
    Fixture fx;
    // Two linked pairs from media whose sound runs 3 frames past the picture (as in most camera files): the
    // picture of each clip ends on its video's end and starts on its media's start, the sound has media to
    // spare. The cut (1.5 s = 37.5 frames at 25 fps) goes to 37 on both tracks, and B's picture and sound move
    // there together, so B's sound plays against its own picture.
    const AssetId first = addWholeMedia(fx, "first.mov", 45, 3);
    const AssetId second = addWholeMedia(fx, "second.mov", 45, 3);
    const ClipId av = fx.addClip(fx.v1, first, 0, 45, 0);
    const ClipId aa = fx.addClip(fx.a1, first, 0, 45, 0);
    fx.link(av, aa);
    const ClipId bv = fx.addClip(fx.v1, second, 45, 45, 0);
    const ClipId ba = fx.addClip(fx.a1, second, 45, 45, 0);
    fx.link(bv, ba);
    fx.requireValid();
    SetSequenceFormat command(fx.seq, formatWith(fx.sequence(), 1920, 1080, CMTimeMake(1, 25)));
    applyReversible(fx.project, command);
    const SequenceConformReport &report = command.report();
    INFO(joined(report.sentences));
    CHECK(clipsTouch(fx.sequence(), {{av, bv}, {aa, ba}}));
    for (const ClipId id : {av, aa}) {
        CHECK(fx.clip(id).timelineEnd() == f25(37));
    }
    for (const ClipId id : {bv, ba}) {
        CHECK(fx.clip(id).timelineStart == f25(37));
        CHECK(fx.clip(id).timelineEnd() == f25(74));
        CHECK(fx.clip(id).sourceIn == kCMTimeZero);
    }
    CHECK(report.clipsMoved == 2); // B's picture and its sound
}

TEST_CASE("SetSequenceFormat: a clip linked to a moved clip moves with it and conforms from there") {
    Fixture fx;
    // B's picture moves 0.02 s earlier with its media to keep touching A (both whole at the cut). B's sound
    // starts later than the picture (at 2 s, in sync: its in point 0.5 s) and runs past it to 4 s; it moves
    // with the picture, so its start and end (both on the 25 fps grid before the move) are conformed from
    // 1.98 s and 3.98 s: back to 2 s and 4 s by a trim, still in sync with the picture.
    fx.addClip(fx.v1, addWholeMedia(fx, "a.mov", 45), 0, 45, 0);
    const AssetId bMedia = addWholeMedia(fx, "b.mov", 45, 45);
    const ClipId bv = fx.addClip(fx.v1, bMedia, 45, 45, 0);
    const ClipId ba = fx.addClip(fx.a1, bMedia, 60, 60, 15);
    fx.link(bv, ba);
    fx.requireValid();
    SetSequenceFormat command(fx.seq, formatWith(fx.sequence(), 1920, 1080, CMTimeMake(1, 25)));
    applyReversible(fx.project, command);
    INFO(joined(command.report().sentences));
    CHECK(fx.clip(bv).timelineStart == f25(37));
    CHECK(fx.clip(bv).sourceIn == kCMTimeZero);
    CHECK(fx.clip(ba).timelineStart == f25(50));
    CHECK(fx.clip(ba).timelineEnd() == f25(100));
    CHECK(fx.clip(ba).sourceIn == CMTimeMake(13, 25)); // 0.5 s + the 0.02 s move
    for (const CMTime t : {f25(50), f25(60), f25(70)}) {
        const auto picture = fx.clip(bv).exactSourceTimeAt(t);
        const auto sound = fx.clip(ba).exactSourceTimeAt(t);
        REQUIRE((picture && sound));
        CHECK(*picture == *sound);
    }
    CHECK(command.report().clipsMoved == 2);
}

TEST_CASE("SetSequenceFormat: a cross dissolve at a cut that moves keeps its partner and its frames") {
    Fixture fx;
    // A [0, 46) has media after its out point, B [46, 91) starts on its media's start: a dissolve at their cut
    // lies wholly after it (no media before B's in point), 5 frames. At 25 fps the cut goes to 39/25 s for both
    // clips (see "a start on the media's start"), and the dissolve stays a cross dissolve between A and B.
    const AssetId whole = addWholeMedia(fx, "starts.mov", 45);
    const ClipId a = fx.addClip(fx.v1, fx.av30, 0, 46, 0);
    const ClipId b = fx.addClip(fx.v1, whole, 46, 45, 0);
    const SpanId dissolve = fx.addTailTransition(a, 0, 5);
    fx.requireValid();
    SetSequenceFormat command(fx.seq, formatWith(fx.sequence(), 1920, 1080, CMTimeMake(1, 25)));
    applyReversible(fx.project, command);
    const SequenceConformReport &report = command.report();
    INFO(joined(report.sentences));
    const auto placed = findTransition(fx.sequence(), dissolve);
    REQUIRE(placed.has_value());
    CHECK(placed->role == TransitionRole::CrossDissolve);
    REQUIRE(placed->partner != nullptr);
    CHECK(placed->partner->id == b);
    CHECK(placed->range.start == f25(39));
    CHECK(placed->range.end == f25(44));
    CHECK(report.transitionsKept == 1);
    CHECK(report.transitionsRemoved.empty());
    CHECK(report.transitionsShortened.empty());
}

TEST_CASE("SetSequenceFormat: adopting a first clip's rate keeps the sound already on the sequence touching") {
    Fixture fx;
    // The placement that sets an unconfigured sequence runs the settings change first (the facade's
    // composite): two whole sound files back to back on A1 conform like any clips.
    fx.sequence().configured = false;
    MediaAsset sound = *fx.project.findAsset(fx.audioOnly);
    sound.duration = f30(45);
    sound.name = "one.m4a";
    const AssetId one = fx.project.addAsset(sound);
    sound.name = "two.m4a";
    const AssetId two = fx.project.addAsset(sound);
    const ClipId first = fx.addClip(fx.a1, one, 0, 45, 0);
    const ClipId second = fx.addClip(fx.a1, two, 45, 45, 0);
    fx.requireValid();
    SequenceFormat adopted = formatWith(fx.sequence(), 1920, 1080, CMTimeMake(1, 25));
    std::vector<std::unique_ptr<Command>> children;
    auto settings = std::make_unique<SetSequenceFormat>(fx.seq, adopted, "Overwrite");
    const SetSequenceFormat *conform = settings.get();
    children.push_back(std::move(settings));
    children.push_back(std::make_unique<OverwriteClip>(
        fx.seq, f25(100), std::vector<ClipPlacement>{place(fx.v1, fx.video60, 0, 60)}, false));
    ve::facade::CompositeCommand composite("Overwrite", std::move(children));
    applyReversible(fx.project, composite);
    INFO(joined(conform->report().sentences));
    CHECK(fx.sequence().configured);
    CHECK(fx.clip(first).timelineEnd() == f25(37));
    CHECK(fx.clip(second).timelineStart == f25(37));
    CHECK(fx.clip(second).sourceIn == kCMTimeZero);
    CHECK(conform->report().clipsMoved == 1);
}

TEST_CASE("SetSequenceFormat: a clip that would have to move against its linked clip is refused") {
    Fixture fx;
    // B's picture starts on its media's start against A, which ends on its media's end: the cut can only
    // stay by moving B earlier with its media. B's sound, linked to it, was slipped to start 5 frames before
    // the picture (so it no longer plays in sync) and was conformed first: moving B's picture alone would move
    // it against its sound. Refused with the reason; nothing changes.
    fx.addClip(fx.v1, addWholeMedia(fx, "a.mov", 45), 0, 45, 0);
    const AssetId bMedia = addWholeMedia(fx, "b.mov", 45, 10);
    const ClipId bv = fx.addClip(fx.v1, bMedia, 45, 45, 0);
    const ClipId ba = fx.addClip(fx.a1, bMedia, 40, 50, 0);
    fx.link(bv, ba);
    fx.requireValid();
    const Project before = fx.project;
    SetSequenceFormat command(fx.seq, formatWith(fx.sequence(), 1920, 1080, CMTimeMake(1, 25)));
    const EditResult result = command.apply(fx.project);
    CHECK(result.error == EditError::OutOfSourceRange);
    CHECK(result.message == "“b.mov” cannot stay against the clip before it at 25 fps: it has no media before its "
                            "in point and moving it would put it out of sync with the clip it is linked to; unlink "
                            "them or trim it first.");
    CHECK(fx.project == before);
}

TEST_CASE("SetSequenceFormat: a cross dissolve with not one frame left is removed with a sentence") {
    Fixture fx;
    // A [0, 45) has 1/30 s of media after its out point: a dissolve 4 frames before the cut and 1 after
    // fits at 30 fps. At 25 fps A's end rounds up to 38/25 = 1.52 s (its media reaches 46/30 = 1.533 s),
    // B's start with it, and one frame after the cut would need A's media to 1.56 s: none fits.
    MediaAsset shortMedia = *fx.project.findAsset(fx.video60);
    shortMedia.name = "ends.mov";
    shortMedia.duration = CMTimeMake(46, 30);
    shortMedia.frameDuration = CMTimeMake(1, 30);
    const AssetId shortId = fx.project.addAsset(shortMedia);
    const ClipId a = fx.addClip(fx.v1, shortId, 0, 45, 0);
    const ClipId b = fx.addClip(fx.v1, fx.av30, 45, 45, 300);
    const SpanId dissolve = fx.addTailTransition(a, 4, 1);
    fx.requireValid();
    SetSequenceFormat command(fx.seq, formatWith(fx.sequence(), 1920, 1080, CMTimeMake(1, 25)));
    const EditResult result = applyReversible(fx.project, command);
    const SequenceConformReport &report = command.report();
    INFO(joined(report.sentences));
    CHECK(fx.clip(a).timelineEnd() == f25(38));
    CHECK(fx.clip(b).timelineStart == f25(38));
    CHECK(fx.span(dissolve) == nullptr);
    CHECK(report.transitionsRemoved == std::vector<SpanId>{dissolve});
    CHECK(result.droppedTransitionIds.empty()); // removed on purpose, named in the report
    CHECK(anyContains(report.sentences, "The cross dissolve between “ends.mov” and “av30.mov” is removed: not one "
                                        "frame of it fits at 25 fps (“ends.mov” has no more media after its out "
                                        "point)."));
}

TEST_CASE("SetSequenceFormat: a clip shorter than a frame keeps one, or the change is refused") {
    Fixture fx;
    fx.sequence().frameDuration = CMTimeMake(1, 60);
    auto add60 = [&](TrackId track, AssetId asset, std::int64_t start, std::int64_t length) {
        const ClipId id = fx.addClip(track, asset, 0, 1);
        Clip &c = *fx.sequence().findClip(id);
        c.timelineStart = CMTimeMake(start, 60);
        c.timelineDuration = CMTimeMake(length, 60);
        c.sourceIn = kCMTimeZero;
        fx.track(track).sortClips();
        return id;
    };
    // One frame of a still at 60 fps, alone on V2: at 24 fps it keeps one frame.
    const ClipId flash = add60(fx.v2, fx.still, 60, 1);
    fx.requireValid();
    {
        Project copy = fx.project;
        SetSequenceFormat command(fx.seq, formatWith(fx.sequence(), 1920, 1080, CMTimeMake(1, 24)));
        REQUIRE(command.apply(copy).ok());
        const Clip &kept = *copy.findSequence(fx.seq)->findClip(flash);
        CHECK(kept.timelineStart == CMTimeMake(24, 24));
        CHECK(kept.timelineDuration == CMTimeMake(1, 24));
    }
    // With a still right after it, touching it, the cut moves to the frame after the flash (the next still
    // gives up the sliver): both keep touching.
    const ClipId next = add60(fx.v2, fx.still, 61, 60);
    fx.requireValid();
    {
        Project copy = fx.project;
        SetSequenceFormat command(fx.seq, formatWith(fx.sequence(), 1920, 1080, CMTimeMake(1, 24)));
        REQUIRE(command.apply(copy).ok());
        const Sequence &conformed = *copy.findSequence(fx.seq);
        CHECK(conformed.findClip(flash)->timelineStart == CMTimeMake(24, 24));
        CHECK(conformed.findClip(flash)->timelineEnd() == CMTimeMake(25, 24));
        CHECK(conformed.findClip(next)->timelineStart == CMTimeMake(25, 24));
        CHECK(conformed.findClip(next)->timelineEnd() == CMTimeMake(48, 24)); // 121/60 s is 48.4 frames
    }
    // One frame of a movie at the very end of its media (nothing after it to extend into): refused, nothing
    // changes.
    const ClipId last = add60(fx.v1, fx.video60, 60, 1);
    fx.sequence().findClip(last)->sourceIn = CMTimeMake(599, 60);
    fx.requireValid();
    const Project before = fx.project;
    SetSequenceFormat command(fx.seq, formatWith(fx.sequence(), 1920, 1080, CMTimeMake(1, 24)));
    const EditResult result = command.apply(fx.project);
    CHECK(result.error == EditError::OutOfSourceRange);
    CHECK(result.message == "“video60.mkv” is shorter than a frame at 24 fps and has no media to fill one; trim or "
                            "remove it first.");
    CHECK(fx.project == before);
}

TEST_CASE("SetSequenceFormat: a one-frame clip whose start moves up keeps a frame after it") {
    Fixture fx;
    // One frame at 60 fps from the start of its media, at 61/60 s: at 24 fps its start cannot round down to
    // 24/24 s (before its media) and goes up to 25/24 s; its end (62/60 s, 24.8 frames) rounds to the same
    // frame, so it ends one frame later, 26/24 s, where its media still reaches.
    fx.sequence().frameDuration = CMTimeMake(1, 60);
    const ClipId flash = fx.addClip(fx.v1, fx.video60, 0, 1);
    Clip &c = *fx.sequence().findClip(flash);
    c.timelineStart = CMTimeMake(61, 60);
    c.timelineDuration = CMTimeMake(1, 60);
    c.sourceIn = kCMTimeZero;
    fx.requireValid();
    SetSequenceFormat command(fx.seq, formatWith(fx.sequence(), 1920, 1080, CMTimeMake(1, 24)));
    applyReversible(fx.project, command);
    CHECK(fx.clip(flash).timelineStart == CMTimeMake(25, 24));
    CHECK(fx.clip(flash).timelineEnd() == CMTimeMake(26, 24));
    CHECK(fx.clip(flash).sourceIn == CMTimeMake(25, 24) - CMTimeMake(61, 60));
}

TEST_CASE("SetSequenceFormat: locked tracks are conformed too; unchanged settings change nothing") {
    Fixture fx;
    const auto [v, a] = fx.addLinkedPair(0, 45);
    fx.sequence().findClip(v)->video.x = 30;
    lockTrack(fx, fx.v1);
    lockTrack(fx, fx.a1);
    fx.requireValid();
    SetSequenceFormat command(fx.seq, formatWith(fx.sequence(), 1280, 720, CMTimeMake(1, 25)));
    applyReversible(fx.project, command);
    CHECK(fx.clip(v).video.x == doctest::Approx(20.0));
    CHECK(fx.clip(v).timelineEnd() == f25(38));
    CHECK(fx.clip(a).timelineEnd() == f25(38));

    // The same settings again: no change, no undo step.
    UndoStack undo;
    const std::size_t steps = undo.undoCount();
    CHECK(undo.push(fx.project, std::make_unique<SetSequenceFormat>(fx.seq, fx.sequence().format())).ok());
    CHECK(undo.undoCount() == steps);
    // Configuring an unconfigured sequence with its own settings is a step (the flag changes) that undo
    // takes back.
    fx.sequence().configured = false;
    SequenceFormat same = fx.sequence().format();
    CHECK(undo.push(fx.project, std::make_unique<SetSequenceFormat>(fx.seq, same)).ok());
    CHECK(fx.sequence().configured);
    CHECK(undo.undoCount() == steps + 1);
    CHECK(undo.undo(fx.project));
    CHECK_FALSE(fx.sequence().configured);
}

TEST_CASE("SetSequenceFormat: patches carry the settings; a change and its reverse compose to nothing") {
    Fixture fx;
    fx.addLinkedPair(0, 60);
    fx.requireValid();
    UndoStack undo;
    undo.beginCoalescing("settings", CoalesceMode::Accumulate);
    auto withKey = [](std::unique_ptr<Command> command) {
        command->setCoalescingKey("settings");
        return command;
    };
    const Project before = fx.project;
    CHECK(undo.push(fx.project, withKey(std::make_unique<SetSequenceFormat>(
                                    fx.seq, formatWith(fx.sequence(), 3840, 2160, CMTimeMake(1, 30)))))
              .ok());
    CHECK(undo.push(fx.project, withKey(std::make_unique<SetSequenceFormat>(
                                    fx.seq, formatWith(fx.sequence(), 1920, 1080, CMTimeMake(1, 30)))))
              .ok());
    undo.endCoalescing();
    CHECK(fx.project == before);
    CHECK(undo.undoCount() == 0);
}

TEST_CASE("SetSharpenScaledDownSources: an undoable project setting") {
    Fixture fx;
    CHECK(fx.project.sharpenScaledDownSources);
    UndoStack undo;
    CHECK(undo.push(fx.project, std::make_unique<SetSharpenScaledDownSources>(true)).ok());
    CHECK(undo.undoCount() == 0); // already on: no step
    CHECK(undo.push(fx.project, std::make_unique<SetSharpenScaledDownSources>(false)).ok());
    CHECK_FALSE(fx.project.sharpenScaledDownSources);
    CHECK(undo.undoName() == "Don't Sharpen Scaled-Down Sources");
    CHECK(undo.undo(fx.project));
    CHECK(fx.project.sharpenScaledDownSources);
    CHECK(undo.redo(fx.project));
    CHECK_FALSE(fx.project.sharpenScaledDownSources);
    // Every graph the Scheduler makes carries it (RenderGraph::sharpenMinified): the program's, the solo
    // preview's; the compositor sharpens by it.
    const ClipId clip = fx.addClip(fx.v1, fx.av30, 0, 30);
    for (const bool sharpen : {false, true}) {
        fx.project.sharpenScaledDownSources = sharpen;
        CHECK(Scheduler::renderGraphAt(fx.sequence(), fx.project, f30(3)).sharpenMinified == sharpen);
        CHECK(Scheduler::renderGraphAt(fx.sequence(), fx.project, f30(300)).sharpenMinified == sharpen); // empty
        CHECK(Scheduler::soloGraphAt(fx.sequence(), fx.project, clip, f30(3), true).sharpenMinified == sharpen);
    }
}
