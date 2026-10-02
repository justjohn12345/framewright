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

// A movie asset with picture and sound of the given lengths (exact times), at `frameDuration`.
AssetId addMovie(Fixture &fx, const std::string &name, CMTime frameDuration, CMTime videoDuration,
                 CMTime audioDuration) {
    MediaAsset asset = *fx.project.findAsset(fx.video60);
    asset.name = name;
    asset.url = "file:///media/" + name;
    asset.frameDuration = frameDuration;
    asset.kind = AssetKind::AudioVideo;
    asset.videoDuration = videoDuration;
    asset.duration = audioDuration;
    asset.audioSampleRate = 48000;
    asset.audioChannels = 2;
    return fx.project.addAsset(asset);
}

// Places a clip at exact times (the fixture's addClip takes 30 fps frames).
ClipId putClip(Fixture &fx, TrackId track, AssetId asset, CMTime start, CMTime length, CMTime in) {
    const ClipId id = fx.addClip(track, asset, 0, 1);
    Clip &c = *fx.sequence().findClip(id);
    c.timelineStart = start;
    c.timelineDuration = length;
    c.sourceIn = in;
    fx.track(track).sortClips();
    return id;
}

// Whether two clips show the same media time wherever both play (linked picture and sound in sync).
bool inSync(const Sequence &sequence, ClipId a, ClipId b) {
    const Clip &x = *sequence.findClip(a);
    const Clip &y = *sequence.findClip(b);
    const CMTime from = maxTime(x.timelineStart, y.timelineStart);
    const CMTime to = minTime(x.timelineEnd(), y.timelineEnd());
    for (const CMTime t : {from, to}) {
        const auto sx = x.exactSourceTimeAt(t);
        const auto sy = y.exactSourceTimeAt(t);
        if (!(sx && sy && *sx == *sy)) {
            return false;
        }
    }
    return true;
}

// Every clip edge of `sequence` on the grid of `frameDuration`.
bool onGrid(const Sequence &sequence, CMTime frameDuration) {
    for (const std::vector<Track> *list : {&sequence.videoTracks, &sequence.audioTracks}) {
        for (const Track &track : *list) {
            for (const Clip &clip : track.clips) {
                if (!isOnFrameGrid(clip.timelineStart, frameDuration) || !isOnFrameGrid(clip.timelineEnd(), frameDuration)) {
                    return false;
                }
            }
        }
    }
    return true;
}

// Whether every clip of every track ends where the next one on its track starts, where they touched.
bool clipsTouch(const Sequence &sequence, const std::vector<std::pair<ClipId, ClipId>> &cuts) {
    return std::all_of(cuts.begin(), cuts.end(), [&](const auto &cut) {
        return sequence.findClip(cut.first)->timelineEnd() == sequence.findClip(cut.second)->timelineStart;
    });
}

bool overlapping(CMTime from, CMTime to, CMTime otherFrom, CMTime otherTo) {
    return maxTime(from, otherFrom) < minTime(to, otherTo);
}

bool overlapping(const Clip &a, const Clip &b) {
    return overlapping(a.timelineStart, a.timelineEnd(), b.timelineStart, b.timelineEnd());
}

// Whether `after` (a clip at speed 1, conformed) still plays part of the source range `before` played.
bool playsPartOf(const Clip &before, const Clip &after) {
    return overlapping(before.sourceIn, before.sourceIn + before.timelineDuration, after.sourceIn,
                       after.sourceIn + after.timelineDuration);
}

