import AppKit
import PhotosUI
import FramewrightEngine

/// File > Import from Photos…: the system photo picker (`PHPickerViewController`, which runs out of
/// process and needs no Photos library entitlement or permission) as a sheet on the editor window.
/// Several items can be picked; each arrives through the same path as a Photos drop (the project's
/// Media folder, the bin's progress list, Live Photo choice, then the normal import).
@MainActor
final class PhotosImportPicker: NSObject, ObservableObject, PHPickerViewControllerDelegate {
    private unowned let store: ProjectStore
    /// The picker shown, if any.
    @Published private(set) var picker: PHPickerViewController?
    /// Shows the picker as a sheet of `host` (tests replace it).
    var presentSheet: (_ picker: PHPickerViewController, _ host: NSViewController) -> Void = { picker, host in
        host.presentAsSheet(picker)
    }
    /// Pickers presented (diagnostics and tests).
    private(set) var presentations = 0

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

    /// Whether the picker is on screen (File > Import from Photos… is disabled meanwhile). A picker
    /// whose sheet went away without telling its delegate is not.
    var isPresenting: Bool {
        picker?.presentingViewController != nil
    }

    /// Shows the picker as a sheet on the editor window.
    func present() {
        if picker != nil, !isPresenting {
            picker = nil // its sheet went away without the delegate hearing of it
        }
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
        presentations += 1
        presentSheet(controller, host)
    }

    nonisolated func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        MainActor.assumeIsolated {
            picker.dismiss(nil)
            if self.picker === picker { self.picker = nil }
            finishPicking(results.map(\.itemProvider))
        }
    }

    /// What was picked, received once the sheet has gone: receiving may ask for the Media folder in
    /// a modal panel, which must not run while the sheet is still dismissing.
    func finishPicking(_ providers: [NSItemProvider]) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.receivePicked(providers)
            }
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
