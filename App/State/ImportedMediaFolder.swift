import AppKit
import Foundation
import FramewrightEngine

/// Where the media received from Photos goes: a "Media" folder the app made (with a marker file
/// inside, `.framewright-media`), either next to the project file, derived from the project's
/// location every time, or inside a folder the user chose once (always for an untitled project,
/// and when the app may not write next to the project, as in the sandbox for a project opened
/// through a panel). Only a folder the user chose is stored with the project
/// (`VEEngine.mediaFolderBookmark`): the folder next to the project is never stored, so a project
/// saved elsewhere (Save As) or a duplicated project folder uses its own Media folder. An existing
/// folder called Media is adopted only when the marker says the app made it; otherwise the app
/// makes "Media 2" (and so on) beside it. New/Open forget the folder (`reset()`).
@MainActor
final class ImportedMediaFolder {
    static let folderName = "Media"
    /// The file inside every Media folder the app made.
    static let markerName = ".framewright-media"

    /// Asks for a folder (`suggested` to start in, `message` to explain); nil when cancelled.
    /// Tests replace it.
    var chooseFolder: (_ suggested: URL?, _ message: String) -> URL? = { suggested, message in
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = suggested
        panel.prompt = "Choose"
        panel.message = message
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// The Trash folders a stored folder may not be in (tests replace them).
    var trashFolders: [URL] = ImportedMediaFolder.systemTrashFolders()

    /// The folder in use for this project (nil until first needed).
    private(set) var folder: URL?
    /// The project file `folder` was derived from; nil for a folder the user chose.
    private var derivedFrom: URL?
    /// Times the user was asked (diagnostics and tests).
    private(set) var promptCount = 0
    /// The security scope of the folder the user chose (held also by promises still receiving).
    private(set) var lease: SecurityScopeLease?

    /// Forgets the folder (the project changed). Promises still receiving keep their own hold on
    /// its security scope (`SecurityScopeLease`), so their late files can still be deleted.
    func reset() {
        lease = nil
        folder = nil
        derivedFrom = nil
    }

    /// The folder for `engine`'s project, asking when needed; nil when the user cancelled.
    func resolve(for engine: VEEngine) -> URL? {
        if let folder, Self.isWritableDirectory(folder), derivedFrom == nil || derivedFrom == engine.projectURL {
            return folder
        }
        folder = nil
        derivedFrom = nil
        // A folder the user chose, stored with the project.
        if let data = engine.mediaFolderBookmark, let url = useBookmark(data, engine: engine) {
            folder = url
            return url
        }
        // Media next to the project file, derived from where the project is now (never stored).
        if let project = engine.projectURL,
           let media = Self.prepareMediaFolder(in: project.deletingLastPathComponent()) {
            lease = nil
            folder = media
            derivedFrom = project
            return media
        }
        let message = engine.projectURL == nil
            ? "Choose where to keep media imported from Photos for this untitled project. Framewright makes a "
                + "“\(Self.folderName)” folder there and remembers it with the project."
            : "Framewright cannot make a “\(Self.folderName)” folder next to “\(engine.projectName)”. Choose "
                + "where to keep media imported from Photos: Framewright makes a “\(Self.folderName)” folder there."
        promptCount += 1
        guard let chosen = chooseFolder(engine.projectURL?.deletingLastPathComponent(), message) else { return nil }
        let scope = SecurityScopeLease(url: chosen)
        guard Self.isWritableDirectory(chosen), !isInTrash(chosen),
              let media = Self.prepareMediaFolder(in: chosen) else { return nil }
        lease = scope
        folder = media
        let bookmark = (try? media.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil,
                                                relativeTo: nil))
            ?? (try? media.bookmarkData())
        if let bookmark, bookmark != engine.mediaFolderBookmark {
            engine.mediaFolderBookmark = bookmark
        }
        return media
    }

    /// The project is about to be saved at `newURL`: a stored folder that is the Media folder next to
    /// the project's old location (the folder of an earlier version, or one the user made there) is
    /// dropped, so the project saved elsewhere uses the Media folder next to its new location.
    func projectWillMove(to newURL: URL, engine: VEEngine) {
        guard let old = engine.projectURL?.deletingLastPathComponent().standardizedFileURL,
              old.resolvingSymlinksInPath() != newURL.deletingLastPathComponent().standardizedFileURL
                .resolvingSymlinksInPath() else { return }
        if let data = engine.mediaFolderBookmark, let stored = Self.resolve(bookmark: data)?.url,
           Self.isMediaFolder(stored, besideProjectIn: old) {
            engine.mediaFolderBookmark = nil
            reset()
        } else if derivedFrom != nil {
            reset() // derived again from the new location
        }
    }

