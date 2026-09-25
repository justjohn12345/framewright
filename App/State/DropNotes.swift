import CoreMedia
import Foundation
import FramewrightEngine

/// What an edit removed as a side effect, in words for the status line (review M1).
///
/// The engine lists the transitions and effect spans an edit removed without being asked
/// (`VEEditResult.droppedTransitionIDs`, `droppedSpanIDs`): a head fade that a move, ripple, insert,
/// overwrite or tail extension made touched, a dissolve whose cut went away or changed partner, a
/// fade that no longer fits, a span a trim cut away (whose held values were folded into the clip's
/// static values when it lay before the new start). By the time the app sees the result the spans
/// are gone from the model, so the store remembers every span it has seen with its clip as they were
/// the last time the span was there (`SpanMemory`, refreshed with the model); the notes are built
/// from that and from the clips as they are now.
@MainActor
struct SpanMemory {
    struct Entry {
        let span: VEEffectSpan
        let clip: VEClipInfo
    }

    private(set) var entries: [VESpanID: Entry] = [:]
    /// The name of every clip seen (a removed partner is still named).
    private(set) var clipNames: [VEClipID: String] = [:]

    /// Remembers the spans of `clips` as they are now. A span that is gone keeps the entry from when
    /// it was last there (so a coalesced drag, which reapplies from its start on every step, still
    /// finds the span and its clip as they were before the drag).
    mutating func remember(_ clips: [VEClipID: VEClipInfo]) {
        for clip in clips.values {
            clipNames[clip.clipID] = clip.name
            for span in clip.spans {
                entries[span.spanID] = Entry(span: span, clip: clip)
            }
        }
    }

    mutating func forget() {
        entries.removeAll()
        clipNames.removeAll()
    }

    subscript(id: VESpanID) -> Entry? { entries[id] }
}

extension ProjectStore {
    /// The result's own note and what it removed as a side effect, for the status line; nil when
    /// there is nothing to say.
    func notes(of result: VEEditResult) -> String? {
        let parts = [result.note.isEmpty ? nil : result.note, dropNote(for: result)].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// One sentence per transition or effect span the edit removed as a side effect ("Removed the
    /// fade in on “B”: “A” now touches its start."; "The Motion span before the new start of “B” was
    /// folded into the clip's values."); a transition's linked partner is named with it. Nil when
    /// the edit removed nothing (or only the transitions of clips it removed).
    func dropNote(for result: VEEditResult) -> String? {
        guard result.ok else { return nil }
        var sentences: [String] = []
        var described = Set<VESpanID>()
        var unknown = 0
        let dropped = result.droppedTransitionIDs.map(\.int64Value)
        for id in dropped where !described.contains(id) {
            described.insert(id)
            guard let entry = spanMemory[id] else {
                unknown += 1
                continue
            }
            // A transition that went with its own clip (the clip was deleted) needs no word.
            guard let owner = clips[entry.clip.clipID] else { continue }
            let linked = entry.span.linkedSpanID
            let withLinked = linked != 0 && dropped.contains(linked)
            if withLinked { described.insert(linked) }
            sentences.append(transitionDropSentence(entry, owner: owner, withLinked: withLinked))
        }
        var unknownSpans = 0
        for id in result.droppedSpanIDs.map(\.int64Value) {
            guard let entry = spanMemory[id], let clip = clips[entry.clip.clipID] else {
                unknownSpans += 1
                continue
            }
            let title = Self.title(of: entry.span, isAudio: clip.trackKind == .audio) + " span"
            if Self.staticValuesDiffer(entry.clip, clip) {
                sentences.append("The \(title) before the new start of “\(clip.name)” was folded into the clip's values.")
            } else {
                sentences.append("Removed the \(title) on “\(clip.name)”: nothing of it is left inside the clip.")
            }
        }
        // Never seen by the app (it cannot happen through the app's own edits): at least a count.
        if unknown > 0 {
            sentences.append(unknown == 1 ? "The edit removed a transition." : "The edit removed \(unknown) transitions.")
        }
        if unknownSpans > 0 {
            sentences.append(unknownSpans == 1 ? "The edit removed an effect span."
                : "The edit removed \(unknownSpans) effect spans.")
        }
        return sentences.isEmpty ? nil : sentences.joined(separator: " ")
    }

    private func transitionDropSentence(_ entry: SpanMemory.Entry, owner: VEClipInfo, withLinked: Bool) -> String {
        let audio = owner.trackKind == .audio
        let also = withLinked ? (audio ? " and its linked cross dissolve" : " and its linked crossfade") : ""
        switch entry.span.transitionStyle {
        case .fadeIn:
            if let before = touching(owner, atStart: true) {
                return "Removed the fade in on “\(owner.name)”\(also): “\(before.name)” now touches its start."
            }
            return "Removed the fade in on “\(owner.name)”\(also): it no longer fits the clip."
        case .fadeOut:
            return "Removed the fade out on “\(owner.name)”\(also): it no longer fits the clip."
        default:
            let what = audio ? "crossfade" : "cross dissolve"
            let partnerID = entry.span.partnerClipID
            let partnerName = clips[partnerID]?.name ?? spanMemory.clipNames[partnerID] ?? "the next clip"
            let between = "Removed the \(what) between “\(owner.name)” and “\(partnerName)”\(also)"
            if let after = touching(owner, atStart: false) {
                if after.clipID != partnerID {
                    // The rest of the owner itself (a split inside the dissolve), or another clip.
                    if after.assetID == owner.assetID, after.sourceIn == owner.sourceOut {
                        return between + ": “\(owner.name)” was split inside it."
                    }
                    return between + ": “\(after.name)” now follows “\(owner.name)”."
                }
                return between + ": the clips no longer have the media it needs."
            }
            return between + ": the clips no longer meet."
        }
    }

    /// The clip of `clip`'s track touching its start (`atStart`) or its end, as the model is now.
    private func touching(_ clip: VEClipInfo, atStart: Bool) -> VEClipInfo? {
        clips.values.first { other in
            other.trackID == clip.trackID && other.clipID != clip.clipID
                && (atStart ? other.timelineEnd == clip.timelineStart : other.timelineStart == clip.timelineEnd)
        }
    }

    /// Whether an edit changed the clip's static values (a span's held values folded into them).
    static func staticValuesDiffer(_ a: VEClipInfo, _ b: VEClipInfo) -> Bool {
        let u = a.videoParams
        let v = b.videoParams
        return u.x != v.x || u.y != v.y || u.scale != v.scale || u.rotationDegrees != v.rotationDegrees
            || u.opacity != v.opacity || a.audioParams.gainDb != b.audioParams.gainDb
    }
}
