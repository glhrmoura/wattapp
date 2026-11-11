import SwiftUI
import AppKit

struct ProfileSheet: View {
    @Environment(ChatStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let chatID: Chat.ID
    @State private var showAllMembers = false
    @State private var confirmClear = false
    @State private var confirmDelete = false
    @State private var copied = false

    private static let memberPreview = 10
    private let mediaColumns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 5)

    private var chat: Chat? { store.chat(chatID) }
    private var profile: ChatProfile? { store.profiles[chatID] }
    private var isSelf: Bool { store.isSelfChat(chatID) }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: chat?.isGroup == true ? "Dados do grupo" : "Dados do contato", onClose: { dismiss() })
                .padding(.bottom, 14)
            Divider()
            if let chat {
                ScrollView {
                    VStack(alignment: .leading, spacing: 26) {
                        hero(chat)
                        actions(chat)
                        if chat.isGroup {
                            groupInfo
                        } else {
                            contactInfo(chat)
                        }
                        media(chat)
                        if chat.isGroup {
                            members(chat)
                        }
                        dangerZone(chat)
                    }
                    .padding(.horizontal, 28)
                    .padding(.vertical, 24)
                    .thinScrollers()
                }
            } else {
                Spacer()
            }
            SheetFooter(confirmTitle: "Ok") { dismiss() }
        }
        .frame(width: 560, height: 660)
        .onAppear { store.requestProfile(chatID) }
        .onExitCommand { dismiss() }
        .confirmationDialog("Limpar esta conversa?", isPresented: $confirmClear) {
            Button("Limpar conversa", role: .destructive) { store.clearMessages(chatID) }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("As mensagens serão removidas apenas deste Mac.")
        }
        .confirmationDialog("Apagar esta conversa?", isPresented: $confirmDelete) {
            Button("Apagar conversa", role: .destructive) {
                dismiss()
                store.delete(chatID)
            }
            Button("Cancelar", role: .cancel) {}
        }
    }

    private func hero(_ chat: Chat) -> some View {
        VStack(spacing: 10) {
            AvatarView(
                name: chat.displayTitle,
                colorIndex: chat.colorIndex,
                isGroup: chat.isGroup,
                size: 108,
                imagePath: chat.avatarPath,
                imageID: chat.avatarID
            )
            .overlay(Circle().strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
            .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
            .padding(.bottom, 4)
            Text(isSelf ? chat.displayTitle + " (Você)" : chat.displayTitle)
                .font(.system(size: 21, weight: .bold))
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
            heroSubtitle(chat)
                .font(.system(size: 13))
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func heroSubtitle(_ chat: Chat) -> some View {
        if chat.isGroup {
            let count = profile?.participants.count ?? chat.members?.count ?? 0
            HStack(spacing: 4) {
                Text("Grupo").foregroundStyle(.secondary)
                if count > 0 {
                    Text("·").foregroundStyle(.secondary)
                    Text("\(count) \(count == 1 ? "membro" : "membros")")
                        .foregroundStyle(Palette.accent)
                }
            }
        } else if isSelf {
            Text("Mensagens para mim").foregroundStyle(.secondary)
        } else if let business = profile?.business {
            Label(business, systemImage: "checkmark.seal.fill")
                .foregroundStyle(.secondary)
        } else {
            Text(phone(chat)).foregroundStyle(.secondary).textSelection(.enabled)
        }
    }

    private func actions(_ chat: Chat) -> some View {
        HStack(spacing: 10) {
            ProfileAction(
                title: chat.isMuted ? "Reativar" : "Silenciar",
                icon: chat.isMuted ? "bell.slash.fill" : "bell",
                active: chat.isMuted
            ) { store.toggleMute(chatID) }
            ProfileAction(
                title: chat.isPinned ? "Fixada" : "Fixar",
                icon: chat.isPinned ? "pin.fill" : "pin",
                active: chat.isPinned
            ) { store.togglePin(chatID) }
            ProfileAction(
                title: "Favorita",
                icon: chat.isFavorite ? "heart.fill" : "heart",
                active: chat.isFavorite
            ) { store.toggleFavorite(chatID) }
            if !chat.isLocked {
                ProfileAction(
                    title: chat.isArchived ? "Desarquivar" : "Arquivar",
                    icon: chat.isArchived ? "archivebox.fill" : "archivebox",
                    active: chat.isArchived
                ) {
                    store.toggleArchive(chatID)
                    dismiss()
                }
            }
        }
    }

    @ViewBuilder
    private var groupInfo: some View {
        SettingsGroup(title: "Descrição") {
            VStack(alignment: .leading, spacing: 8) {
                if let profile {
                    if let description = profile.description {
                        Text(description)
                            .font(.system(size: 13))
                            .lineSpacing(2)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Text("Sem descrição")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                    if let created = createdText(profile) {
                        Text(created)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                } else {
                    loading
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
    }

    private func contactInfo(_ chat: Chat) -> some View {
        SettingsGroup(title: "Sobre") {
            VStack(spacing: 0) {
                if !isSelf || profile?.about != nil {
                    HStack(spacing: 12) {
                        ProfileIcon(name: "quote.bubble.fill")
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Recado")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                            if let profile {
                                Text(profile.about ?? "Sem recado")
                                    .font(.system(size: 13))
                                    .foregroundStyle(profile.about == nil ? .secondary : .primary)
                                    .textSelection(.enabled)
                            } else {
                                loading
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    Divider().padding(.leading, 56)
                }
                HStack(spacing: 12) {
                    ProfileIcon(name: "phone.fill")
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Telefone")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Text(phone(chat))
                            .font(.system(size: 13))
                            .textSelection(.enabled)
                    }
                    Spacer(minLength: 0)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(phone(chat), forType: .string)
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                    } label: {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(copied ? Palette.accent : .secondary)
                            .frame(width: 28, height: 28)
                            .background(Circle().fill(Color.primary.opacity(0.06)))
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .pointerStyle(.link)
                    .help("Copiar número")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
        }
    }

    @ViewBuilder
    private func media(_ chat: Chat) -> some View {
        let items = chat.messages.filter { $0.mediaKind == "image" && $0.mediaPath != nil && !($0.revoked ?? false) }
        let documents = chat.messages.filter { $0.mediaKind == "document" }.count
        let links = chat.messages.filter { $0.linkPreview != nil }.count
        SettingsGroup(title: "Mídia, links e docs", subtitle: mediaSummary(images: items.count, documents: documents, links: links)) {
            if items.isEmpty {
                HStack(spacing: 12) {
                    ProfileIcon(name: "photo.on.rectangle.angled")
                    Text("Nenhuma foto nesta conversa")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            } else {
                LazyVGrid(columns: mediaColumns, spacing: 6) {
                    ForEach(items.suffix(15).reversed()) { message in
                        MediaThumb(path: message.mediaPath ?? "") {
                            dismiss()
                            store.openMedia(message.id, in: chatID)
                        }
                    }
                }
                .padding(8)
            }
        }
    }

    private func members(_ chat: Chat) -> some View {
        let participants = profile?.participants ?? []
        let visible = showAllMembers ? participants : Array(participants.prefix(Self.memberPreview))
        return SettingsGroup(
            title: participants.isEmpty ? "Membros" : "\(participants.count) \(participants.count == 1 ? "membro" : "membros")",
            subtitle: profile.flatMap(groupAdmins)
        ) {
            if profile == nil {
                loading
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(Array(visible.enumerated()), id: \.element.id) { index, member in
                        if index > 0 { Divider().padding(.leading, 62) }
                        MemberRow(member: member) {
                            guard !member.isSelf else { return }
                            dismiss()
                            store.openChat(jid: member.id, name: member.name.hasPrefix("~") ? String(member.name.dropFirst()) : member.name)
                        }
                    }
                    if participants.count > Self.memberPreview {
                        Divider().padding(.leading, 62)
                        Button {
                            withAnimation(.easeOut(duration: 0.18)) { showAllMembers.toggle() }
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: showAllMembers ? "chevron.up" : "chevron.down")
                                    .font(.system(size: 12, weight: .semibold))
                                    .frame(width: 34)
                                Text(showAllMembers ? "Mostrar menos" : "Ver todos (\(participants.count - Self.memberPreview) a mais)")
                                    .font(.system(size: 13, weight: .medium))
                                Spacer(minLength: 0)
                            }
                            .foregroundStyle(Palette.accent)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .pointerStyle(.link)
                    }
                }
            }
        }
    }

    private func dangerZone(_ chat: Chat) -> some View {
        SettingsGroup(title: "Conversa") {
            VStack(spacing: 0) {
                if !chat.isGroup && !isSelf {
                    DangerRow(
                        title: chat.isBlocked ? "Desbloquear \(chat.displayTitle)" : "Bloquear \(chat.displayTitle)",
                        icon: chat.isBlocked ? "hand.raised.slash" : "hand.raised"
                    ) { store.setBlocked(chatID, !chat.isBlocked) }
                    Divider().padding(.leading, 56)
                }
                DangerRow(title: "Limpar conversa", icon: "eraser") { confirmClear = true }
                Divider().padding(.leading, 56)
                DangerRow(title: "Apagar conversa", icon: "trash") { confirmDelete = true }
            }
        }
    }

    private var loading: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Carregando…")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }

    private func phone(_ chat: Chat) -> String {
        guard let user = chat.id.split(separator: "@").first, chat.id.hasSuffix("s.whatsapp.net") else { return chat.displayTitle }
        return Formatters.phone("+" + user)
    }

    private func createdText(_ profile: ChatProfile) -> String? {
        let date = profile.created?.formatted(date: .long, time: .omitted)
        switch (profile.owner, date) {
        case let (owner?, date?): return "Criado por \(owner) em \(date)"
        case let (owner?, nil): return "Criado por \(owner)"
        case let (nil, date?): return "Criado em \(date)"
        default: return nil
        }
    }

    private func groupAdmins(_ profile: ChatProfile) -> String? {
        let admins = profile.participants.filter(\.isAdmin).count
        guard admins > 0 else { return nil }
        return admins == 1 ? "1 admin" : "\(admins) admins"
    }

    private func mediaSummary(images: Int, documents: Int, links: Int) -> String? {
        let parts = [
            images > 0 ? "\(images) \(images == 1 ? "foto" : "fotos")" : nil,
            documents > 0 ? "\(documents) \(documents == 1 ? "documento" : "documentos")" : nil,
            links > 0 ? "\(links) \(links == 1 ? "link" : "links")" : nil
        ].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

private struct ProfileAction: View {
    let title: String
    let icon: String
    var active = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(Palette.accent)
                    .frame(height: 20)
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 68)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(active ? Palette.accent.opacity(0.14) : Color.primary.opacity(hovering ? 0.09 : 0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(active ? Palette.accent.opacity(0.35) : Color.clear, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .animation(.easeOut(duration: 0.15), value: active)
    }
}

private struct ProfileIcon: View {
    let name: String
    var tint: Color = Palette.accent

    var body: some View {
        Image(systemName: name)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.black)
            .frame(width: 30, height: 30)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(tint.gradient))
    }
}

private struct DangerRow: View {
    let title: String
    let icon: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ProfileIcon(name: icon, tint: .red)
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.red)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.primary.opacity(hovering ? 0.04 : 0))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .onHover { hovering = $0 }
    }
}

private struct MemberRow: View {
    @Environment(ChatStore.self) private var store
    let member: ChatProfile.Participant
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                AvatarView(
                    name: member.name,
                    colorIndex: member.id.unicodeScalars.reduce(0) { $0 + Int($1.value) },
                    size: 36,
                    imagePath: store.avatarPath(for: member.id)
                )
                VStack(alignment: .leading, spacing: 2) {
                    Text(Formatters.phone(member.name))
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    if !member.isSelf, member.name.hasPrefix("~") || member.name.hasPrefix("+") {
                        Text(Formatters.phone("+" + (member.id.split(separator: "@").first.map(String.init) ?? "")))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if member.isAdmin {
                    Text("Admin")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Palette.accent)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Palette.accent.opacity(0.14)))
                }
                if !member.isSelf {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .opacity(hovering ? 1 : 0)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.primary.opacity(hovering && !member.isSelf ? 0.04 : 0))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerStyle(member.isSelf ? nil : .link)
        .onHover { hovering = $0 }
        .help(member.isSelf ? "" : "Abrir conversa")
        .onAppear { if !member.isSelf { store.requestContactAvatar(member.id) } }
    }
}

private struct MediaThumb: View {
    let path: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Color.primary.opacity(0.06)
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    if let image = ImageCache.shared.image(at: path) {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFill()
                    } else {
                        Image(systemName: "photo")
                            .foregroundStyle(.secondary)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.black.opacity(hovering ? 0.15 : 0))
                )
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .onHover { hovering = $0 }
    }
}
