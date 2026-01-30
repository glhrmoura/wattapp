import SwiftUI
import AppKit
import ImageIO
import QuartzCore

final class ImageAnimation {
    let frames: [CGImage]
    let keyTimes: [NSNumber]
    let duration: CFTimeInterval

    init(frames: [CGImage], delays: [Double]) {
        self.frames = frames
        let total = delays.reduce(0, +)
        duration = total
        var elapsed = 0.0
        var times: [NSNumber] = []
        for delay in delays {
            times.append(NSNumber(value: elapsed / total))
            elapsed += delay
        }
        times.append(1)
        keyTimes = times
    }

    nonisolated(unsafe) private static let cache: NSCache<NSString, ImageAnimation> = {
        let cache = NSCache<NSString, ImageAnimation>()
        cache.countLimit = 24
        return cache
    }()

    static func load(path: String) -> ImageAnimation? {
        if let cached = cache.object(forKey: path as NSString) { return cached }
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
        let count = CGImageSourceGetCount(source)
        guard count > 1 else { return nil }
        var frames: [CGImage] = []
        var delays: [Double] = []
        for index in 0..<count {
            guard let frame = CGImageSourceCreateImageAtIndex(source, index, nil) else { continue }
            frames.append(frame)
            delays.append(delay(source, index))
        }
        guard frames.count > 1 else { return nil }
        let animation = ImageAnimation(frames: frames, delays: delays)
        cache.setObject(animation, forKey: path as NSString)
        return animation
    }

    private static func delay(_ source: CGImageSource, _ index: Int) -> Double {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] ?? [:]
        let dictionaries: [(CFString, CFString, CFString)] = [
            (kCGImagePropertyWebPDictionary, kCGImagePropertyWebPUnclampedDelayTime, kCGImagePropertyWebPDelayTime),
            (kCGImagePropertyGIFDictionary, kCGImagePropertyGIFUnclampedDelayTime, kCGImagePropertyGIFDelayTime),
            (kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGUnclampedDelayTime, kCGImagePropertyAPNGDelayTime)
        ]
        for (dictionaryKey, unclampedKey, clampedKey) in dictionaries {
            guard let dictionary = properties[dictionaryKey] as? [CFString: Any] else { continue }
            let value = seconds(dictionary[unclampedKey]) ?? seconds(dictionary[clampedKey]) ?? 0
            return value > 0.011 ? value : 0.1
        }
        return 0.1
    }

    private static func seconds(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let text = value as? String { return Double(text) }
        return nil
    }
}

struct AnimatedImage: NSViewRepresentable {
    let animation: ImageAnimation

    func makeNSView(context: Context) -> AnimatedLayerView {
        AnimatedLayerView()
    }

    func updateNSView(_ view: AnimatedLayerView, context: Context) {
        view.play(animation)
    }
}

final class AnimatedLayerView: NSView {
    private weak var current: ImageAnimation?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.contentsGravity = .resizeAspect
    }

    required init?(coder: NSCoder) {
        fatalError()
    }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }

    func play(_ animation: ImageAnimation) {
        guard let layer, current !== animation || layer.animation(forKey: "frames") == nil else { return }
        current = animation
        layer.contents = animation.frames.first
        let keyframes = CAKeyframeAnimation(keyPath: "contents")
        keyframes.values = animation.frames + [animation.frames.last!]
        keyframes.keyTimes = animation.keyTimes
        keyframes.calculationMode = .discrete
        keyframes.duration = animation.duration
        keyframes.repeatCount = .infinity
        keyframes.isRemovedOnCompletion = false
        layer.add(keyframes, forKey: "frames")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, let current, layer?.animation(forKey: "frames") == nil {
            self.current = nil
            play(current)
        }
    }
}
