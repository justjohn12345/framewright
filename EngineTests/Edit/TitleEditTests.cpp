// Edits of titles and colour mattes (TitleEdits.h; titles design sections 9 and 10; slice 1, item 8): setting
// parameters on a selection (the others kept, refusals, no step for no change, what a newer version wrote kept,
// coalescing keys and names), the "Mixed" summary, the placement rule of a new title (above the target on the
// lowest free track, else a new track, nothing overwritten), placing a generated clip by its content with Insert and
// Overwrite, and the grade's rules (titles and mattes are never graded). Every successful edit undoes and redoes
// exactly (applyReversible).

#include "../../Engine/Edit/EditOps.h"
#include "../../Engine/Edit/GradeEdits.h"
#include "../../Engine/Edit/TitleEdits.h"
#include "../Model/ModelFixtures.h"

using namespace vetest;

namespace {

struct TitleRig : Fixture {
    AssetId titles = project.addAsset(makeGeneratorAsset(GeneratorKind::Title));
    AssetId mattes = project.addAsset(makeGeneratorAsset(GeneratorKind::ColourMatte));

    ClipId addGenerated(TrackId track, AssetId asset, std::shared_ptr<const GeneratedContent> content,
                        std::int64_t start, std::int64_t frames) {
        const ClipId id = addClip(track, asset, start, frames);
        sequence().findClip(id)->generated = std::move(content);
        return id;
    }
    ClipId addTitle(TrackId track, const char *text, std::int64_t start, std::int64_t frames) {
        TitleContent content;
        content.text = text;
        return addGenerated(track, titles, GeneratedContent::makeTitle(content), start, frames);
    }
    const TitleContent &titleOf(ClipId id) const {
        return clip(id).generated->title();
    }
    TrackId addVideoTrack(const char *name) {
        Track track;
        track.id = project.ids.make<TrackId>();
        track.kind = TrackKind::Video;
        track.name = name;
        sequence().videoTracks.push_back(track);
        return track.id;
    }
};

} // namespace

TEST_CASE("Title edits: a parameter set on several titles keeps what differs between them") {
    TitleRig fx;
    const ClipId a = fx.addTitle(fx.v2, "First", 0, 60);
    const ClipId b = fx.addTitle(fx.v2, "Second", 60, 60);
    SetGeneratedContent size(fx.seq, {a, b}, TitleChange::of(TitleParameter::Size, 0.1));
    applyReversible(fx.project, size);
    CHECK(fx.titleOf(a).size == 0.1);
    CHECK(fx.titleOf(b).size == 0.1);
    CHECK(fx.titleOf(a).text == "First");
    CHECK(fx.titleOf(b).text == "Second");
    CHECK(size.name() == "Change Size");
    SetGeneratedContent text(fx.seq, {a}, TitleChange::of(TitleParameter::Text, std::string("First, edited")));
    applyReversible(fx.project, text);
    CHECK(fx.titleOf(a).text == "First, edited");
    CHECK(text.name() == "Edit Title Text");
    // The content id follows the text; the position does not change it.
    const ContentId before = fx.clip(a).generated->contentId();
    TitleChange move;
    move[TitleParameter::PositionX] = 0.25;
    move[TitleParameter::PositionY] = 0.75;
    SetGeneratedContent moved(fx.seq, {a}, move, "Move Title");
    applyReversible(fx.project, moved);
    CHECK(fx.clip(a).generated->contentId() == before);
    CHECK(fx.titleOf(a).x == 0.25);
    CHECK(moved.name() == "Move Title");
    // Every kind of value.
    TitleChange many;
    many[TitleParameter::Font] = TitleFont::named("Helvetica-Bold", "Helvetica", "Bold");
    many[TitleParameter::FillColour] = SRGBColour{1, 0, 0};
    many[TitleParameter::Alignment] = TitleAlignment::Right;
    many[TitleParameter::Box] = true;
    SetGeneratedContent several(fx.seq, {a, b}, many);
    applyReversible(fx.project, several);
    CHECK(fx.titleOf(b).font.postScriptName == "Helvetica-Bold");
    CHECK(fx.titleOf(b).fillColour == SRGBColour{1, 0, 0});
    CHECK(fx.titleOf(b).alignment == TitleAlignment::Right);
    CHECK(fx.titleOf(b).box);
    CHECK(several.name() == "Change Title");
}

