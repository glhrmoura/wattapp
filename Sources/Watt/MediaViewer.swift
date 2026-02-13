import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct MediaViewer: View {
    let chat: Chat
    @Binding var currentID: Message.ID?
    @Environment(ChatStore.self) private var store
    @FocusState private var focused: Bool

    private var items: [Message] {
        chat.messages.filter { $0.mediaKind == "image" && $0.mediaPath != nil }
    }

    private var index: Int? {
        items.firstIndex { $0.id == currentID }
    }

    private var current: Message? {
        index.map { items[$0] }
    }

    var body: some View {
        ZStack {
            Color(red: 0.08, green: 0.09, blue: 0.09)
                .ignoresSafeArea()
                .onTapGesture { close() }
            if let current {
                VStack(spacing: 0) {
                    header(current)
                    Divider().opacity(0.4)
                    ZStack {
                        image(current)
                        HStack {
                            arrow("chevron.left", enabled: (index ?? 0) > 0) { move(-1) }
                            Spacer()
                            arrow("chevron.right", enabled: (index ?? 0) < items.count - 1) { move(1) }
                        }
                        .padding(.horizontal, 16)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    Divider().opacity(0.4)
                    footer
                }
            }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true }
        .onKeyPress(.leftArrow) { move(-1); return .handled }
        .onKeyPress(.rightArrow) { move(1); return .handled }
        .onKeyPress(.escape) { close(); return .handled }
        .transition(.opacity)
    }

    private func header(_ message: Message) -> some View {
        HStack(spacing: 12) {
            Button(action: close) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Color.white.opacity(0.08)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .pointerStyle(.link)
            .help("Voltar")
            AvatarView(
                name: senderName(message),
                colorIndex: chat.colorIndex,
                isGroup: chat.isGroup && message.isOutgoing == false && message.senderJID == nil,
                size: 36,
                imagePath: senderAvatar(message)
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(senderName(message))
                    .font(.system(size: 14, weight: .medium))
                Text(message.date.formatted(date: .numeric, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            toolbarButton("square.and.arrow.up", help: "Compartilhar") { share(message) }
            toolbarButton("doc.on.doc", help: "Copiar imagem") { copy(message) }
            toolbarButton("arrow.up.forward.app", help: "Abrir no Pré-Visualização") { openExternally(message) }
            toolbarButton("square.and.arrow.down", help: "Salvar") { save(message) }
        }
        .padding(.horizontal, 16)
        .frame(height: 60)
        .foregroundStyle(.white)
    }

    private func image(_ message: Message) -> some View {
        Group {
            if let path = message.mediaPath, let image = ImageCache.shared.image(at: path) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(24)
            } else {
                ProgressView()
            }
        }
        .id(message.id)
    }

    private var footer: some View {
        HStack(spacing: 16) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(items) { item in
                            thumbnail(item)
                                .id(item.id)
                        }
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 4)
                }
                .onAppear { proxy.scrollTo(currentID, anchor: .center) }
                .onChange(of: currentID) { _, id in
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) }
                }
            }
            Button(action: close) {
                Text("OK")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.black.opacity(0.85))
                    .padding(.horizontal, 18)
                    .frame(height: 32)
                    .background(Capsule().fill(Palette.accent))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .pointerStyle(.link)
        }
        .padding(.horizontal, 16)
        .frame(height: 72)
    }

    private func thumbnail(_ item: Message) -> some View {
        let selected = item.id == currentID
        return Group {
            if let path = item.mediaPath, let image = ImageCache.shared.image(at: path) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Color.white.opacity(0.08)
            }
        }
        .frame(width: 48, height: 48)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(selected ? Palette.accent : .clear, lineWidth: 2))
        .opacity(selected ? 1 : 0.6)
        .contentShape(Rectangle())
        .onTapGesture { currentID = item.id }
        .pointerStyle(.link)
    }

    private func arrow(_ systemImage: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 64)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.06)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .opacity(enabled ? 1 : 0)
        .disabled(!enabled)
    }

    private func toolbarButton(_ systemImage: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 15))
                .frame(width: 38, height: 38)
                .background(Circle().fill(Color.white.opacity(0.08)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .help(help)
    }

    private func senderName(_ message: Message) -> String {
        if message.isOutgoing { return "Você" }
        if chat.isGroup, let name = message.senderName { return name }
        return chat.displayTitle
    }

    private func senderAvatar(_ message: Message) -> String? {
        if message.isOutgoing { return store.selfJID.flatMap { store.avatarPath(for: $0) } }
        if chat.isGroup, let sender = message.senderJID { return store.avatarPath(for: sender) }
        return chat.avatarPath
    }

    private func move(_ delta: Int) {
        guard let index else { return }
        let next = index + delta
        guard items.indices.contains(next) else { return }
        currentID = items[next].id
    }

    private func close() {
        withAnimation(.easeOut(duration: 0.15)) { currentID = nil }
    }

    private func fileURL(_ message: Message) -> URL? {
        message.mediaPath.map { URL(fileURLWithPath: $0) }
    }

    private func share(_ message: Message) {
        guard let url = fileURL(message), let view = NSApp.keyWindow?.contentView else { return }
        let picker = NSSharingServicePicker(items: [url])
        let anchor = NSRect(x: view.bounds.maxX - 200, y: view.bounds.maxY - 60, width: 1, height: 1)
        picker.show(relativeTo: anchor, of: view, preferredEdge: .minY)
    }

    private func copy(_ message: Message) {
        guard let path = message.mediaPath, let image = NSImage(contentsOfFile: path) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
    }

    private func openExternally(_ message: Message) {
        guard let url = fileURL(message) else { return }
        NSWorkspace.shared.open(url)
    }

    private func save(_ message: Message) {
        guard let url = fileURL(message) else { return }
        let panel = NSSavePanel()
        let name = "Watt \(message.date.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false)))"
            .replacingOccurrences(of: ":", with: "-")
        panel.nameFieldStringValue = name + "." + url.pathExtension
        panel.allowedContentTypes = [UTType(filenameExtension: url.pathExtension) ?? .image]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        try? FileManager.default.removeItem(at: destination)
        try? FileManager.default.copyItem(at: url, to: destination)
    }
}
