import SwiftUI
import AppKit
import AVFoundation
import ImageIO
import QuickLookThumbnailing
import UniformTypeIdentifiers

struct Attachment: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable { case image, video, audio, document, sticker, voice }

    let id = UUID()
    let url: URL
    let kind: Kind
    var seconds: Int?
    var waveform: [UInt8]?

    var fileName: String { url.lastPathComponent }
    var type: UTType? { UTType(filenameExtension: url.pathExtension) }

    var byteCount: Int { (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }

    var fileSize: String {
        ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file)
    }

    static func media(_ url: URL) -> Attachment {
        let type = UTType(filenameExtension: url.pathExtension)
        if type?.conforms(to: .image) == true { return Attachment(url: url, kind: .image) }
        if ["mp4", "m4v"].contains(url.pathExtension.lowercased()) { return Attachment(url: url, kind: .video) }
        return Attachment(url: url, kind: .document)
    }

    static func dropped(_ url: URL) -> Attachment {
        let type = UTType(filenameExtension: url.pathExtension)
        if type?.conforms(to: .audio) == true { return Attachment(url: url, kind: .audio) }
        return media(url)
    }

    func label(caption: String) -> String {
        let base = switch kind {
        case .image: "📷 Foto"
        case .video: "🎥 Vídeo"
        case .sticker: "Figurinha"
        case .audio, .voice: "🎤 Áudio"
        case .document: "📄 " + fileName
        }
        return caption.isEmpty ? base : base + " · " + caption
    }

    func command(chat: String, tempID: String, caption: String, directory: URL) async -> [String: any Sendable]? {
        var command: [String: any Sendable] = [
            "cmd": "send_media", "chat": chat, "tempId": tempID, "text": caption,
            "kind": kind.rawValue, "fileName": fileName, "path": url.path,
            "mime": type?.preferredMIMEType ?? "application/octet-stream"
        ]
        switch kind {
        case .image:
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let full = Self.render(source, maxPixel: 2560),
                  let data = Self.jpeg(full, quality: 0.85) else { return nil }
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let output = directory.appendingPathComponent(UUID().uuidString + ".jpg")
            guard (try? data.write(to: output)) != nil else { return nil }
            command["path"] = output.path
            command["mime"] = "image/jpeg"
            command["width"] = full.width
            command["height"] = full.height
            if let thumb = Self.render(source, maxPixel: 100).flatMap({ Self.jpeg($0, quality: 0.6) }) {
                command["thumb"] = thumb.base64EncodedString()
            }
        case .sticker:
            break
        case .video:
            let asset = AVURLAsset(url: url)
            if let duration = try? await asset.load(.duration) { command["seconds"] = Int(duration.seconds.rounded()) }
            if let track = try? await asset.loadTracks(withMediaType: .video).first,
               let size = try? await track.load(.naturalSize),
               let transform = try? await track.load(.preferredTransform) {
                let rect = CGRect(origin: .zero, size: size).applying(transform)
                command["width"] = Int(abs(rect.width))
                command["height"] = Int(abs(rect.height))
            }
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 200, height: 200)
            if let frame = try? await generator.image(at: .zero).image, let thumb = Self.jpeg(frame, quality: 0.6) {
                command["thumb"] = thumb.base64EncodedString()
            }
            command["mime"] = "video/mp4"
        case .audio:
            if let duration = try? await AVURLAsset(url: url).load(.duration) { command["seconds"] = Int(duration.seconds.rounded()) }
        case .voice:
            command["seconds"] = seconds ?? 0
            command["waveform"] = Data(waveform ?? []).base64EncodedString()
            command["mime"] = "audio/ogg; codecs=opus"
        case .document:
            break
        }
        return command
    }

    private static func render(_ source: CGImageSource, maxPixel: Int) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private static func jpeg(_ image: CGImage, quality: Double) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}

enum AttachmentPicker {
    @MainActor
    static func choose(types: [UTType], completion: @escaping ([URL]) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = types
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window) { response in
                if response == .OK { completion(panel.urls) }
            }
        } else if panel.runModal() == .OK {
            completion(panel.urls)
        }
    }
}

