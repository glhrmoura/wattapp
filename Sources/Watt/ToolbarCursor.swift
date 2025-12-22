import AppKit

@MainActor
final class ToolbarCursor {
    static let shared = ToolbarCursor()
    private var monitor: Any?
    private var observer: NSObjectProtocol?
    private var active = false

    func install() {
        guard monitor == nil else { return }
        for window in NSApp.windows { window.acceptsMouseMovedEvents = true }
        observer = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                for window in NSApp.windows { window.acceptsMouseMovedEvents = true }
            }
        }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .cursorUpdate, .mouseEntered, .mouseExited, .leftMouseUp]) { [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        let over = isOverToolbarControl(event)
        if over {
            NSCursor.pointingHand.set()
            active = true
            return event.type == .cursorUpdate ? nil : event
        }
        if active {
            active = false
            NSCursor.arrow.set()
        }
        return event
    }

    private func isOverToolbarControl(_ event: NSEvent) -> Bool {
        guard let window = event.window, let frameView = window.contentView?.superview else { return false }
        let point = frameView.convert(event.locationInWindow, from: nil)
        guard var view = frameView.hitTest(point) else { return false }
        var control: NSControl?
        var inToolbar = false
        while true {
            if control == nil, let found = view as? NSControl { control = found }
            if NSStringFromClass(type(of: view)).contains("Toolbar") { inToolbar = true }
            guard let parent = view.superview else { break }
            view = parent
        }
        guard inToolbar, let control else { return false }
        return control.isEnabled && !(control is NSTextField)
    }
}
