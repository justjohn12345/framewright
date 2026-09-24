#include "../../Engine/Edit/UndoStack.h"
#include "EditTestSupport.h"

using namespace vetest;

namespace {

std::unique_ptr<Command> moveTo(const Fixture &fx, ClipId clip, TrackId track, std::int64_t frame) {
    return std::make_unique<MoveClip>(fx.seq, clip, track, f30(frame));
}

} // namespace

TEST_CASE("UndoStack: push, undo and redo restore each state exactly") {
    Fixture fx;
    const ClipId c = fx.addClip(fx.v1, fx.av30, 0, 30);
    UndoStack stack;
    const Project s0 = fx.project;
    CHECK_FALSE(stack.canUndo());
    CHECK_FALSE(stack.undo(fx.project));

    REQUIRE(stack.push(fx.project, moveTo(fx, c, fx.v1, 10)).ok());
    const Project s1 = fx.project;
    REQUIRE(stack.push(fx.project, std::make_unique<SplitClip>(fx.seq, c, f30(20))).ok());
    const Project s2 = fx.project;
    CHECK(stack.undoCount() == 2);
    CHECK(stack.undoName() == "Split Clip");

    CHECK(stack.undo(fx.project));
    CHECK(fx.project == s1);
    CHECK(stack.redoName() == "Split Clip");
    CHECK(stack.undo(fx.project));
    CHECK(fx.project == s0);
    CHECK(toJsonString(fx.project) == toJsonString(s0));
    CHECK_FALSE(stack.undo(fx.project));
    CHECK(stack.redo(fx.project));
    CHECK(stack.redo(fx.project));
    CHECK(fx.project == s2);
    CHECK_FALSE(stack.redo(fx.project));
}

TEST_CASE("UndoStack: refused commands are not recorded; pushing discards the redo branch") {
    Fixture fx;
    const ClipId c = fx.addClip(fx.v1, fx.av30, 0, 30);
    UndoStack stack;
    const std::uint64_t version = stack.changeCount();
    const EditResult refused = stack.push(fx.project, moveTo(fx, c, fx.a1, 10));
    CHECK(refused.error == EditError::TrackKindMismatch);
    CHECK(stack.undoCount() == 0);
    CHECK(stack.changeCount() == version);
    CHECK(stack.push(fx.project, nullptr).error == EditError::InvalidArgument);

    REQUIRE(stack.push(fx.project, moveTo(fx, c, fx.v1, 10)).ok());
    REQUIRE(stack.push(fx.project, moveTo(fx, c, fx.v1, 20)).ok());
    REQUIRE(stack.undo(fx.project));
    CHECK(stack.redoCount() == 1);
    REQUIRE(stack.push(fx.project, moveTo(fx, c, fx.v2, 50)).ok());
    CHECK(stack.redoCount() == 0);
    CHECK(stack.undoCount() == 2);
    CHECK(fx.clip(c).trackId == fx.v2);
}

TEST_CASE("UndoStack: a drag coalesces into one step, each step relative to the drag start") {
    Fixture fx;
    const ClipId dragged = fx.addClip(fx.v1, fx.av30, 0, 30);
    const ClipId neighbour = fx.addClip(fx.v1, fx.av30, 60, 30);
    const Project start = fx.project;
    UndoStack stack;
    const auto key = moveTo(fx, dragged, fx.v1, 0)->coalescingKey();

    stack.beginCoalescing(key);
    CHECK(stack.isCoalescing());
    // Drag over the neighbour (overwriting part of it) and back off it again.
    for (const std::int64_t frame : {10, 40, 50, 45, 20}) {
        REQUIRE(stack.push(fx.project, moveTo(fx, dragged, fx.v1, frame)).ok());
    }
    stack.endCoalescing();

    CHECK(stack.undoCount() == 1);
    CHECK(framesOf(fx.clip(dragged)) == span(20, 50));
    CHECK(framesOf(fx.clip(neighbour)) == span(60, 90)); // untouched by the transient overlap
    REQUIRE(stack.undo(fx.project));
    CHECK(fx.project == start);
    REQUIRE(stack.redo(fx.project));
    CHECK(framesOf(fx.clip(dragged)) == span(20, 50));
    CHECK(framesOf(fx.clip(neighbour)) == span(60, 90));
}

