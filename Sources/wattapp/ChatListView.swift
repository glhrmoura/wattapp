import SwiftUI
import AppKit

struct ChatListView: View {
    @Environment(ChatStore.self) private var store
    var onNewChat: () -> Void
    @FocusState private var searchFocused: Bool

    private var allArchived: Bool {
        store.visibleChats.isEmpty && store.archivedCount > 0 && !store.showArchived && !store.showLocked
            && store.searchText.isEmpty && store.filter == .all
    }

    var body: some View {
        @Bindable var store = store
        VStack(spacing: 0) {
            SearchField(prompt: "Pesquisar", text: $store.searchText, focused: $searchFocused)
                .padding(.horizontal, 12)
                .padding(.top, 14)
                .onExitCommand { store.searchText = ""; searchFocused = false }
                .onAppear {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        searchFocused = false
                        NSApp.keyWindow?.makeFirstResponder(nil)
                    }
                }
            FilterBar(selection: $store.filter)
                .padding(.horizontal, 12)
                .padding(.top, 14)
                .padding(.bottom, 8)

            ScrollView {
                LazyVStack(spacing: 2) {
                if allArchived {
                    AllArchivedNotice(count: store.archivedUnreadCount) { store.showArchived = true }
                        .padding(.top, 150)
                } else if store.archivedCount > 0 && !store.showArchived && !store.showLocked && store.searchText.isEmpty {
                    Button {
                        store.showArchived = true
                    } label: {
                        HStack(spacing: 16) {
                            Image(systemName: "archivebox")
                                .font(.system(size: 17))
                                .frame(width: 50)
                            Text("Arquivadas")
                                .font(.system(size: 15))
                            Spacer()
                            if store.archivedUnreadCount > 0 {
                                Text("\(store.archivedUnreadCount)")
                                    .font(.caption)
                                    .foregroundStyle(Palette.accent)
                            }
                        }
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 10)
                        .padding(.horizontal, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(HoverRowStyle())
                    .pointerStyle(.link)
                }

                ForEach(store.visibleChats) { chat in
                    ChatRow(
                        chat: chat,
                        isSelected: store.isSelecting ? store.selection.contains(chat.id) : store.selectedChatID == chat.id,
                        selecting: store.isSelecting,
                        checked: store.selection.contains(chat.id)
                    )
                    .onTapGesture {
                        if NSEvent.modifierFlags.contains(.shift) {
                            store.extendSelection(to: chat.id)
                        } else if store.isSelecting {
                            store.toggleSelection(chat.id)
                        } else {
                            store.select(chat.id)
                        }
                    }
                    .pointerStyle(.link)
                    .contextMenu { if !store.isSelecting { ChatMenu(chat: chat) } }
                }

                if !store.visibleChats.isEmpty && !store.showArchived && !store.showLocked {
                    EncryptionFooter()
                        .padding(.horizontal, 10)
                }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
                .thinScrollers()
            }
            .overlay {
                if store.visibleChats.isEmpty && !allArchived {
                    if store.searchText.isEmpty && store.showLocked {
                        ContentUnavailableView {
                            Label {
                                Text("Nenhuma conversa trancada")
                            } icon: {
                                WideLockIcon(size: 40, lineWidth: 3.2)
                            }
                        }
                    } else {
                        ContentUnavailableView(
                            store.searchText.isEmpty ? "Nenhuma conversa" : "Nada encontrado",
                            systemImage: store.searchText.isEmpty ? "bubble.left" : "magnifyingglass"
                        )
                    }
                }
            }
            if store.isSelecting {
                SelectionBar()
            }
        }

        .onExitCommand { if store.isSelecting { store.stopSelecting() } }
        .toolbar {
            ToolbarItem {
                if inSubpage {
                    Button("Voltar", systemImage: "chevron.left") {
                        store.stopSelecting()
                        store.leaveLocked()
                        store.showArchived = false
                    }
                    .help("Voltar")
                } else {
                    Menu("Mais opções", systemImage: "ellipsis") {
                        Button(store.isSelecting ? "Cancelar seleção" : "Selecionar conversas") {
                            if store.isSelecting { store.stopSelecting() } else { store.startSelecting() }
                        }
                    }
                    .menuIndicator(.hidden)
                    .help("Mais opções")
                }
            }
            if #available(macOS 26.0, *) {
                ToolbarSpacer(.flexible)
            }
            ToolbarItem {
                Text(store.showLocked ? "Conversas trancadas" : store.showArchived ? "Arquivadas" : "Conversas")
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                    .fixedSize()
            }
            .hiddenSharedBackground()
            if #available(macOS 26.0, *) {
                ToolbarSpacer(.flexible)
            }
            ToolbarItem {
                if inSubpage {
                    Button {
                        if store.isSelecting { store.stopSelecting() } else { store.startSelecting() }
                    } label: {
                        Text(store.isSelecting ? "OK" : "Editar")
                            .font(.system(size: 14, weight: .semibold))
                            .padding(.horizontal, 8)
                    }
                    .help(store.isSelecting ? "Concluir seleção" : "Selecionar conversas")
                } else {
                    NewChatButton(action: onNewChat)
                }
            }
        }
    }

    private var inSubpage: Bool { store.showArchived || store.showLocked }
}

