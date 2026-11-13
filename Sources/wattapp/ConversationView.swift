import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ConversationView: View {
    @Environment(ChatStore.self) private var store
    @Environment(\.colorScheme) private var scheme
    let chatID: Chat.ID
    @State private var text = ""
    @FocusState private var composerFocused: Bool
    @FocusState private var editFocused: Bool
    @State private var showAttachMenu = false
    @State private var selecting = false
    @State private var growDown = false
    @State private var selected = Set<Message.ID>()
    @State private var confirmDelete = false
    @State private var pendingDeleteForEveryone: Bool?
    @State private var forwarding: [Message] = []
    @State private var showForward = false
    @State private var undoable: [Message] = []
    @State private var showExpressions = false
    @State private var recorder = VoiceRecorder()
    @State private var undoTask: Task<Void, Never>?
    @State private var flashID: Message.ID?
    @State private var pasteMonitor = PasteMonitor()
    @State private var savedDraft = ""
    @State private var showProfile = false

    private var chat: Chat? { store.chat(chatID) }

    var body: some View {
        if let chat {
            VStack(spacing: 0) {
                messages(chat)
                    .overlay(alignment: .bottom) {
                        if !undoable.isEmpty {
                            UndoToast(count: undoable.count) {
                                store.restoreMessages(undoable, in: chatID)
                                hideUndo()
                            }
                            .padding(.bottom, 16)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                    }
                    .animation(.easeOut(duration: 0.2), value: undoable.isEmpty)
                if selecting {
                    selectionBar(chat)
                } else {
                    composer
                }
            }
            .overlay {
                if let editingMessage = store.editing[chatID] {
                    editOverlay(editingMessage, in: chat)
                }
            }
            .animation(.easeOut(duration: 0.2), value: store.editing[chatID]?.id)
            .navigationTitle(chat.displayTitle)
            .toolbar(removing: .title)
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Button { showProfile = true } label: {
                        ConversationHeader(chat: chat)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .pointerStyle(.link)
                    .help(chat.isGroup ? "Dados do grupo" : "Dados do contato")
                }
                .hiddenSharedBackground()
                if #available(macOS 26.0, *) {
                    ToolbarSpacer(.flexible)
                }
                ToolbarItem(placement: .primaryAction) {
                    HStack(spacing: 0) {
                    Menu {
                        Button("Chamada de voz", systemImage: "phone") {}
                            .disabled(true)
                        Button("Chamada de vídeo", systemImage: "video") {}
                            .disabled(true)
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "video")
                                .font(.system(size: 15))
                            Image(systemName: "chevron.down")
                                .font(.system(size: 9, weight: .bold))
                        }
                        .frame(width: 48, height: 28)
                        .contentShape(Rectangle())
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Ligações ainda não são suportadas")
                    Menu {
                        Button("Selecionar mensagens") { startSelecting(nil) }
                        Divider()
                        Button(chat.isMuted ? "Reativar notificações" : "Silenciar notificações") { store.toggleMute(chatID) }
                        Button(chat.isPinned ? "Desafixar" : "Fixar") { store.togglePin(chatID) }
                        if !chat.isLocked {
                            Button(chat.isArchived ? "Desarquivar" : "Arquivar") { store.toggleArchive(chatID) }
                        }
                        Divider()
                        Button("Fechar conversa") { if selecting { stopSelecting() } else { store.select(nil) } }
                            .keyboardShortcut(.escape, modifiers: [])
                        Button("Limpar conversa", role: .destructive) { store.clearMessages(chatID) }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 15, weight: .semibold))
                            .frame(width: 40, height: 28)
                            .contentShape(Rectangle())
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Mais opções")
                    Button {
                        store.select(nil)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .semibold))
                            .frame(width: 40, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Fechar conversa")
                    }
                    .padding(.horizontal, 4)
                }
            }
            .onAppear {
                text = chat.draft
                startPasteMonitor()
            }
            .task {
                await Task.yield()
                try? await Task.sleep(for: .milliseconds(60))
                composerFocused = true
            }
            .onChange(of: composerFocused) { _, focused in pasteMonitor.enabled = focused }
            .onChange(of: text) { _, newValue in
                if store.editing[chatID] == nil { store.updateDraft(newValue, for: chatID) }
            }
            .dropDestination(for: URL.self) { urls, _ in
                let files = urls.filter(\.isFileURL)
                guard !files.isEmpty else { return false }
                present(files.map(Attachment.dropped))
                return true
            }
            .onExitCommand { if selecting { stopSelecting() } }
            .sheet(isPresented: $showForward) {
                ForwardSheet(messages: forwarding)
            }
            .sheet(isPresented: $showProfile) {
                ProfileSheet(chatID: chatID)
                    .environment(store)
            }
            .onDisappear {
                store.cancelEditing(in: chatID)
                pasteMonitor.stop()
                store.persistNow()
            }
        }
    }

    private func messages(_ chat: Chat) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    if chat.messages.isEmpty {
                        DayChip(date: .now)
                        EncryptionNotice(isSelf: store.isSelfChat(chat.id))
                            .padding(.bottom, 10)
                    }
                    ForEach(Array(chat.messages.enumerated()), id: \.element.id) { index, message in
                        let previous = index > 0 ? chat.messages[index - 1] : nil
                        if previous.map({ !Calendar.current.isDate($0.date, inSameDayAs: message.date) }) ?? true {
                            DayChip(date: message.date)
                        }
                        if index == 0 {
                            EncryptionNotice(isSelf: store.isSelfChat(chat.id))
                                .padding(.bottom, 10)
                        }
                        let next = index + 1 < chat.messages.count ? chat.messages[index + 1] : nil
                        messageRow(message, previous: previous, next: next, chat: chat, proxy: proxy)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
                .thinScrollers()
            }
            .defaultScrollAnchor(.top, for: .alignment)
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .defaultScrollAnchor(growDown ? .top : .bottom, for: .sizeChanges)
            .environment(\.bubbleWillExpand) {
                growDown = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { growDown = false }
            }
            .background(Wallpaper())
            .onChange(of: chat.messages.count) {
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(chat.messages.last?.id, anchor: .bottom) }
            }
        }
    }

    @ViewBuilder
    private var composer: some View {
        if recorder.isRecording {
            RecordingBar(recorder: recorder, onSend: sendVoice)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Palette.bar)
        } else {
            textComposer
        }
    }

    private func sendVoice() {
        let samples = recorder.finish()
        guard samples.count > 48000 / 2 else { return }
        let directory = store.baseURL.appendingPathComponent("outgoing")
        let chatID = chatID
        Task {
            guard let attachment = await VoiceDraft.make(samples, directory: directory) else {
                store.lastError = "Não foi possível gravar o áudio"
                return
            }
            store.sendAttachments([attachment], caption: "", to: chatID)
        }
    }

    private var textComposer: some View {
        VStack(spacing: 8) {
            if let replying = store.replyTo[chatID], let chat {
                HStack(spacing: 10) {
                    QuoteBlock(quote: quoteDisplay(for: replying, in: chat), lineLimit: 2)
                    Button { store.cancelReply(in: chatID) } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 30, height: 30)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .pointerStyle(.link)
                    .help("Cancelar resposta")
                }
                .padding(.leading, 46)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            composerRow
        }
        .animation(.easeOut(duration: 0.15), value: store.replyTo[chatID]?.id)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Palette.bar)
        .onChange(of: store.replyTo[chatID]?.id) { _, id in
            if id != nil { composerFocused = true }
        }
    }

    private var composerRow: some View {
        HStack(alignment: .bottom, spacing: 10) {
            Button { showAttachMenu.toggle() } label: {
                Image(systemName: "plus")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(.primary)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Color.primary.opacity(showAttachMenu ? 0.18 : 0.1)))
                    .contentShape(Circle())
            }
                .buttonStyle(.plain)
                .pointerStyle(.link)
                .help("Anexar")
                .popover(isPresented: $showAttachMenu, arrowEdge: .top) {
                    AttachmentMenu(
                        onFiles: { pick(types: [.item]) { Attachment(url: $0, kind: .document) } },
                        onMedia: { pick(types: [.image, .movie], Attachment.media) }
                    )
                }
            TextField("Digite uma mensagem", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...6)
                .focused($composerFocused)
                .padding(.leading, 14)
                .padding(.trailing, 40)
                .padding(.vertical, 9)
                .frame(minHeight: 36)
                .background(RoundedRectangle(cornerRadius: 20).fill(Color(nsColor: .controlBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.secondary.opacity(0.2)))
                .overlay(alignment: .bottomTrailing) {
                    Button { showExpressions.toggle() } label: {
                        SmileyIcon()
                            .foregroundStyle(showExpressions ? Palette.accent : .primary)
                            .frame(width: 22, height: 22)
                            .frame(width: 36, height: 36)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .pointerStyle(.link)
                    .help("Emojis, GIFs e figurinhas")
                    .popover(isPresented: $showExpressions, arrowEdge: .top) {
                        ExpressionPanel(
                            onEmoji: { text += $0 },
                            onSticker: { url in
                                showExpressions = false
                                store.sendAttachments([Attachment(url: url, kind: .sticker)], caption: "", to: chatID)
                            }
                        )
                    }
                }
                .onKeyPress(.escape) {
                    guard store.replyTo[chatID] != nil else { return .ignored }
                    store.cancelReply(in: chatID)
                    return .handled
                }
                .onKeyPress(.return, phases: .down) { press in
                    if press.modifiers.contains(.shift) { return .ignored }
                    send()
                    return .handled
                }
            Button {
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Task { await recorder.start() }
                } else {
                    send()
                }
            } label: {
                Image(systemName: text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "mic" : "paperplane.fill")
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(.black)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Palette.accent))
            }
            .buttonStyle(.plain)
            .pointerStyle(.link)
            .help(text.isEmpty ? "Gravar áudio" : "Enviar")
            .alert("Sem acesso ao microfone", isPresented: $recorder.denied) {
                Button("Abrir Ajustes") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
                }
                Button("Cancelar", role: .cancel) {}
            } message: {
                Text("Permita o acesso ao microfone para o WattApp em Ajustes do Sistema › Privacidade e Segurança.")
            }
        }
    }

    private func author(of message: Message, in chat: Chat) -> String {
        if message.isOutgoing { return "Você" }
        if !chat.isGroup { return chat.displayTitle }
        return message.senderName ?? message.senderJID.map(Formatters.phone) ?? ""
    }

    private func quoteDisplay(for message: Message, in chat: Chat) -> QuoteDisplay {
        let image = (message.mediaKind == "image" || message.mediaKind == "sticker")
            ? message.mediaPath.flatMap { ImageCache.shared.image(at: $0) }
            : nil
        return QuoteDisplay(
            id: message.id,
            author: author(of: message, in: chat),
            fromMe: message.isOutgoing,
            text: message.quoteText,
            mediaKind: message.mediaKind,
            image: image
        )
    }

    private func quoteDisplay(for quote: QuotedMessage, in chat: Chat) -> QuoteDisplay {
        if let original = chat.messages.first(where: { $0.id == quote.id }) {
            var display = quoteDisplay(for: original, in: chat)
            if display.image == nil, let data = quote.thumbnail, let image = NSImage(data: data) {
                display = QuoteDisplay(id: display.id, author: display.author, fromMe: display.fromMe, text: display.text, mediaKind: display.mediaKind, image: image)
            }
            return display
        }
        let author: String
        if quote.fromMe {
            author = "Você"
        } else if !chat.isGroup {
            author = chat.displayTitle
        } else if let jid = quote.senderJID, let known = chat.messages.last(where: { $0.senderJID == jid && $0.senderName != nil })?.senderName {
            author = known
        } else {
            author = quote.senderName.map { $0.hasPrefix("~") ? String($0.dropFirst()) : Formatters.phone($0) } ?? ""
        }
        return QuoteDisplay(
            id: quote.id,
            author: author,
            fromMe: quote.fromMe,
            text: quote.text,
            mediaKind: quote.mediaKind,
            image: quote.thumbnail.flatMap { NSImage(data: $0) }
        )
    }

    private func jump(to id: Message.ID, proxy: ScrollViewProxy) {
        guard chat?.messages.contains(where: { $0.id == id }) == true else { return }
        withAnimation(.easeOut(duration: 0.3)) { proxy.scrollTo(id, anchor: .center) }
        flashID = id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            if flashID == id { withAnimation(.easeOut(duration: 0.4)) { flashID = nil } }
        }
    }

    private func send() {
        if store.editing[chatID] != nil {
            store.finishEditing(text, in: chatID)
            text = savedDraft
            savedDraft = ""
            composerFocused = true
            return
        }
        store.send(text, to: chatID)
        text = ""
    }

    private func messageRow(_ message: Message, previous: Message?, next: Message?, chat: Chat, proxy: ScrollViewProxy) -> some View {
        let isGroup = chat.isGroup
        let isChecked = selected.contains(message.id)
        return HStack(spacing: 14) {
            if selecting {
                SelectionCheck(isOn: isChecked)
            }
            MessageBubble(
                message: message,
                showSender: isGroup && !message.isOutgoing && previous?.senderName != message.senderName,
                isFirstInGroup: previous.map { breaksGroup($0, message, isGroup: isGroup) } ?? true,
                isLastInGroup: next.map { breaksGroup(message, $0, isGroup: isGroup) } ?? true,
                onOpenMedia: { if !selecting { store.openMedia(message.id, in: chatID) } },
                quote: message.quoted.map { quoteDisplay(for: $0, in: chat) },
                onQuoteTap: { if let id = message.quoted?.id { jump(to: id, proxy: proxy) } },
                actions: selecting ? nil : actions(for: message)
            )
            .allowsHitTesting(!selecting)
        }
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Palette.accent.opacity(flashID == message.id ? 0.18 : 0))
                .padding(.horizontal, -16)
        )
        .padding(.vertical, selecting ? 2 : 0)
        .contentShape(Rectangle())
        .onTapGesture {
            guard selecting else { return }
            if isChecked { selected.remove(message.id) } else { selected.insert(message.id) }
        }
        .id(message.id)
        .contextMenu {
            if !selecting, let actions = actions(for: message) {
                if let reply = actions.reply {
                    Button("Responder", systemImage: "arrowshape.turn.up.left", action: reply)
                }
                Button("Copiar", systemImage: "doc.on.doc", action: actions.copy)
                if let edit = actions.edit {
                    Button("Editar", systemImage: "pencil", action: edit)
                }
                if let forward = actions.forward {
                    Button("Encaminhar", systemImage: "arrowshape.turn.up.right", action: forward)
                }
                Button("Selecionar", systemImage: "checkmark.circle", action: actions.select)
                Divider()
                Button("Apagar", systemImage: "trash", role: .destructive, action: actions.delete)
            }
        }
    }

    private func breaksGroup(_ first: Message, _ second: Message, isGroup: Bool) -> Bool {
        first.isOutgoing != second.isOutgoing
            || (isGroup && first.senderName != second.senderName)
            || !Calendar.current.isDate(first.date, inSameDayAs: second.date)
    }

    private func actions(for message: Message) -> MessageActions? {
        MessageActions(
            copy: {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(message.caption ?? message.text, forType: .string)
            },
            react: { store.react($0, to: message.id, in: chatID) },
            forward: message.canForward ? {
                forwarding = [message]
                showForward = true
            } : nil,
            favorite: message.mediaKind == "sticker" ? message.mediaPath.map { path in { StickerFavorites.toggle(path) } } : nil,
            isFavorite: message.mediaPath.map(StickerFavorites.contains) ?? false,
            select: { startSelecting(message.id) },
            delete: { startSelecting(message.id) },
            reply: message.canReply ? { store.reply(to: message, in: chatID) } : nil,
            edit: message.canEdit ? { startEditing(message) } : nil
        )
    }

    private func startEditing(_ message: Message) {
        if store.editing[chatID] == nil { savedDraft = text }
        store.startEditing(message, in: chatID)
        text = message.text
    }

    private func editOverlay(_ message: Message, in chat: Chat) -> some View {
        VStack(spacing: 13) {
            Spacer(minLength: 0)
            MessageBubble(
                message: message,
                showSender: false,
                isFirstInGroup: false,
                isLastInGroup: true,
                quote: message.quoted.map { quoteDisplay(for: $0, in: chat) }
            )
            .padding(.horizontal, 16)
            .allowsHitTesting(false)
            editComposer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            ZStack {
                BlurBackdrop()
                Color.black.opacity(scheme == .dark ? 0.2 : 0.06)
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: cancelEditing)
        )
        .transition(.opacity)
    }

    private var editComposer: some View {
        let dark = scheme == .dark
        return HStack(alignment: .bottom, spacing: 8) {
            Button(action: cancelEditing) {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(.primary)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(dark ? Color.white.opacity(0.1) : Color.white))
                    .overlay(Circle().stroke(Color.primary.opacity(dark ? 0.1 : 0.12), lineWidth: 0.5))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .pointerStyle(.link)
            .help("Cancelar edição")
            TextField("", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .lineLimit(1...6)
                .focused($editFocused)
                .padding(.leading, 16)
                .padding(.trailing, 14)
                .padding(.vertical, 7)
                .frame(minHeight: 32)
                .background(Capsule().fill(dark ? Color.white.opacity(0.16) : Color.white))
                .overlay(Capsule().stroke(Color.primary.opacity(dark ? 0.12 : 0.15), lineWidth: 0.5))
                .padding(.vertical, 2)
                .onAppear { editFocused = true }
                .onKeyPress(.escape) {
                    cancelEditing()
                    return .handled
                }
                .onKeyPress(.return, phases: .down) { press in
                    if press.modifiers.contains(.shift) { return .ignored }
                    send()
                    return .handled
                }
            Button(action: send) {
                Image(systemName: "checkmark")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.black)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Palette.accent))
            }
            .buttonStyle(.plain)
            .pointerStyle(.link)
            .help("Salvar edição")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func cancelEditing() {
        store.cancelEditing(in: chatID)
        text = savedDraft
        savedDraft = ""
        composerFocused = true
    }

    private func startSelecting(_ id: Message.ID?) {
        selected = id.map { [$0] } ?? []
        selecting = true
    }

    private func showUndo(_ messages: [Message]) {
        undoTask?.cancel()
        undoable = messages
        undoTask = Task {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            undoable = []
        }
    }

    private func hideUndo() {
        undoTask?.cancel()
        undoable = []
    }

    private func stopSelecting() {
        selecting = false
        selected = []
        confirmDelete = false
    }

    private func performPendingDelete() {
        guard let forEveryone = pendingDeleteForEveryone else { return }
        pendingDeleteForEveryone = nil
        let removed = store.deleteMessages(selected, in: chatID, forEveryone: forEveryone)
        stopSelecting()
        if !removed.isEmpty { showUndo(removed) }
    }

    private func selectionBar(_ chat: Chat) -> some View {
        let chosen = chat.messages.filter { selected.contains($0.id) }
        let canRevoke = !chosen.isEmpty && chosen.allSatisfy { $0.isOutgoing && !($0.revoked ?? false) }
        let canForward = !chosen.isEmpty && chosen.allSatisfy(\.canForward)
        return HStack(spacing: 14) {
            Button(action: stopSelecting) {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerStyle(.link)
            .help("Cancelar")
            Text(selected.count == 1 ? "1 selecionada" : "\(selected.count) selecionadas")
                .font(.system(size: 15))
            Spacer()
            Button {
                forwarding = chosen
                showForward = true
            } label: {
                Image(systemName: "arrowshape.turn.up.right")
                    .font(.system(size: 17))
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerStyle(.link)
            .disabled(!canForward)
            .opacity(canForward ? 1 : 0.4)
            .help("Encaminhar")
            Button { confirmDelete = true } label: {
                Image(systemName: "trash")
                    .font(.system(size: 17))
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerStyle(.link)
            .disabled(selected.isEmpty)
            .opacity(selected.isEmpty ? 0.4 : 1)
            .help("Apagar")
            .popover(isPresented: $confirmDelete, arrowEdge: .top) {
                DeleteConfirmation(count: selected.count, canRevoke: canRevoke) { forEveryone in
                    pendingDeleteForEveryone = forEveryone
                    confirmDelete = false
                }
                .onDisappear(perform: performPendingDelete)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 48)
        .background(Capsule().fill(Color.primary.opacity(scheme == .dark ? 0.1 : 0.05)))
        .overlay(Capsule().stroke(Color.primary.opacity(0.1)))
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Palette.bar)
    }

    private func pick(types: [UTType], _ make: @escaping (URL) -> Attachment) {
        showAttachMenu = false
        AttachmentPicker.choose(types: types) { urls in
            present(urls.map(make))
        }
    }

    private func startPasteMonitor() {
        let store = store
        let chatID = chatID
        pasteMonitor.enabled = true
        pasteMonitor.start {
            guard store.attachmentChatID == nil else { return false }
            let items = PastedAttachments.read(from: .general, directory: store.baseURL.appendingPathComponent("outgoing"))
            guard !items.isEmpty else { return false }
            store.presentAttachments(items, for: chatID)
            return true
        }
    }

    private func present(_ items: [Attachment]) {
        store.presentAttachments(items, for: chatID)
    }
}

private struct BlurBackdrop: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .fullScreenUI
        view.blendingMode = .withinWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

struct Wallpaper: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Canvas { context, size in
            let symbols = ["bubble.left", "heart", "star", "music.note", "camera", "leaf", "moon", "sun.max"]
            let step: CGFloat = 70
            var i = 0
            for y in stride(from: 0, through: size.height + step, by: step) {
                for x in stride(from: 0, through: size.width + step, by: step) {
                    let name = symbols[i % symbols.count]
                    i += 1
                    let offset: CGFloat = Int(y / step) % 2 == 0 ? 0 : step / 2
                    if let symbol = context.resolveSymbol(id: name) {
                        context.draw(symbol, at: CGPoint(x: x + offset, y: y))
                    }
                }
            }
        } symbols: {
            ForEach(["bubble.left", "heart", "star", "music.note", "camera", "leaf", "moon", "sun.max"], id: \.self) { name in
                Image(systemName: name)
                    .font(.system(size: 18))
                    .foregroundStyle(Color.primary.opacity(scheme == .dark ? 0.05 : 0.06))
                    .tag(name)
            }
        }
        .background(scheme == .dark ? Palette.wallpaperDark : Palette.wallpaperLight)
    }
}

