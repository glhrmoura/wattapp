import Foundation
import AppKit
import Observation
import LocalAuthentication
import SQLite3

@MainActor
@Observable
final class ChatStore {
    var chats: [Chat] = []
    var selectedChatID: Chat.ID?
    var filter: ChatFilter = .all
    var searchText: String = ""
    var showArchived = false
    var connection: ConnectionState = .starting
    var lastError: String?
    var isComposing = false
    var showLocked = false
    var replyTo: [Chat.ID: Message] = [:]
    var editing: [Chat.ID: Message] = [:]
    @ObservationIgnored private var pendingEdits: [Message.ID: (text: String, edited: Bool?)] = [:]
    var isSelecting = false
    var selection = Set<Chat.ID>()
    var selectionAnchor: Chat.ID?
    var pendingDelete = Set<Chat.ID>()
    var viewerChatID: Chat.ID?
    var viewerMessageID: Message.ID? {
        didSet { if viewerMessageID == nil { viewerChatID = nil } }
    }

    var attachmentItems: [Attachment] = []
    var attachmentChatID: Chat.ID?

    func presentAttachments(_ items: [Attachment], for chatID: Chat.ID) {
        guard !items.isEmpty else { return }
        attachmentItems = items
        attachmentChatID = chatID
    }

    func dismissAttachments() {
        attachmentItems = []
        attachmentChatID = nil
    }

    func openMedia(_ messageID: Message.ID, in chatID: Chat.ID) {
        viewerChatID = chatID
        viewerMessageID = messageID
    }
    @ObservationIgnored private var deletedIDs: Set<String> = []
    @ObservationIgnored let accountID: String
    @ObservationIgnored var onIdentity: ((String, String) -> Void)?
    @ObservationIgnored var onLoggedOut: (() -> Bool)?
    @ObservationIgnored private var deletedKey: String { "deletedChats.\(accountID)" }
    var hasLockedChats: Bool { chats.contains(where: \.isLocked) }
    var contacts: [Contact] = []
    var selfJID: String?
    var selfName = ""
    var contactAvatars: [String: String] = [:]
    var profiles: [String: ChatProfile] = [:]
    @ObservationIgnored private var requestedAvatars = Set<String>()

    @ObservationIgnored private var bridge: WhatsAppBridge?
    @ObservationIgnored private var indexByID: [String: Int] = [:]
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var settleTask: Task<Void, Never>?
    private(set) var isSynced = false
    @ObservationIgnored let baseURL: URL
    @ObservationIgnored private var cacheURL: URL { baseURL.appendingPathComponent("wa-chats.json") }
    @ObservationIgnored private var databaseURL: URL { baseURL.appendingPathComponent("whatsapp.db") }

    init(accountID: String, directory: URL) {
        self.accountID = accountID
        baseURL = directory
        try? FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
        deletedIDs = Set(UserDefaults.standard.stringArray(forKey: "deletedChats.\(accountID)") ?? [])
        hasSession = Self.hasPairedDevice(at: baseURL.appendingPathComponent("whatsapp.db").path)
        loadCache()
        startBridge()
        settle(after: .seconds(hasSession ? 20 : 0))
    }