TEST_CASE("UndoStack: a refused step during a drag keeps the last good position") {
    Fixture fx;
    const ClipId c = fx.addClip(fx.v1, fx.av30, 30, 30);
    UndoStack stack;
    stack.beginCoalescing(moveTo(fx, c, fx.v1, 0)->coalescingKey());
    REQUIRE(stack.push(fx.project, moveTo(fx, c, fx.v1, 40)).ok());
    CHECK(stack.push(fx.project, moveTo(fx, c, fx.v1, -10)).error == EditError::InvalidTime);
    CHECK(framesOf(fx.clip(c)) == span(40, 70));
    REQUIRE(stack.push(fx.project, moveTo(fx, c, fx.v1, 50)).ok());
    stack.endCoalescing();
    CHECK(stack.undoCount() == 1);
    REQUIRE(stack.undo(fx.project));
    CHECK(framesOf(fx.clip(c)) == span(30, 60));
}

TEST_CASE("UndoStack: accumulate mode merges consecutive changes") {
    Fixture fx;
    const ClipId c = fx.addClip(fx.v1, fx.av30, 0, 30);
    const Project start = fx.project;
    UndoStack stack;
    SetVideoParams probe(fx.seq, c, VideoParams{});
    stack.beginCoalescing(probe.coalescingKey(), CoalesceMode::Accumulate);
    for (int i = 1; i <= 5; ++i) {
        REQUIRE(stack.push(fx.project, std::make_unique<SetVideoParams>(fx.seq, c, VideoParams{i * 10.0, 0, 1, 0, 1}))
                    .ok());
    }
    stack.endCoalescing();
    CHECK(stack.undoCount() == 1);
    const Project end = fx.project;
    CHECK(fx.clip(c).video.x == 50.0);
    REQUIRE(stack.undo(fx.project));
    CHECK(fx.project == start);
    REQUIRE(stack.redo(fx.project));
    CHECK(fx.project == end);
}

TEST_CASE("UndoStack: accumulate mode merges edits that create ids") {
    Fixture fx;
    const ClipId c = fx.addClip(fx.v1, fx.av30, 0, 90);
    const Project start = fx.project;
    UndoStack stack;
    stack.beginCoalescing("razor", CoalesceMode::Accumulate);
    for (const std::int64_t frame : {20, 40, 60}) {
        auto split = std::make_unique<SplitClip>(fx.seq, fx.track(fx.v1).clipAt(f30(frame))->id, f30(frame));
        split->setCoalescingKey("razor");
        REQUIRE(stack.push(fx.project, std::move(split)).ok());
    }
    stack.endCoalescing();
    CHECK(stack.undoCount() == 1);
    CHECK(fx.track(fx.v1).clips.size() == 4);
    const Project end = fx.project;
    REQUIRE(stack.undo(fx.project));
    CHECK(fx.project == start);
    CHECK(fx.clip(c).duration() == f30(90));
    REQUIRE(stack.redo(fx.project));
    CHECK(fx.project == end);
}