struct NewChatButton: View {
    var action: () -> Void

    var body: some View {
        if #available(macOS 26.0, *) {
            Button(action: action) {
                Image(systemName: "plus")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.black)
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.circle)
            .tint(Palette.accent)
            .help("Nova conversa")
        } else {
            Button("Nova conversa", systemImage: "plus", action: action)
                .help("Nova conversa")
        }
    }
}

struct AllArchivedNotice: View {
    var count = 0
    var onOpen: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            (Text("Todas as suas conversas estão arquivadas. Clique no ícone ")
                + Text(Image(systemName: "plus.circle.fill")).foregroundStyle(Palette.accent)
                + Text(" para iniciar uma nova conversa."))
                .font(.system(size: 15))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 20)
            Divider()
            Button(action: onOpen) {
                HStack {
                    Text("Arquivadas")
                        .font(.system(size: 15))
                    Spacer()
                    if count > 0 {
                        Text("\(count)")
                            .font(.caption2.bold())
                            .foregroundStyle(Color.black)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Palette.accent))
                    }
                }
                .foregroundStyle(Palette.accent)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerStyle(.link)
            Divider()
        }
        .padding(.horizontal, 12)
    }
}

struct ChatMenu: View {
    @Environment(ChatStore.self) private var store
    let chat: Chat

    var body: some View {
        if !chat.isLocked {
            Button(chat.isArchived ? "Desarquivar conversa" : "Arquivar conversa", systemImage: "archivebox") {
                store.toggleArchive(chat.id)
            }
        }
        if chat.isMuted {
            Button("Reativar notificações", systemImage: "bell") { store.unmute(chat.id) }
        } else {
            Menu("Silenciar notificações", systemImage: "bell.slash") {
                Button("8 horas") { store.mute(chat.id, for: 8 * 3600) }
                Button("1 semana") { store.mute(chat.id, for: 7 * 86400) }
                Button("Sempre") { store.mute(chat.id, for: nil) }
            }
        }
        Button(chat.isPinned ? "Desafixar conversa" : "Fixar conversa", systemImage: chat.isPinned ? "pin.slash" : "pin") {
            store.togglePin(chat.id)
        }
        if chat.unreadCount > 0 {
            Button("Marcar como lida", systemImage: "message") { store.markRead(chat.id) }
        } else {
            Button("Marcar como não lida", systemImage: "message.badge") { store.markUnread(chat.id) }
        }
        Button(chat.isLocked ? "Destrancar conversa" : "Trancar conversa", systemImage: chat.isLocked ? "lock.open" : "lock") {
            store.toggleLock(chat.id)
        }
        Button(chat.isFavorite ? "Remover dos Favoritos" : "Adicionar aos Favoritos", systemImage: chat.isFavorite ? "heart.slash" : "heart") {
            store.toggleFavorite(chat.id)
        }
        Divider()
        if !chat.isGroup {
            Button(chat.isBlocked ? "Desbloquear" : "Bloquear", systemImage: chat.isBlocked ? "checkmark.circle" : "nosign") {
                store.setBlocked(chat.id, !chat.isBlocked)
            }
        }
        Button("Limpar conversa", systemImage: "minus.circle") { store.clearMessages(chat.id) }
        Button("Selecionar conversas", systemImage: "checkmark.circle") { store.startSelecting(with: chat.id) }
        Button("Apagar conversa", systemImage: "trash", role: .destructive) { store.pendingDelete = [chat.id] }
    }
}

