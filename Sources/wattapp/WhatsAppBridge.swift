import Foundation

struct BridgeContact: Decodable {
    let jid: String
    let name: String
}

struct BridgeEvent: Decodable {
    let type: String
    var code: String?
    var message: String?
    var jid: String?
    var name: String?
    var isGroup: Bool?
    var chat: String?
    var id: String?
    var ids: [String]?
    var sender: String?
    var senderName: String?
    var fromMe: Bool?
    var text: String?
    var timestamp: Double?
    var history: Bool?
    var status: String?
    var tempId: String?
    var count: Int?
    var pictureId: String?
    var path: String?
    var fallback: Bool?
    var media: String?
    var caption: String?
    var archived: Bool?
    var pinned: Bool?
    var muted: Bool?
    var unread: Bool?
    var locked: Bool?
    var contacts: [BridgeContact]?
    var names: [String]?
    var fileName: String?
    var fileSize: Int?
    var seconds: Int?
    var waveform: String?
    var previewURL: String?
    var previewTitle: String?
    var previewDescription: String?
    var previewThumb: String?
    var quotedId: String?
    var quotedText: String?
    var quotedThumb: String?
    var quotedMedia: String?
    var quotedFromMe: Bool?
    var quotedSender: String?
    var quotedSenderName: String?
}

final class WhatsAppBridge: @unchecked Sendable {
    private var process: Process?
    private var input: FileHandle?
    private var buffer = Data()
    private let queue = DispatchQueue(label: "wattapp.bridge")
    private let onEvents: @Sendable ([BridgeEvent]) -> Void
    private let onExit: @Sendable (Int32) -> Void

    init(onEvents: @escaping @Sendable ([BridgeEvent]) -> Void, onExit: @escaping @Sendable (Int32) -> Void) {
        self.onEvents = onEvents
        self.onExit = onExit
    }

    static var executableURL: URL? {
        let candidates = [
            Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("wattapp-bridge"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("build/wattapp-bridge")
        ]
        return candidates.compactMap { $0 }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    func start(databaseURL: URL) throws {
        guard let url = Self.executableURL else {
            throw NSError(domain: "WattApp", code: 1, userInfo: [NSLocalizedDescriptionKey: "wattapp-bridge não encontrado"])
        }
        let process = Process()
        process.executableURL = url
        process.arguments = [databaseURL.path]
        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let self else { return }
            self.queue.async { self.consume(data) }
        }
        process.terminationHandler = { [weak self] p in
            stdout.fileHandleForReading.readabilityHandler = nil
            self?.onExit(p.terminationStatus)
        }
        try process.run()
        self.process = process
        self.input = stdin.fileHandleForWriting
    }

    func stop() {
        try? input?.close()
        process?.terminate()
        process = nil
    }

    func send(_ command: [String: Any]) {
        guard let input, let json = try? JSONSerialization.data(withJSONObject: command) else { return }
        let line = json + Data([0x0A])
        queue.async { try? input.write(contentsOf: line) }
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        var events: [BridgeEvent] = []
        let decoder = JSONDecoder()
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            if let event = try? decoder.decode(BridgeEvent.self, from: line) {
                events.append(event)
            }
        }
        if !events.isEmpty { onEvents(events) }
    }
}