TEST_CASE("Title edits: each clip's own change, as one step (slice 2)") {
    TitleRig fx;
    const ClipId a = fx.addTitle(fx.v2, "First", 0, 60);
    const ClipId b = fx.addTitle(fx.v2, "Second", 60, 60);
    TitleChange toA = TitleChange::of(TitleParameter::PointText, true);
    toA[TitleParameter::PositionX] = 0.1;
    TitleChange toB = TitleChange::of(TitleParameter::PointText, true);
    toB[TitleParameter::PositionX] = 0.9;
    SetGeneratedContent both(fx.seq, std::vector<std::pair<ClipId, TitleChange>>{{a, toA}, {b, toB}});
    applyReversible(fx.project, both);
    CHECK(fx.titleOf(a).pointText);
    CHECK(fx.titleOf(b).pointText);
    CHECK(fx.titleOf(a).x == 0.1);
    CHECK(fx.titleOf(b).x == 0.9);
    CHECK(both.name() == "Change Title"); // two parameters (the facade names it after the one asked for)
    SetGeneratedContent anchor(fx.seq, std::vector<std::pair<ClipId, TitleChange>>{
                                           {a, TitleChange::of(TitleParameter::Anchor, TitleAnchor::Top)}});
    applyReversible(fx.project, anchor);
    CHECK(anchor.name() == "Change Vertical Anchor");
    CHECK(fx.titleOf(a).anchor == TitleAnchor::Top);
    // Refused as a whole when one clip's change is not valid.
    const Project before = fx.project;
    SetGeneratedContent bad(fx.seq, std::vector<std::pair<ClipId, TitleChange>>{
                                        {a, TitleChange::of(TitleParameter::Size, 0.2)},
                                        {b, TitleChange::of(TitleParameter::Anchor, static_cast<TitleAnchor>(5))}});
    CHECK(bad.apply(fx.project).error == EditError::InvalidArgument);
    CHECK(fx.project == before);
}

TEST_CASE("Title edits: a style is every parameter but the text and where it is") {
    TitleContent styled = titlePreset(GeneratedPreset::LowerThird);
    styled.font = TitleFont::named("Helvetica-Bold", "Helvetica", "Bold");
    styled.tracking = 40;
    styled.pointText = true;
    styled.anchor = TitleAnchor::Bottom;
    const TitleChange style = TitleChange::style(styled);
    for (const TitleParameter parameter : kTitleParameters) {
        CAPTURE(nameOf(parameter));
        const bool where = parameter == TitleParameter::Text || parameter == TitleParameter::PositionX ||
                           parameter == TitleParameter::PositionY || parameter == TitleParameter::BoxWidth ||
                           parameter == TitleParameter::PointText || parameter == TitleParameter::Anchor;
        CHECK(isStyleParameter(parameter) == !where);
        CHECK(style[parameter].has_value() == !where);
        if (!where) {
            CHECK(*style[parameter] == valueOf(styled, parameter));
        }
    }
    // Pasted: the style comes, the text, place, width, point text and anchor stay.
    TitleRig fx;
    const ClipId target = fx.addTitle(fx.v2, "Target", 0, 60);
    SetGeneratedContent paste(fx.seq, {target}, style, "Paste Style");
    applyReversible(fx.project, paste);
    const TitleContent &pasted = fx.titleOf(target);
    CHECK(pasted.font == styled.font);
    CHECK(pasted.box);
    CHECK(pasted.alignment == TitleAlignment::Left);
    CHECK(pasted.text == "Target");
    CHECK(pasted.x == 0.5);
    CHECK(pasted.width == 0.8);
    CHECK_FALSE(pasted.pointText);
    CHECK(pasted.anchor == TitleAnchor::Centre);
}

