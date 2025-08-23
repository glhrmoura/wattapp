import SwiftUI

struct ContentView: View {
    @Environment(ChatStore.self) private var store

    @Environment(AccountManager.self) private var accounts

    private var needsLogin: Bool { store.needsLogin }

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
                        Divider()
                        HStack(spacing: 0) {
                            SideRail()
                            Divider()
                            Group {
                                if store.isComposing {
                                    NewChatView()
                                } else {
                                    ChatListView(onNewChat: { store.startComposing() })
                                }
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                    .background(Palette.background)
                        .navigationSplitViewColumnWidth(min: 360, ideal: 400, max: 500)
                        .toolbar(removing: .sidebarToggle)
                } detail: {
                    VStack(spacing: 0) {
                        Divider()
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
        .background(Palette.background)
        .background(WindowBackground())
        .onReceive(NotificationCenter.default.publisher(for: .wattNewChat)) { _ in
            if !needsLogin { store.startComposing() }
        }
    }
}

struct EmptyDetailView: View {

    var body: some View {
        VStack(spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 112, height: 112)
            VStack(spacing: 6) {
                Text("Watt para Mac")
                    .font(.title.weight(.semibold))
                Text("Selecione uma conversa para começar.")
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.background)
        .navigationTitle("Watt")
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
