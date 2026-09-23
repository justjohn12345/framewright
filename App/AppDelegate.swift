import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set by the app scene once it exists. Project files the Finder asked to open before then
    /// (a cold launch by double-clicking a project) are opened when it is set.
    @MainActor weak var documents: DocumentController? {
        didSet { openPendingProjects() }
    }

    @MainActor private(set) var pendingProjectURLs: [URL] = []

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        true
    }

    @MainActor
    func applicationShouldTerminate(_: NSApplication) -> NSApplication.TerminateReply {
        guard let documents else { return .terminateNow }
        return documents.shouldTerminate() ? .terminateNow : .terminateCancel
    }

    /// Project files opened from the Finder.
    @MainActor
    func application(_: NSApplication, open urls: [URL]) {
        guard let url = urls.first(where: { $0.pathExtension == "videdit" }) else { return }
        if let documents {
            documents.openRecent(url)
        } else {
            pendingProjectURLs = [url] // the window is not up yet: open it when it is
        }
    }

    @MainActor
    private func openPendingProjects() {
        guard let documents, let url = pendingProjectURLs.first else { return }
        pendingProjectURLs = []
        documents.open(url)
    }
}