TEST_CASE("Title edits: refusals change nothing") {
    TitleRig fx;
    const ClipId title = fx.addTitle(fx.v2, "Title", 0, 30);
    const ClipId matte = fx.addGenerated(fx.v1, fx.mattes, GeneratedContent::makeMatte(kBlack), 0, 30);
    const ClipId video = fx.addClip(fx.v1, fx.av30, 60, 30);
    const Project before = fx.project;
    auto refused = [&](std::vector<ClipId> clips, TitleChange change) {
        SetGeneratedContent command(fx.seq, std::move(clips), std::move(change));
        const EditResult result = command.apply(fx.project);
        CHECK(fx.project == before);
        return result;
    };
    CHECK(refused({video}, TitleChange::of(TitleParameter::Size, 0.1)).message == "Clip " +
                                                                                      std::to_string(video.value()) +
                                                                                      " is not a title.");
    CHECK(refused({matte}, TitleChange::of(TitleParameter::Size, 0.1)).error == EditError::InvalidArgument);
    CHECK(refused({title}, TitleChange::matte(kWhite)).message ==
          "Clip " + std::to_string(title.value()) + " is not a colour matte.");
    CHECK(refused({title}, TitleChange::of(TitleParameter::Size, 3.0)).message ==
          "The title's Size must be a number from 0.005 to 1 (not 3).");
    CHECK(refused({title}, TitleChange::of(TitleParameter::Size, true)).error == EditError::InvalidArgument);
    CHECK(refused({title}, TitleChange{}).message == "No title values to set.");
    CHECK(refused({}, TitleChange::of(TitleParameter::Size, 0.1)).message == "No titles to change.");
    CHECK(refused({title, title}, TitleChange::of(TitleParameter::Size, 0.1)).message ==
          "Clip " + std::to_string(title.value()) + " is listed twice.");
    CHECK(refused({ClipId{999}}, TitleChange::of(TitleParameter::Size, 0.1)).error == EditError::ClipNotFound);
    fx.track(fx.v2).locked = true;
    const Project locked = fx.project;
    SetGeneratedContent onLocked(fx.seq, {title}, TitleChange::of(TitleParameter::Size, 0.1));
    CHECK(onLocked.apply(fx.project).error == EditError::TrackLocked);
    CHECK(fx.project == locked);
}

TEST_CASE("Title edits: no change is no undo step, and a newer version's keys stay") {
    TitleRig fx;
    TitleContent content;
    const ClipId title = fx.addGenerated(fx.v2, fx.titles, GeneratedContent::makeTitle(content, "{\"glow\":1}"), 0, 30);
    SetGeneratedContent same(fx.seq, {title}, TitleChange::of(TitleParameter::Size, content.size));
    REQUIRE(same.apply(fx.project).ok());
    CHECK(same.isNoOp());
    SetGeneratedContent changed(fx.seq, {title}, TitleChange::of(TitleParameter::Size, 0.2));
    applyReversible(fx.project, changed);
    CHECK(fx.clip(title).generated->foreign() == "{\"glow\":1}");
    // The matte's colour, likewise.
    const ClipId matte = fx.addGenerated(fx.v1, fx.mattes, GeneratedContent::makeMatte(kBlack, "{\"x\":2}"), 0, 30);
    SetGeneratedContent colour(fx.seq, {matte}, TitleChange::matte(SRGBColour{0.5, 0.5, 0.5}));
    applyReversible(fx.project, colour);
    CHECK(fx.clip(matte).generated->matteColour() == SRGBColour{0.5, 0.5, 0.5});
    CHECK(fx.clip(matte).generated->foreign() == "{\"x\":2}");
    CHECK(colour.name() == "Change Matte Colour");
}

TEST_CASE("Title edits: a drag's steps share a coalescing key; other parameters or clips do not") {
    TitleRig fx;
    const ClipId a = fx.addTitle(fx.v2, "A", 0, 30);
    const ClipId b = fx.addTitle(fx.v2, "B", 30, 30);
    const SetGeneratedContent one(fx.seq, {a}, TitleChange::of(TitleParameter::Size, 0.1));
    const SetGeneratedContent two(fx.seq, {a}, TitleChange::of(TitleParameter::Size, 0.2));
    const SetGeneratedContent other(fx.seq, {a}, TitleChange::of(TitleParameter::Tracking, 10.0));
    const SetGeneratedContent both(fx.seq, {a, b}, TitleChange::of(TitleParameter::Size, 0.1));
    CHECK(one.coalescingKey() == two.coalescingKey());
    CHECK(one.coalescingKey() != other.coalescingKey());
    CHECK(one.coalescingKey() != both.coalescingKey());
}

