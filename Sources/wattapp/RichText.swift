import SwiftUI
import AppKit

enum RichText {
    static let limit = 800
    static let moreURL = URL(string: "wattapp-more://expand")!

    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    static func firstLink(in text: String) -> URL? {
        detector?.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))?.url
    }

    static func truncated(_ text: String) -> String? {
        guard text.count > limit else { return nil }
        let cut = text.prefix(limit)
        let end = cut.lastIndex(where: { $0 == " " || $0 == "\n" }) ?? cut.endIndex
        return String(cut[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let intentKey = NSAttributedString.Key("wattappIntent")

    static func inline(_ text: String) -> AttributedString {
        let marked = NSMutableAttributedString(string: text)
        for (marker, intent) in [("```", InlinePresentationIntent.code), ("*", .stronglyEmphasized), ("_", .emphasized), ("~", .strikethrough)] {
            _ = apply(marker, to: marked, multiline: marker == "```") { range in
                let current = marked.attribute(intentKey, at: range.location, effectiveRange: nil) as? UInt ?? 0
                marked.addAttribute(intentKey, value: current | intent.rawValue, range: range)
            }
        }
        let plain = marked.string
        var result = AttributedString(plain)
        marked.enumerateAttribute(intentKey, in: NSRange(location: 0, length: marked.length)) { value, range, _ in
            guard let raw = value as? UInt,
                  let bounds = Range(range, in: plain),
                  let lower = AttributedString.Index(bounds.lowerBound, within: result),
                  let upper = AttributedString.Index(bounds.upperBound, within: result) else { return }
            result[lower..<upper].inlinePresentationIntent = InlinePresentationIntent(rawValue: raw)
        }
        return result
    }

    static func build(_ text: String, trailing: String, more: Bool) -> NSAttributedString? {
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let result = NSMutableAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.labelColor])
        var changed = false
        changed = apply("```", to: result, multiline: true) { result.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: font.pointSize, weight: .regular), range: $0) } || changed
        changed = apply("*", to: result) { convert(result, $0, .boldFontMask) } || changed
        changed = apply("_", to: result) { convert(result, $0, .italicFontMask) } || changed
        changed = apply("~", to: result) { result.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: $0) } || changed
        for (range, url) in links(in: result.string) {
            result.addAttributes([
                .link: url,
                .foregroundColor: Palette.linkNS,
                .underlineStyle: NSUnderlineStyle.single.rawValue
            ], range: range)
            changed = true
        }
        if more {
            result.append(NSAttributedString(string: "… ", attributes: [.font: font, .foregroundColor: NSColor.labelColor]))
            result.append(NSAttributedString(string: "Ler mais", attributes: [
                .font: NSFont.systemFont(ofSize: font.pointSize, weight: .medium),
                .foregroundColor: Palette.linkNS,
                .link: moreURL
            ]))
            changed = true
        }
        guard changed else { return nil }
        result.append(NSAttributedString(string: trailing, attributes: [.font: font]))
        return result
    }

    private static func links(in text: String) -> [(NSRange, URL)] {
        guard let detector else { return [] }
        return detector.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            match.url.map { (match.range, $0) }
        }
    }

    private static func apply(_ marker: String, to string: NSMutableAttributedString, multiline: Bool = false, style: (NSRange) -> Void) -> Bool {
        let m = NSRegularExpression.escapedPattern(for: marker)
        let body = multiline ? "[\\s\\S]+?" : ".+?"
        guard let regex = try? NSRegularExpression(pattern: "(?<![\\p{L}\\p{N}])\(m)(?=\\S)(\(body))(?<=\\S)\(m)(?![\\p{L}\\p{N}])") else { return false }
        let protected = links(in: string.string).map(\.0)
        let matches = regex.matches(in: string.string, range: NSRange(location: 0, length: string.length)).filter { match in
            !protected.contains { NSIntersectionRange($0, match.range).length > 0 }
        }
        let length = (marker as NSString).length
        for match in matches.reversed() {
            style(match.range(at: 1))
            string.deleteCharacters(in: NSRange(location: NSMaxRange(match.range) - length, length: length))
            string.deleteCharacters(in: NSRange(location: match.range.location, length: length))
        }
        return !matches.isEmpty
    }

    private static func convert(_ string: NSMutableAttributedString, _ range: NSRange, _ trait: NSFontTraitMask) {
        string.enumerateAttribute(.font, in: range) { value, sub, _ in
            guard let font = value as? NSFont else { return }
            string.addAttribute(.font, value: NSFontManager.shared.convert(font, toHaveTrait: trait), range: sub)
        }
    }
}

struct LinkText: NSViewRepresentable {
    let content: NSAttributedString
    var onMore: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSTextView {
        let view = NSTextView()
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.isVerticallyResizable = false
        view.isHorizontallyResizable = false
        view.linkTextAttributes = [.cursor: NSCursor.pointingHand]
        view.delegate = context.coordinator
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateNSView(_ view: NSTextView, context: Context) {
        context.coordinator.onMore = onMore
        if view.attributedString() != content {
            view.textStorage?.setAttributedString(content)
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: NSTextView, context: Context) -> CGSize? {
        let maxWidth = proposal.width.map { $0.isFinite ? $0 : .greatestFiniteMagnitude } ?? .greatestFiniteMagnitude
        let storage = NSTextStorage(attributedString: content)
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: maxWidth, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container)
        return CGSize(width: ceil(min(used.width, maxWidth)), height: ceil(used.height))
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var onMore: () -> Void = {}

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:))
            guard let url else { return false }
            if url == RichText.moreURL {
                onMore()
            } else {
                NSWorkspace.shared.open(url)
            }
            return true
        }
    }
}

struct LinkPreviewCard: View {
    @Environment(\.colorScheme) private var scheme
    let preview: LinkPreview

    private var host: String {
        let url = URL(string: preview.url) ?? URL(string: "https://" + preview.url)
        return url?.host() ?? preview.url
    }

    private var thumbnail: NSImage? {
        preview.thumbnail.flatMap(NSImage.init(data:))
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(preview.title.isEmpty ? host : preview.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(2)
                Text(preview.description.isEmpty ? preview.url : preview.description)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Image(systemName: "link")
                        .font(.system(size: 10))
                    Text(host)
                        .font(.system(size: 12))
                        .lineLimit(1)
                }
                .foregroundStyle(.secondary)
                .padding(.top, 6)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.black.opacity(scheme == .dark ? 0.18 : 0.06)))
        .contentShape(Rectangle())
        .onTapGesture {
            let url = URL(string: preview.url).flatMap { $0.scheme == nil ? nil : $0 } ?? URL(string: "https://" + preview.url)
            if let url { NSWorkspace.shared.open(url) }
        }
        .pointerStyle(.link)
    }
}
