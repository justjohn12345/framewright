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