TEST_CASE("Title edits: the summary says what titles agree on and where they differ") {
    TitleRig fx;
    const ClipId a = fx.addTitle(fx.v2, "Same", 0, 30);
    const ClipId b = fx.addTitle(fx.v2, "Same", 30, 30);
    const ClipId video = fx.addClip(fx.v1, fx.av30, 0, 30);
    SetGeneratedContent size(fx.seq, {b}, TitleChange::of(TitleParameter::Size, 0.2));
    REQUIRE(size.apply(fx.project).ok());
    const ClipId m1 = fx.addGenerated(fx.v1, fx.mattes, GeneratedContent::makeMatte(kBlack), 40, 10);
    const ClipId m2 = fx.addGenerated(fx.v1, fx.mattes, GeneratedContent::makeMatte(kWhite), 60, 10);
    const TitleSummary summary = summarizeTitles(fx.sequence(), {a, video, b, a, m1, ClipId{999}});
    CHECK(summary.titles == std::vector<ClipId>{a, b});
    CHECK(summary.mattes == std::vector<ClipId>{m1});
    CHECK(summary.valueOf(TitleParameter::Text) == TitleValue(std::string("Same")));
    CHECK_FALSE(summary.isMixed(TitleParameter::Text));
    CHECK_FALSE(summary.valueOf(TitleParameter::Size).has_value());
    CHECK(summary.isMixed(TitleParameter::Size));
    CHECK(summary.matteColour == kBlack);
    CHECK_FALSE(summary.matteColourMixed);
    const TitleSummary mattes = summarizeTitles(fx.sequence(), {m1, m2});
    CHECK(mattes.matteColourMixed);
    CHECK_FALSE(mattes.matteColour.has_value());
    CHECK(summarizeTitles(fx.sequence(), {video}).titles.empty());
}

TEST_CASE("Title edits: a title card stacks its matte above the target and its title above the matte (slice 2)") {
    TitleRig fx;
    fx.addClip(fx.v1, fx.av30, 0, 300);
    const std::vector<std::shared_ptr<const GeneratedContent>> layers = presetLayers(GeneratedPreset::TitleCard);
    REQUIRE(layers.size() == 2);
    CHECK(layers[0]->isMatte());
    CHECK(layers[0]->matteColour() == kBlack);
    CHECK(layers[1]->isTitle());
    CHECK(layers[1]->title().font == TitleFont::system(SystemFontWeight::Bold));
    CHECK(presetLayers(GeneratedPreset::Caption).size() == 1);
    AddGeneratedClip card(fx.seq, f30(30), fx.v1, layers, defaultStillDuration(), "Add Title Card");
    applyReversible(fx.project, card);
    REQUIRE(card.createdClipIds().size() == 2);
    const ClipId matte = card.createdClipIds()[0];
    const ClipId title = card.createdClipIds()[1];
    CHECK(card.createdClipId() == title);
    CHECK(fx.clip(matte).trackId == fx.v2); // the lowest free track above V1
    CHECK(fx.clip(matte).generated->isMatte());
    CHECK(fx.clip(title).generated->isTitle());
    CHECK(card.addedTrack()); // V2 is the top track: the title gets a new V3
    CHECK(fx.clip(title).trackId == fx.sequence().videoTracks[2].id);
    CHECK(fx.clip(title).timelineStart == fx.clip(matte).timelineStart);
    CHECK(fx.clip(title).timelineDuration == fx.clip(matte).timelineDuration);
    CHECK(card.name() == "Add Title Card");
    fx.requireValid();
    // A caption: point text at the top left of title-safe, anchored at its top.
    const TitleContent caption = titlePreset(GeneratedPreset::Caption);
    CHECK(caption.pointText);
    CHECK(caption.anchor == TitleAnchor::Top);
    CHECK(caption.alignment == TitleAlignment::Left);
    CHECK(caption.x > 0.05);
    CHECK(caption.y > 0.05);
    CHECK(caption.x < 0.07);
    CHECK_FALSE(titleContentProblem(caption).has_value());
    CHECK(std::string(displayNameOf(GeneratedPreset::TitleCard)) == "Title Card");
    CHECK(std::string(displayNameOf(GeneratedPreset::Caption)) == "Caption");
}