TEST_CASE("UndoStack: a different key ends the group; cancel reverts it") {
    Fixture fx;
    const ClipId c = fx.addClip(fx.v1, fx.av30, 0, 30);
    const Project start = fx.project;
    UndoStack stack;
    stack.beginCoalescing(moveTo(fx, c, fx.v1, 0)->coalescingKey());
    REQUIRE(stack.push(fx.project, moveTo(fx, c, fx.v1, 10)).ok());
    REQUIRE(stack.push(fx.project, std::make_unique<SplitClip>(fx.seq, c, f30(20))).ok());
    CHECK_FALSE(stack.isCoalescing());
    REQUIRE(stack.push(fx.project, moveTo(fx, c, fx.v1, 5)).ok()); // not coalesced any more
    CHECK(stack.undoCount() == 3);

    stack.beginCoalescing(moveTo(fx, c, fx.v1, 0)->coalescingKey());
    const Project beforeDrag = fx.project;
    REQUIRE(stack.push(fx.project, moveTo(fx, c, fx.v2, 100)).ok());
    REQUIRE(stack.push(fx.project, moveTo(fx, c, fx.v2, 120)).ok());
    CHECK(stack.cancelCoalescing(fx.project));
    CHECK(fx.project == beforeDrag);
    CHECK(stack.undoCount() == 3);
    CHECK_FALSE(stack.cancelCoalescing(fx.project));
    while (stack.undo(fx.project)) {
    }
    CHECK(fx.project == start);
}

TEST_CASE("UndoStack: max depth drops the oldest steps") {
    Fixture fx;
    const ClipId c = fx.addClip(fx.v1, fx.av30, 0, 30);
    UndoStack stack(3);
    std::vector<Project> states{fx.project};
    for (int i = 1; i <= 5; ++i) {
        REQUIRE(stack.push(fx.project, moveTo(fx, c, fx.v1, i * 10)).ok());
        states.push_back(fx.project);
    }
    CHECK(stack.undoCount() == 3);
    while (stack.undo(fx.project)) {
    }
    CHECK(fx.project == states[2]);
    stack.setMaxDepth(1);
    CHECK(stack.redoCount() == 1);
    CHECK(stack.maxDepth() == 1);
}

TEST_CASE("UndoStack: dirty tracking follows the saved position") {
    Fixture fx;
    const ClipId c = fx.addClip(fx.v1, fx.av30, 0, 30);
    UndoStack stack;
    CHECK_FALSE(stack.isDirty());
    CHECK(stack.dirtyCount() == 0);

    REQUIRE(stack.push(fx.project, moveTo(fx, c, fx.v1, 10)).ok());
    CHECK(stack.isDirty());
    CHECK(stack.dirtyCount() == 1);
    stack.markClean(); // saved
    CHECK_FALSE(stack.isDirty());
    REQUIRE(stack.push(fx.project, moveTo(fx, c, fx.v1, 20)).ok());
    CHECK(stack.isDirty());
    REQUIRE(stack.undo(fx.project));
    CHECK_FALSE(stack.isDirty());
    REQUIRE(stack.undo(fx.project));
    CHECK(stack.isDirty());
    CHECK(stack.dirtyCount() == -1);
    REQUIRE(stack.redo(fx.project));
    CHECK_FALSE(stack.isDirty());

    // Branching away from the saved state makes it unreachable.
    REQUIRE(stack.undo(fx.project));
    REQUIRE(stack.push(fx.project, moveTo(fx, c, fx.v1, 40)).ok());
    CHECK(stack.isDirty());
    CHECK_FALSE(stack.dirtyCount().has_value());
    REQUIRE(stack.undo(fx.project));
    CHECK(stack.isDirty()); // same content as saved, but the history position is gone

    const std::uint64_t before = stack.changeCount();
    REQUIRE(stack.redo(fx.project));
    CHECK(stack.changeCount() == before + 1);
    stack.clear();
    CHECK_FALSE(stack.isDirty());
    CHECK_FALSE(stack.canUndo());
    CHECK_FALSE(stack.canRedo());
}

TEST_CASE("UndoStack: a coalesced change at the saved position makes the document dirty") {
    Fixture fx;
    const ClipId c = fx.addClip(fx.v1, fx.av30, 0, 30);
    UndoStack stack;
    stack.beginCoalescing(moveTo(fx, c, fx.v1, 0)->coalescingKey());
    REQUIRE(stack.push(fx.project, moveTo(fx, c, fx.v1, 10)).ok());
    stack.markClean();
    REQUIRE(stack.push(fx.project, moveTo(fx, c, fx.v1, 20)).ok());
    CHECK(stack.isDirty());
}

