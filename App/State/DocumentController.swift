import AppKit
import Foundation
import UniformTypeIdentifiers

/// File menu behaviour for the single-window app: New / Open / Open Recent / Save / Save As,
/// unsaved-changes confirmation and the recent projects list.
///
/// Recent projects are kept as security-scoped bookmarks in UserDefaults so they can be
/// reopened from inside the App Sandbox.
@MainActor
final class DocumentController: ObservableObject {
    static let recentsKey = "recentProjectBookmarks"
    static let maxRecents = 10

    let store: ProjectStore
    @Published private(set) var recentURLs: [URL] = []
    /// Security-scoped access to the open project file (opened from recents).
    private var accessedProjectURL: URL?
    private let defaults: UserDefaults

    init(store: ProjectStore, defaults: UserDefaults = .standard) {
        self.store = store
        self.defaults = defaults
        recentURLs = resolveRecents()
    }

    // MARK: Actions

    func newProject() {
        guard confirmDiscardingChanges() else { return }
        store.newProject()
        stopAccessingProject()
    }

    func openWithPanel() {
        guard confirmDiscardingChanges() else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.videditProject]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url)
    }

    func openRecent(_ url: URL) {
        guard confirmDiscardingChanges() else { return }
        open(url)
    }

    /// Opens `url` (no confirmation); reports errors in an alert.
    func open(_ url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        do {
            try store.open(url: url)
            stopAccessingProject()
            if accessing { accessedProjectURL = url }
            noteRecent(url)
        } catch {
            if accessing { url.stopAccessingSecurityScopedResource() }
            presentError(error, title: "The project could not be opened.")
        }
    }

    /// Saves to the current file, or asks where. Returns false if cancelled or failed.
    @discardableResult
    func save() -> Bool {
        if let url = store.projectURL {
            return save(to: url)
        }
        return saveAs()
    }

    @discardableResult
    func saveAs() -> Bool {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.videditProject]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = store.projectName + ".videdit"
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        return save(to: url)
    }

    private func save(to url: URL) -> Bool {
        do {
            try store.save(to: url)
            noteRecent(url)
            return true
        } catch {
            presentError(error, title: "The project could not be saved.")
            return false
        }
    }

    /// Asks to save unsaved changes. Returns true when it is fine to continue (saved or
    /// discarded), false when the user cancelled.
    func confirmDiscardingChanges() -> Bool {
        guard store.isDirty else { return true }
        let alert = NSAlert()
        alert.messageText = "Do you want to save the changes made to “\(store.projectName)”?"
        alert.informativeText = "Your changes will be lost if you don’t save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don’t Save")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return save()
        case .alertThirdButtonReturn:
            return true
        default:
            return false
        }
    }

    // MARK: Recents

    func clearRecents() {
        defaults.removeObject(forKey: Self.recentsKey)
        recentURLs = []
    }

    private func noteRecent(_ url: URL) {
        let scoped = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil,
                                           relativeTo: nil)
        guard let bookmark = scoped ?? (try? url.bookmarkData()) else { return }
        var entries = (defaults.array(forKey: Self.recentsKey) as? [Data]) ?? []
        entries.removeAll { data in
            var stale = false
            let existing = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI],
                                    relativeTo: nil, bookmarkDataIsStale: &stale)
            return existing?.standardizedFileURL == url.standardizedFileURL
        }
        entries.insert(bookmark, at: 0)
        defaults.set(Array(entries.prefix(Self.maxRecents)), forKey: Self.recentsKey)
        recentURLs = resolveRecents()
    }

    private func resolveRecents() -> [URL] {
        let entries = (defaults.array(forKey: Self.recentsKey) as? [Data]) ?? []
        return entries.compactMap { data in
            var stale = false
            return (try? URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI], relativeTo: nil,
                             bookmarkDataIsStale: &stale))
                ?? (try? URL(resolvingBookmarkData: data, options: [.withoutUI], relativeTo: nil,
                             bookmarkDataIsStale: &stale))
        }
    }

    private func stopAccessingProject() {
        accessedProjectURL?.stopAccessingSecurityScopedResource()
        accessedProjectURL = nil
    }

    private func presentError(_ error: Error, title: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }
}
