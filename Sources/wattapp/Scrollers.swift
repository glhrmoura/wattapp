import SwiftUI
import AppKit

final class ThinScroller: NSScroller {
    private static let thickness: CGFloat = 10
    private static let knobWidth: CGFloat = 5

    override class var isCompatibleWithOverlayScrollers: Bool { true }

    override class func scrollerWidth(for controlSize: NSControl.ControlSize, scrollerStyle: NSScroller.Style) -> CGFloat {
        thickness
    }

    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {}

    override func draw(_ dirtyRect: NSRect) {
        drawKnob()
    }

    override func drawKnob() {
        let knob = rect(for: .knob)
        guard !knob.isEmpty else { return }
        let rect = NSRect(
            x: knob.midX - Self.knobWidth / 2,
            y: knob.minY + 2,
            width: Self.knobWidth,
            height: max(knob.height - 4, 0)
        )
        NSColor.labelColor.withAlphaComponent(0.22).setFill()
        NSBezierPath(roundedRect: rect, xRadius: Self.knobWidth / 2, yRadius: Self.knobWidth / 2).fill()
    }
}

private final class ScrollerConfiguratorView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self)
        guard window != nil else { return }
        configure()
        DispatchQueue.main.async { [weak self] in self?.configure() }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(styleChanged),
            name: NSScroller.preferredScrollerStyleDidChangeNotification,
            object: nil
        )
    }

    @objc private func styleChanged() {
        DispatchQueue.main.async { [weak self] in self?.configure() }
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        configure()
    }

    private func configure() {
        guard let scrollView = enclosingScrollView else { return }
        if !(scrollView.verticalScroller is ThinScroller) {
            scrollView.verticalScroller = ThinScroller()
        }
        guard scrollView.scrollerStyle != .overlay || !scrollView.autohidesScrollers || scrollView.hasHorizontalScroller else { return }
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        scrollView.hasHorizontalScroller = false
    }
}

private struct ScrollerConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { ScrollerConfiguratorView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

extension View {
    func thinScrollers() -> some View {
        background(ScrollerConfigurator().frame(width: 0, height: 0))
    }
}
