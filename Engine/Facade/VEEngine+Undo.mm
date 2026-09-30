// VEEngine (Undo): coalescing groups, undo and redo, and the gateway every edit goes through
// (pushCommand: and the push helpers that notify and wrap the result).

#import "VEEngine+Internal.h"

#import "VEFacadeCommands+Internal.h"

#include <algorithm>
#include <memory>

using namespace ve;
using namespace ve::facade;

@implementation VEEngine (Undo)

// MARK: - Undo

- (void)beginCoalescingWithKey:(NSString *)key {
    VE_ASSERT_MAIN();
    [self beginCoalescingWithKey:key mode:VECoalescingModeReplace];
}

- (void)beginCoalescingWithKey:(NSString *)key mode:(VECoalescingMode)mode {
    VE_ASSERT_MAIN();
    [self closeCoalescingIfOpen];
    _coalescingKey = [key copy];
    _undo->beginCoalescing(toStd(_coalescingKey), mode == VECoalescingModeAccumulate ? CoalesceMode::Accumulate
                                                                                   : CoalesceMode::ReplacePrevious);
}

- (nullable NSString *)coalescingKey {
    VE_ASSERT_MAIN();
    return _coalescingKey;
}

- (VEEditResult *)performInCoalescingGroup:(NSString *)key edit:(NS_NOESCAPE VEEditResult * (^)(void))edit {
    VE_ASSERT_MAIN();
    if (_coalescingKey == nil || ![_coalescingKey isEqualToString:key]) {
        return [VEEditResult failureWithCode:VEEditErrorBusy
                                     message:@"The gesture's edit group has ended (another edit committed it)."];
    }
    NSString *outer = _gestureEditKey;
    _gestureEditKey = [key copy];
    VEEditResult *result = edit();
    _gestureEditKey = outer;
    return result ?: [VEEditResult failureWithCode:VEEditErrorInvalidArgument message:@"The edit returned no result."];
}

- (void)endCoalescing {
    VE_ASSERT_MAIN();
    [self closeCoalescingIfOpen];
}

- (void)cancelCoalescing {
    VE_ASSERT_MAIN();
    if (_coalescingKey == nil) {
        return;
    }
    _coalescingKey = nil;
    const bool reverted = _undo->cancelCoalescing(_project);
    if (reverted) {
        [self notifyAssetsChanged];
        [self notifyModelChanged];
    }
    [self flushDeferredImports];
}

- (BOOL)isCoalescing {
    VE_ASSERT_MAIN();
    return _coalescingKey != nil;
}

- (BOOL)undo {
    VE_ASSERT_MAIN();
    _coalescingKey = nil;
    [self flushDeferredImports];
    if (!_undo->undo(_project)) {
        return NO;
    }
    [self notifyAssetsChanged];
    [self notifyModelChanged];
    return YES;
}

- (BOOL)redo {
    VE_ASSERT_MAIN();
    _coalescingKey = nil;
    [self flushDeferredImports];
    if (!_undo->redo(_project)) {
        return NO;
    }
    _idFloor = std::max(_idFloor, _project.ids.nextValue());
    [self notifyAssetsChanged];
    [self notifyModelChanged];
    return YES;
}

- (BOOL)canUndo {
    VE_ASSERT_MAIN();
    return _undo->canUndo();
}

- (BOOL)canRedo {
    VE_ASSERT_MAIN();
    return _undo->canRedo();
}

- (NSString *)undoActionName {
    VE_ASSERT_MAIN();
    return toNS(_undo->undoName());
}

- (NSString *)redoActionName {
    VE_ASSERT_MAIN();
    return toNS(_undo->redoName());
}

@end

@implementation VEEngine (UndoInternal)