struct AttachmentMenu: View {
    @Environment(\.colorScheme) private var scheme
    var onFiles: () -> Void
    var onMedia: () -> Void

    private let columns = Array(repeating: GridItem(.fixed(78), spacing: 12), count: 4)

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
            item("Arquivo", symbol: "folder.fill", color: Color(red: 0.31, green: 0.62, blue: 0.91), action: onFiles)
            item("Fotos e vídeos", symbol: "photo.fill.on.rectangle.fill", color: Color(red: 0.33, green: 0.6, blue: 0.98), action: onMedia)
            item("Enquete", symbol: "text.alignleft", color: Color(red: 1, green: 0.73, blue: 0.22), action: nil)
            item("Evento", symbol: "calendar", color: Color(red: 0.86, green: 0.2, blue: 0.27), action: nil)
            item("Contato", symbol: "person.crop.circle", color: Color(red: 0.98, green: 0.45, blue: 0.25), action: nil)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 18)
    }

    private func item(_ title: String, symbol: String, color: Color, action: (() -> Void)?) -> some View {
        Button {
            action?()
        } label: {
            VStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(color)
                    .frame(width: 60, height: 60)
                    .background(Circle().fill(Color.primary.opacity(scheme == .dark ? 0.1 : 0.06)))
                Text(title)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .fixedSize()
            }
            .frame(width: 78)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerStyle(action == nil ? nil : .link)
        .disabled(action == nil)
        .opacity(action == nil ? 0.4 : 1)
        .help(action == nil ? "Ainda não disponível" : title)
    }
}

struct AttachmentPreview: View {
    @Environment(ChatStore.self) private var store
    let chat: Chat
    @State private var selection: Attachment.ID?
    @State private var caption = ""
    @State private var showEmojis = false
    @FocusState private var captionFocused: Bool