TEST_CASE("UndoStack: setMaxDepth with a redo tail keeps undo and redo on the right states (review finding 6)") {
    Fixture fx;
    const ClipId c = fx.addClip(fx.v1, fx.av30, 0, 30);
    UndoStack stack;
    std::vector<Project> states{fx.project};
    for (int i = 1; i <= 4; ++i) {
        REQUIRE(stack.push(fx.project, moveTo(fx, c, fx.v1, i * 10)).ok());
        states.push_back(fx.project);
    }
    for (int i = 0; i < 3; ++i) {
        REQUIRE(stack.undo(fx.project)); // at states[1] with three redo steps
    }
    stack.setMaxDepth(2); // the redo steps go first: one undo and one redo step remain
    CHECK(fx.project == states[1]);
    CHECK(stack.undoCount() == 1);
    CHECK(stack.redoCount() == 1);
    REQUIRE(stack.redo(fx.project));
    CHECK(fx.project == states[2]);
    CHECK(framesOf(fx.clip(c)) == span(20, 50));
    CHECK_FALSE(stack.redo(fx.project));
    REQUIRE(stack.undo(fx.project));
    REQUIRE(stack.undo(fx.project));
    CHECK(fx.project == states[0]);

    // With only applied steps, the oldest go.
    while (stack.redo(fx.project)) {
    }
    stack.setMaxDepth(1);
    CHECK(stack.undoCount() == 1);
    CHECK(stack.redoCount() == 0);
    REQUIRE(stack.undo(fx.project));
    CHECK(fx.project == states[1]);
}

TEST_CASE("UndoStack: setMaxDepth drops a clean position that no longer exists") {
    Fixture fx;
    const ClipId c = fx.addClip(fx.v1, fx.av30, 0, 30);
    UndoStack stack;
    for (int i = 1; i <= 3; ++i) {
        REQUIRE(stack.push(fx.project, moveTo(fx, c, fx.v1, i * 10)).ok());
    }
    stack.markClean();
    REQUIRE(stack.undo(fx.project));
    REQUIRE(stack.undo(fx.project));
    stack.setMaxDepth(2); // the saved state was the last redo step
    CHECK(stack.isDirty());
    CHECK_FALSE(stack.dirtyCount().has_value());
}

TEST_CASE("UndoStack: a failed redo drops the stale branch and its clean position (review finding 9)") {
    Fixture fx;
    const ClipId c = fx.addClip(fx.v1, fx.av30, 0, 30);
    UndoStack stack;
    REQUIRE(stack.push(fx.project, moveTo(fx, c, fx.v1, 10)).ok());
    REQUIRE(stack.push(fx.project, moveTo(fx, c, fx.v1, 20)).ok());
    stack.markClean(); // saved with the clip at 20
    REQUIRE(stack.undo(fx.project));
    fx.sequence().findClip(c)->video.opacity = 0.5; // modified outside the stack
    CHECK_FALSE(stack.redo(fx.project));
    CHECK(stack.redoCount() == 0);
    CHECK(fx.clip(c).video.opacity == 0.5); // the stale redo was not forced onto the project
    CHECK(framesOf(fx.clip(c)) == span(10, 40));
    REQUIRE(stack.push(fx.project, moveTo(fx, c, fx.v1, 50)).ok());
    CHECK(stack.isDirty()); // back at position 2, but not the saved state
    REQUIRE(stack.push(fx.project, moveTo(fx, c, fx.v1, 60)).ok());
    CHECK(stack.isDirty());
}