// Whether two linked clips shared an edge (started or ended together).
bool shareAnEdge(const Clip &a, const Clip &b) {
    return a.timelineStart == b.timelineStart || a.timelineEnd() == b.timelineEnd();
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

TEST_CASE("SequenceFormat: a rate above 240 fps is a time base, not a frame rate") {
    // Matroska and WebM tick in milliseconds: a variable-rate file's shortest interval can read as 1000 fps,
    // which is a whole multiple of 50 and used to adopt 50 fps.
    CHECK_FALSE(standardFrameDurationFor(1000.0).has_value());
    CHECK_FALSE(standardFrameDurationFor(90000.0).has_value());
    CHECK_FALSE(standardFrameDurationFor(241.0).has_value());
    const auto fastest = standardFrameDurationFor(240.0);
    REQUIRE(fastest.has_value());
    CHECK(identical(*fastest, CMTimeMake(1, 60)));
    const Fixture fx;
    SequenceFormat unconfigured = fx.sequence().format();
    unconfigured.configured = false;
    MediaAsset mkv = *fx.project.findAsset(fx.video60);
    mkv.frameDuration = CMTimeMake(1, 1000);
    mkv.isVFR = true;
    const auto adopted = formatAdoptedFrom(mkv, unconfigured);
    REQUIRE(adopted.has_value());
    CHECK(identical(adopted->frameDuration, unconfigured.frameDuration)); // no usable rate: the sequence's own
    CHECK(adopted->width == 1280);
    CHECK(adopted->configured);
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
    move[SpanParameter::X] = {key(kCMTimeZero, 0), key(f30(30), 240)};
    move[SpanParameter::Y] = {key(kCMTimeZero, -30), key(f30(30), 60)};
    move[SpanParameter::Scale] = {key(kCMTimeZero, 1), key(f30(30), 1.5)};
    move[SpanParameter::Rotation] = {key(kCMTimeZero, 0), key(f30(30), 10)};
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
        CHECK(moved.tracks[SpanParameter::X][1].value == 480.0);
        CHECK(moved.tracks[SpanParameter::Y][0].value == -60.0);
        CHECK(moved.tracks[SpanParameter::Y][1].value == 120.0);
        CHECK(moved.tracks[SpanParameter::Scale][1].value == 1.5); // factors and degrees do not change
        CHECK(moved.tracks[SpanParameter::Rotation][1].value == 10.0);
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
    zoom[SpanParameter::Scale] = {key(kCMTimeZero, 1), key(f30(20), 2)};
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
    CHECK(identical(fx.transition(dissolve)->start, -f25(5)));
    CHECK(identical(fx.transition(dissolve)->end, f25(5)));
    CHECK(identical(fx.transition(fadeOut)->start, -f25(15)));
    CHECK(identical(fx.transition(fadeIn)->end, f25(9)));
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
    TransitionSpan span;
    span.id = fx.project.ids.make<SpanId>();
    span.edge = ClipEdge::Tail;
    span.start = CMTimeMake(-10, 60);
    span.end = CMTimeMake(10, 60);
    fx.sequence().findClip(a)->transitions.push_back(span);
    const SpanId dissolve = span.id;
    // V2: C [0, 6) at 60 fps (0.1 s) with a fade in of 5 frames and nothing after it.
    const ClipId c = add60(fx.v2, fx.video60, 0, 6, kCMTimeZero);
    TransitionSpan fade;
    fade.id = fx.project.ids.make<SpanId>();
    fade.edge = ClipEdge::Head;
    fade.start = kCMTimeZero;
    fade.end = CMTimeMake(5, 60);
    fx.sequence().findClip(c)->transitions.push_back(fade);
    fx.requireValid();

    SetSequenceFormat command(fx.seq, formatWith(fx.sequence(), 1920, 1080, CMTimeMake(1, 24)));
    applyReversible(fx.project, command);
    const SequenceConformReport &report = command.report();
    INFO(joined(report.sentences));
    // A and B: 2 s = 48 frames each at 24 fps (on the grid already).
    CHECK(fx.clip(a).timelineEnd() == CMTimeMake(48, 24));
    CHECK(fx.clip(b).timelineEnd() == CMTimeMake(96, 24));
    // The dissolve: 10 frames before the cut fit, after it A's 0.2 s of media give 4 whole frames.
    REQUIRE(fx.transition(dissolve) != nullptr);
    CHECK(identical(fx.transition(dissolve)->start, CMTimeMake(-10, 24)));
    CHECK(identical(fx.transition(dissolve)->end, CMTimeMake(4, 24)));
    CHECK(report.transitionsShortened == std::vector<SpanId>{dissolve, fade.id});
    CHECK(anyContains(report.sentences, "The cross dissolve between “short.mov” and “video60.mkv” is shortened "
                                        "from 20 frames to 14 frames: “short.mov” has no more media after its out "
                                        "point."));
    // C: 0.1 s is 2.4 frames at 24 fps -> 2 frames; its 5-frame fade in keeps 2 (the clip's length).
    CHECK(fx.clip(c).timelineDuration == CMTimeMake(2, 24));
    const TransitionSpan *fadeIn = fx.clip(c).transitionAt(ClipEdge::Head);
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
    REQUIRE(fx.transition(fade) != nullptr);
    CHECK(identical(fx.transition(fade)->start, -f25(6)));
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

TEST_CASE("SetSequenceFormat: a clip linked to a clip decided earlier moves with it, or the change is refused") {
    // B's picture starts on its media's start against A, which ends on its media's end: the cut can only stay
    // by moving B earlier with its media, and its sound with it.
    SUBCASE("the sound conformed first keeps its media with the move: both move, their offset kept") {
        // B's sound, linked to it, was slipped to start 5 frames before the picture (out of sync) and was
        // conformed first (its start, on its media's start, goes up to 34/25 s). Moving it by B's move keeps
        // media from there, so both move: the 5-frame offset stays as it was. (Refused before the fix round's
        // R2: a start decided first counted as a decided move of zero.)
        Fixture fx;
        fx.addClip(fx.v1, addWholeMedia(fx, "a.mov", 45), 0, 45, 0);
        const AssetId bMedia = addWholeMedia(fx, "b.mov", 45, 10);
        const ClipId bv = fx.addClip(fx.v1, bMedia, 45, 45, 0);
        const ClipId ba = fx.addClip(fx.a1, bMedia, 40, 50, 0);
        fx.link(bv, ba);
        fx.requireValid();
        const CMTime offset = fx.clip(bv).timelineStart - fx.clip(ba).timelineStart;
        SetSequenceFormat command(fx.seq, formatWith(fx.sequence(), 1920, 1080, CMTimeMake(1, 25)));
        applyReversible(fx.project, command);
        INFO(joined(command.report().sentences));
        CHECK(fx.clip(bv).timelineStart == f25(37));
        CHECK(fx.clip(bv).sourceIn == kCMTimeZero);
        CHECK(fx.clip(ba).timelineStart == f25(34));
        // Both moved by 1/50 s; the sound's head was then trimmed to its decided start.
        CHECK(fx.clip(ba).sourceIn == f25(34) - (f30(40) - CMTimeMake(1, 50)));
        const auto picture = fx.clip(bv).exactSourceTimeAt(f25(50));
        const auto sound = fx.clip(ba).exactSourceTimeAt(f25(50) - offset);
        REQUIRE((picture && sound));
        CHECK(*picture == *sound); // the offset is the one it had
        CHECK(command.report().clipsMoved == 2);
    }
    SUBCASE("refused: the sound moved with its picture at one cut would have to move again at another") {
        // B (whole, at 41/30 s) moves 1/150 s earlier to keep touching A (the cut 41/30 s goes to 34/25 s). B's
        // sound, linked to it but slipped to its media's start (out of sync), starts later, against a sound
        // file that ends on its media's end at 46/30 s (38.33 frames at 25 fps): its start can only go to
        // 38/25 s, where it has media only if it moves 1/75 s earlier, which would put it out of sync with
        // the picture that moved by 1/150 s. Refused with the reason; nothing changes.
        Fixture fx;
        fx.addClip(fx.v1, addWholeMedia(fx, "a.mov", 41), 0, 41, 0);
        const AssetId bMedia = addWholeMedia(fx, "b.mov", 60, 30);
        const ClipId bv = fx.addClip(fx.v1, bMedia, 41, 60, 0);
        MediaAsset sound = *fx.project.findAsset(fx.audioOnly);
        sound.name = "room.m4a";
        sound.duration = f30(46);
        const AssetId room = fx.project.addAsset(sound);
        fx.addClip(fx.a1, room, 0, 46, 0);
        const ClipId ba = fx.addClip(fx.a1, bMedia, 46, 50, 0);
        fx.link(bv, ba);
        fx.requireValid();
        const Project before = fx.project;
        SetSequenceFormat command(fx.seq, formatWith(fx.sequence(), 1920, 1080, CMTimeMake(1, 25)));
        const EditResult result = command.apply(fx.project);
        CHECK(result.error == EditError::OutOfSourceRange);
        CHECK(result.message == "“b.mov” cannot stay against the clip before it at 25 fps: it has no media before "
                                "its in point and moving it would put it out of sync with the clip it is linked "
                                "to; unlink them or trim it first.");
        CHECK(fx.project == before);
    }
}

TEST_CASE("SetSequenceFormat: dual-system sound that starts before its whole picture moves with it, in sync") {
    // Review R2 of the fix round: two whole camera clips back to back; the second is linked by hand to the
    // recorder's sound (music.m4a from 100 frames in), which rolled 10 frames before the camera and is in sync
    // with it. The cut (1.5 s = 37.5 frames at 25 fps) goes to 37/25 s and B moves 1/50 s earlier with its
    // media; the sound, whose start (35/30 s -> 29/25 s) was decided first, moves with it and is trimmed back
    // to its decided start: still in sync. It was refused as "out of sync with the clip it is linked to".
    Fixture fx;
    fx.addClip(fx.v1, addWholeMedia(fx, "a.mov", 45), 0, 45, 0);
    const ClipId bv = fx.addClip(fx.v1, addWholeMedia(fx, "b.mov", 45), 45, 45, 0);
    const ClipId rec = fx.addClip(fx.a1, fx.audioOnly, 35, 55, 100);
    fx.link(bv, rec);
    fx.requireValid();
    // Two files: in sync means the recorder's media time minus the camera's is the same everywhere.
    auto offset = [&](CMTime t) {
        const auto picture = fx.clip(bv).exactSourceTimeAt(t);
        const auto sound = fx.clip(rec).exactSourceTimeAt(t);
        REQUIRE((picture && sound));
        return sound->toTimeRounded() - picture->toTimeRounded();
    };
    const CMTime before = offset(f30(60));
    SetSequenceFormat command(fx.seq, formatWith(fx.sequence(), 1920, 1080, CMTimeMake(1, 25)));
    const EditResult result = applyReversible(fx.project, command);
    REQUIRE_MESSAGE(result.ok(), doctest::String(result.message.c_str()));
    INFO(joined(command.report().sentences));
    CHECK(fx.clip(bv).timelineStart == f25(37));
    CHECK(fx.clip(bv).sourceIn == kCMTimeZero);
    CHECK(fx.clip(rec).timelineStart == f25(29));
    CHECK(fx.clip(rec).timelineEnd() == fx.clip(bv).timelineEnd());
    CHECK(offset(f25(40)) == before);
    CHECK(offset(fx.clip(bv).timelineStart) == before);
    CHECK(onGrid(fx.sequence(), CMTimeMake(1, 25)));
    CHECK(command.report().clipsMoved == 2);
}

TEST_CASE("SetSequenceFormat: a linked sound clip's end that rounded up on its own comes back to the cut") {
    // Review R1 of the fix round: V1 holds a.mov ending on its picture's end, then b.mov from its start; A1
    // their linked sound, a.mov's one source frame shorter than its picture (so its end is not aligned and is
    // conformed alone, earlier). The sound's end rounds up past the frame the cut must take (the frame before:
    // two whole pictures), and came back as a refusal "“a.mov” is shorter than a frame ... the next clip
    // leaves no room for one", which was false: it ends at the cut now, with its picture.
    struct Case {
        const char *name;
        CMTime oldFd, newFd;
        std::int64_t pictureFrames, soundFrames, bFrames; // in old frames
        CMTime cut;
    };
    for (const Case &c : {Case{"60 -> 25 fps", CMTimeMake(1, 60), CMTimeMake(1, 25), 91, 90, 60, CMTimeMake(37, 25)},
                          Case{"120 -> 24 fps", CMTimeMake(1, 120), CMTimeMake(1, 24), 184, 183, 120, CMTimeMake(36, 24)}}) {
        CAPTURE(c.name);
        Fixture fx;
        fx.sequence().frameDuration = c.oldFd;
        auto T = [&](std::int64_t frames) { return CMTimeMultiply(c.oldFd, static_cast<int32_t>(frames)); };
        const AssetId a = addMovie(fx, "a.mov", c.oldFd, T(c.pictureFrames), T(c.pictureFrames + 200));
        const AssetId b = addMovie(fx, "b.mov", c.oldFd, T(c.bFrames), T(c.bFrames + 200));
        const ClipId av = putClip(fx, fx.v1, a, kCMTimeZero, T(c.pictureFrames), kCMTimeZero);
        const ClipId aa = putClip(fx, fx.a1, a, kCMTimeZero, T(c.soundFrames), kCMTimeZero);
        fx.link(av, aa);
        const ClipId bv = putClip(fx, fx.v1, b, T(c.pictureFrames), T(c.bFrames), kCMTimeZero);
        const ClipId ba = putClip(fx, fx.a1, b, T(c.pictureFrames), T(c.bFrames), kCMTimeZero);
        fx.link(bv, ba);
        fx.requireValid();
        SetSequenceFormat command(fx.seq, formatWith(fx.sequence(), 1920, 1080, c.newFd));
        const EditResult result = applyReversible(fx.project, command);
        REQUIRE_MESSAGE(result.ok(), doctest::String(result.message.c_str()));
        INFO(joined(command.report().sentences));
        for (const ClipId id : {av, aa}) {
            CHECK(fx.clip(id).timelineEnd() == c.cut);
        }
        for (const ClipId id : {bv, ba}) {
            CHECK(fx.clip(id).timelineStart == c.cut);
            CHECK(fx.clip(id).sourceIn == kCMTimeZero);
        }
        CHECK(inSync(fx.sequence(), av, aa));
        CHECK(inSync(fx.sequence(), bv, ba));
        CHECK(onGrid(fx.sequence(), c.newFd));
    }
}

TEST_CASE("SetSequenceFormat: a linked sound clip shorter than a frame starts earlier to keep one") {
    // A one-frame-at-30-fps sound clip (two 60 fps frames) linked to a three-frame whole picture, the sound
    // starting a frame later (an L-cut). Its start rounds up to the frame its end must take (the picture
    // ends on its media's end, and the next picture starts on its media's start), which left it no frame and
    // refused the change; it now starts a frame before that, into its media, still in sync.
    SUBCASE("at a cut") {
        Fixture fx;
        fx.sequence().frameDuration = CMTimeMake(1, 60);
        const AssetId m0 = addMovie(fx, "m0.mov", CMTimeMake(1, 60), CMTimeMake(3, 60), CMTimeMake(6, 60));
        const AssetId m1 = addMovie(fx, "m1.mov", CMTimeMake(1, 60), CMTimeMake(25, 60), CMTimeMake(26, 60));
        const ClipId v0 = putClip(fx, fx.v1, m0, kCMTimeZero, CMTimeMake(3, 60), kCMTimeZero);
        const ClipId s0 = putClip(fx, fx.a1, m0, CMTimeMake(1, 60), CMTimeMake(2, 60), CMTimeMake(1, 60));
        fx.link(v0, s0);
        const ClipId v1 = putClip(fx, fx.v1, m1, CMTimeMake(3, 60), CMTimeMake(24, 60), CMTimeMake(1, 60));
        const ClipId s1 = putClip(fx, fx.a1, m1, CMTimeMake(3, 60), CMTimeMake(24, 60), CMTimeMake(1, 60));
        fx.link(v1, s1);
        fx.requireValid();
        SetSequenceFormat command(fx.seq, formatWith(fx.sequence(), 1920, 1080, CMTimeMake(1, 30)));
        const EditResult result = applyReversible(fx.project, command);
        REQUIRE_MESSAGE(result.ok(), doctest::String(result.message.c_str()));
        CHECK(fx.clip(s0).timelineStart == kCMTimeZero);
        CHECK(fx.clip(s0).timelineEnd() == CMTimeMake(1, 30));
        CHECK(fx.clip(s0).sourceIn == kCMTimeZero);
        CHECK(fx.clip(v0).timelineEnd() == CMTimeMake(1, 30));
        CHECK(fx.clip(v1).timelineStart == CMTimeMake(1, 30));
        CHECK(fx.clip(s1).timelineStart == CMTimeMake(1, 30));
        CHECK(inSync(fx.sequence(), v0, s0));
        CHECK(inSync(fx.sequence(), v1, s1));
        CHECK(onGrid(fx.sequence(), CMTimeMake(1, 30)));
    }
    SUBCASE("at the end of the sequence") {
        // The last pair: a three-frame whole picture at 29.97 fps and its one-frame sound, ends aligned.
        Fixture fx;
        const CMTime fd = CMTimeMake(1001, 30000);
        fx.sequence().frameDuration = fd;
        auto T = [&](std::int64_t frames) { return CMTimeMultiply(fd, static_cast<int32_t>(frames)); };
        const AssetId m0 = addMovie(fx, "m0.mov", fd, T(60), T(60));
        const AssetId m1 = addMovie(fx, "m1.mov", fd, T(3), T(4));
        const ClipId v0 = putClip(fx, fx.v1, m0, kCMTimeZero, T(60), kCMTimeZero);
        const ClipId s0 = putClip(fx, fx.a1, m0, kCMTimeZero, T(60), kCMTimeZero);
        fx.link(v0, s0);
        const ClipId v1 = putClip(fx, fx.v1, m1, T(85), T(3), kCMTimeZero);
        const ClipId s1 = putClip(fx, fx.a1, m1, T(87), T(1), T(2));
        fx.link(v1, s1);
        fx.requireValid();
        const CMTime newFd = CMTimeMake(1001, 24000);
        SetSequenceFormat command(fx.seq, formatWith(fx.sequence(), 1920, 1080, newFd));
        const EditResult result = applyReversible(fx.project, command);
        REQUIRE_MESSAGE(result.ok(), doctest::String(result.message.c_str()));
        CHECK(fx.clip(s1).timelineDuration == newFd);
        CHECK(fx.clip(s1).timelineEnd() == fx.clip(v1).timelineEnd());
        CHECK(inSync(fx.sequence(), v1, s1));
        CHECK(onGrid(fx.sequence(), newFd));
    }
}

TEST_CASE("SetSequenceFormat: a linked sound clip shorter than a frame with no way to keep one is refused, naming both") {
    // As "a linked sound clip shorter than a frame starts earlier to keep one" (at a cut), but the sound
    // (s0.m4a, linked to the picture by hand) starts on its media's start, so its start cannot go back, and
    // the next sound touches it, so its end cannot leave the cut: the cut would need a frame after the
    // picture's media. Refused, naming the sound that has no frame and the picture without media.
    Fixture fx;
    fx.sequence().frameDuration = CMTimeMake(1, 60);
    const AssetId m0 = addMovie(fx, "m0.mov", CMTimeMake(1, 60), CMTimeMake(3, 60), CMTimeMake(6, 60));
    const AssetId m1 = addMovie(fx, "m1.mov", CMTimeMake(1, 60), CMTimeMake(25, 60), CMTimeMake(26, 60));
    MediaAsset sound = *fx.project.findAsset(fx.audioOnly);
    sound.name = "s0.m4a";
    const AssetId s0Media = fx.project.addAsset(sound);
    const ClipId v0 = putClip(fx, fx.v1, m0, kCMTimeZero, CMTimeMake(3, 60), kCMTimeZero);
    const ClipId s0 = putClip(fx, fx.a1, s0Media, CMTimeMake(1, 60), CMTimeMake(2, 60), kCMTimeZero);
    fx.link(v0, s0);
    const ClipId v1 = putClip(fx, fx.v1, m1, CMTimeMake(3, 60), CMTimeMake(24, 60), CMTimeMake(1, 60));
    const ClipId s1 = putClip(fx, fx.a1, m1, CMTimeMake(3, 60), CMTimeMake(24, 60), CMTimeMake(1, 60));
    fx.link(v1, s1);
    fx.requireValid();
    const Project before = fx.project;
    SetSequenceFormat command(fx.seq, formatWith(fx.sequence(), 1920, 1080, CMTimeMake(1, 30)));
    const EditResult result = command.apply(fx.project);
    CHECK(result.error == EditError::OutOfSourceRange);
    CHECK(result.message == "“s0.m4a” is shorter than a frame at 30 fps, and “m0.mov”, which ends with it, has no "
                            "media to make room for one; trim or unlink them first.");
    CHECK(fx.project == before);
}

TEST_CASE("SetSequenceFormat: sub-frame linked sound brings the cut at its start back to stay under its picture") {
    // Review of 2026-10-01 (a regression of R2, 7e2335b): at 50 fps, p.mov's two-frame whole picture
    // [42, 44) has its sound on A1 for its last frame only, [43, 44) from source frame 1, touching the sound
    // of v0.mov before it (one frame longer than v0.mov's picture). At 25 fps the A1 cut (43/50 s, 21.5
    // frames) rounds up to 22/25, the sound's end must take p.mov's end (22/25, its media's end, before
    // q.mov from its media's start), and the sound had no frame. Its start could not go back alone (it
    // shares the cut), so its end went apart to 23/25: the sound played [22, 23)/25 from source 0.04-0.08,
    // none of its own sound, wholly after its picture and under q.mov, while v0.mov's sound grew over
    // where it was. Now the cut comes back to 21/25 with it: the sound plays [21, 22)/25 from source 0,
    // under its picture and in sync, and v0.mov's sound ends with its picture.
    Fixture fx;
    const CMTime fd = CMTimeMake(1, 50);
    fx.sequence().frameDuration = fd;
    auto T = [](std::int64_t frames) { return CMTimeMake(frames, 50); };
    const AssetId m0 = addMovie(fx, "v0.mov", fd, T(42), T(60));
    const AssetId m1 = addMovie(fx, "p.mov", fd, T(2), T(4));
    const AssetId m2 = addMovie(fx, "q.mov", fd, T(30), T(40));
    const ClipId v0 = putClip(fx, fx.v1, m0, kCMTimeZero, T(42), kCMTimeZero);
    const ClipId v0Sound = putClip(fx, fx.a1, m0, kCMTimeZero, T(43), kCMTimeZero);
    fx.link(v0, v0Sound);
    const ClipId p = putClip(fx, fx.v1, m1, T(42), T(2), kCMTimeZero);
    const ClipId pSound = putClip(fx, fx.a1, m1, T(43), T(1), T(1));
    fx.link(p, pSound);
    const ClipId q = putClip(fx, fx.v1, m2, T(44), T(30), kCMTimeZero);
    const ClipId qSound = putClip(fx, fx.a1, m2, T(45), T(29), T(1));
    fx.link(q, qSound);
    fx.requireValid();
    SetSequenceFormat command(fx.seq, formatWith(fx.sequence(), 1920, 1080, CMTimeMake(1, 25)));
    const EditResult result = applyReversible(fx.project, command);
    REQUIRE_MESSAGE(result.ok(), doctest::String(result.message.c_str()));
    INFO(joined(command.report().sentences));
    CHECK(fx.clip(p).timelineStart == f25(21));
    CHECK(fx.clip(p).timelineEnd() == f25(22));
    CHECK(fx.clip(pSound).timelineStart == f25(21));
    CHECK(fx.clip(pSound).timelineEnd() == f25(22));
    CHECK(fx.clip(pSound).sourceIn == kCMTimeZero);
    CHECK(fx.clip(v0Sound).timelineStart == kCMTimeZero);
    CHECK(fx.clip(v0Sound).timelineEnd() == f25(21));
    CHECK(fx.clip(q).timelineStart == f25(22));
    CHECK(fx.clip(q).sourceIn == kCMTimeZero);
    CHECK(fx.clip(qSound).timelineStart == f25(23)); // 45/50 s, 22.5 frames, rounds up
    CHECK(fx.clip(qSound).sourceIn == T(2));
    for (const auto &[picture, sound] : {std::pair{v0, v0Sound}, std::pair{p, pSound}, std::pair{q, qSound}}) {
        CHECK(inSync(fx.sequence(), picture, sound));
    }
    CHECK(onGrid(fx.sequence(), CMTimeMake(1, 25)));
}

TEST_CASE("SetSequenceFormat: a linked sound clip shorter than a frame with no frame under its picture is refused") {
    // The last pair at 59.94 fps: the picture [86, 89) from source frame 4 ends on its media's end; its sound,
    // one frame [88, 89) from source frame 6, ends with it. At 23.976 fps the end can only take frame 35
    // (picture media), where the sound (its start at frame 35 too) has no frame. Starting a frame earlier
    // would play none of its own sound (it would end before its old start), and ending at 36 would put it
    // wholly after its picture ([34, 35) and [35, 36): 7e2335b did this, pinned here as right until the
    // review of 2026-10-01). No conform keeps the sound under its picture playing its own sound: refused,
    // naming the sound and why; nothing changes.
    Fixture fx;
    const CMTime fd = CMTimeMake(1001, 60000);
    fx.sequence().frameDuration = fd;
    auto T = [&](std::int64_t frames) { return CMTimeMultiply(fd, static_cast<int32_t>(frames)); };
    const AssetId m = addMovie(fx, "m.mov", fd, T(7), T(8));
    const ClipId v = putClip(fx, fx.v1, m, T(86), T(3), T(4));
    const ClipId a = putClip(fx, fx.a1, m, T(88), T(1), T(6));
    fx.link(v, a);
    fx.requireValid();
    const Project before = fx.project;
    SetSequenceFormat command(fx.seq, formatWith(fx.sequence(), 1920, 1080, CMTimeMake(1001, 24000)));
    const EditResult result = command.apply(fx.project);
    CHECK(result.error == EditError::OutOfSourceRange);
    CHECK(result.message == "“m.mov” is shorter than a frame at 23.976 fps and has no room for one: it cannot start "
                            "earlier, and a frame from its start would start after the clip it is linked to ends; trim "
                            "or unlink them first.");
    CHECK(fx.project == before);
}

TEST_CASE("SetSequenceFormat: an end that comes back to the cut brings the cut it shares on another track with it") {
    // As in "a linked sound clip's end that rounded up on its own comes back to the cut" (60 -> 25 fps), but
    // the sound clip before b.mov's sound on A1 is linked to a picture on V2 whose end is a cut: that cut
    // (1.5 s, rounded up to 38/25 s with them) comes back to 37/25 s too when its next clip has media from
    // there, or the change is refused with the reason.
    for (const bool mediaBefore : {true, false}) {
        CAPTURE(mediaBefore);
        Fixture fx;
        fx.sequence().frameDuration = CMTimeMake(1, 60);
        auto T = [](std::int64_t frames) { return CMTimeMake(frames, 60); };
        const AssetId a = addMovie(fx, "a.mov", T(1), T(91), T(400));
        const AssetId b = addMovie(fx, "b.mov", T(1), T(60), T(400));
        const AssetId x = addMovie(fx, "x.mov", T(1), T(400), T(400));
        const AssetId z = addMovie(fx, "z.mov", T(1), T(400), T(400));
        putClip(fx, fx.v1, a, kCMTimeZero, T(91), kCMTimeZero);
        const ClipId bv = putClip(fx, fx.v1, b, T(91), T(60), kCMTimeZero);
        const ClipId ba = putClip(fx, fx.a1, b, T(91), T(60), kCMTimeZero);
        fx.link(bv, ba);
        const ClipId xv = putClip(fx, fx.v2, x, T(60), T(30), T(10));
        const ClipId xa = putClip(fx, fx.a1, x, T(60), T(30), T(10));
        fx.link(xv, xa);
        const ClipId zv = putClip(fx, fx.v2, z, T(90), T(60), mediaBefore ? T(10) : kCMTimeZero);
        fx.requireValid();
        const Project before = fx.project;
        SetSequenceFormat command(fx.seq, formatWith(fx.sequence(), 1920, 1080, CMTimeMake(1, 25)));
        if (mediaBefore) {
            const EditResult result = applyReversible(fx.project, command);
            REQUIRE_MESSAGE(result.ok(), doctest::String(result.message.c_str()));
            for (const ClipId id : {xv, xa}) {
                CHECK(fx.clip(id).timelineEnd() == f25(37));
            }
            CHECK(fx.clip(zv).timelineStart == f25(37));
            CHECK(fx.clip(ba).timelineStart == f25(37));
            CHECK(inSync(fx.sequence(), xv, xa));
            CHECK(inSync(fx.sequence(), bv, ba));
            CHECK(onGrid(fx.sequence(), CMTimeMake(1, 25)));
        } else {
            // z.mov from its media's start: its start went up to 38/25 s (no media before 1.5 s) and cannot
            // come back.
            const EditResult result = command.apply(fx.project);
            CHECK(result.error == EditError::Overlap);
            CHECK(result.message == "“x.mov” cannot end before the next clip on its track at 25 fps: “z.mov” starts "
                                    "where it ends and has no media to start earlier; trim one of them first.");
            CHECK(fx.project == before);
        }
    }
}

TEST_CASE("SetSequenceFormat: a clip that cannot keep a frame before the next clip's start is refused") {
    // The Overlap refusal: on A1 a sound clip of two 60 fps frames from its media's start (shorter than a
    // frame at 25 fps, no media before it) ends 1/60 s before b.mov's sound, whose start the cut between two
    // whole pictures takes to 37/25 s. Its end, rounded up to 38/25 s, cannot come back there and keep a frame
    // (its start cannot go back before its media). Refused with the reason; nothing changes.
    Fixture fx;
    fx.sequence().frameDuration = CMTimeMake(1, 60);
    const AssetId a = addMovie(fx, "a.mov", CMTimeMake(1, 60), CMTimeMake(91, 60), CMTimeMake(400, 60));
    const AssetId b = addMovie(fx, "b.mov", CMTimeMake(1, 60), CMTimeMake(60, 60), CMTimeMake(400, 60));
    MediaAsset sound = *fx.project.findAsset(fx.audioOnly);
    sound.name = "blip.m4a";
    const AssetId blip = fx.project.addAsset(sound);
    const ClipId av = putClip(fx, fx.v1, a, kCMTimeZero, CMTimeMake(91, 60), kCMTimeZero);
    putClip(fx, fx.a1, blip, CMTimeMake(88, 60), CMTimeMake(2, 60), kCMTimeZero);
    const ClipId bv = putClip(fx, fx.v1, b, CMTimeMake(91, 60), CMTimeMake(60, 60), kCMTimeZero);
    const ClipId ba = putClip(fx, fx.a1, b, CMTimeMake(91, 60), CMTimeMake(60, 60), kCMTimeZero);
    fx.link(bv, ba);
    (void)av;
    fx.requireValid();
    const Project before = fx.project;
    SetSequenceFormat command(fx.seq, formatWith(fx.sequence(), 1920, 1080, CMTimeMake(1, 25)));
    const EditResult result = command.apply(fx.project);
    CHECK(result.error == EditError::Overlap);
    CHECK(result.message == "“blip.m4a” is shorter than a frame at 25 fps and the next clip leaves no room for one; "
                            "trim or remove it first.");
    CHECK(fx.project == before);
}

TEST_CASE("SetSequenceFormat: property: random linked pairs conform touching, aligned, in sync and on the grid") {
    // Random sequences of linked picture/sound pairs (back to back or with gaps, sound aligned or starting a
    // few frames later, media with or without handles) between random standard rates. Every change that
    // succeeds keeps the cuts touching, the pairs in sync and every edge on the new grid; the only refusal
    // is a clip that truly has no media for a frame (no in-sync pair is refused as out of sync, and no
    // false "no room" Overlap). Before the fix round's R1/R2, pairs like these were refused as out of sync
    // or as having no room.
    std::uint64_t state = 12345;
    auto next = [&](std::uint64_t n) {
        state = state * 6364136223846793005ull + 1442695040888963407ull;
        return (state >> 33) % n;
    };
    const auto &rates = standardFrameDurations();
    int succeeded = 0;
    int refused = 0;
    for (int iteration = 0; iteration < 1500; ++iteration) {
        Fixture fx;
        const CMTime oldFd = rates[next(rates.size())];
        const CMTime newFd = rates[next(rates.size())];
        if (newFd == oldFd) {
            continue;
        }
        fx.sequence().frameDuration = oldFd;
        auto T = [&](std::int64_t frames) { return CMTimeMultiply(oldFd, static_cast<int32_t>(frames)); };
        std::int64_t at = 0;
        std::vector<std::pair<ClipId, ClipId>> pairs;
        const int count = 2 + static_cast<int>(next(4));
        for (int i = 0; i < count; ++i) {
            const std::int64_t length = 3 + static_cast<std::int64_t>(next(40));
            const std::int64_t head = next(2) ? 0 : static_cast<std::int64_t>(next(5));
            const std::int64_t tail = next(2) ? 0 : static_cast<std::int64_t>(next(5));
            const std::int64_t soundExtra = static_cast<std::int64_t>(next(3));
            const std::int64_t soundLater = next(3) == 0 ? std::min<std::int64_t>(static_cast<std::int64_t>(next(3)), length - 1) : 0;
            if (next(4) == 0) {
                at += 1 + static_cast<std::int64_t>(next(3));
            }
            const AssetId media = addMovie(fx, "m" + std::to_string(i) + ".mov", oldFd, T(head + length + tail),
                                           T(head + length + tail + soundExtra));
            const ClipId v = putClip(fx, fx.v1, media, T(at), T(length), T(head));
            const ClipId a = putClip(fx, fx.a1, media, T(at + soundLater), T(length - soundLater), T(head + soundLater));
            fx.link(v, a);
            pairs.emplace_back(v, a);
            at += length;
        }
        if (!problemOf(fx.project).empty()) {
            continue;
        }
        std::vector<std::pair<ClipId, ClipId>> cuts;
        for (const TrackId track : {fx.v1, fx.a1}) {
            const std::vector<Clip> &clips = fx.track(track).clips;
            for (std::size_t k = 0; k + 1 < clips.size(); ++k) {
                if (clips[k].timelineEnd() == clips[k + 1].timelineStart) {
                    cuts.emplace_back(clips[k].id, clips[k + 1].id);
                }
            }
        }
        Project copy = fx.project;
        SetSequenceFormat command(fx.seq, formatWith(fx.sequence(), 1920, 1080, newFd));
        const EditResult result = command.apply(copy);
        CAPTURE(iteration);
        if (!result.ok()) {
            ++refused;
            CHECK(result.message.find("has no media to fill one") != std::string::npos);
            // True only if a clip of the named media cannot hold one new frame anywhere in its media where it
            // lies (overlapping where it plays), without moving: no grid frame fits.
            bool explained = false;
            for (const TrackId track : {fx.v1, fx.a1}) {
                for (const Clip &clip : fx.track(track).clips) {
                    const MediaAsset &asset = *fx.project.findAsset(clip.assetId);
                    if (result.message.find("“" + asset.name + "”") != 0) {
                        continue;
                    }
                    const CMTime media = track == fx.v1 ? asset.videoDuration : asset.duration;
                    const CMTime from = clip.timelineStart - clip.sourceIn;
                    const CMTime to = from + media;
                    bool fits = false;
                    for (std::int64_t k = frameIndexAt(clip.timelineStart, newFd, SnapMode::Floor) - 1;
                         k <= frameIndexAt(clip.timelineEnd(), newFd, SnapMode::Ceil) + 1; ++k) {
                        const CMTime start = timeForFrame(k, newFd);
                        const CMTime end = timeForFrame(k + 1, newFd);
                        fits = fits || (from <= start && end <= to && start < clip.timelineEnd() &&
                                        clip.timelineStart < end);
                    }
                    explained = explained || !fits;
                }
            }
            CHECK_MESSAGE(explained, doctest::String(result.message.c_str()));
            continue;
        }
        ++succeeded;
        const Sequence &conformed = *copy.findSequence(fx.seq);
        CHECK(clipsTouch(conformed, cuts));
        for (const auto &[v, a] : pairs) {
            CHECK(inSync(conformed, v, a));
            // Each pair still plays together, each clip part of what it played.
            CHECK(overlapping(*conformed.findClip(v), *conformed.findClip(a)));
            for (const ClipId id : {v, a}) {
                CHECK(playsPartOf(fx.clip(id), *conformed.findClip(id)));
            }
        }
        CHECK(onGrid(conformed, newFd));
        CHECK(problemOf(copy).empty());
    }
    MESSAGE("conformed " << succeeded << ", refused " << refused);
    CHECK(succeeded > 1000);
    CHECK(refused < 30);
}

namespace {

// Random shots for the conform's property test of linked sound (the review of 2026-10-01's generators):
// pictures of one or two old frames or more, back to back or with gaps, from sources at the sequence's
// rate or another standard rate, whole or with handles of whole or partial source frames; each linked
// to sound that is aligned with it, starts or ends a few frames apart (J/L cuts), is slipped out of the
// picture's media time, comes from a separate recorder file in sync by its own offset (rolling before
// the camera), or is shorter than a frame (one old frame) at the head or tail of its picture. Times are
// in 1/240000 s, which every standard frame duration divides.
class ShotGenerator {
  public:
    explicit ShotGenerator(std::uint64_t seed) : state_(seed) {}

    // Adds the shots of one picture/sound track pair; with `subFrame`, every picture of two old frames or
    // more gets sound shorter than a frame.
    void addShots(Fixture &fx, std::vector<std::pair<ClipId, ClipId>> &pairs, TrackId pictureTrack,
                  TrackId soundTrack, CMTime oldFd, int firstName, bool subFrame) {
        const auto &rates = standardFrameDurations();
        const std::int64_t F = units(oldFd);
        std::int64_t at = percent(30) ? below(4) * F : 0; // the picture track's end so far
        std::int64_t soundEnd = 0;                        // the sound track's end so far
        const int count = 2 + static_cast<int>(below(4));
        for (int i = 0; i < count; ++i) {
            if (percent(20)) {
                at += (1 + below(3)) * F;
            }
            const std::int64_t frames = percent(15) ? 1 + below(2) : 2 + below(30);
            const std::int64_t length = frames * F;
            const auto rate = static_cast<std::size_t>(below(static_cast<std::int64_t>(rates.size())));
            const CMTime sourceFd = percent(70) ? oldFd : rates[rate];
            const std::int64_t SF = units(sourceFd);
            auto handle = [&] { return percent(55) ? 0 : (percent(50) ? below(4) * SF : below(4 * SF)); };
            const std::int64_t head = handle();
            const std::int64_t tail = handle();
            const std::int64_t media = head + length + tail;
            const int kind = static_cast<int>(below(100));
            auto offset = [&]() -> std::int64_t {
                const std::int64_t k = below(10);
                if (k < 5) {
                    return 0;
                }
                const std::int64_t frameOffset = k < 7 ? (below(5) - 2) * F : below(4 * F) - 2 * F;
                return (frameOffset / F) * F;
            };
            const std::int64_t startOffset = offset();
            const std::int64_t endOffset = offset();
            std::int64_t soundStart = std::max(at + startOffset, soundEnd);
            std::int64_t soundStop = at + length + endOffset;
            if ((kind >= 85 || subFrame) && frames >= 2) {
                if (percent(50)) {
                    soundStart = std::max(at, soundEnd);
                    soundStop = soundStart + F;
                } else {
                    soundStop = at + length;
                    soundStart = std::max(soundStop - F, soundEnd);
                }
            }
            if (soundStop <= soundStart) {
                soundStop = soundStart + F;
            }
            const std::int64_t extra = below(3) * SF;
            const std::int64_t soundMedia = media + extra + (percent(30) ? below(SF) : 0);
            const std::string number = std::to_string(firstName + i);
            const AssetId movie = addMovie(fx, "m" + number + ".mov", sourceFd, at240k(media), at240k(soundMedia));
            const ClipId picture = putClip(fx, pictureTrack, movie, at240k(at), at240k(length), at240k(head));
            const std::int64_t pictureStart = at;
            at += length;
            if (kind >= 95) {
                continue; // no sound
            }
            std::optional<ClipId> sound;
            if (kind < 25) {
                // A recorder's file, in sync by its own offset: its media's start plays at `zero`.
                const std::int64_t roll = below(3 * F);
                const std::int64_t zero = pictureStart - roll - (percent(50) ? below(F) : 0);
                std::int64_t in = soundStart - zero;
                if (in < 0) {
                    soundStart = std::max(zero <= 0 ? 0 : (zero + F - 1) / F * F, soundEnd);
                    in = soundStart - zero;
                }
                const std::int64_t untilStop = soundStop - zero;
                const std::int64_t recorded = percent(40) ? untilStop : untilStop + below(3 * F);
                MediaAsset recorder = *fx.project.findAsset(fx.audioOnly);
                recorder.name = "rec" + number + ".wav";
                recorder.url = "file:///media/" + recorder.name;
                recorder.duration = at240k(recorded);
                const AssetId file = fx.project.addAsset(recorder);
                if (soundStop > soundStart) {
                    sound = putClip(fx, soundTrack, file, at240k(soundStart), at240k(soundStop - soundStart),
                                    at240k(in));
                }
            } else {
                std::int64_t in = head + (soundStart - pictureStart);
                if (kind < 40) {
                    const int sign = percent(50) ? 1 : -1;
                    in += sign * (percent(50) ? F : 1 + below(F - 1)); // slipped
                }
                if (in < 0) {
                    const std::int64_t up = (-in + F - 1) / F * F;
                    soundStart += up;
                    in += up;
                }
                if (in + (soundStop - soundStart) > soundMedia) {
                    soundStop = soundStart + (soundMedia - in) / F * F;
                }
                if (soundStop > soundStart) {
                    sound = putClip(fx, soundTrack, movie, at240k(soundStart), at240k(soundStop - soundStart),
                                    at240k(in));
                }
            }
            if (sound) {
                fx.link(picture, *sound);
                pairs.emplace_back(picture, *sound);
                soundEnd = soundStop;
            }
        }
    }

  private:
    static std::int64_t units(CMTime frameDuration) {
        return frameDuration.value * (240000 / frameDuration.timescale);
    }
    static CMTime at240k(std::int64_t value) {
        return CMTimeMake(value, 240000);
    }
    std::int64_t below(std::int64_t n) {
        state_ = state_ * 6364136223846793005ull + 1442695040888963407ull;
        return n <= 0 ? 0 : static_cast<std::int64_t>((state_ >> 33) % static_cast<std::uint64_t>(n));
    }
    bool percent(int p) {
        return below(100) < p;
    }

    std::uint64_t state_;
};

} // namespace

TEST_CASE("SetSequenceFormat: property: dual-system, slipped and sub-frame linked sound stays with its picture") {
    // The review of 2026-10-01: a linked sound clip shorter than a frame whose end went apart from its
    // picture's (7e2335b, R2) played wholly after it, none of its own sound. On random shots (see
    // ShotGenerator) between every pair of standard rates, half with sound shorter than a frame on every
    // picture, every change that succeeds keeps the cuts touching, the pairs in sync, every edge on the
    // grid and the project valid; a pair that started or ended together still overlaps; and a clip whose
    // shared edge went apart from its partner's still overlaps it and plays part of what it played. A
    // refusal names a clip and changes nothing. Pairs that shared no edge are conformed edge by edge and
    // are not held to overlapping (an overlap under about a frame can round away), and a clip shorter than
    // a frame whose start the grid trims is not held to keeping what it played: both are older rules.
    const auto &rates = standardFrameDurations();
    int succeeded = 0;
    int refused = 0;
    for (const bool subFrame : {false, true}) {
        for (std::size_t from = 0; from < rates.size(); ++from) {
            for (std::size_t to = 0; to < rates.size(); ++to) {
                if (from == to) {
                    continue;
                }
                for (int iteration = 0; iteration < 15; ++iteration) {
                    const std::uint64_t seed = (subFrame ? 7777ull : 1ull) * 1000003ull + (from * 8 + to) * 7919ull +
                                               static_cast<std::uint64_t>(iteration) * 104729ull;
                    ShotGenerator generator(seed);
                    Fixture fx;
                    const CMTime oldFd = rates[from];
                    const CMTime newFd = rates[to];
                    fx.sequence().frameDuration = oldFd;
                    std::vector<std::pair<ClipId, ClipId>> pairs;
                    generator.addShots(fx, pairs, fx.v1, fx.a1, oldFd, 0, subFrame);
                    if (seed % 3 == 0) {
                        generator.addShots(fx, pairs, fx.v2, fx.a2, oldFd, 100, subFrame);
                    }
                    if (!problemOf(fx.project).empty()) {
                        continue;
                    }
                    CAPTURE(subFrame);
                    CAPTURE(from);
                    CAPTURE(to);
                    CAPTURE(iteration);
                    std::vector<std::pair<ClipId, ClipId>> cuts;
                    for (const TrackId track : {fx.v1, fx.a1, fx.v2, fx.a2}) {
                        const std::vector<Clip> &clips = fx.track(track).clips;
                        for (std::size_t k = 0; k + 1 < clips.size(); ++k) {
                            if (clips[k].timelineEnd() == clips[k + 1].timelineStart) {
                                cuts.emplace_back(clips[k].id, clips[k + 1].id);
                            }
                        }
                    }
                    Project copy = fx.project;
                    SetSequenceFormat command(fx.seq, formatWith(fx.sequence(), 1920, 1080, newFd));
                    const EditResult result = command.apply(copy);
                    if (!result.ok()) {
                        ++refused;
                        CHECK(result.message.find("“") == 0);
                        CHECK(copy == fx.project);
                        continue;
                    }
                    ++succeeded;
                    const Sequence &conformed = *copy.findSequence(fx.seq);
                    CHECK(clipsTouch(conformed, cuts));
                    CHECK(onGrid(conformed, newFd));
                    CHECK(problemOf(copy).empty());
                    for (const auto &[v, a] : pairs) {
                        const Clip &picture = fx.clip(v);
                        const Clip &sound = fx.clip(a);
                        const Clip &newPicture = *conformed.findClip(v);
                        const Clip &newSound = *conformed.findClip(a);
                        // In sync: both moved against their media by the same amount.
                        const CMTime pictureMove = (newPicture.timelineStart - newPicture.sourceIn) -
                                                   (picture.timelineStart - picture.sourceIn);
                        const CMTime soundMove =
                            (newSound.timelineStart - newSound.sourceIn) - (sound.timelineStart - sound.sourceIn);
                        CHECK(pictureMove == soundMove);
                        if (shareAnEdge(picture, sound)) {
                            CHECK_MESSAGE(overlapping(newPicture, newSound),
                                          "the pair " << v.value() << "/" << a.value() << " no longer plays together");
                        }
                        const bool startApart = picture.timelineStart == sound.timelineStart &&
                                                !(newPicture.timelineStart == newSound.timelineStart);
                        const bool endApart = picture.timelineEnd() == sound.timelineEnd() &&
                                              !(newPicture.timelineEnd() == newSound.timelineEnd());
                        if (startApart || endApart) {
                            CHECK(overlapping(newPicture, newSound));
                            CHECK_MESSAGE(playsPartOf(picture, newPicture), "clip " << v.value());
                            CHECK_MESSAGE(playsPartOf(sound, newSound), "clip " << a.value());
                        }
                    }
                }
            }
        }
    }
    MESSAGE("conformed " << succeeded << ", refused " << refused);
    CHECK(succeeded > 900);
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
    CHECK(fx.transition(dissolve) == nullptr);
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