    private var items: [Attachment] { store.attachmentItems }
    private var current: Attachment? { items.first { $0.id == selection } ?? items.first }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                if let current {
                    Text(current.fileName)
                        .font(.system(size: 17, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.horizontal, 90)
                }
                HStack {
                    Button(action: close) {
                        Image(systemName: "xmark")
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(.white)
                            .frame(width: 40, height: 40)
                            .background(Circle().fill(Color.white.opacity(0.1)))
                    }
                    .buttonStyle(.plain)
                    .pointerStyle(.link)
                    .keyboardShortcut(.cancelAction)
                    Spacer()
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .frame(height: 62)

            Group {
                if let current { AttachmentPage(item: current) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 60)
            .padding(.vertical, 18)

            if items.count > 1 {
                thumbnails.padding(.bottom, 12)
            }

            HStack(spacing: 8) {
                TextField("", text: $caption, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .lineLimit(1...4)
                    .focused($captionFocused)
                    .onKeyPress(.return, phases: .down) { press in
                        if press.modifiers.contains(.shift) { return .ignored }
                        send()
                        return .handled
                    }
                Button { showEmojis.toggle() } label: {
                    SmileyIcon()
                        .foregroundStyle(showEmojis ? Palette.accent : .primary)
                        .frame(width: 20, height: 20)
                        .frame(width: 30, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointerStyle(.link)
                .popover(isPresented: $showEmojis, arrowEdge: .top) {
                    EmojiGrid(query: "") { caption += $0 }
                        .frame(width: 380, height: 420)
                }
            }
            .padding(.leading, 18)
            .padding(.trailing, 10)
            .padding(.vertical, 8)
            .frame(minHeight: 44)
            .frame(maxWidth: 360)
            .overlay(Capsule().stroke(Color.white.opacity(0.25)))
            .padding(.bottom, 10)

            HStack {
                Text(chat.isGroup || !store.isSelfChat(chat.id) ? chat.displayTitle : "Você")
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(1)
                    .padding(.horizontal, 12)
                    .frame(height: 32)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.1)))
                Spacer()
                Button(action: send) {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 19, weight: .semibold))
                        .rotationEffect(.degrees(45))
                        .offset(x: -2)
                        .foregroundStyle(.black)
                        .frame(width: 46, height: 46)
                        .background(Circle().fill(Palette.accent))
                }
                .buttonStyle(.plain)
                .pointerStyle(.link)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color.black)
        }
        .foregroundStyle(.white)
        .background(Color(white: 0.07))
        .environment(\.colorScheme, .dark)
        .onAppear { captionFocused = true }
        .onChange(of: items.isEmpty) { _, empty in if empty { close() } }
    }

    private var thumbnails: some View {
        HStack(spacing: 8) {
            ForEach(items) { item in
                let selected = item.id == current?.id
                AttachmentThumb(item: item)
                    .frame(width: 52, height: 52)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected ? Palette.accent : .clear, lineWidth: 2))
                    .overlay(alignment: .topTrailing) {
                        if selected {
                            Button {
                                store.attachmentItems.removeAll { $0.id == item.id }
                                selection = nil
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(.white, .black.opacity(0.7))
                            }
                            .buttonStyle(.plain)
                            .offset(x: 5, y: -5)
                        }
                    }
                    .onTapGesture { selection = item.id }
                    .pointerStyle(.link)
            }
            Button(action: addMore) {
                Image(systemName: "plus")
                    .font(.system(size: 18))
                    .frame(width: 52, height: 52)
                    .background(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [4])))
            }
            .buttonStyle(.plain)
            .pointerStyle(.link)
        }
    }

    private func addMore() {
        let kind = items.first?.kind ?? .image
        let types: [UTType] = kind == .document ? [.item] : [.image, .movie]
        AttachmentPicker.choose(types: types) { urls in
            store.attachmentItems += urls.map { kind == .document ? Attachment(url: $0, kind: .document) : Attachment.media($0) }
        }
    }

    private func send() {
        guard !items.isEmpty else { return }
        store.sendAttachments(items, caption: caption, to: chat.id)
        close()
    }

    private func close() {
        store.dismissAttachments()
    }
}

struct AttachmentPage: View {
    let item: Attachment
    @State private var preview: NSImage?

    var body: some View {
        Group {
            if item.kind == .image, let image = ImageCache.shared.image(at: item.url.path) {
                Image(nsImage: image).resizable().scaledToFit()
            } else if let preview {
                Image(nsImage: preview).resizable().scaledToFit()
                    .shadow(color: .black.opacity(0.4), radius: 6)
            } else {
                VStack(spacing: 12) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path))
                        .resizable()
                        .frame(width: 128, height: 128)
                    Text(item.fileSize).foregroundStyle(.secondary)
                }
            }
        }
        .task(id: item.id) {
            preview = nil
            guard item.kind != .image else { return }
            preview = await QuickLookPreview.image(for: item.url, size: CGSize(width: 900, height: 1100))
        }
    }
}

struct AttachmentThumb: View {
    let item: Attachment
    @State private var preview: NSImage?

    var body: some View {
        Group {
            if item.kind == .image, let image = ImageCache.shared.image(at: item.url.path) {
                Image(nsImage: image).resizable().scaledToFill()
            } else if let preview {
                Image(nsImage: preview).resizable().scaledToFill()
            } else {
                Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path)).resizable().padding(8)
            }
        }
        .task(id: item.id) {
            guard item.kind != .image else { return }
            preview = await QuickLookPreview.image(for: item.url, size: CGSize(width: 120, height: 120))
        }
    }
}

enum QuickLookPreview {
    static func image(for url: URL, size: CGSize) async -> NSImage? {
        let scale = await MainActor.run { NSScreen.main?.backingScaleFactor ?? 2 }
        let request = QLThumbnailGenerator.Request(fileAt: url, size: size, scale: scale, representationTypes: .thumbnail)
        guard let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) else { return nil }
        return representation.nsImage
    }
}