TEST_CASE("UndoStack: undo against a project changed behind its back fails cleanly") {
    Fixture fx;
    const ClipId c = fx.addClip(fx.v1, fx.av30, 0, 30);
    UndoStack stack;
    REQUIRE(stack.push(fx.project, moveTo(fx, c, fx.v1, 10)).ok());
    REQUIRE(stack.push(fx.project, moveTo(fx, c, fx.v1, 20)).ok());
    fx.sequence().findClip(c)->timelineStart = f30(25);
    const Project changed = fx.project;
    CHECK_FALSE(stack.undo(fx.project));
    CHECK(fx.project == changed);
    CHECK_FALSE(stack.canUndo());
    CHECK(stack.isDirty());
}

TEST_CASE("applyPatch refuses a sequence that is not in the patch's source state") {
    Fixture fx;
    const ClipId c = fx.addClip(fx.v1, fx.av30, 0, 30);
    AddTrack add(fx.seq, TrackKind::Video);
    REQUIRE(add.apply(fx.project).ok());
    MoveClip move(fx.seq, c, fx.v1, f30(40));
    REQUIRE(move.apply(fx.project).ok());
    const SequencePatch trackPatch = *add.patch();
    // Going forward again from the edited state: the new track already exists.
    Sequence sequence = fx.sequence();
    IdGenerator ids = fx.project.ids;
    CHECK_FALSE(patchApplies(sequence, ids, trackPatch, PatchDirection::Forward));
    CHECK_FALSE(applyPatch(sequence, ids, trackPatch, PatchDirection::Forward)); // no throw, no change
    CHECK(sequence == fx.sequence());
    // Backward over a sequence missing the track the patch would remove.
    move.revert(fx.project);
    add.revert(fx.project);
    sequence = fx.sequence();
    ids = fx.project.ids;
    CHECK_FALSE(applyPatch(sequence, ids, trackPatch, PatchDirection::Backward));
    CHECK(sequence == fx.sequence());
    CHECK(applyPatch(sequence, ids, trackPatch, PatchDirection::Forward));
    CHECK(sequence.videoTracks.size() == 3);
    // A command refuses to redo onto the wrong base.
    fx.sequence().findClip(c)->timelineStart = f30(5);
    REQUIRE(add.apply(fx.project).ok());
    CHECK(move.apply(fx.project).error == EditError::InvariantViolation);
    CHECK_FALSE(move.canRevert(fx.project));
}

TEST_CASE("UndoStack: commands that change nothing are not recorded (review finding 8)") {
    Fixture fx;
    const ClipId c = fx.addClip(fx.v1, fx.av30, 0, 30);
    UndoStack stack;
    const std::uint64_t version = stack.changeCount();
    const EditResult r = stack.push(fx.project, moveTo(fx, c, fx.v1, 0));
    CHECK(r.ok());
    CHECK(stack.undoCount() == 0);
    CHECK_FALSE(stack.isDirty());
    CHECK(stack.changeCount() == version);
    REQUIRE(stack.push(fx.project, std::make_unique<SetVideoParams>(fx.seq, c, VideoParams{})).ok());
    CHECK(stack.undoCount() == 0); // same parameters as before
    REQUIRE(stack.push(fx.project, std::make_unique<TrimClipTail>(fx.seq, c, f30(30))).ok());
    CHECK(stack.undoCount() == 0);
}

TEST_CASE("UndoStack: a drag that returns to its start leaves no undo step") {
    Fixture fx;
    const ClipId c = fx.addClip(fx.v1, fx.av30, 0, 30);
    const Project start = fx.project;
    UndoStack stack;
    stack.beginCoalescing(moveTo(fx, c, fx.v1, 0)->coalescingKey());
    for (const std::int64_t frame : {10, 20, 5, 0}) {
        REQUIRE(stack.push(fx.project, moveTo(fx, c, fx.v1, frame)).ok());
    }
    CHECK(stack.undoCount() == 0);
    CHECK_FALSE(stack.isDirty());
    CHECK(fx.project == start);
    // The gesture continues after passing through its start.
    REQUIRE(stack.push(fx.project, moveTo(fx, c, fx.v1, 15)).ok());
    stack.endCoalescing();
    CHECK(stack.undoCount() == 1);
    REQUIRE(stack.undo(fx.project));
    CHECK(fx.project == start);
}