struct SmileyIcon: View {
    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            ZStack {
                Circle()
                    .strokeBorder(lineWidth: side * 0.085)
                HStack(spacing: side * 0.2) {
                    Capsule().frame(width: side * 0.1, height: side * 0.17)
                    Capsule().frame(width: side * 0.1, height: side * 0.17)
                }
                .offset(y: -side * 0.12)
                SmileMouth()
                    .frame(width: side * 0.5, height: side * 0.24)
                    .offset(y: side * 0.15)
            }
            .frame(width: side, height: side)
        }
    }
}

struct SmileMouth: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.minY), control: CGPoint(x: rect.midX, y: rect.maxY * 1.9))
        path.closeSubpath()
        return path
    }
}

struct UndoToast: View {
    let count: Int
    var onUndo: () -> Void

    var body: some View {
        HStack(spacing: 24) {
            Text(count == 1 ? "Mensagem apagada para mim." : "\(count) mensagens apagadas para mim.")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
            Button(action: onUndo) {
                Text("Desfazer")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Palette.accent)
                    .padding(.horizontal, 14)
                    .frame(height: 32)
                    .background(Capsule().fill(Color.white.opacity(0.1)))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .pointerStyle(.link)
        }
        .padding(.leading, 24)
        .padding(.trailing, 8)
        .frame(height: 48)
        .background(Capsule().fill(Color(white: 0.13)))
        .shadow(color: .black.opacity(0.3), radius: 8, y: 2)
    }
}

