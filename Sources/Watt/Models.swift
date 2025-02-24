import Foundation

enum DeliveryStatus: String, Codable, Comparable {
    case failed, sending, sent, delivered, read

    private var rank: Int {
        switch self {
        case .failed: 0
        case .sending: 1
        case .sent: 2
        case .delivered: 3
        case .read: 4
        }
    }

    static func < (lhs: DeliveryStatus, rhs: DeliveryStatus) -> Bool { lhs.rank < rhs.rank }
}

struct Message: Identifiable, Codable, Hashable {
    var id: String
    var text: String
    var date: Date
    var isOutgoing: Bool
    var status: DeliveryStatus = .read
    var senderJID: String?
    var senderName: String?
    var mediaKind: String?
    var mediaPath: String?
    var caption: String?
    var reactions: [String: String]?
    var fileName: String?
    var fileSize: Int?
    var revoked: Bool?
    var duration: Int?
    var waveform: [UInt8]?
    var linkPreview: LinkPreview?
    var quoted: QuotedMessage?

    var canReply: Bool { !id.hasPrefix("tmp-") && !(revoked ?? false) }

    var quoteText: String {
        if mediaKind == "sticker" { return "Figurinha" }
        return text
    }

    var canForward: Bool {
        guard !(revoked ?? false), !isViewOnce else { return false }
        if mediaKind == "image" || mediaKind == "sticker" { return mediaPath != nil }
        return mediaKind == nil
    }

    var isViewOnce: Bool {
        mediaKind == "view_once" || text.hasSuffix("visualização única · abra no celular")
    }

    var viewOnceTitle: String {
        guard mediaKind != "view_once" else { return text }
        let trimmed = text.replacingOccurrences(of: " · abra no celular", with: "")
        guard let space = trimmed.firstIndex(of: " ") else { return trimmed }
        return String(trimmed[trimmed.index(after: space)...])
    }
}

struct QuotedMessage: Codable, Hashable {
    var id: String
    var senderJID: String?
    var senderName: String?
    var fromMe: Bool
    var text: String
    var mediaKind: String?
    var thumbnail: Data?
}

struct LinkPreview: Codable, Hashable {
    var url: String
    var title: String
    var description: String
    var thumbnail: Data?
}

struct Chat: Identifiable, Codable, Hashable {
    var id: String
    var title: String
    var isGroup: Bool
    var messages: [Message] = []
    var unreadCount: Int = 0
    var isPinned: Bool = false
    var isMuted: Bool = false
    var isArchived: Bool = false
    var draft: String = ""
    var avatarID: String?
    var avatarPath: String?
    var favorite: Bool?
    var blocked: Bool?
    var isBlocked: Bool { blocked ?? false }
    var locked: Bool?
    var members: [String]?
    var isLocked: Bool {
        get { locked ?? false }
        set { locked = newValue }
    }

    var isFavorite: Bool {
        get { favorite ?? false }
        set { favorite = newValue }
    }
    var displayTitle: String { Formatters.phone(title) }

    var lastMessage: Message? { messages.last }
    var lastActivity: Date { messages.last?.date ?? .distantPast }
    var colorIndex: Int { id.unicodeScalars.reduce(0) { $0 + Int($1.value) } }

    var subtitle: String {
        if isGroup { return members.map { $0.joined(separator: ", ") } ?? "Grupo" }
        guard let user = id.split(separator: "@").first, id.hasSuffix("s.whatsapp.net") else { return "" }
        return "+" + user
    }
}

struct Contact: Identifiable, Hashable {
    let id: String
    let name: String
}

enum ChatFilter: String, CaseIterable, Identifiable {
    case all = "Tudo"
    case favorites = "Favoritas"
    case unread = "Não lidas"
    case groups = "Grupos"

    var id: String { rawValue }
    static let optional: [ChatFilter] = [.unread, .groups]
}

enum ConnectionState: Equatable {
    case starting
    case waitingQR(String)
    case pairing
    case connected(name: String)
    case disconnected
    case failed(String)
}
