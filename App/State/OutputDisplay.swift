import AppKit
import Combine
import FramewrightEngine

/// A display the program monitor can be shown on.
struct DisplayScreen: Equatable {
    /// CGDirectDisplayID (NSScreen's "NSScreenNumber").
    let id: UInt32
    /// The screen's frame in global screen coordinates.
    let frame: CGRect
    let name: String
}

/// Where the displays come from (the system's screens; tests inject their own).
@MainActor
protocol ScreenProviding {
    var screens: [DisplayScreen] { get }
    /// The display showing `window`, if any.
    func screenID(of window: NSWindow?) -> UInt32?
}

/// The system's screens (NSScreen).
struct SystemScreens: ScreenProviding {
    var screens: [DisplayScreen] {
        NSScreen.screens.compactMap { screen in
            Self.id(of: screen).map { DisplayScreen(id: $0, frame: screen.frame, name: screen.localizedName) }
        }
    }

    func screenID(of window: NSWindow?) -> UInt32? {
        window?.screen.flatMap(Self.id(of:))
    }

    static func id(of screen: NSScreen) -> UInt32? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}

/// The program monitor on a second display (View > Program Monitor on Second Display), like
/// Premiere's and Resolve's full-screen output: a borderless window covering another display than
/// the editor window's, showing a `VEPreviewView` that the engine drives from the program's
/// playback controller (`VEEngine.attachOutputView`: the pictures are decoded once, each view maps
/// them itself, and both show the same frame of the same clock). The engine runs and pauses the
/// view with the program's transport, so it plays, pauses and refuses to play during an export
/// exactly like the in-window monitor.
///
/// The window closes on Escape (it becomes key when clicked; the transport keys work in it as
/// in the editor), from the menu again, when its display goes away (the status line says so) and
/// when the editor window closes. Available only while there is a display other than the editor
/// window's.
@MainActor
final class OutputDisplayController: ObservableObject {
    /// The output window is up.
    @Published private(set) var isShowing = false
    /// A display other than the editor window's exists (the menu item is enabled).
    @Published private(set) var isAvailable = false

    /// What the status line says when the output's display was disconnected.
    static let screenGoneMessage = "The second display was disconnected; the program output window closed."

    private(set) var window: OutputWindow?
    /// The display the output window covers.
    private(set) var screenID: UInt32?
    var screenProvider: ScreenProviding {
        didSet { screensChanged() }
    }

    private weak var store: ProjectStore?
    private let center: NotificationCenter
    private var observers: [NSObjectProtocol] = []

    init(store: ProjectStore, screens: ScreenProviding, center: NotificationCenter = .default) {
        self.store = store
        self.center = center
        screenProvider = screens
        func observe(_ name: Notification.Name, _ handler: @escaping @MainActor (OutputDisplayController, Notification) -> Void) {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                nonisolated(unsafe) let received = note
                MainActor.assumeIsolated {
                    if let self { handler(self, received) }
                }
            })
        }
        observe(NSApplication.didChangeScreenParametersNotification) { controller, _ in controller.screensChanged() }
        observe(NSWindow.didChangeScreenNotification) { controller, note in
            if (note.object as? NSWindow) === controller.store?.editorWindow { controller.screensChanged() }
        }
        observe(NSWindow.willCloseNotification) { controller, note in
            // The editor window closing takes its output window with it (the app then quits).
            if let closing = note.object as? NSWindow, closing === controller.store?.editorWindow {
                controller.hide()
            }
        }
        refreshAvailability()
    }

    deinit {
        for observer in observers {
            center.removeObserver(observer)
        }
    }

    /// The display the output would use: the first one the editor window is not on.
    var targetScreen: DisplayScreen? {
        let screens = screenProvider.screens
        guard screens.count > 1 else { return nil }
        let editor = screenProvider.screenID(of: store?.editorWindow)
        return screens.first { $0.id != editor }
    }

    func toggle() {
        if isShowing { hide() } else { show() }
    }

    /// Opens the output window on the other display and attaches it to the engine. Does nothing
    /// without a second display.
    func show() {
        guard !isShowing, let store, let screen = targetScreen else { return }
        let output = OutputWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        output.isReleasedWhenClosed = false
        output.backgroundColor = .black
        // Above the menu bar of its display (a full-screen output), on every Space.
        output.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1)
        output.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        output.hidesOnDeactivate = false
        output.title = "Program Output"
        let view = VEPreviewView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.autoresizingMask = [.width, .height]
        output.contentView = view
        output.onCancel = { [weak self] in self?.hide() }
        output.setFrame(screen.frame, display: false)
        output.orderFrontRegardless()
        store.engine.attachOutputView(view)
        window = output
        screenID = screen.id
        isShowing = true
    }

    /// Closes the output window (the engine stops driving its view).
    func hide() {
        guard isShowing || window != nil else { return }
        if let view = window?.contentView as? VEPreviewView, store?.engine.outputView === view {
            store?.engine.detachOutputView()
        }
        window?.onCancel = nil
        window?.orderOut(nil)
        window?.close()
        window = nil
        screenID = nil
        isShowing = false
    }

    /// The displays changed (connected, disconnected, rearranged) or the editor window moved to
    /// another one: the output closes when its display is gone, and availability is re-read.
    func screensChanged() {
        if isShowing, let screenID {
            if let screen = screenProvider.screens.first(where: { $0.id == screenID }) {
                // Still there (maybe resized or moved in the arrangement): cover it again.
                window?.setFrame(screen.frame, display: true)
            } else {
                hide()
                store?.statusMessage = Self.screenGoneMessage
            }
        }
        refreshAvailability()
    }

    private func refreshAvailability() {
        let available = targetScreen != nil
        if available != isAvailable { isAvailable = available }
    }
}

/// The borderless output window: it can become key (so Escape and the transport keys reach the
/// app while it is focused) and closes on Escape.
final class OutputWindow: NSWindow {
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Escape
            onCancel?()
        } else {
            super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}
