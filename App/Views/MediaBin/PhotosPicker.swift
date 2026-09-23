import AppKit
import PhotosUI
import FramewrightEngine

/// File > Import from Photos…: the system photo picker (`PHPickerViewController`, which runs out of
/// process and needs no Photos library entitlement or permission) as a sheet on the editor window.
/// Several items can be picked; each arrives through the same path as a Photos drop (the project's
/// Media folder, the bin's progress list, Live Photo choice, then the normal import).
@MainActor
final class PhotosImportPicker: NSObject, PHPickerViewControllerDelegate {
    private unowned let store: ProjectStore
    /// The picker on screen, if any.
    private(set) var picker: PHPickerViewController?

    init(store: ProjectStore) {
        self.store = store
    }

    /// Photos and videos (Live Photos included), as many as the user likes, in their current
    /// form: HEIC stays HEIC and HEVC stays HEVC (no transcoding to compatible formats).
    static func configuration() -> PHPickerConfiguration {
        var configuration = PHPickerConfiguration()
        configuration.selectionLimit = 0
        configuration.filter = .any(of: [.images, .videos, .livePhotos])
        configuration.preferredAssetRepresentationMode = .current
        return configuration
    }

    /// Shows the picker as a sheet on the editor window.
    func present() {
        guard picker == nil else { return }
        guard !store.isGestureActive else {
            store.statusMessage = "Finish the current drag first."
            return
        }
        guard let host = store.editorWindow?.contentViewController else {
            store.statusMessage = "Open the editor window to import from Photos."
            return
        }
        let controller = PHPickerViewController(configuration: Self.configuration())
        controller.delegate = self
        picker = controller
        host.presentAsSheet(controller)
    }

    nonisolated func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        MainActor.assumeIsolated {
            picker.dismiss(nil)
            self.picker = nil
            receivePicked(results.map(\.itemProvider))
        }
    }

    /// Receives what was picked (nothing when the picker was cancelled).
    func receivePicked(_ providers: [NSItemProvider]) {
        guard !providers.isEmpty else { return }
        let promises = providers.compactMap { ItemProviderPromise(provider: $0) }
        if promises.count < providers.count {
            store.statusMessage = "Some picked items are not media Framewright can import."
        }
        store.incoming.receive(promises)
    }
}