/// Pushes a command onto the undo stack, wrapped so it never reuses an id (see FreshIds). Only
/// the open gesture's own edits (made inside performInCoalescingGroup:edit: with the group's
/// key) join its coalescing group; any other edit first ends the group, committing the gesture
/// as one undo step, and is then pushed on its own.
- (EditResult)pushCommand:(std::unique_ptr<Command>)command {
    if (_coalescingKey != nil && ![_gestureEditKey isEqualToString:_coalescingKey]) {
        [self closeCoalescingIfOpen];
    }
    _idFloor = std::max(_idFloor, _project.ids.nextValue());
    auto wrapped = std::make_unique<FreshIds>(std::move(command), _idFloor);
    if (_coalescingKey != nil) {
        wrapped->setCoalescingKey(toStd(_coalescingKey));
    }
    EditResult result = _undo->push(_project, std::move(wrapped));
    _idFloor = std::max(_idFloor, _project.ids.nextValue());
    return result;
}

/// Pushes an edit and notifies on success.
- (VEEditResult *)push:(std::unique_ptr<Command>)command created:(NSArray<NSNumber *> * (^_Nullable)(void))created {
    return [self push:std::move(command) created:created note:nil];
}

- (VEEditResult *)push:(std::unique_ptr<Command>)command
               created:(NSArray<NSNumber *> * (^_Nullable)(void))created
                  note:(nullable NSString *)note {
    EditResult result = [self pushCommand:std::move(command)];
    if (!result) {
        return toVE(result);
    }
    NSArray<NSNumber *> *ids = created ? created() : @[];
    [self notifyModelChanged];
    return toVE(result, ids, note);
}

/// Pushes the ripple edit `make` builds for `scope`; with the all-tracks scope refused because
/// another track is in the way, retries on the synced tracks and says so.
- (VEEditResult *)pushRipple:(std::unique_ptr<Command> (^)(RippleScope scope))make
                     created:(NSArray<NSNumber *> * (^_Nullable)(void))created {
    return [self pushRipple:make scope:_rippleScope created:created];
}

- (VEEditResult *)pushRipple:(std::unique_ptr<Command> (^)(RippleScope scope))make
                       scope:(VERippleScope)rippleScope
                     created:(NSArray<NSNumber *> * (^_Nullable)(void))created {
    return [self pushRipple:make scope:rippleScope created:created note:nil];
}

/// `note`: what the user should know when the edit succeeds (joined with the ripple fallback's).
- (VEEditResult *)pushRipple:(std::unique_ptr<Command> (^)(RippleScope scope))make
                       scope:(VERippleScope)rippleScope
                     created:(NSArray<NSNumber *> * (^_Nullable)(void))created
                        note:(nullable NSString *)note {
    if (rippleScope == VERippleScopeSyncedTracks) {
        return [self push:make(RippleScope::SyncedTracks) created:created note:note];
    }
    EditResult result = [self pushCommand:make(RippleScope::AllUnlockedTracks)];
    if (result.error == EditError::Overlap) {
        NSString *fallback = @"Other tracks have clips in the way, so only the edited clips' tracks were rippled.";
        return [self push:make(RippleScope::SyncedTracks)
                  created:created
                     note:note.length > 0 ? [NSString stringWithFormat:@"%@ %@", note, fallback] : fallback];
    }
    if (!result) {
        return toVE(result);
    }
    NSArray<NSNumber *> *ids = created ? created() : @[];
    [self notifyModelChanged];
    return toVE(result, ids, note);
}

- (void)closeCoalescingIfOpen {
    if (_coalescingKey != nil) {
        _undo->endCoalescing();
        _coalescingKey = nil;
    }
    [self flushDeferredImports];
}

/// Runs the imports that finished while a coalescing group was open (on the next main-queue
/// turn, so the caller that ended the group finishes first).
- (void)flushDeferredImports {
    if (_deferredImports.count == 0) {
        return;
    }
    NSArray<dispatch_block_t> *pending = [_deferredImports copy];
    [_deferredImports removeAllObjects];
    for (dispatch_block_t block in pending) {
        dispatch_async(dispatch_get_main_queue(), block);
    }
}

@end