TEST_CASE("Title edits: a new title goes on the lowest free track above the target") {
    TitleRig fx;
    fx.addClip(fx.v1, fx.av30, 0, 300); // the footage on V1
    auto add = [&](TrackId above, std::int64_t at) {
        AddGeneratedClip command(fx.seq, f30(at), above, GeneratedContent::makePreset(GeneratedPreset::Title));
        applyReversible(fx.project, command);
        return std::make_tuple(command.createdClipId(), command.placedTrackId(), command.addedTrack());
    };
    // Over V1's footage: on V2, 5 s long, at the playhead.
    const auto [first, firstTrack, firstAdded] = add(fx.v1, 30);
    CHECK(firstTrack == fx.v2);
    CHECK_FALSE(firstAdded);
    CHECK(fx.clip(first).timelineStart == f30(30));
    CHECK(fx.clip(first).timelineDuration == CMTimeMake(5, 1));
    CHECK(fx.clip(first).isStill);
    CHECK(fx.clip(first).assetId == fx.titles);
    CHECK(fx.clip(first).generated->isTitle());
    // V2 is taken there: a new track on top (V3), in the same edit; V1 and V2 untouched.
    const auto [second, secondTrack, secondAdded] = add(fx.v1, 60);
    CHECK(secondAdded);
    CHECK(fx.sequence().videoTracks.size() == 3);
    CHECK(fx.sequence().videoTracks[2].id == secondTrack);
    CHECK(fx.sequence().videoTracks[2].name == "V3");
    CHECK(fx.track(fx.v2).clips.size() == 1);
    // Later, where V2 is free again: back on V2 (the lowest free one).
    const auto [third, thirdTrack, thirdAdded] = add(fx.v1, 300);
    CHECK(thirdTrack == fx.v2);
    CHECK_FALSE(thirdAdded);
    // Above V2: the next free track (V3 is free at 400).
    const auto [fourth, fourthTrack, fourthAdded] = add(fx.v2, 400);
    CHECK(fourthTrack == secondTrack);
    // A locked track is passed over.
    fx.track(fx.v2).locked = true;
    const auto [fifth, fifthTrack, fifthAdded] = add(fx.v1, 600);
    CHECK(fifthTrack == secondTrack);
    // No target: from the bottom track up; V1 is free at 1000 (the footage ends at 300).
    fx.track(fx.v2).locked = false;
    const auto [sixth, sixthTrack, sixthAdded] = add(TrackId{}, 1000);
    CHECK(sixthTrack == fx.v1);
    // A hidden track (muted video) is passed over: the title would not show there.
    fx.track(fx.v2).muted = true;
    const auto [seventh, seventhTrack, seventhAdded] = add(fx.v1, 2000);
    CHECK(seventhTrack == secondTrack);
    fx.requireValid();
}

TEST_CASE("Title edits: what a new title refuses") {
    TitleRig fx;
    const Project before = fx.project;
    auto refusal = [&](CMTime at, TrackId above, std::shared_ptr<const GeneratedContent> content) {
        AddGeneratedClip command(fx.seq, at, above, std::move(content));
        const EditResult result = command.apply(fx.project);
        CHECK(fx.project == before);
        return result;
    };
    const auto title = GeneratedContent::makePreset(GeneratedPreset::Title);
    CHECK(refusal(f30(-5), fx.v1, title).error == EditError::InvalidTime);
    CHECK(refusal(kCMTimeInvalid, fx.v1, title).error == EditError::InvalidTime);
    CHECK(refusal(f30(0), fx.a1, title).error == EditError::TrackKindMismatch);
    CHECK(refusal(f30(0), TrackId{4242}, title).error == EditError::TrackNotFound);
    CHECK(refusal(f30(0), fx.v1, nullptr).error == EditError::InvalidArgument);
    TitleContent invalid;
    invalid.size = 7;
    CHECK(refusal(f30(0), fx.v1, GeneratedContent::makeTitle(invalid)).error == EditError::InvalidArgument);
    // Without the project's generator asset (the facade adds it in the same step).
    Fixture bare;
    AddGeneratedClip noAsset(bare.seq, f30(0), bare.v1, title);
    CHECK(noAsset.apply(bare.project).error == EditError::AssetNotFound);
    // The matte and the lower third take their kind's asset.
    AddGeneratedClip matte(fx.seq, f30(7), fx.v1, GeneratedContent::makePreset(GeneratedPreset::ColourMatte));
    applyReversible(fx.project, matte);
    CHECK(fx.clip(matte.createdClipId()).assetId == fx.mattes);
    CHECK(fx.clip(matte.createdClipId()).timelineStart == f30(7));
    CHECK(matte.name() == "Add Colour Matte");
}

