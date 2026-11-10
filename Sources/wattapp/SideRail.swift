import SwiftUI

struct SideRail: View {
    static let width: CGFloat = 76
    @Environment(ChatStore.self) private var store
    @State private var confirmLogout = false

    private var section: RailSection {
        if store.isComposing { return .none }
        if store.showLocked { return .locked }
        return store.showArchived ? .archived : .chats
    }

    var body: some View {
        VStack(spacing: 0) {
            AccountSwitcher()
                .padding(.bottom, 18)
            VStack(spacing: 14) {
                RailItem(title: "Conversas", systemImage: "bubble.left.and.bubble.right", selectedImage: "bubble.left.and.bubble.right.fill", selected: section == .chats) {
                    store.leaveLocked()
                    store.isComposing = false
                    store.showArchived = false
                }
                RailItem(title: "Arquivadas", systemImage: "archivebox", selectedImage: "archivebox.fill", selected: section == .archived, dot: store.archivedUnreadCount > 0) {
                    store.leaveLocked()
                    store.isComposing = false
                    store.showArchived = true
                }
                RailItem(title: "Trancadas", systemImage: nil, selectedImage: nil, selected: section == .locked, dot: store.lockedUnreadCount > 0) {
                    if store.showLocked {
                        store.isComposing = false
                    } else {
                        store.openLocked()
                    }
                }
            }
            Spacer(minLength: 16)
            ProfileButton(confirmLogout: $confirmLogout)
        }
        .padding(.top, 14)
        .padding(.bottom, 16)
        .frame(width: Self.width)
        .confirmationDialog("Sair desta conta?", isPresented: $confirmLogout) {
            Button("Sair", role: .destructive) { store.logout() }
        } message: {
            Text("O WattApp será removido dos aparelhos conectados desta conta e o histórico local dela será apagado.")
        }
        .onChange(of: store.selfJID) { _, jid in
            if let jid { store.requestContactAvatar(jid) }
        }
        .onAppear {
            if let jid = store.selfJID { store.requestContactAvatar(jid) }
        }
    }
}

private enum RailSection {
    case chats, archived, locked, none
}

private struct RailItem: View {
    let title: String
    let systemImage: String?
    let selectedImage: String?
    let selected: Bool
    var dot = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                icon
                    .foregroundStyle(selected || hovering ? Color.primary : .secondary)
                    .frame(width: 40, height: 40)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.primary.opacity(selected ? 0.13 : hovering ? 0.06 : 0))
                    )
                    .overlay(alignment: .topTrailing) {
                        if dot {
                            Circle()
                                .fill(Palette.accent)
                                .frame(width: 8, height: 8)
                                .offset(x: -5, y: 5)
                        }
                    }
                Text(title)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(selected || hovering ? Color.primary : .secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }

    @ViewBuilder
    private var icon: some View {
        if let systemImage {
            Image(systemName: selected ? (selectedImage ?? systemImage) : systemImage)
                .font(.system(size: 17))
        } else {
            WideLockIcon(size: 17)
        }
    }
}

private struct ProfileButton: View {
    @Environment(AccountManager.self) private var accounts
    @Environment(ChatStore.self) private var store
    @Binding var confirmLogout: Bool
    @State private var open = false
    @State private var hovering = false

    private var current: AccountInfo? {
        accounts.accounts.first { $0.id == accounts.currentID }
    }

    var body: some View {
        if let current {
            Button { open.toggle() } label: {
                AccountAvatar(account: current, size: 36)
                    .overlay(
                        Circle()
                            .strokeBorder(Color.primary.opacity(hovering ? 0.35 : 0.15), lineWidth: 1)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerStyle(.link)
            .onHover { hovering = $0 }
            .help([current.name, current.phone].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
            .popover(isPresented: $open, arrowEdge: .trailing) {
                ProfilePanel(account: current, confirmLogout: $confirmLogout, openTheme: {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { accounts.settingsAccountID = current.id }
                }) { open = false }
            }
        }
    }
}

private struct ProfilePanel: View {
    @Environment(ChatStore.self) private var store
    let account: AccountInfo
    @Binding var confirmLogout: Bool
    let openTheme: () -> Void
    let dismiss: () -> Void

    private var name: String {
        if !store.selfName.isEmpty { return store.selfName }
        return account.name.isEmpty ? "Minha conta" : account.name
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                AccountAvatar(account: account, size: 48)
                VStack(alignment: .leading, spacing: 3) {
                    Text(name)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)
                    if let phone = account.phone {
                        Text(phone)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 12)
            Divider()
                .padding(.horizontal, 6)
                .padding(.bottom, 6)
            PopoverRow {
                dismiss()
                openTheme()
            } label: {
                actionLabel("Configurações", systemImage: "gearshape", color: .primary)
            }
            PopoverRow {
                store.startBridge()
                dismiss()
            } label: {
                actionLabel("Reconectar", systemImage: "arrow.clockwise", color: .primary)
            }
            PopoverRow {
                dismiss()
                confirmLogout = true
            } label: {
                actionLabel("Sair desta conta", systemImage: "rectangle.portrait.and.arrow.right", color: .red)
            }
        }
        .padding(8)
        .frame(width: 280)
    }

    private func actionLabel(_ title: String, systemImage: String, color: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 20)
            Text(title)
                .font(.system(size: 13))
        }
        .foregroundStyle(color)
        .padding(.vertical, 4)
    }
}