struct FilterBar: View {
    @Binding var selection: ChatFilter
    @AppStorage("extraFilters") private var extraFilters = ""

    private var added: [ChatFilter] {
        ChatFilter.optional.filter { extraFilters.split(separator: ",").contains(Substring($0.rawValue)) }
    }

    var body: some View {
        HStack(spacing: 8) {
            ForEach([ChatFilter.all, .favorites] + added) { filter in
                pill(filter)
            }
            Menu {
                ForEach(ChatFilter.optional) { filter in
                    Toggle(filter.rawValue, isOn: Binding(
                        get: { added.contains(filter) },
                        set: { setAdded(filter, $0) }
                    ))
                }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 32, height: 32)
                    .overlay(Circle().strokeBorder(Color.secondary.opacity(0.35)))
                    .contentShape(Circle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .pointerStyle(.link)
            .menuIndicator(.hidden)
            .fixedSize()
            .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            ConnectionIndicator()
        }
    }

    private func pill(_ filter: ChatFilter) -> some View {
        let isSelected = selection == filter
        return Button {
            selection = filter
        } label: {
            Text(filter.rawValue)
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 14)
                .frame(height: 32)
                .background(Capsule().fill(isSelected ? Palette.accent.opacity(0.16) : Color.primary.opacity(0.001)))
                .overlay(Capsule().strokeBorder(isSelected ? Palette.accent.opacity(0.45) : Color.secondary.opacity(0.35)))
                .foregroundStyle(isSelected ? Palette.accentText : .secondary)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .contentShape(Capsule())
        .pointerStyle(.link)
        .contextMenu {
            if ChatFilter.optional.contains(filter) {
                Button("Remover filtro", systemImage: "minus.circle") { setAdded(filter, false) }
            }
        }
    }

    private func setAdded(_ filter: ChatFilter, _ on: Bool) {
        var current = added
        if on { current.append(filter) } else { current.removeAll { $0 == filter } }
        extraFilters = ChatFilter.optional.filter(current.contains).map(\.rawValue).joined(separator: ",")
        if !on && selection == filter { selection = .all }
    }
}

struct EncryptionFooter: View {
    var body: some View {
        VStack(spacing: 14) {
            (Text(Image(systemName: "lock")) + Text(" Suas mensagens pessoais são protegidas com a ")
                + Text("criptografia de ponta a ponta").foregroundStyle(Palette.accent).fontWeight(.semibold))
                .font(.caption)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }
        .padding(.vertical, 10)
    }
}

struct SelectionBar: View {
    @Environment(ChatStore.self) private var store