    /// "Media" inside `parent`, made by the app: created with the marker, or an existing one that has
    /// the marker (a folder with that name the user made is left alone: "Media 2", ... instead). Nil
    /// when the app may not write there.
    static func prepareMediaFolder(in parent: URL) -> URL? {
        let fileManager = FileManager.default
        var index = 1
        while index < 100 {
            let name = index == 1 ? folderName : "\(folderName) \(index)"
            let candidate = parent.appendingPathComponent(name, isDirectory: true)
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory) {
                if isDirectory.boolValue, hasMarker(candidate), isWritableDirectory(candidate) {
                    return candidate
                }
                index += 1
                continue
            }
            do {
                try fileManager.createDirectory(at: candidate, withIntermediateDirectories: false)
                try markerText.write(to: candidate.appendingPathComponent(markerName), atomically: true, encoding: .utf8)
            } catch {
                return nil
            }
            return isWritableDirectory(candidate) ? candidate : nil
        }
        return nil
    }

    static func hasMarker(_ folder: URL) -> Bool {
        FileManager.default.fileExists(atPath: folder.appendingPathComponent(markerName).path)
    }

    static func isWritableDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
            && FileManager.default.isWritableFile(atPath: url.path)
    }

    private static let markerText = "Framewright keeps the photos and videos it receives from Photos for a project here.\n"

    /// Whether `url` is the Media folder next to a project in `directory` ("Media", "Media 2", ...,
    /// made by the app or by an earlier version, which wrote no marker).
    private static func isMediaFolder(_ url: URL, besideProjectIn directory: URL) -> Bool {
        let parent = url.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
        guard parent == directory.standardizedFileURL.resolvingSymlinksInPath() else { return false }
        let name = url.lastPathComponent
        return name == folderName || (name.hasPrefix(folderName + " ") && hasMarker(url))
    }

    private static func resolve(bookmark data: Data) -> (url: URL, stale: Bool)? {
        var stale = false
        if let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI, .withoutMounting],
                              relativeTo: nil, bookmarkDataIsStale: &stale) {
            return (url, stale)
        }
        if let url = try? URL(resolvingBookmarkData: data, options: [.withoutUI, .withoutMounting], relativeTo: nil,
                              bookmarkDataIsStale: &stale) {
            return (url, stale)
        }
        return nil
    }

    /// The stored folder when it can be used: resolved, not in the Trash, writable, and not the
    /// Media folder next to the project's old location (an earlier version stored that one too; a
    /// duplicated project folder's copy would still point at the original's). A stale bookmark is
    /// rewritten; the security scope is held only for a folder that is used.
    private func useBookmark(_ data: Data, engine: VEEngine) -> URL? {
        guard let (url, stale) = Self.resolve(bookmark: data) else { return nil }
        if isInTrash(url) {
            engine.mediaFolderBookmark = nil // moved to the Trash: never import there
            return nil
        }
        if let project = engine.projectURL, url.lastPathComponent == Self.folderName, !Self.hasMarker(url),
           url.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
               != project.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath() {
            // An earlier version's "Media next to the project" of another location: derive it again.
            engine.mediaFolderBookmark = nil
            return nil
        }
        let scope = SecurityScopeLease(url: url)
        guard Self.isWritableDirectory(url) else { return nil } // the scope is released here
        lease = scope
        if stale, let fresh = (try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil,
                                                     relativeTo: nil)) ?? (try? url.bookmarkData()) {
            engine.mediaFolderBookmark = fresh
        }
        return url
    }

    private func isInTrash(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        if url.pathComponents.contains(".Trash") || url.pathComponents.contains(".Trashes") { return true }
        return trashFolders.contains { trash in
            let trashPath = trash.standardizedFileURL.resolvingSymlinksInPath().path
            return path == trashPath || path.hasPrefix(trashPath + "/")
        }
    }

    private static func systemTrashFolders() -> [URL] {
        var folders = FileManager.default.urls(for: .trashDirectory, in: .userDomainMask)
        // Sandboxed, the user domain's Trash is the container's; the real one is in the home folder.
        if let home = getpwuid(getuid())?.pointee.pw_dir {
            folders.append(URL(fileURLWithPath: String(cString: home)).appendingPathComponent(".Trash"))
        }
        return folders
    }
}
