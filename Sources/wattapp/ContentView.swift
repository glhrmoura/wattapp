import SwiftUI

struct ContentView: View {
    @Environment(ChatStore.self) private var store

    @Environment(AccountManager.self) private var accounts
    @Environment(\.colorScheme) private var colorScheme
    @State private var windowSize: CGSize = .zero

    private var needsLogin: Bool { store.needsLogin }

    private var theme: String? {
        accounts.currentTheme.flatMap { AccountTheme.color($0) != nil ? $0 : nil }
    }

    private var accentTheme: String? {
        accounts.currentAccentFollowsTheme ? theme : nil
    }

    var body: some View {
        Group {
            if needsLogin {
                LoginView()
                    .overlay(alignment: .topLeading) {
                        if accounts.accounts.count > 1 {
                            Button {
                                if accounts.accounts.first(where: { $0.id == accounts.currentID })?.jid == nil {
                                    accounts.cancelPending(accounts.currentID)
                                } else if let other = accounts.accounts.first(where: { $0.id != accounts.currentID }) {
                                    accounts.switchTo(other.id)
                                }
                            } label: {
                                Label("Voltar", systemImage: "chevron.left")
                                    .font(.system(size: 13, weight: .medium))
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 2)
                            }
                            .glassButton()
                            .pointerStyle(.link)
                            .padding(16)
                        }
                    }
            } else {
                NavigationSplitView {
                    VStack(spacing: 0) {
                        if theme == nil {
                            Divider()
                        } else {
                            HStack(spacing: 0) {
                                Color.clear.frame(width: SideRail.width, height: 1)
                                ThemeLine()
                            }
                        }
                        HStack(spacing: 0) {
                            SideRail()
                                .environment(\.colorScheme, theme == nil ? colorScheme : .dark)
                            if theme == nil { Divider() } else { ThemeLine(vertical: true) }
                            Group {
                                if store.isComposing {
                                    NewChatView()
                                } else {
                                    ChatListView(onNewChat: { store.startComposing() })
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .background {
                                ThemedPanelBackground(theme: theme)
                            }
                        }
                    }
                    .background {
                        if let theme {
                            WindowAlignedBackdrop(hex: theme).ignoresSafeArea()
                        } else {
                            Palette.background.ignoresSafeArea()
                        }
                    }
                        .navigationSplitViewColumnWidth(min: 360, ideal: 400, max: 500)
                        .toolbar(removing: .sidebarToggle)
                } detail: {
                    VStack(spacing: 0) {
                        if theme == nil { Divider() } else { ThemeLine() }
                        if let chat = store.selectedChat {
                            ConversationView(chatID: chat.id)
                                .id(chat.id)
                        } else {
                            EmptyDetailView()
                        }
                    }
                    .overlay(alignment: .topLeading) {
                        GeometryReader { proxy in
                            Rectangle()
                                .fill(Color(nsColor: .separatorColor))
                                .frame(width: 1, height: proxy.safeAreaInsets.top)
                                .offset(x: -1, y: -proxy.safeAreaInsets.top)
                        }
                    }
                    .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
                }
            }
        }
        .overlay {
            if let chatID = store.viewerChatID, let chat = store.chat(chatID) {
                @Bindable var store = store
                MediaViewer(chat: chat, currentID: $store.viewerMessageID)
            }
        }
        .overlay {
            if !store.pendingDelete.isEmpty {
                ZStack {
                    Color.black.opacity(0.45)
                        .ignoresSafeArea()
                        .onTapGesture { store.pendingDelete = [] }
                    DeleteChatDialog()
                        .transition(.scale(scale: 0.95).combined(with: .opacity))
                }
            }
        }
        .animation(.easeOut(duration: 0.15), value: store.pendingDelete.isEmpty)
        .overlay {
            if let chatID = store.attachmentChatID, let chat = store.chat(chatID) {
                AttachmentPreview(chat: chat)
                    .id(chatID)
            }
        }
        .toolbar(store.viewerChatID == nil && store.attachmentChatID == nil ? .automatic : .hidden, for: .windowToolbar)
        .environment(\.windowSize, windowSize)
        .sheet(isPresented: Binding(
            get: { accounts.settingsAccountID != nil },
            set: { if !$0 { accounts.settingsAccountID = nil } }
        )) {
            if let id = accounts.settingsAccountID, let account = accounts.accounts.first(where: { $0.id == id }) {
                SettingsSheet(account: account)
                    .environment(accounts)
            }
        }
        .background {
            ChromeBackground(theme: theme)
                .ignoresSafeArea()
                .onGeometryChange(for: CGSize.self) { $0.size } action: { windowSize = $0 }
        }
        .background(WindowBackground())
        .onChange(of: accentTheme, initial: true) { _, value in AccentState.shared.apply(theme: value) }
        .onReceive(NotificationCenter.default.publisher(for: .wattappNewChat)) { _ in
            if !needsLogin { store.startComposing() }
        }
    }
}

private struct ThemeLine: View {
    var vertical = false

    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(0.12))
            .frame(width: vertical ? 1 : nil, height: vertical ? nil : 1)
            .background(Palette.background, ignoresSafeAreaEdges: [])
    }
}

struct EmptyDetailView: View {

    var body: some View {
        VStack(spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 112, height: 112)
            VStack(spacing: 6) {
                Text("WattApp para Mac")
                    .font(.title.weight(.semibold))
                Text("Selecione uma conversa para começar.")
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.background)
        .navigationTitle("WattApp")
    }
}

private extension View {
    @ViewBuilder
    func glassButton() -> some View {
        if #available(macOS 26.0, *) {
            buttonStyle(.glass).buttonBorderShape(.capsule).controlSize(.large)
        } else {
            buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.large)
        }
    }
}
