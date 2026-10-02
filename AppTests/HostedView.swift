import AppKit
import SwiftUI
import XCTest

/// A SwiftUI view hosted in a window, as the app shows it, for tests that look at what it draws: `settle()`
/// lets SwiftUI apply the updates a model change asked for, `bitmap()` draws the view offscreen into a bitmap
/// (its own drawing, never a capture of the screen), `pixels()` is that bitmap's bytes, to compare two drawings.
@MainActor
final class HostedView {
    let window: NSWindow
    let host: NSView

    init<Content: View>(_ content: Content, size: NSSize) {
        window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered,
                          defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: content)
        host.frame = NSRect(origin: .zero, size: size)
        window.contentView = host
        self.host = host
        window.orderFront(nil)
    }

    /// Lets SwiftUI run the updates pending on the main queue and lay the view out again.
    func settle() async {
        for _ in 0 ..< 5 {
            try? await Task.sleep(nanoseconds: 20_000_000)
            host.layoutSubtreeIfNeeded()
        }
    }

    /// The view's drawing.
    func bitmap() -> NSBitmapImageRep? {
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    /// The bytes of the view's drawing (equal drawings, equal bytes), drawn as the frontmost window (an
    /// inactive window draws some controls differently) once it no longer changes (a control may animate to its
    /// new state), or after about a second.
    func pixels() async -> Data {
        window.orderFront(nil)
        await settle()
        var drawing = currentPixels()
        for _ in 0 ..< 10 {
            await settle()
            let next = currentPixels()
            if next == drawing { break }
            drawing = next
        }
        return drawing
    }

    private func currentPixels() -> Data {
        guard let rep = bitmap(), let data = rep.bitmapData else { return Data() }
        return Data(bytes: data, count: rep.bytesPerPlane * rep.numberOfPlanes)
    }

    func close() {
        window.orderOut(nil)
        window.close()
    }
}