    private func settle(after delay: Duration) {
        guard !isSynced else { return }
        settleTask?.cancel()
        settleTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.isSynced = true
        }
    }

    var unreadTotal: Int {
        chats.filter { !$0.isMuted && !$0.isArchived && !$0.isLocked && $0.unreadCount > 0 }.count
    }

    var hasSession = true

    private static func hasPairedDevice(at path: String) -> Bool {
        guard FileManager.default.fileExists(atPath: path) else { return false }
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return true
        }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM whatsmeow_device", -1, &statement, nil) == SQLITE_OK else {
            sqlite3_finalize(statement)
            return false
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return false }
        return sqlite3_column_int(statement, 0) > 0
    }

    var needsLogin: Bool {
        switch connection {
        case .waitingQR, .pairing: true
        case .failed: chats.isEmpty
        case .starting, .disconnected: !hasSession
        case .connected: false
        }
    }

    var isConnected: Bool {
        if case .connected = connection { return true }
        return false
    }

    var archivedCount: Int { chats.filter { $0.isArchived && !$0.isLocked }.count }
    var archivedUnreadCount: Int { chats.filter { $0.isArchived && !$0.isLocked && $0.unreadCount > 0 }.count }
    var lockedUnreadCount: Int { chats.filter { $0.isLocked && $0.unreadCount > 0 }.count }

    var visibleChats: [Chat] {
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        return chats
            .filter { showLocked ? $0.isLocked : (!$0.isLocked && $0.isArchived == showArchived) }
            .filter { chat in
                switch filter {
                case .all: true
                case .unread: chat.unreadCount > 0
                case .groups: chat.isGroup
                case .favorites: chat.isFavorite
                }
            }
            .filter { chat in
                query.isEmpty
                    || chat.title.lowercased().contains(query)
                    || chat.displayTitle.lowercased().contains(query)
                    || chat.messages.contains { $0.text.lowercased().contains(query) }
            }
            .sorted {
                if $0.isPinned != $1.isPinned { return $0.isPinned }
                return $0.lastActivity > $1.lastActivity
            }
    }

    var selectedChat: Chat? {
        guard let id = selectedChatID, let i = indexByID[id] else { return nil }
        return chats[i]
    }

    func chat(_ id: Chat.ID) -> Chat? {
        indexByID[id].map { chats[$0] }
    }

    func startBridge() {
        bridge?.stop()
        connection = .starting
        let bridge = WhatsAppBridge(
            onEvents: { [weak self] events in
                Task { @MainActor in self?.apply(events) }
            },
            onExit: { [weak self] status in
                Task { @MainActor in self?.bridgeExited(status) }
            }
        )
        self.bridge = bridge
        do {
            try bridge.start(databaseURL: databaseURL)
        } catch {
            connection = .failed(error.localizedDescription)
        }
    }

    func logout() {
        bridge?.send(["cmd": "logout"])
    }

    func shutdown() {
        persistNow()
        bridge?.stop()
    }

    func select(_ id: Chat.ID?) {
        selectedChatID = id
        guard let id, let i = indexByID[id] else { return }
        if chats[i].isGroup { bridge?.send(["cmd": "members", "chat": id]) }
        if chats[i].unreadCount > 0 {
            chats[i].unreadCount = 0
            sendReadReceipts(for: chats[i])
            scheduleSave()
        }
    }

    func updateDraft(_ text: String, for id: Chat.ID) {
        guard let i = indexByID[id] else { return }
        chats[i].draft = text
    }

    func reply(to message: Message, in chatID: Chat.ID) {
        guard message.canReply else { return }
        replyTo[chatID] = message
    }

    func cancelReply(in chatID: Chat.ID) {
        replyTo[chatID] = nil
    }

    func startEditing(_ message: Message, in chatID: Chat.ID) {
        guard message.canEdit else { return }
        replyTo[chatID] = nil
        editing[chatID] = message
    }

    func cancelEditing(in chatID: Chat.ID) {
        editing[chatID] = nil
    }

    func finishEditing(_ text: String, in chatID: Chat.ID) {
        guard let original = editing.removeValue(forKey: chatID) else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != original.text,
              let i = indexByID[chatID],
              let m = chats[i].messages.firstIndex(where: { $0.id == original.id }) else { return }
        pendingEdits[original.id] = (chats[i].messages[m].text, chats[i].messages[m].edited)
        chats[i].messages[m].text = trimmed
        chats[i].messages[m].edited = true
        chats[i].messages[m].linkPreview = nil
        bridge?.send(["cmd": "edit", "chat": chatID, "id": original.id, "text": trimmed])
        scheduleSave()
    }

    private func takeQuote(for chatID: Chat.ID) -> QuotedMessage? {
        guard let message = replyTo.removeValue(forKey: chatID) else { return nil }
        let thumbnail: Data? = message.mediaKind == "image"
            ? message.mediaPath.flatMap { ImageCache.shared.image(at: $0) }.flatMap(Self.thumbnailData)
            : nil
        return QuotedMessage(
            id: message.id,
            senderJID: message.senderJID,
            senderName: message.senderName,
            fromMe: message.isOutgoing,
            text: message.quoteText,
            mediaKind: message.mediaKind,
            thumbnail: thumbnail
        )
    }

    private static func thumbnailData(_ image: NSImage) -> Data? {
        let side: CGFloat = 96
        let scale = side / max(min(image.size.width, image.size.height), 1)
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        let resized = NSImage(size: size)
        resized.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: size))
        resized.unlockFocus()
        guard let tiff = resized.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.7])
    }

    private static func quoteFields(_ quote: QuotedMessage?) -> [String: any Sendable] {
        guard let quote else { return [:] }
        return [
            "quotedId": quote.id,
            "quotedSender": quote.senderJID ?? "",
            "quotedText": quote.text,
            "quotedFromMe": quote.fromMe
        ]
    }

    func send(_ text: String, to id: Chat.ID) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let i = indexByID[id] else { return }
        let tempID = "tmp-" + UUID().uuidString
        let quote = takeQuote(for: id)
        chats[i].messages.append(Message(id: tempID, text: trimmed, date: .now, isOutgoing: true, status: .sending, quoted: quote))
        chats[i].draft = ""
        let command: [String: any Sendable] = ["cmd": "send", "chat": id, "text": trimmed, "tempId": tempID]
        bridge?.send(command.merging(Self.quoteFields(quote)) { $1 })
        scheduleSave()
    }

    func sendAttachments(_ items: [Attachment], caption: String, to id: Chat.ID) {
        guard let i = indexByID[id], !items.isEmpty else { return }
        let trimmed = caption.trimmingCharacters(in: .whitespacesAndNewlines)
        let directory = baseURL.appendingPathComponent("outgoing")
        let bridge = bridge
        let firstQuote = takeQuote(for: id)
        for (n, item) in items.enumerated() {
            let text = n == 0 ? trimmed : ""
            let quote = n == 0 ? firstQuote : nil
            let quoteFields = Self.quoteFields(quote)
            let tempID = "tmp-" + UUID().uuidString
            let isImage = item.kind == .image
            let localKind: String? = switch item.kind {
            case .image: "image"
            case .sticker: "sticker"
            case .document: "document"
            case .voice: "audio"
            default: nil
            }
            chats[i].messages.append(Message(
                id: tempID,
                text: item.label(caption: text),
                date: .now,
                isOutgoing: true,
                status: .sending,
                mediaKind: localKind,
                mediaPath: localKind == nil ? nil : item.url.path,
                caption: (isImage || item.kind == .document) && !text.isEmpty ? text : nil,
                fileName: item.kind == .document ? item.fileName : nil,
                fileSize: item.kind == .document ? item.byteCount : nil,
                duration: item.seconds,
                waveform: item.waveform,
                quoted: quote
            ))
            Task.detached { [weak self] in
                if let command = await item.command(chat: id, tempID: tempID, caption: text, directory: directory) {
                    bridge?.send(command.merging(quoteFields) { $1 })
                } else {
                    await self?.markFailed(tempID, reason: "Não foi possível ler \(item.fileName)")
                }
            }
        }
        scheduleSave()
    }

    private func markFailed(_ tempID: String, reason: String) {
        updateAnyChat(messageID: tempID) { $0.status = .failed }
        lastError = reason
    }

    func openLocked() {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            enterLocked()
            return
        }
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "ver as conversas trancadas") { success, _ in
            guard success else { return }
            Task { @MainActor [weak self] in self?.enterLocked() }
        }
    }

    private func enterLocked() {
        isComposing = false
        showArchived = false
        showLocked = true
        selectedChatID = nil
    }

    func leaveLocked() {
        guard showLocked else { return }
        showLocked = false
        if let id = selectedChatID, chat(id)?.isLocked == true { selectedChatID = nil }
    }

    func toggleLock(_ id: Chat.ID) {
        let unarchive = chat(id)?.isArchived ?? false
        mutate(id) {
            $0.isLocked.toggle()
            if unarchive { $0.isArchived = false }
        }
        if unarchive { syncSetting("archive", id, false) }
        if chat(id)?.isLocked == true, !showLocked, selectedChatID == id { selectedChatID = nil }
    }

    func startComposing() {
        isComposing = true
        bridge?.send(["cmd": "contacts"])
        if let selfJID { requestContactAvatar(selfJID) }
    }

    func requestProfile(_ id: Chat.ID) {
        bridge?.send(["cmd": "profile", "chat": id])
    }

    func requestContactAvatar(_ jid: String) {
        guard isConnected, requestedAvatars.insert(jid).inserted else { return }
        bridge?.send(["cmd": "avatar", "chat": jid])
    }

    func avatarPath(for jid: String) -> String? {
        if let path = indexByID[jid].flatMap({ chats[$0].avatarPath }) ?? contactAvatars[jid] { return path }
        let file = baseURL.appendingPathComponent("avatars/\(jid).jpg").path
        return FileManager.default.fileExists(atPath: file) ? file : nil
    }

    func openChat(jid: String, name: String) {
        let i = ensureChat(jid, name: name, isGroup: jid.hasSuffix("@g.us"))
        if chats[i].title == jid || chats[i].title.hasPrefix("+") { chats[i].title = name }
        if chats[i].avatarPath == nil, let path = contactAvatars[jid] { chats[i].avatarPath = path }
        chats[i].isArchived = false
        showArchived = false
        isComposing = false
        select(jid)
        scheduleSave()
    }

    func newChat(phone: String) {
        let digits = phone.filter(\.isNumber)
        guard digits.count >= 8 else { return }
        let jid = digits + "@s.whatsapp.net"
        let i = ensureChat(jid, name: "+" + digits, isGroup: false)
        chats[i].isArchived = false
        showArchived = false
        isComposing = false
        select(jid)
    }

    func togglePin(_ id: Chat.ID) {
        mutate(id) { $0.isPinned.toggle() }
        syncSetting("pin", id, chat(id)?.isPinned)
    }
    func toggleFavorite(_ id: Chat.ID) { mutate(id) { $0.isFavorite.toggle() } }
    func toggleMute(_ id: Chat.ID) {
        if chat(id)?.isMuted == true { unmute(id) } else { mute(id, for: nil) }
    }

    func mute(_ id: Chat.ID, for duration: TimeInterval?) {
        mutate(id) { $0.isMuted = true }
        bridge?.send(["cmd": "mute", "chat": id, "value": true, "duration": Int(duration ?? 0)])
    }

    func unmute(_ id: Chat.ID) {
        mutate(id) { $0.isMuted = false }
        syncSetting("mute", id, false)
    }

    func setBlocked(_ id: Chat.ID, _ blocked: Bool) {
        mutate(id) { $0.blocked = blocked }
        bridge?.send(["cmd": "block", "chat": id, "value": blocked])
    }

    func toggleArchive(_ id: Chat.ID) {
        mutate(id) {
            $0.isArchived.toggle()
            if $0.isArchived { $0.isPinned = false }
        }
        syncSetting("archive", id, chat(id)?.isArchived)
        if selectedChatID == id { selectedChatID = nil }
    }

    private func syncSetting(_ command: String, _ id: Chat.ID, _ value: Bool?) {
        guard let value else { return }
        bridge?.send(["cmd": command, "chat": id, "value": value])
    }
    func markUnread(_ id: Chat.ID) {
        mutate(id) { $0.unreadCount = max($0.unreadCount, 1) }
        if selectedChatID == id { selectedChatID = nil }
        syncSetting("read", id, false)
    }

    func markRead(_ id: Chat.ID) {
        guard let chat = chat(id) else { return }
        mutate(id) { $0.unreadCount = 0 }
        sendReadReceipts(for: chat)
        syncSetting("read", id, true)
    }
    func clearMessages(_ id: Chat.ID) { mutate(id) { $0.messages.removeAll() } }

    func delete(_ id: Chat.ID) {
        delete([id])
    }

    func delete(_ ids: Set<Chat.ID>) {
        guard !ids.isEmpty else { return }
        for id in ids { bridge?.send(["cmd": "delete", "chat": id]) }
        removeChats(ids)
        deletedIDs.formUnion(ids)
        UserDefaults.standard.set(Array(deletedIDs), forKey: deletedKey)
        selection.subtract(ids)
        if selection.isEmpty { isSelecting = false }
    }

    func startSelecting(with id: Chat.ID? = nil) {
        isSelecting = true
        selection = id.map { [$0] } ?? []
        selectionAnchor = id
    }

    func stopSelecting() {
        isSelecting = false
        selection = []
        selectionAnchor = nil
    }

    func toggleSelection(_ id: Chat.ID) {
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
        selectionAnchor = id
    }

    func extendSelection(to id: Chat.ID) {
        let ids = visibleChats.map(\.id)
        if !isSelecting {
            startSelecting(with: selectedChatID.flatMap { ids.contains($0) ? $0 : nil } ?? id)
        }
        guard let anchor = selectionAnchor, let start = ids.firstIndex(of: anchor), let end = ids.firstIndex(of: id) else {
            toggleSelection(id)
            return
        }
        selection.formUnion(ids[min(start, end)...max(start, end)])
    }

    private func removeChats(_ ids: Set<Chat.ID>) {
        chats.removeAll { ids.contains($0.id) }
        rebuildIndex()
        if let selected = selectedChatID, ids.contains(selected) { selectedChatID = nil }
        scheduleSave()
    }

    private static func isHidden(_ jid: String) -> Bool {
        jid.hasSuffix("@newsletter") || jid.hasSuffix("@broadcast")
    }

    func deleteMessage(_ messageID: Message.ID, in chatID: Chat.ID) {
        mutate(chatID) { $0.messages.removeAll { $0.id == messageID } }
    }

    func restoreMessages(_ messages: [Message], in chatID: Chat.ID) {
        mutate(chatID) { chat in
            let existing = Set(chat.messages.map(\.id))
            chat.messages += messages.filter { !existing.contains($0.id) }
            chat.messages.sort { $0.date < $1.date }
        }
    }

    @discardableResult
    func deleteMessages(_ ids: Set<Message.ID>, in chatID: Chat.ID, forEveryone: Bool) -> [Message] {
        guard !ids.isEmpty else { return [] }
        let removed = chat(chatID)?.messages.filter { ids.contains($0.id) } ?? []
        if forEveryone {
            let remote = ids.filter { !$0.hasPrefix("tmp-") }
            if !remote.isEmpty { bridge?.send(["cmd": "revoke", "chat": chatID, "ids": Array(remote)]) }
            mutate(chatID) { chat in
                for m in chat.messages.indices where ids.contains(chat.messages[m].id) {
                    Self.markRevoked(&chat.messages[m], fromMe: true)
                }
            }
        } else {
            mutate(chatID) { $0.messages.removeAll { ids.contains($0.id) } }
        }
        return forEveryone ? [] : removed
    }

    func react(_ emoji: String, to messageID: Message.ID, in chatID: Chat.ID) {
        guard let i = indexByID[chatID], let m = chats[i].messages.firstIndex(where: { $0.id == messageID }) else { return }
        let message = chats[i].messages[m]
        let value = message.reactions?["me"] == emoji ? "" : emoji
        var reactions = message.reactions ?? [:]
        reactions["me"] = value.isEmpty ? nil : value
        chats[i].messages[m].reactions = reactions.isEmpty ? nil : reactions
        bridge?.send([
            "cmd": "react", "chat": chatID, "id": messageID, "text": value,
            "fromMe": message.isOutgoing, "sender": message.senderJID ?? chatID
        ])
        scheduleSave()
    }

    func forward(_ messages: [Message], to chatIDs: [Chat.ID]) {
        for chatID in chatIDs {
            for message in messages where message.canForward {
                if message.mediaKind == "sticker", let path = message.mediaPath {
                    sendAttachments([Attachment(url: URL(fileURLWithPath: path), kind: .sticker)], caption: "", to: chatID)
                } else if message.mediaKind == "image", let path = message.mediaPath {
                    sendAttachments([Attachment(url: URL(fileURLWithPath: path), kind: .image)], caption: message.caption ?? "", to: chatID)
                } else {
                    send(message.text, to: chatID)
                }
            }
        }
    }

    private static func markRevoked(_ message: inout Message, fromMe: Bool) {
        message.text = fromMe ? "Mensagem apagada" : "Esta mensagem foi apagada"
        message.revoked = true
        message.mediaKind = nil
        message.mediaPath = nil
        message.caption = nil
        message.reactions = nil
    }

    private func apply(_ events: [BridgeEvent]) {
        var touched = Set<Int>()
        for event in events {
            switch event.type {
            case "qr":
                if let code = event.code { connection = .waitingQR(code) }
            case "qr_timeout":
                startBridge()
            case "paired":
                connection = .pairing
            case "connected":
                connection = .connected(name: event.name ?? "")
                hasSession = true
                selfJID = event.jid
                selfName = event.name ?? ""
                lastError = nil
                if let jid = event.jid { onIdentity?(jid, event.name ?? "") }
                if isComposing { bridge?.send(["cmd": "contacts"]) }
                for chat in chats {
                    bridge?.send(["cmd": "resolve", "chat": chat.id])
                    requestAvatar(chat)
                }
            case "offline_synced":
                settle(after: .seconds(1.5))
            case "disconnected":
                if isConnected { connection = .starting }
            case "logged_out":
                handleLoggedOut()
            case "error":
                lastError = event.message
            case "chat":
                guard let jid = event.jid, !Self.isHidden(jid) else { continue }
                if indexByID[jid] == nil && deletedIDs.contains(jid) { continue }
                let i = ensureChat(jid, name: event.name ?? jid, isGroup: event.isGroup ?? false)
                if let name = event.name, !name.isEmpty,
                   !(event.fallback ?? false) || chats[i].title == jid || chats[i].title.isEmpty {
                    chats[i].title = name
                }
            case "reaction":
                let key = (event.fromMe ?? false) ? "me" : (event.sender ?? "")
                updateMessage(chat: event.chat, id: event.id) { message in
                    var reactions = message.reactions ?? [:]
                    reactions[key] = (event.text ?? "").isEmpty ? nil : event.text
                    message.reactions = reactions.isEmpty ? nil : reactions
                }
            case "revoked":
                updateMessage(chat: event.chat, id: event.id) { Self.markRevoked(&$0, fromMe: event.fromMe ?? false) }
            case "edited":
                guard let text = event.text else { continue }
                if let id = event.id { pendingEdits[id] = nil }
                updateMessage(chat: event.chat, id: event.id) { message in
                    guard !(message.revoked ?? false) else { return }
                    if message.mediaKind != nil {
                        if let caption = event.caption { message.caption = caption.isEmpty ? nil : caption }
                    } else if message.text != text {
                        message.linkPreview = nil
                    }
                    message.text = text
                    message.edited = true
                }
            case "edit_failed":
                lastError = event.message
                guard let id = event.id, let previous = pendingEdits.removeValue(forKey: id) else { continue }
                updateMessage(chat: event.chat, id: id) {
                    $0.text = previous.text
                    $0.edited = previous.edited
                }
            case "members":
                guard let jid = event.jid, let i = indexByID[jid], let names = event.names else { continue }
                chats[i].members = names
            case "profile":
                guard let jid = event.jid else { continue }
                let participants = (event.participants ?? []).map {
                    ChatProfile.Participant(id: $0.jid, name: $0.name, isAdmin: $0.admin ?? false, isSelf: $0.`self` ?? false)
                }
                profiles[jid] = ChatProfile(
                    about: event.about.flatMap { $0.isEmpty ? nil : $0 },
                    business: event.business.flatMap { $0.isEmpty ? nil : $0 },
                    description: event.description.flatMap { $0.isEmpty ? nil : $0 },
                    created: event.created.map { Date(timeIntervalSince1970: $0) },
                    owner: event.owner,
                    participants: participants.sorted { a, b in
                        if a.isSelf != b.isSelf { return a.isSelf }
                        if a.isAdmin != b.isAdmin { return a.isAdmin }
                        let x = a.name.hasPrefix("~"), y = b.name.hasPrefix("~")
                        if x != y { return !x }
                        return a.name.localizedStandardCompare(b.name) == .orderedAscending
                    }
                )
            case "deleted":
                guard let jid = event.jid else { continue }
                removeChats([jid])
            case "merge":
                guard let from = event.chat, let to = event.jid else { continue }
                merge(from, into: to)
            case "settings":
                guard let jid = event.jid, !Self.isHidden(jid), !deletedIDs.contains(jid) else { continue }
                let flagged = [event.archived, event.pinned, event.muted, event.locked, event.unread].contains(true)
                if indexByID[jid] == nil && !flagged { continue }
                let i = ensureChat(jid, name: jid, isGroup: jid.hasSuffix("@g.us"))
                if let archived = event.archived {
                    chats[i].isArchived = archived
                    if archived && selectedChatID == jid { selectedChatID = nil }
                }
                if let pinned = event.pinned { chats[i].isPinned = pinned }
                if let muted = event.muted { chats[i].isMuted = muted }
                if let locked = event.locked {
                    chats[i].isLocked = locked
                    if locked && !showLocked && selectedChatID == jid { selectedChatID = nil }
                }
                if let unread = event.unread, jid != selectedChatID {
                    chats[i].unreadCount = unread ? max(chats[i].unreadCount, 1) : 0
                }
            case "blocklist":
                let blocked = Set(event.ids ?? [])
                for i in chats.indices where !chats[i].isGroup {
                    chats[i].blocked = blocked.contains(chats[i].id)
                }
            case "media":
                updateMessage(chat: event.chat, id: event.id) { $0.mediaPath = event.path }
            case "contacts":
                contacts = (event.contacts ?? [])
                    .map { Contact(id: $0.jid, name: $0.name) }
                    .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            case "avatar":
                guard let jid = event.jid else { continue }
                if let path = event.path, !path.isEmpty {
                    ImageCache.shared.invalidate(path)
                    contactAvatars[jid] = path
                } else {
                    contactAvatars[jid] = nil
                }
                guard let i = indexByID[jid] else { continue }
                let id = event.pictureId.flatMap { $0.isEmpty ? nil : $0 }
                let path = event.path.flatMap { $0.isEmpty ? nil : $0 }
                if let path { ImageCache.shared.invalidate(path) }
                chats[i].avatarID = id
                chats[i].avatarPath = path
            case "unread":
                guard let jid = event.chat, let i = indexByID[jid], jid != selectedChatID else { continue }
                chats[i].unreadCount = max(chats[i].unreadCount, event.count ?? 0)
            case "message":
                if let i = receive(event) { touched.insert(i) }
            case "sent":
                updateMessage(chat: event.chat, id: event.tempId) {
                    $0.id = event.id ?? $0.id
                    $0.status = max($0.status, .sent)
                    if let path = event.path, !path.isEmpty, ["image", "sticker", "audio"].contains($0.mediaKind ?? "") { $0.mediaPath = path }
                }
            case "send_failed":
                updateAnyChat(messageID: event.tempId) { $0.status = .failed }
                lastError = event.message
            case "receipt":
                guard let chat = event.chat, let i = indexByID[chat], let ids = event.ids else { continue }
                let set = Set(ids)
                if event.own ?? false {
                    applyOwnRead(at: i, ids: set, timestamp: event.timestamp)
                    continue
                }
                let status: DeliveryStatus = event.status == "read" ? .read : .delivered
                for m in chats[i].messages.indices where set.contains(chats[i].messages[m].id) && chats[i].messages[m].isOutgoing {
                    chats[i].messages[m].status = max(chats[i].messages[m].status, status)
                }
            default:
                break
            }
        }
        for i in touched where chats[i].messages.count > 1 {
            chats[i].messages.sort { $0.date < $1.date }
        }
        markSelfChatRead()
        scheduleSave()
    }

    private func receive(_ event: BridgeEvent) -> Int? {
        guard let jid = event.chat, let id = event.id, let text = event.text else { return nil }
        if deletedIDs.contains(jid) {
            if event.history ?? false { return nil }
            deletedIDs.remove(jid)
            UserDefaults.standard.set(Array(deletedIDs), forKey: deletedKey)
        }
        let i = ensureChat(jid, name: jid, isGroup: event.isGroup ?? false)
        let fromMe = event.fromMe ?? false
        let reported: DeliveryStatus? = switch event.status {
        case "read": .read
        case "delivered": .delivered
        case "sent": .sent
        default: nil
        }
        if let m = chats[i].messages.firstIndex(where: { $0.id == id }) {
            if fromMe, let reported { chats[i].messages[m].status = max(chats[i].messages[m].status, reported) }
            return nil
        }
        let message = Message(
            id: id,
            text: text,
            date: Date(timeIntervalSince1970: event.timestamp ?? Date.now.timeIntervalSince1970),
            isOutgoing: fromMe,
            status: fromMe ? (reported ?? .sent) : .read,
            senderJID: event.sender,
            senderName: event.senderName,
            mediaKind: event.media,
            mediaPath: event.path.flatMap { $0.isEmpty ? nil : $0 },
            caption: event.caption.flatMap { $0.isEmpty ? nil : $0 },
            fileName: event.fileName,
            fileSize: event.fileSize,
            duration: event.seconds,
            waveform: event.waveform.flatMap { Data(base64Encoded: $0) }.map { [UInt8]($0) },
            linkPreview: event.previewURL.map {
                LinkPreview(
                    url: $0,
                    title: event.previewTitle ?? "",
                    description: event.previewDescription ?? "",
                    thumbnail: event.previewThumb.flatMap { Data(base64Encoded: $0) }
                )
            },
            quoted: event.quotedId.map {
                QuotedMessage(
                    id: $0,
                    senderJID: event.quotedSender,
                    senderName: event.quotedSenderName,
                    fromMe: event.quotedFromMe ?? false,
                    text: event.quotedText ?? "",
                    mediaKind: event.quotedMedia,
                    thumbnail: event.quotedThumb.flatMap { Data(base64Encoded: $0) }
                )
            }
        )
        let outOfOrder = (chats[i].messages.last?.date ?? .distantPast) > message.date
        chats[i].messages.append(message)
        let isLive = !(event.history ?? false)
        if isLive && !fromMe {
            if selectedChatID == jid {
                sendReadReceipts(ids: [id], chat: jid, sender: event.sender, isGroup: chats[i].isGroup)
            } else {
                chats[i].unreadCount += 1
            }
        }
        return outOfOrder ? i : nil
    }

    private func applyOwnRead(at i: Int, ids: Set<String>, timestamp: Double?) {
        guard chats[i].unreadCount > 0 else { return }
        let messages = chats[i].messages
        if let last = messages.lastIndex(where: { ids.contains($0.id) }) {
            let remaining = messages[(last + 1)...].filter { !$0.isOutgoing }.count
            chats[i].unreadCount = min(chats[i].unreadCount, remaining)
        } else if let timestamp, let newest = messages.last?.date, Date(timeIntervalSince1970: timestamp) >= newest {
            chats[i].unreadCount = 0
        }
    }

    private func sendReadReceipts(for chat: Chat) {
        let incoming = chat.messages.suffix(50).filter { !$0.isOutgoing }
        if chat.isGroup {
            let bySender = Dictionary(grouping: incoming) { $0.senderJID ?? "" }
            for (sender, msgs) in bySender where !sender.isEmpty {
                sendReadReceipts(ids: msgs.map(\.id), chat: chat.id, sender: sender, isGroup: true)
            }
        } else if !incoming.isEmpty {
            sendReadReceipts(ids: incoming.map(\.id), chat: chat.id, sender: nil, isGroup: false)
        }
    }

    private func sendReadReceipts(ids: [String], chat: String, sender: String?, isGroup: Bool) {
        var command: [String: Any] = ["cmd": "mark_read", "chat": chat, "ids": ids]
        if isGroup, let sender { command["sender"] = sender }
        bridge?.send(command)
    }

    @discardableResult
    private func ensureChat(_ jid: String, name: String, isGroup: Bool) -> Int {
        if let i = indexByID[jid] { return i }
        chats.append(Chat(id: jid, title: name, isGroup: isGroup))
        indexByID[jid] = chats.count - 1
        if isConnected { requestAvatar(chats[chats.count - 1]) }
        return chats.count - 1
    }

    private func merge(_ from: String, into to: String) {
        guard from != to, let source = indexByID[from].map({ chats[$0] }) else { return }
        let i = ensureChat(to, name: source.title, isGroup: source.isGroup)
        let known = Set(chats[i].messages.map(\.id))
        chats[i].messages.append(contentsOf: source.messages.filter { !known.contains($0.id) })
        chats[i].messages.sort { $0.date < $1.date }
        chats[i].unreadCount += source.unreadCount
        chats[i].isPinned = chats[i].isPinned || source.isPinned
        chats[i].isMuted = chats[i].isMuted || source.isMuted
        if chats[i].draft.isEmpty { chats[i].draft = source.draft }
        if chats[i].avatarPath == nil {
            chats[i].avatarID = source.avatarID
            chats[i].avatarPath = source.avatarPath
        }
        chats.removeAll { $0.id == from }
        rebuildIndex()
        if selectedChatID == from { selectedChatID = to }
    }

    private func requestAvatar(_ chat: Chat) {
        var command: [String: Any] = ["cmd": "avatar", "chat": chat.id]
        if let id = chat.avatarID, let path = chat.avatarPath, FileManager.default.fileExists(atPath: path) {
            command["pictureId"] = id
        }
        bridge?.send(command)
    }

    private func updateMessage(chat: String?, id: String?, _ change: (inout Message) -> Void) {
        guard let chat, let id, let i = indexByID[chat],
              let m = chats[i].messages.firstIndex(where: { $0.id == id }) else { return }
        change(&chats[i].messages[m])
    }

    private func updateAnyChat(messageID: String?, _ change: (inout Message) -> Void) {
        guard let messageID else { return }
        for i in chats.indices {
            if let m = chats[i].messages.firstIndex(where: { $0.id == messageID }) {
                change(&chats[i].messages[m])
                return
            }
        }
    }

    private func handleLoggedOut() {
        bridge?.stop()
        try? FileManager.default.removeItem(at: databaseURL)
        for suffix in ["-wal", "-shm"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: databaseURL.path + suffix))
        }
        chats = []
        rebuildIndex()
        selectedChatID = nil
        hasSession = false
        persistNow()
        if onLoggedOut?() == true { return }
        startBridge()
    }

    private func bridgeExited(_ status: Int32) {
        guard status != 0, case .connected = connection else {
            if case .starting = connection, status != 0 {
                connection = .failed(lastError ?? "A conexão foi encerrada (código \(status))")
            }
            return
        }
        connection = .failed(lastError ?? "A conexão foi encerrada")
    }

    private func mutate(_ id: Chat.ID, _ change: (inout Chat) -> Void) {
        guard let i = indexByID[id] else { return }
        change(&chats[i])
        scheduleSave()
    }

    private func rebuildIndex() {
        indexByID = Dictionary(uniqueKeysWithValues: chats.enumerated().map { ($1.id, $0) })
    }

    func isSelfChat(_ id: Chat.ID) -> Bool {
        guard let user = selfJID?.split(separator: "@").first else { return false }
        return id == user + "@s.whatsapp.net"
    }

    private func markSelfChatRead() {
        guard let user = selfJID?.split(separator: "@").first,
              let i = indexByID[user + "@s.whatsapp.net"] else { return }
        for m in chats[i].messages.indices where chats[i].messages[m].isOutgoing {
            let status = chats[i].messages[m].status
            if status == .sent || status == .delivered { chats[i].messages[m].status = .read }
        }
    }

    private func loadCache() {
        guard let data = try? Data(contentsOf: cacheURL),
              let decoded = try? JSONDecoder().decode([Chat].self, from: data) else { return }
        chats = decoded.filter { chat in
            !Self.isHidden(chat.id) && !(chat.messages.isEmpty && chat.title == chat.id && !chat.isLocked)
        }
        relocateStalePaths()
        rebuildIndex()
    }

    private func relocateStalePaths() {
        let fm = FileManager.default
        func relocate(_ path: String?, into folder: String) -> String? {
            guard let path, !path.isEmpty, !fm.fileExists(atPath: path) else { return path }
            let candidate = baseURL.appendingPathComponent(folder).appendingPathComponent((path as NSString).lastPathComponent).path
            return fm.fileExists(atPath: candidate) ? candidate : path
        }
        for i in chats.indices {
            chats[i].avatarPath = relocate(chats[i].avatarPath, into: "avatars")
            for m in chats[i].messages.indices {
                chats[i].messages[m].mediaPath = relocate(chats[i].messages[m].mediaPath, into: "media")
            }
        }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            self?.persistNow()
        }
    }

    func persistNow() {
        let trimmed = chats.map { chat -> Chat in
            var copy = chat
            if copy.messages.count > 500 { copy.messages = Array(copy.messages.suffix(500)) }
            return copy
        }
        guard let data = try? JSONEncoder().encode(trimmed) else { return }
        try? data.write(to: cacheURL, options: .atomic)
    }
}
