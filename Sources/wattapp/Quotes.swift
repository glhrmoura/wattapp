import SwiftUI
import AppKit

struct QuoteDisplay: Hashable {
    let id: String
    let author: String
    let fromMe: Bool
    let text: String
    let mediaKind: String?
    let image: NSImage?

    var color: Color {
        fromMe ? Palette.accent : Palette.avatar(author.unicodeScalars.reduce(0) { $0 + Int($1.value) })
    }

    var symbol: String? {
        switch mediaKind {
        case "image": "camera.fill"
        case "video": "video.fill"
        case "audio": "mic.fill"
        case "document": "doc.fill"
        case "sticker": "face.smiling"
        default: nil
        }
    }

    var body: String {
        guard symbol != nil else { return text }
        for prefix in ["📷 ", "🎥 ", "🎤 ", "📄 "] where text.hasPrefix(prefix) {
            return String(text.dropFirst(prefix.count)).replacingOccurrences(of: "Foto · ", with: "").replacingOccurrences(of: "Vídeo · ", with: "")
        }
        return text
    }
}

struct QuoteBlock: View {
    @Environment(\.colorScheme) private var scheme
    let quote: QuoteDisplay
    var lineLimit = 3
    var background: Color?

    var body: some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(quote.color)
                .frame(width: 4)
            VStack(alignment: .leading, spacing: 2) {
                Text(quote.author)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(quote.color)
                    .lineLimit(1)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    if let symbol = quote.symbol {
                        Image(systemName: symbol)
                            .font(.system(size: 11))
                    }
                    Text(quote.body)
                        .font(.system(size: 13))
                        .lineLimit(lineLimit)
                        .multilineTextAlignment(.leading)
                }
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, minHeight: quote.image == nil ? nil : 58, alignment: .leading)
            if let image = quote.image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 58, height: 58)
                    .clipped()
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .background(background ?? Color.black.opacity(scheme == .dark ? 0.22 : 0.05))
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

struct QuoteStack: Layout {
    var spacing: CGFloat = 6

    private func width(_ proposal: ProposedViewSize, _ subviews: Subviews) -> CGFloat {
        let limit = proposal.width ?? .infinity
        guard let first = subviews.first else { return 0 }
        var result = min(first.sizeThatFits(.unspecified).width, limit)
        for view in subviews.dropFirst() {
            result = max(result, view.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil)).width)
        }
        return min(result, limit)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let w = width(proposal, subviews)
        let heights = subviews.map { $0.sizeThatFits(ProposedViewSize(width: w, height: nil)).height }
        return CGSize(width: w, height: heights.reduce(0, +) + spacing * CGFloat(max(subviews.count - 1, 0)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for view in subviews {
            let size = ProposedViewSize(width: bounds.width, height: nil)
            let height = view.sizeThatFits(size).height
            view.place(at: CGPoint(x: bounds.minX, y: y), proposal: ProposedViewSize(width: bounds.width, height: height))
            y += height + spacing
        }
    }
}