private struct AccountAvatar: View {
    @Environment(AccountManager.self) private var accounts
    let account: AccountInfo
    let size: CGFloat
    var rounded = false

    var body: some View {
        AvatarView(
            name: account.name,
            colorIndex: account.id.unicodeScalars.reduce(0) { $0 + Int($1.value) },
            size: size,
            imagePath: accounts.avatarPath(for: account),
            cornerRadius: rounded ? size * 0.26 : nil
        )
    }
}

struct AccountSwitcher: View {
    @Environment(AccountManager.self) private var accounts
    @State private var open = false
    @State private var hovering = false

    private var current: AccountInfo? {
        accounts.accounts.first { $0.id == accounts.currentID }
    }

    private var listed: [AccountInfo] {
        accounts.accounts.filter { $0.jid != nil || $0.id == accounts.currentID }
    }

    private var othersUnread: Bool {
        accounts.accounts.contains { $0.id != accounts.currentID && accounts.hasUnread(for: $0) }
    }

    var body: some View {
        if let current {
            Button { open.toggle() } label: {
                ZStack(alignment: .top) {
                    if listed.count > 1 {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.primary.opacity(0.14))
                            .frame(width: 34, height: 40)
                            .offset(y: 5)
                    }
                    AccountAvatar(account: current, size: 40, rounded: true)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10.4, style: .continuous)
                                .strokeBorder(Color.primary.opacity(hovering ? 0.35 : 0.15), lineWidth: 1)
                        )
                }
                .overlay(alignment: .topTrailing) {
                    if othersUnread {
                        Circle()
                            .fill(Palette.accent)
                            .frame(width: 10, height: 10)
                            .overlay(Circle().strokeBorder(Palette.background, lineWidth: 2))
                            .offset(x: 3, y: -3)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerStyle(.link)
            .onHover { hovering = $0 }
            .help("Trocar de conta")
            .popover(isPresented: $open, arrowEdge: .trailing) {
                AccountList(accounts: listed) { open = false }
            }
        }
    }
}

private struct AccountList: View {
    @Environment(AccountManager.self) private var manager
    let accounts: [AccountInfo]
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(accounts) { account in
                PopoverRow {
                    manager.switchTo(account.id)
                    dismiss()
                } label: {
                    HStack(spacing: 12) {
                        AccountAvatar(account: account, size: 38, rounded: true)
                            .padding(3)
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .strokeBorder(Color.primary.opacity(account.id == manager.currentID ? 0.45 : 0), lineWidth: 2)
                            )
                        VStack(alignment: .leading, spacing: 2) {
                            Text(account.name.isEmpty ? (account.phone ?? "Nova conta") : account.name)
                                .font(.system(size: 14, weight: .semibold))
                                .lineLimit(1)
                            if let phone = account.phone, !account.name.isEmpty {
                                Text(phone)
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 16)
                        let unread = manager.unread(for: account)
                        if unread > 0, account.id != manager.currentID {
                            Text(unread > 99 ? "99+" : "\(unread)")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.black)
                                .padding(.horizontal, 5)
                                .frame(minWidth: 18, minHeight: 18)
                                .background(Capsule().fill(Palette.accent))
                        } else if account.id != manager.currentID, manager.hasUnread(for: account) {
                            Circle()
                                .fill(Palette.accent)
                                .frame(width: 8, height: 8)
                        }
                        if let index = manager.accounts.firstIndex(of: account), index < 9 {
                            Text("⌘\(index + 1)")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            PopoverRow {
                manager.addAccount()
                dismiss()
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "plus")
                        .font(.system(size: 16, weight: .medium))
                        .frame(width: 38, height: 38)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color.primary.opacity(0.08))
                        )
                        .padding(3)
                    Text("Adicionar conta")
                        .font(.system(size: 14))
                    Spacer(minLength: 16)
                    Text("⌃⌘N")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(8)
        .frame(minWidth: 300)
    }
}

private struct PopoverRow<Label: View>: View {
    let action: () -> Void
    @ViewBuilder let label: () -> Label
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            label()
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(hovering ? 0.08 : 0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .onHover { hovering = $0 }
    }
}