struct SelectionCheck: View {
    let isOn: Bool

    var body: some View {
        ZStack {
            if isOn {
                Circle().fill(Palette.accent)
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
            } else {
                Circle().strokeBorder(Color.secondary, lineWidth: 1.5)
            }
        }
        .frame(width: 20, height: 20)
    }
}

struct DeleteConfirmation: View {
    let count: Int
    let canRevoke: Bool
    var onDelete: (Bool) -> Void

    var body: some View {
        VStack(spacing: 10) {
            Text(count == 1 ? "Deseja apagar a mensagem?" : "Deseja apagar \(count) mensagens?")
                .font(.system(size: 14, weight: .bold))
                .padding(.top, 4)
            if canRevoke {
                row("Apagar para todos") { onDelete(true) }
            }
            row("Apagar para mim") { onDelete(false) }
        }
        .padding(14)
        .frame(width: 320)
        .fixedSize()
    }

    private func row(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14))
                .foregroundStyle(Color(red: 0.93, green: 0.36, blue: 0.4))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .frame(height: 40)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.08)))
                .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
    }
}

struct ForwardSheet: View {
    @Environment(ChatStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let messages: [Message]
    @State private var query = ""
    @State private var targets = Set<Chat.ID>()

    private var candidates: [Chat] {
        let all = store.chats.filter { !$0.isLocked }.sorted { $0.lastActivity > $1.lastActivity }
        guard !query.isEmpty else { return all }
        return all.filter { $0.displayTitle.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "Encaminhar mensagem") { dismiss() }
                .padding(.bottom, 12)
                .onExitCommand { dismiss() }
            TextField("Pesquisar", text: $query)
                .textFieldStyle(.plain)
                .padding(.horizontal, 12)
                .frame(height: 34)
                .background(RoundedRectangle(cornerRadius: 17).fill(Color.primary.opacity(0.07)))
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(candidates) { chat in
                        let isOn = targets.contains(chat.id)
                        HStack(spacing: 12) {
                            SelectionCheck(isOn: isOn)
                            AvatarView(name: chat.displayTitle, colorIndex: chat.colorIndex, isGroup: chat.isGroup, size: 36, imagePath: chat.avatarPath, imageID: chat.avatarID)
                            Text(chat.displayTitle).lineLimit(1)
                            Spacer()
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 7)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if isOn { targets.remove(chat.id) } else { targets.insert(chat.id) }
                        }
                        .pointerStyle(.link)
                    }
                }
            }
            Divider()
            HStack {
                Text(targets.isEmpty ? "Escolha as conversas" : store.chats.filter { targets.contains($0.id) }.map(\.displayTitle).joined(separator: ", "))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Button {
                    store.forward(messages, to: Array(targets))
                    dismiss()
                } label: {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(Circle().fill(Palette.accent))
                }
                .buttonStyle(.plain)
                .pointerStyle(.link)
                .disabled(targets.isEmpty)
                .opacity(targets.isEmpty ? 0.5 : 1)
            }
            .padding(12)
        }
        .frame(width: 420, height: 560)
    }
}

