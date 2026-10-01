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
    _undo.coalescingKey = [key copy];
    _undo.stack->beginCoalescing(toStd(_undo.coalescingKey), mode == VECoalescingModeAccumulate
                                                                 ? CoalesceMode::Accumulate
                                                                 : CoalesceMode::ReplacePrevious);
}

- (nullable NSString *)coalescingKey {
    VE_ASSERT_MAIN();
    return _undo.coalescingKey;
}

- (VEEditResult *)performInCoalescingGroup:(NSString *)key edit:(NS_NOESCAPE VEEditResult * (^)(void))edit {
    VE_ASSERT_MAIN();
    if (_undo.coalescingKey == nil || ![_undo.coalescingKey isEqualToString:key]) {
        return [VEEditResult failureWithCode:VEEditErrorBusy
                                     message:@"The gesture's edit group has ended (another edit committed it)."];
    }
    NSString *outer = _undo.gestureEditKey;
    _undo.gestureEditKey = [key copy];
    VEEditResult *result = edit();
    _undo.gestureEditKey = outer;
    return result ?: [VEEditResult failureWithCode:VEEditErrorInvalidArgument message:@"The edit returned no result."];
}

- (void)endCoalescing {
    VE_ASSERT_MAIN();
    [self closeCoalescingIfOpen];
}

- (void)cancelCoalescing {
    VE_ASSERT_MAIN();
    if (_undo.coalescingKey == nil) {
        return;
    }
    _undo.coalescingKey = nil;
    const bool reverted = _undo.stack->cancelCoalescing(_project);
    if (reverted) {
        [self notifyAssetsAndModelChanged];
    }
    [self flushDeferredImports];
}

- (BOOL)isCoalescing {
    VE_ASSERT_MAIN();
    return _undo.coalescingKey != nil;
}

- (BOOL)undo {
    VE_ASSERT_MAIN();
    _undo.coalescingKey = nil;
    [self flushDeferredImports];
    if (!_undo.stack->undo(_project)) {
        return NO;
    }
    [self notifyAssetsAndModelChanged];
    return YES;
}

- (BOOL)redo {
    VE_ASSERT_MAIN();
    _undo.coalescingKey = nil;
    [self flushDeferredImports];
    if (!_undo.stack->redo(_project)) {
        return NO;
    }
    _undo.idFloor = std::max(_undo.idFloor, _project.ids.nextValue());
    [self notifyAssetsAndModelChanged];
    return YES;
}

- (BOOL)canUndo {
    VE_ASSERT_MAIN();
    return _undo.stack->canUndo();
}

- (BOOL)canRedo {
    VE_ASSERT_MAIN();
    return _undo.stack->canRedo();
}

- (NSString *)undoActionName {
    VE_ASSERT_MAIN();
    return toNS(_undo.stack->undoName());
}

- (NSString *)redoActionName {
    VE_ASSERT_MAIN();
    return toNS(_undo.stack->redoName());
}

@end

@implementation VEEngine (UndoInternal)

// MARK: - Private (VEEngine+Internal.h declares what other files call)

/// Pushes a command onto the undo stack, wrapped so it never reuses an id (see FreshIds). Only
/// the open gesture's own edits (made inside performInCoalescingGroup:edit: with the group's
/// key) join its coalescing group; any other edit first ends the group, committing the gesture
/// as one undo step, and is then pushed on its own.
- (EditResult)pushCommand:(std::unique_ptr<Command>)command {
    if (_undo.coalescingKey != nil && ![_undo.gestureEditKey isEqualToString:_undo.coalescingKey]) {
        [self closeCoalescingIfOpen];
    }
    _undo.idFloor = std::max(_undo.idFloor, _project.ids.nextValue());
    auto wrapped = std::make_unique<FreshIds>(std::move(command), _undo.idFloor);
    if (_undo.coalescingKey != nil) {
        wrapped->setCoalescingKey(toStd(_undo.coalescingKey));
    }
    EditResult result = _undo.stack->push(_project, std::move(wrapped));
    _undo.idFloor = std::max(_undo.idFloor, _project.ids.nextValue());
    return result;
}