    var body: some View {
        HStack(spacing: 12) {
            Button {
                store.stopSelecting()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerStyle(.link)
            .help("Cancelar")
            Text(store.selection.isEmpty ? "Selecione conversas" : "\(store.selection.count) selecionada\(store.selection.count == 1 ? "" : "s")")
                .font(.system(size: 14, weight: .medium))
            Spacer()
            Button {
                let all = Set(store.visibleChats.map(\.id))
                store.selection = store.selection == all ? [] : all
            } label: {
                Text(store.selection == Set(store.visibleChats.map(\.id)) ? "Desmarcar todas" : "Selecionar todas")
                    .font(.system(size: 13))
            }
            .buttonStyle(.plain)
            .pointerStyle(.link)
            .foregroundStyle(.secondary)
            Button {
                store.pendingDelete = store.selection
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(store.selection.isEmpty ? Color.secondary : Color.red)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(Color.red.opacity(store.selection.isEmpty ? 0 : 0.15)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .pointerStyle(.link)
            .disabled(store.selection.isEmpty)
            .help("Apagar conversas selecionadas")
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
        .background(Palette.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

struct ChatRow: View {
    let chat: Chat
    var isSelected = false
    var selecting = false
    var checked = false
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 16) {
            if selecting {
                Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundStyle(checked ? Palette.accent : Color.secondary.opacity(0.6))
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
            AvatarView(name: chat.title, colorIndex: chat.colorIndex, isGroup: chat.isGroup, size: 50, imagePath: chat.avatarPath, imageID: chat.avatarID)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(chat.displayTitle)
                        .font(.system(size: 16, weight: .semibold))
                        .lineLimit(1)
                    Spacer()
                    if let last = chat.lastMessage {
                        Text(Formatters.listTimestamp(last.date))
                            .font(.system(size: 13))
                            .foregroundStyle(chat.unreadCount > 0 ? Palette.accent : .secondary)
                    }
                    if hovering && !selecting {
                        Menu {
                            ChatMenu(chat: chat)
                        } label: {
                            Image(systemName: "chevron.down")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 18, height: 18)
                                .background(Circle().fill(Color(white: 0.4)))
                                .contentShape(Circle())
                        }
                        .menuStyle(.button)
                        .buttonStyle(.plain)
                        .pointerStyle(.link)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .frame(height: 14)
                        .offset(y: -3)
                    }
                }
                HStack(spacing: 4) {
                    preview
                    Spacer()
                    if chat.isMuted {
                        Image(systemName: "bell.slash").font(.system(size: 15)).foregroundStyle(.secondary)
                    }
                    if chat.isPinned {
                        Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.secondary)
                    }
                    if chat.unreadCount > 0 {
                        Text("\(chat.unreadCount)")
                            .font(.caption2.bold())
                            .foregroundStyle(Color.black)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Palette.accent))
                    }
                }
                .frame(height: 20)
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.primary.opacity(isSelected ? 0.1 : hovering ? 0.05 : 0))
        )
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.primary.opacity(isSelected || hovering ? 0 : 0.1))
                .frame(height: 0.5)
                .padding(.leading, selecting ? 112 : 76)
                .padding(.trailing, 10)
                .offset(y: 1)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    @ViewBuilder
    private var preview: some View {
        if !chat.draft.isEmpty {
            (Text("Rascunho: ").foregroundStyle(.red) + Text(chat.draft).foregroundStyle(.secondary))
                .font(.system(size: 14))
                .lineLimit(1)
        } else if let last = chat.lastMessage {
            HStack(spacing: 3) {
                if last.isOutgoing { StatusTicks(status: last.status) }
                if last.isViewOnce {
                    ViewOnceIcon()
                        .foregroundStyle(.secondary)
                        .frame(width: 14, height: 14)
                        .scaleEffect(0.8)
                }
                if last.mediaKind == "audio" && !(last.revoked ?? false) {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.readTick)
                    Text("Mensagem de voz" + (last.duration.map { " (\(formatDuration(Double($0))))" } ?? ""))
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text(previewText(last))
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        } else {
            Text(verbatim: " ").font(.system(size: 14))
        }
    }

    private func previewText(_ message: Message) -> AttributedString {
        let text = message.isViewOnce ? AttributedString(message.viewOnceTitle) : RichText.inline(message.text)
        if chat.isGroup, let sender = message.senderName { return AttributedString("\(sender.split(separator: " ").first ?? ""): ") + text }
        return text
    }
}

struct AvatarView: View {
    let name: String
    let colorIndex: Int
    var isGroup = false
    var size: CGFloat = 40
    var imagePath: String?
    var imageID: String?
    var cornerRadius: CGFloat?

    private var shape: AnyShape {
        if let cornerRadius { AnyShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)) } else { AnyShape(Circle()) }
    }