struct ConversationHeader: View {
    @Environment(ChatStore.self) private var store
    let chat: Chat

    private var isSelf: Bool { store.isSelfChat(chat.id) }
    private var subtitle: String { isSelf ? "Mensagens para mim" : chat.subtitle }

    var body: some View {
        HStack(spacing: 10) {
            AvatarView(
                name: chat.displayTitle,
                colorIndex: chat.colorIndex,
                isGroup: chat.isGroup,
                size: 36,
                imagePath: chat.avatarPath,
                imageID: chat.avatarID
            )
            VStack(alignment: .leading, spacing: 1) {
                Text(isSelf ? chat.displayTitle + " (Você)" : chat.displayTitle)
                    .font(.system(size: 15, weight: .bold))
                    .lineLimit(1)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .frame(maxWidth: 520, alignment: .leading)
        }
        .padding(.leading, 6)
    }
}

struct EncryptionNotice: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.openURL) private var openURL
    var isSelf = false

    private var message: String {
        isSelf
            ? " As mensagens que você envia nesta conversa são protegidas com a criptografia de ponta a ponta. Nem mesmo o WhatsApp pode ler, ouvir ou compartilhar essas mensagens. "
            : " As mensagens e ligações são protegidas com a criptografia de ponta a ponta. Somente as pessoas que fazem parte da conversa podem ler, ouvir e compartilhar esse conteúdo. "
    }

    private var textColor: Color {
        scheme == .dark ? Color(red: 1, green: 0.82, blue: 0.47) : Color(red: 0.33, green: 0.27, blue: 0.1)
    }

    var body: some View {
        Button {
            openURL(URL(string: "https://faq.whatsapp.com/820124435853543")!)
        } label: {
            (Text(Image(systemName: "lock.fill"))
                + Text(message)
                + Text("Clique para saber mais").fontWeight(.bold))
                .font(.system(size: 13))
                .lineSpacing(3)
                .multilineTextAlignment(.center)
                .foregroundStyle(textColor)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(maxWidth: 360)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(scheme == .dark ? Color(red: 0.09, green: 0.1, blue: 0.1) : Color(red: 1, green: 0.96, blue: 0.77))
                )
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
    }
}

struct DayChip: View {
    @Environment(\.colorScheme) private var scheme
    let date: Date

    var body: some View {
        Text(Formatters.daySeparator(date))
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(scheme == .dark ? Color(red: 0.09, green: 0.1, blue: 0.1) : Color.white)
                    .shadow(color: .black.opacity(scheme == .dark ? 0 : 0.08), radius: 0.5, y: 1)
            )
            .padding(.vertical, 8)
    }
}
