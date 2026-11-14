import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct MessageActions {
    var copy: () -> Void
    var react: (String) -> Void
    var forward: (() -> Void)?
    var favorite: (() -> Void)?
    var isFavorite = false
    var select: () -> Void
    var delete: () -> Void
    var reply: (() -> Void)?
    var edit: (() -> Void)?
}

extension EnvironmentValues {
    @Entry var bubbleWillExpand: () -> Void = {}
}

struct MessageBubble: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.bubbleWillExpand) private var bubbleWillExpand
    let message: Message
    let showSender: Bool
    let isFirstInGroup: Bool
    var isLastInGroup = false
    var onOpenMedia: () -> Void = {}
    var quote: QuoteDisplay?
    var onQuoteTap: () -> Void = {}
    var actions: MessageActions?
    @State private var hovering = false
    @State private var showReactions = false
    @State private var menuOpen = false
    @State private var expanded = false

    private var fill: Color {
        switch (message.isOutgoing, scheme == .dark) {
        case (true, false): Palette.outgoingLight
        case (true, true): Palette.outgoingDark
        case (false, false): Palette.incomingLight
        case (false, true): Palette.incomingDark
        }
    }

    private var image: NSImage? {
        guard message.mediaKind == "image" || message.mediaKind == "sticker", let path = message.mediaPath else { return nil }
        return ImageCache.shared.image(at: path)
    }

    private var isDocument: Bool { message.mediaKind == "document" && !(message.revoked ?? false) }

    private var isSticker: Bool { message.mediaKind == "sticker" && image != nil }
    private var showActions: Bool { actions != nil && (hovering || showReactions || menuOpen) }
    private var reactionList: [String] {
        let values = (message.reactions ?? [:]).values.sorted()
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    var body: some View {
        HStack(spacing: 8) {
            if message.isOutgoing { Spacer(minLength: 80) }
            HStack(spacing: 8) {
            if message.isOutgoing { sideActions }
            Group {
                if isSticker, let image {
                    VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: 0) {
                        sender
                        if let quote {
                            quoteView(quote)
                                .frame(maxWidth: 280)
                                .padding(5)
                                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(fill))
                                .padding(.bottom, 4)
                        }
                        media(image, maxSide: 180)
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text(message.date.formatted(date: .omitted, time: .shortened))
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                            if message.isOutgoing { StatusTicks(status: message.status) }
                        }
                        .padding(.horizontal, 10)
                        .frame(height: 25)
                        .background(Capsule().fill(fill))
                        .padding(.top, 8)
                        if !reactionList.isEmpty {
                            stickerReactionPill
                                .padding(.top, -3)
                        }
                    }
                } else {
                    bubble
                }
            }
            .overlay(alignment: .topTrailing) {
                if showActions { chevronMenu }
            }
            .overlay(alignment: message.isOutgoing ? .bottomTrailing : .bottomLeading) {
                if !reactionList.isEmpty && !isSticker { reactionPill.padding(.horizontal, 8).offset(y: 16) }
            }
            if !message.isOutgoing { sideActions }
            }
            .frame(maxWidth: 600, alignment: message.isOutgoing ? .trailing : .leading)
            if !message.isOutgoing { Spacer(minLength: 80) }
        }
        .padding(.top, isFirstInGroup ? 6 : 0)
        .padding(.bottom, reactionList.isEmpty || isSticker ? 0 : 18)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    @ViewBuilder
    private var sideActions: some View {
        if let actions {
            HStack(spacing: 8) {
                if message.isOutgoing, let forward = actions.forward { circleButton("arrowshape.turn.up.right.fill", help: "Encaminhar", action: forward) }
                circleButton("face.smiling.inverse", help: "Reagir") { showReactions = true }
                    .popover(isPresented: $showReactions, arrowEdge: .top) {
                        ReactionPicker(current: message.reactions?["me"]) { emoji in
                            showReactions = false
                            actions.react(emoji)
                        }
                    }
                if !message.isOutgoing, let forward = actions.forward { circleButton("arrowshape.turn.up.right.fill", help: "Encaminhar", action: forward) }
            }
            .opacity(showActions ? 1 : 0)
            .allowsHitTesting(showActions)
        }
    }

    private func circleButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 32, height: 32)
                .background(Circle().fill(scheme == .dark ? Color(white: 0.22) : Color.white))
                .shadow(color: .black.opacity(0.15), radius: 1.5, y: 1)
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .help(help)
    }

    @ViewBuilder
    private var chevronMenu: some View {
        if let actions {
            Menu {
                if let reply = actions.reply {
                    Button("Responder", action: reply)
                }
                Button("Reagir") { showReactions = true }
                if let forward = actions.forward {
                    Button("Encaminhar", action: forward)
                }
                Button("Copiar", action: actions.copy)
                    .disabled(message.mediaKind == "sticker")
                if let edit = actions.edit {
                    Button("Editar", action: edit)
                }
                if let favorite = actions.favorite {
                    Divider()
                    Button(actions.isFavorite ? "Remover das favoritas" : "Adicionar às favoritas", action: favorite)
                }
                Divider()
                Button("Apagar", action: actions.delete)
                Divider()
                Button("Selecionar mensagens", action: actions.select)
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(isSticker ? Color.black.opacity(0.35) : (scheme == .dark ? Color(white: 0.2) : Color.white)))
                    .foregroundStyle(isSticker ? Color.white : Color.primary)
                    .shadow(color: .black.opacity(isSticker ? 0 : 0.2), radius: 1, y: 0.5)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .pointerStyle(.link)
            .padding(6)
        }
    }

    private var stickerReactionPill: some View {
        let count = message.reactions?.count ?? 0
        return HStack(spacing: 3) {
            ForEach(reactionList, id: \.self) { Text($0) }
            if count > 1 {
                Text("\(count)").font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 15))
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(Capsule().fill(scheme == .dark ? Color(white: 0.17) : Color.white))
        .padding(2)
        .background(Capsule().fill(scheme == .dark ? Color.black : Palette.wallpaperLight))
        .onTapGesture { if let mine = message.reactions?["me"] { actions?.react(mine) } }
    }

    private var reactionPill: some View {
        let count = message.reactions?.count ?? 0
        return HStack(spacing: 2) {
            ForEach(reactionList, id: \.self) { Text($0) }
            if count > 1 {
                Text("\(count)").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(scheme == .dark ? Color(white: 0.2) : Color.white))
        .padding(2)
        .background(Capsule().fill(scheme == .dark ? Color.black : Palette.wallpaperLight))
        .onTapGesture { if let mine = message.reactions?["me"] { actions?.react(mine) } }
    }

    private func quoteView(_ quote: QuoteDisplay) -> some View {
        QuoteBlock(quote: quote)
            .contentShape(Rectangle())
            .onTapGesture(perform: onQuoteTap)
            .pointerStyle(.link)
    }

    private var bubble: some View {
        VStack(alignment: .leading, spacing: 4) {
            sender
            if let quote {
                QuoteStack(spacing: 6) {
                    quoteView(quote)
                        .padding(.horizontal, image == nil && !isDocument ? -9 : 0)
                        .padding(.top, image == nil && !isDocument ? -4 : 0)
                    bubbleContent
                }
            } else {
                bubbleContent
            }
        }
        .padding(.horizontal, image == nil && !isDocument ? 14 : 5)
        .padding(.top, image == nil && !isDocument ? 9 : 5)
        .padding(.bottom, (image == nil && !isDocument) || message.caption != nil ? 9 : 5)
        .background(
            BubbleShape(isOutgoing: message.isOutgoing, hasTail: isLastInGroup && message.isOutgoing)
                .fill(fill)
                .shadow(color: .black.opacity(0.08), radius: 0.5, y: 1)
        )
    }

    @ViewBuilder
    private var bubbleContent: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let image {
                ZStack(alignment: .bottomTrailing) {
                    media(image, maxSide: 320)
                    if message.caption == nil {
                        timestamp
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(.black.opacity(0.45)))
                            .environment(\.colorScheme, .dark)
                            .padding(6)
                    }
                }
                if let caption = message.caption { textBody(caption) }
            } else if message.revoked ?? false {
                revokedBody
            } else if message.mediaKind == "audio" {
                VoiceMessageBody(message: message, timestamp: AnyView(timestamp))
            } else if message.mediaKind == "document" {
                documentBody
            } else if message.isViewOnce {
                viewOnceBody
            } else {
                if let preview = linkPreview {
                    LinkPreviewCard(preview: preview)
                        .padding(.horizontal, -8)
                        .padding(.top, -3)
                        .padding(.bottom, 2)
                }
                textBody(message.text, fill: linkPreview != nil || quote != nil)
            }
        }
    }

    @ViewBuilder
    private var sender: some View {
        if showSender, let sender = message.senderName {
            Text(sender)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Palette.avatar(sender.unicodeScalars.reduce(0) { $0 + Int($1.value) }))
                .padding(.horizontal, image == nil ? 0 : 6)
        }
    }

    private var viewOnceBody: some View {
        HStack(alignment: .bottom, spacing: 14) {
            HStack(spacing: 10) {
                ViewOnceIcon()
                    .foregroundStyle(.primary)
                    .frame(width: 24, height: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(message.viewOnceTitle)
                    Text("Abra no celular para ver")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 2)
            timestamp.offset(y: 3)
        }
    }

    private var documentName: String {
        message.fileName ?? String(message.text.drop(while: { $0 != " " }).dropFirst())
    }

    private var documentBody: some View {
        let ext = (documentName as NSString).pathExtension.lowercased()
        let details = [message.fileSize.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) }, ext.isEmpty ? nil : ext]
            .compactMap { $0 }
            .joined(separator: " • ")
        let available = message.mediaPath.map { FileManager.default.fileExists(atPath: $0) } ?? false
        return VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 12) {
                Image(nsImage: NSWorkspace.shared.icon(for: UTType(filenameExtension: ext) ?? .data))
                    .resizable()
                    .frame(width: 26, height: 32)
                VStack(alignment: .leading, spacing: 3) {
                    Text(documentName)
                        .font(.system(size: 15, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if !details.isEmpty {
                        Text(details)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(minWidth: 150, alignment: .leading)
            }
            .padding(.leading, 12)
            .padding(.trailing, 20)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(Color.black.opacity(scheme == .dark ? 0.18 : 0.06)))
            .contentShape(Rectangle())
            .onTapGesture {
                if available, let path = message.mediaPath { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
            }
            .pointerStyle(available ? .link : nil)
            .help(available ? "Abrir" : "Abra no celular para baixar")
            if let caption = message.caption {
                textBody(caption)
                    .padding(.horizontal, 9)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                timestamp.padding(.horizontal, 8).padding(.bottom, 2)
            }
        }
    }

    private var revokedBody: some View {
        HStack(alignment: .bottom, spacing: 14) {
            HStack(spacing: 5) {
                Image(systemName: "nosign")
                Text(message.isOutgoing ? "Mensagem apagada" : "Esta mensagem foi apagada")
                    .italic()
            }
            .foregroundStyle(.secondary)
            Text(message.date.formatted(date: .omitted, time: .shortened))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .offset(y: 3)
        }
    }

    private var linkPreview: LinkPreview? {
        if let preview = message.linkPreview { return preview }
        guard let url = RichText.firstLink(in: message.text) else { return nil }
        return LinkPreview(url: url.absoluteString, title: "", description: "")
    }

    private func textBody(_ text: String, fill: Bool = false) -> some View {
        let padding = String(repeating: "\u{2007}", count: (message.isOutgoing ? 8 : 6) + (isEdited ? 6 : 0))
        let short = expanded ? nil : RichText.truncated(text)
        let shown = short ?? text
        return ZStack(alignment: .bottomTrailing) {
            if let rich = RichText.build(shown, trailing: padding, more: short != nil) {
                LinkText(content: rich) {
                    bubbleWillExpand()
                    DispatchQueue.main.async {
                        withAnimation(.easeOut(duration: 0.25)) { expanded = true }
                    }
                }
                    .frame(maxWidth: fill ? .infinity : nil, alignment: .leading)
            } else {
                (Text(shown + padding) + Text(".").foregroundColor(.clear))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: fill ? .infinity : nil, alignment: .leading)
            }
            timestamp.offset(y: 3)
        }
        .padding(.horizontal, image == nil ? 0 : 6)
    }

    private var isEdited: Bool { (message.edited ?? false) && !(message.revoked ?? false) }

    private var timestamp: some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            if isEdited {
                Text("Editada")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text(message.date.formatted(date: .omitted, time: .shortened))
                .font(.caption2)
                .foregroundStyle(.secondary)
            if message.isOutgoing { StatusTicks(status: message.status) }
        }
    }

    private func media(_ image: NSImage, maxSide: CGFloat) -> some View {
        let size = image.size
        let scale = min(maxSide / max(size.width, 1), maxSide / max(size.height, 1))
        let width = max(size.width * scale, 120)
        let height = size.height * (width / max(size.width, 1))
        return Group {
            if message.mediaKind == "sticker", let path = message.mediaPath, let animation = ImageAnimation.load(path: path) {
                AnimatedImage(animation: animation)
            } else {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            }
        }
        .frame(width: width, height: min(height, maxSide * 1.2))
        .clipShape(RoundedRectangle(cornerRadius: isSticker ? 6 : 14, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { if message.mediaKind == "image" { onOpenMedia() } }
        .pointerStyle(.link)
    }
}

struct BubbleShape: Shape {
    let isOutgoing: Bool
    let hasTail: Bool

    func path(in rect: CGRect) -> Path {
        let radius: CGFloat = 18
        guard hasTail else { return Path(roundedRect: rect, cornerRadius: radius, style: .continuous) }
        let shape = isOutgoing ? rect : rect.applying(CGAffineTransform(scaleX: -1, y: 1))
        var path = Path()
        path.move(to: CGPoint(x: shape.minX + radius, y: shape.minY))
        path.addLine(to: CGPoint(x: shape.maxX - radius, y: shape.minY))
        path.addQuadCurve(to: CGPoint(x: shape.maxX, y: shape.minY + radius), control: CGPoint(x: shape.maxX, y: shape.minY))
        path.addLine(to: CGPoint(x: shape.maxX, y: shape.maxY - 12))
        path.addQuadCurve(to: CGPoint(x: shape.maxX + 6, y: shape.maxY), control: CGPoint(x: shape.maxX, y: shape.maxY - 3))
        path.addQuadCurve(to: CGPoint(x: shape.maxX - 14, y: shape.maxY - 1.5), control: CGPoint(x: shape.maxX - 5, y: shape.maxY + 0.5))
        path.addQuadCurve(to: CGPoint(x: shape.maxX - 22, y: shape.maxY), control: CGPoint(x: shape.maxX - 17, y: shape.maxY))
        path.addLine(to: CGPoint(x: shape.minX + radius, y: shape.maxY))
        path.addQuadCurve(to: CGPoint(x: shape.minX, y: shape.maxY - radius), control: CGPoint(x: shape.minX, y: shape.maxY))
        path.addLine(to: CGPoint(x: shape.minX, y: shape.minY + radius))
        path.addQuadCurve(to: CGPoint(x: shape.minX + radius, y: shape.minY), control: CGPoint(x: shape.minX, y: shape.minY))
        path.closeSubpath()
        return isOutgoing ? path : path.applying(CGAffineTransform(scaleX: -1, y: 1))
    }
}

struct ViewOnceIcon: View {
    var body: some View {
        ZStack {
            Circle()
                .trim(from: 0.0, to: 0.75)
                .stroke(style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Circle()
                .trim(from: 0.8, to: 0.97)
                .stroke(style: StrokeStyle(lineWidth: 2.4, lineCap: .round, dash: [0.5, 3.8]))
                .rotationEffect(.degrees(-90))
            Text(verbatim: "1")
                .font(.system(size: 12, weight: .bold, design: .rounded))
        }
    }
}

struct ReactionPicker: View {
    let current: String?
    var onPick: (String) -> Void
    @AppStorage("recentReactions") private var recentRaw = ""
    @State private var showAll = false
    @State private var query = ""
    @FocusState private var searchFocused: Bool
    private let defaults = ["👍", "❤️", "😂", "😮", "😢", "🙏"]

    private var quick: [String] {
        let extra = recentRaw.split(separator: " ").map(String.init).first { !defaults.contains($0) }
        return defaults + (extra.map { [$0] } ?? [])
    }

    var body: some View {
        if showAll {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Pesquisar", text: $query)
                        .textFieldStyle(.plain)
                        .focused($searchFocused)
                }
                .font(.system(size: 15))
                .padding(.horizontal, 14)
                .frame(height: 40)
                .background(Capsule().fill(Color.primary.opacity(0.07)))
                .overlay(Capsule().stroke(searchFocused ? Palette.accent : Color.primary.opacity(0.1), lineWidth: searchFocused ? 2 : 1))
                .padding(12)
                EmojiGrid(query: query, columns: 8, uppercase: true, recentTitle: "Frequentes", storageKey: "recentReactions", onPick: onPick)
            }
            .frame(width: 340, height: 440)
            .onAppear { searchFocused = true }
        } else {
            HStack(spacing: 2) {
                ForEach(quick, id: \.self) { emoji in
                    Button { pick(emoji) } label: {
                        Text(emoji)
                            .font(.system(size: 26))
                            .frame(width: 40, height: 40)
                            .background(Circle().fill(current == emoji ? Color.primary.opacity(0.16) : .clear))
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .pointerStyle(.link)
                }
                Button { showAll = true } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 18, weight: .medium))
                        .frame(width: 38, height: 38)
                        .background(Circle().fill(Color.primary.opacity(0.12)))
                }
                .buttonStyle(.plain)
                .pointerStyle(.link)
                .padding(.leading, 4)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
    }

    private func pick(_ emoji: String) {
        var list = recentRaw.split(separator: " ").map(String.init).filter { $0 != emoji }
        list.insert(emoji, at: 0)
        recentRaw = list.prefix(16).joined(separator: " ")
        onPick(emoji)
    }
}
