// Facade commands (VEFacadeCommands+Internal.h) under the undo stack's coalescing modes.

#include "../../Engine/Edit/UndoStack.h"
#include "../../Engine/Facade/VEFacadeCommands+Internal.h"
#include "../Edit/EditTestSupport.h"

#include <memory>

using namespace vetest;

namespace {

/// Wraps `inner` the way the facade pushes every edit (FreshIds with the project's id floor) and
/// tags it with `key`.
std::unique_ptr<Command> wrapped(Fixture &fx, std::unique_ptr<Command> inner, const std::string &key) {
    auto command = std::make_unique<facade::FreshIds>(std::move(inner), fx.project.ids.nextValue());
    command->setCoalescingKey(key);
    return command;
}

} // namespace

TEST_CASE("FreshIds: wrapped edits merge into one step under Accumulate coalescing") {
    Fixture fx;
    const ClipId c = fx.addClip(fx.v1, fx.av30, 0, 30);
    const Project start = fx.project;
    UndoStack stack;
    stack.beginCoalescing("nudge", CoalesceMode::Accumulate);
    for (int i = 1; i <= 3; ++i) {
        REQUIRE(stack
                    .push(fx.project, wrapped(fx, std::make_unique<SetVideoParams>(
                                                      fx.seq, c, VideoParams{i * 10.0, 0, 1, 0, 1}),
                                              "nudge"))
                    .ok());
    }
    stack.endCoalescing();
    CHECK(stack.undoCount() == 1);
    CHECK(fx.clip(c).video.x == 30.0);
    const Project end = fx.project;
    REQUIRE(stack.undo(fx.project));
    CHECK(fx.project == start);
    REQUIRE(stack.redo(fx.project));
    CHECK(fx.project == end);
}

TEST_CASE("FreshIds: wrapped edits that create ids merge under Accumulate and replay exactly") {
    Fixture fx;
    fx.addClip(fx.v1, fx.av30, 0, 90);
    const Project start = fx.project;
    UndoStack stack;
    stack.beginCoalescing("razor", CoalesceMode::Accumulate);
    for (const std::int64_t frame : {20, 40, 60}) {
        const ClipId under = fx.track(fx.v1).clipAt(f30(frame))->id;
        REQUIRE(stack.push(fx.project, wrapped(fx, std::make_unique<SplitClip>(fx.seq, under, f30(frame)), "razor"))
                    .ok());
    }
    stack.endCoalescing();
    CHECK(stack.undoCount() == 1);
    CHECK(fx.track(fx.v1).clips.size() == 4);
    const Project end = fx.project;
    REQUIRE(stack.undo(fx.project));
    CHECK(fx.project == start);
    REQUIRE(stack.redo(fx.project));
    CHECK(fx.project == end);
}