TEST_CASE("Title edits: a dropped title is placed by its content, overwriting or inserting") {
    TitleRig fx;
    const ClipId footage = fx.addClip(fx.v2, fx.av30, 0, 90);
    ClipPlacement placement;
    placement.trackId = fx.v2;
    placement.generated = GeneratedContent::makePreset(GeneratedPreset::LowerThird);
    placement.sourceOut = CMTimeMake(1, 1);
    OverwriteClip overwrite(fx.seq, f30(30), {placement}, false);
    applyReversible(fx.project, overwrite);
    REQUIRE(overwrite.createdClipIds().size() == 1);
    const Clip &placed = fx.clip(overwrite.createdClipIds()[0]);
    CHECK(placed.assetId == fx.titles);
    CHECK(placed.generated->title().text == "Name\nRole");
    CHECK(placed.timelineDuration == CMTimeMake(1, 1));
    CHECK(fx.clip(footage).timelineDuration == f30(30)); // cut where the title lands
    InsertClip insert(fx.seq, f30(0), {placement}, false);
    applyReversible(fx.project, insert);
    CHECK(fx.clip(footage).timelineStart == f30(30)); // rippled by the inserted second
    // Content on a clip of media, or none for a generator asset, is refused.
    ClipPlacement mixed = placement;
    mixed.assetId = fx.av30;
    OverwriteClip wrong(fx.seq, f30(200), {mixed}, false);
    CHECK(wrong.apply(fx.project).error == EditError::InvalidArgument);
    ClipPlacement empty;
    empty.trackId = fx.v2;
    empty.assetId = fx.titles;
    OverwriteClip none(fx.seq, f30(200), {empty}, false);
    CHECK(none.apply(fx.project).error == EditError::InvalidArgument);
    // A title on an audio track: the asset does not fit it.
    ClipPlacement onAudio = placement;
    onAudio.trackId = fx.a1;
    OverwriteClip audio(fx.seq, f30(200), {onAudio}, false);
    CHECK(audio.apply(fx.project).error == EditError::TrackKindMismatch);
}

TEST_CASE("Title edits: titles and mattes are not graded") {
    TitleRig fx;
    const ClipId title = fx.addTitle(fx.v2, "Title", 0, 30);
    const ClipId matte = fx.addGenerated(fx.v1, fx.mattes, GeneratedContent::makeMatte(kBlack), 0, 30);
    const ClipId video = fx.addClip(fx.v1, fx.av30, 30, 30);
    CHECK(gradeTargets(fx.sequence(), {title, video, matte}) == std::vector<ClipId>{video});
    CHECK(summarizeGrades(fx.sequence(), {title, matte}).clips.empty());
    const Project before = fx.project;
    SetClipGrade grade(fx.seq, {title}, GradeChange::of(GradeParameter::Exposure, 1.0));
    const EditResult refused = grade.apply(fx.project);
    CHECK(refused.error == EditError::InvalidArgument);
    CHECK(refused.message == "Clip " + std::to_string(title.value()) + " is a Title: titles and colour mattes are not graded.");
    CHECK(fx.project == before);
}

TEST_CASE("Title edits: sentences name a title by its first line") {
    TitleRig fx;
    const ClipId title = fx.addTitle(fx.v2, "\nOpening Card\nsubtitle", 0, 60);
    const ClipId matte = fx.addGenerated(fx.v1, fx.mattes, GeneratedContent::makeMatte(kBlack), 0, 60);
    const ClipId empty = fx.addTitle(fx.v2, " ", 100, 30);
    const ClipId video = fx.addClip(fx.v1, fx.av30, 60, 30);
    CHECK(fx.project.clipName(fx.clip(title)) == "Opening Card");
    CHECK(fx.project.clipName(fx.clip(matte)) == "Colour Matte");
    CHECK(fx.project.clipName(fx.clip(empty)) == "Title");
    CHECK(fx.project.clipName(fx.clip(video)) == "av30.mov");
    // A refusal that names the clip (Continue on Next Clip with nothing after it).
    SpanTracks move;
    move[SpanParameter::X] = {key(kCMTimeZero, 0), key(f30(30), 100)};
    const SpanId span = fx.addSpan(title, SpanKind::Motion, 1, kCMTimeZero, f30(30), move);
    ContinueMotionPlan plan;
    const EditResult refused = planContinueMotion(fx.project, fx.sequence(), span, plan);
    CHECK(refused.error == EditError::NotAdjacent);
    CHECK(refused.message == "No clip touches the end of “Opening Card”, so there is nothing to continue the move on.");
}