    var body: some View {
        ZStack {
            shape.fill(Palette.avatar(colorIndex).opacity(0.18))
            if let imagePath, let image = ImageCache.shared.image(at: imagePath, id: imageID) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(shape)
            } else {
                Image(systemName: isGroup ? "person.2.fill" : "person.fill")
                    .font(.system(size: size * 0.32))
            }
        }
        .foregroundStyle(Palette.avatar(colorIndex))
        .frame(width: size, height: size)
    }
}

@MainActor
final class ImageCache {
    static let shared = ImageCache()
    private let images = NSCache<NSString, NSImage>()
    private var keysByPath: [String: Set<String>] = [:]

    func image(at path: String, id: String? = nil) -> NSImage? {
        let key = path + "#" + (id ?? "")
        if let cached = images.object(forKey: key as NSString) { return cached }
        guard let image = NSImage(contentsOfFile: path) else { return nil }
        images.setObject(image, forKey: key as NSString)
        keysByPath[path, default: []].insert(key)
        return image
    }

    func invalidate(_ path: String) {
        for key in keysByPath.removeValue(forKey: path) ?? [] {
            images.removeObject(forKey: key as NSString)
        }
    }
}

struct StatusTicks: View {
    let status: DeliveryStatus

    var body: some View {
        switch status {
        case .failed:
            Image(systemName: "exclamationmark.circle.fill").font(.caption2).foregroundStyle(.red)
        case .sending:
            Image(systemName: "clock").font(.caption2).foregroundStyle(.secondary)
        case .sent:
            TickShape(double: false)
                .stroke(Color.secondary, style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
                .frame(width: 11, height: 8)
                .frame(width: 16)
        case .delivered:
            TickShape(double: true)
                .stroke(Color.secondary, style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
                .frame(width: 16, height: 8)
        case .read:
            TickShape(double: true)
                .stroke(Palette.readTick, style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
                .frame(width: 16, height: 8)
        }
    }
}

struct TickShape: Shape {
    let double: Bool

    func path(in rect: CGRect) -> Path {
        let width = double ? rect.width * 0.7 : rect.width
        let h = rect.height
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY + h * 0.55))
        path.addLine(to: CGPoint(x: rect.minX + width * 0.32, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + width, y: rect.minY))
        if double {
            let offset = rect.width - width
            path.move(to: CGPoint(x: rect.minX + offset + width * 0.2, y: rect.minY + h * 0.82))
            path.addLine(to: CGPoint(x: rect.minX + offset + width * 0.32, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        }
        return path
    }
}

struct DeleteChatDialog: View {
    @Environment(ChatStore.self) private var store

    private var title: String {
        let ids = store.pendingDelete
        if ids.count == 1, let id = ids.first, let chat = store.chat(id) {
            return "Deseja apagar a conversa com \(chat.displayTitle)?"
        }
        return "Deseja apagar \(ids.count) conversas?"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 15, weight: .bold))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 6)
                .padding(.bottom, 10)
            button("Apagar conversa", color: Color(red: 0.95, green: 0.3, blue: 0.3), fill: Color(red: 0.55, green: 0.18, blue: 0.18).opacity(0.75)) {
                store.delete(store.pendingDelete)
                store.pendingDelete = []
            }
            .keyboardShortcut(.defaultAction)
            button("Arquivar", color: .primary, fill: Color.primary.opacity(0.1)) {
                for id in store.pendingDelete where store.chat(id)?.isArchived == false {
                    store.toggleArchive(id)
                }
                store.pendingDelete = []
            }
            button("Cancelar", color: .primary, fill: Color.primary.opacity(0.1)) {
                store.pendingDelete = []
            }
            .keyboardShortcut(.cancelAction)
        }
        .padding(16)
        .frame(width: 290)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Color.primary.opacity(0.12)))
        .shadow(color: .black.opacity(0.35), radius: 20, y: 8)
    }

    private func button(_ title: String, color: Color, fill: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 15))
                .foregroundStyle(color)
                .frame(maxWidth: .infinity)
                .frame(height: 30)
                .background(Capsule().fill(fill))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
    }
}