TEST_CASE("UndoStack: accumulated changes that cancel out leave no undo step; accumulate then cancel") {
    Fixture fx;
    const ClipId c = fx.addClip(fx.v1, fx.av30, 0, 30);
    const Project start = fx.project;
    UndoStack stack;
    SetVideoParams probe(fx.seq, c, VideoParams{});
    stack.beginCoalescing(probe.coalescingKey(), CoalesceMode::Accumulate);
    REQUIRE(stack.push(fx.project, std::make_unique<SetVideoParams>(fx.seq, c, VideoParams{5, 0, 1, 0, 1})).ok());
    REQUIRE(stack.push(fx.project, std::make_unique<SetVideoParams>(fx.seq, c, VideoParams{})).ok());
    CHECK(stack.undoCount() == 0);
    CHECK(fx.project == start);
    REQUIRE(stack.push(fx.project, std::make_unique<SetVideoParams>(fx.seq, c, VideoParams{7, 0, 1, 0, 1})).ok());
    REQUIRE(stack.push(fx.project, std::make_unique<SetVideoParams>(fx.seq, c, VideoParams{9, 0, 1, 0, 1})).ok());
    CHECK(stack.undoCount() == 1);
    CHECK(stack.cancelCoalescing(fx.project));
    CHECK(fx.project == start);
    CHECK(stack.undoCount() == 0);
    CHECK_FALSE(stack.canRedo());
}

TEST_CASE("UndoStack: a group whose first push is refused starts with the next good one") {
    Fixture fx;
    const ClipId c = fx.addClip(fx.v1, fx.av30, 30, 30);
    const Project start = fx.project;
    UndoStack stack;
    stack.beginCoalescing(moveTo(fx, c, fx.v1, 0)->coalescingKey());
    CHECK(stack.push(fx.project, moveTo(fx, c, fx.v1, -10)).error == EditError::InvalidTime);
    CHECK(stack.undoCount() == 0);
    REQUIRE(stack.push(fx.project, moveTo(fx, c, fx.v1, 40)).ok());
    REQUIRE(stack.push(fx.project, moveTo(fx, c, fx.v1, 50)).ok());
    stack.endCoalescing();
    CHECK(stack.undoCount() == 1);
    REQUIRE(stack.undo(fx.project));
    CHECK(fx.project == start);
}

TEST_CASE("UndoStack: markClean mid-drag, then cancel") {
    Fixture fx;
    const ClipId c = fx.addClip(fx.v1, fx.av30, 0, 30);
    UndoStack stack;
    stack.beginCoalescing(moveTo(fx, c, fx.v1, 0)->coalescingKey());
    REQUIRE(stack.push(fx.project, moveTo(fx, c, fx.v1, 10)).ok());
    stack.markClean(); // saved mid-gesture with the clip at 10
    CHECK_FALSE(stack.isDirty());
    CHECK(stack.cancelCoalescing(fx.project)); // back at 0: not what was saved
    CHECK(stack.isDirty());
    CHECK(framesOf(fx.clip(c)) == span(0, 30));
}

TEST_CASE("UndoStack: push reports the transitions an edit dropped") {
    Fixture fx;
    const ClipId a = fx.addClip(fx.v1, fx.av30, 0, 60, 30);
    const ClipId b = fx.addClip(fx.v1, fx.av30, 60, 60, 300);
    const SpanId t = fx.addTransition(fx.v1, a, b, 10);
    UndoStack stack;
    const EditResult r = stack.push(fx.project, std::make_unique<TrimClipTail>(fx.seq, a, f30(50)));
    REQUIRE(r.ok());
    CHECK(r.droppedTransitionIds == std::vector<SpanId>{t});
}
