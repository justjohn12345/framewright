import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set by the app scene once it exists.
    @MainActor weak var documents: DocumentController?

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        true
    }

    @MainActor
    func applicationShouldTerminate(_: NSApplication) -> NSApplication.TerminateReply {
        guard let documents else { return .terminateNow }
        return documents.confirmDiscardingChanges() ? .terminateNow : .terminateCancel
    }

    /// Project files opened from the Finder.
    @MainActor
    func application(_: NSApplication, open urls: [URL]) {
        guard let documents, let url = urls.first(where: { $0.pathExtension == "videdit" }) else { return }
        documents.openRecent(url)
    }
}