/// Pushes an edit and notifies on success.
- (VEEditResult *)push:(std::unique_ptr<Command>)command created:(NSArray<NSNumber *> * (^_Nullable)(void))created {
    return [self push:std::move(command) created:created note:nil];
}

- (VEEditResult *)push:(std::unique_ptr<Command>)command
               created:(NSArray<NSNumber *> * (^_Nullable)(void))created
                  note:(nullable NSString *)note {
    return [self push:std::move(command) created:created note:note lateNote:nil];
}

- (VEEditResult *)push:(std::unique_ptr<Command>)command
               created:(NSArray<NSNumber *> * (^_Nullable)(void))created
                  note:(nullable NSString *)note
              lateNote:(NSString *_Nullable (^_Nullable)(void))lateNote {
    return [self finishPush:[self pushCommand:std::move(command)] created:created note:note lateNote:lateNote];
}

/// The facade's result for a pushed edit: its refusal, or (after notifying the change) its success
/// with the ids `created` lists and `note` followed by what `lateNote` says now.
- (VEEditResult *)finishPush:(const EditResult &)result
                     created:(NSArray<NSNumber *> * (^_Nullable)(void))created
                        note:(nullable NSString *)note
                    lateNote:(NSString *_Nullable (^_Nullable)(void))lateNote {
    if (!result) {
        return toVE(result);
    }
    NSArray<NSNumber *> *ids = created ? created() : @[];
    NSString *late = lateNote ? lateNote() : nil;
    if (late.length > 0) {
        note = note.length > 0 ? [NSString stringWithFormat:@"%@ %@", note, late] : late;
    }
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
    return [self pushRipple:make scope:rippleScope created:created note:note lateNote:nil];
}

- (VEEditResult *)pushRipple:(std::unique_ptr<Command> (^)(RippleScope scope))make
                       scope:(VERippleScope)rippleScope
                     created:(NSArray<NSNumber *> * (^_Nullable)(void))created
                        note:(nullable NSString *)note
                    lateNote:(NSString *_Nullable (^_Nullable)(void))lateNote {
    if (rippleScope == VERippleScopeSyncedTracks) {
        return [self push:make(RippleScope::SyncedTracks) created:created note:note lateNote:lateNote];
    }
    EditResult result = [self pushCommand:make(RippleScope::AllUnlockedTracks)];
    if (result.error == EditError::Overlap) {
        NSString *fallback = @"Other tracks have clips in the way, so only the edited clips' tracks were rippled.";
        return [self push:make(RippleScope::SyncedTracks)
                  created:created
                     note:note.length > 0 ? [NSString stringWithFormat:@"%@ %@", note, fallback] : fallback
                 lateNote:lateNote];
    }
    return [self finishPush:result created:created note:note lateNote:lateNote];
}

- (void)closeCoalescingIfOpen {
    if (_undo.coalescingKey != nil) {
        _undo.stack->endCoalescing();
        _undo.coalescingKey = nil;
    }
    [self flushDeferredImports];
}

- (void)deferUntilCoalescingEnds:(dispatch_block_t)block {
    [_undo.deferredImports addObject:block];
}

- (void)markUndoHistoryClean {
    _undo.stack->markClean();
}

- (void)startUndoHistory {
    _undo.stack = std::make_unique<UndoStack>();
    _undo.coalescingKey = nil;
    _undo.idFloor = _project.ids.nextValue();
}

/// Runs the imports that finished while a coalescing group was open (on the next main-queue
/// turn, so the caller that ended the group finishes first).
- (void)flushDeferredImports {
    if (_undo.deferredImports.count == 0) {
        return;
    }
    NSArray<dispatch_block_t> *pending = [_undo.deferredImports copy];
    [_undo.deferredImports removeAllObjects];
    for (dispatch_block_t block in pending) {
        dispatch_async(dispatch_get_main_queue(), block);
    }
}

@end
