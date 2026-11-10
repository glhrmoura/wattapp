import SwiftUI
import AppKit
@preconcurrency import AVFoundation
import CryptoKit

enum OggOpus {
    static func write(packets: [Data], preSkip: Int, totalSamples: Int) -> Data {
        var output = Data()
        let serial = UInt32.random(in: 1...UInt32.max)
        var sequence: UInt32 = 0

        var head = Data("OpusHead".utf8)
        head.append(1)
        head.append(1)
        head.appendLE(UInt16(preSkip))
        head.appendLE(UInt32(48000))
        head.appendLE(UInt16(0))
        head.append(0)
        output.append(page(packets: [head], granule: 0, serial: serial, sequence: &sequence, flags: 0x02))

        var tags = Data("OpusTags".utf8)
        let vendor = Data("WattApp".utf8)
        tags.appendLE(UInt32(vendor.count))
        tags.append(vendor)
        tags.appendLE(UInt32(0))
        output.append(page(packets: [tags], granule: 0, serial: serial, sequence: &sequence, flags: 0))

        let finalGranule = Int64(totalSamples + preSkip)
        var index = 0
        var granule: Int64 = 0
        while index < packets.count {
            var batch: [Data] = []
            var segments = 0
            while index < packets.count {
                let needed = packets[index].count / 255 + 1
                if segments + needed > 255 || batch.count >= 50 { break }
                batch.append(packets[index])
                segments += needed
                index += 1
            }
            granule += Int64(batch.count * 960)
            let last = index >= packets.count
            output.append(page(packets: batch, granule: last ? min(granule, finalGranule) : granule, serial: serial, sequence: &sequence, flags: last ? 0x04 : 0))
        }
        return output
    }

    static func read(_ data: Data) -> (channels: Int, preSkip: Int, packets: [Data])? {
        let bytes = [UInt8](data)
        var offset = 0
        var packets: [Data] = []
        var pending = Data()
        while offset + 27 <= bytes.count {
            guard bytes[offset] == 0x4F, bytes[offset + 1] == 0x67, bytes[offset + 2] == 0x67, bytes[offset + 3] == 0x53 else { return nil }
            let count = Int(bytes[offset + 26])
            guard offset + 27 + count <= bytes.count else { break }
            let lacing = bytes[(offset + 27)..<(offset + 27 + count)]
            var cursor = offset + 27 + count
            for value in lacing {
                let length = Int(value)
                guard cursor + length <= bytes.count else { return nil }
                pending.append(contentsOf: bytes[cursor..<(cursor + length)])
                cursor += length
                if value < 255 {
                    packets.append(pending)
                    pending = Data()
                }
            }
            offset = cursor
        }
        guard packets.count >= 2, packets[0].starts(with: Data("OpusHead".utf8)), packets[0].count >= 12 else { return nil }
        let head = [UInt8](packets[0])
        let channels = max(Int(head[9]), 1)
        let preSkip = Int(head[10]) | Int(head[11]) << 8
        return (channels, preSkip, Array(packets.dropFirst(2)))
    }

    private static func page(packets: [Data], granule: Int64, serial: UInt32, sequence: inout UInt32, flags: UInt8) -> Data {
        var lacing: [UInt8] = []
        var body = Data()
        for packet in packets {
            var remaining = packet.count
            while remaining >= 255 {
                lacing.append(255)
                remaining -= 255
            }
            lacing.append(UInt8(remaining))
            body.append(packet)
        }
        var header = Data("OggS".utf8)
        header.append(0)
        header.append(flags)
        header.appendLE(UInt64(bitPattern: granule))
        header.appendLE(serial)
        header.appendLE(sequence)
        header.appendLE(UInt32(0))
        header.append(UInt8(lacing.count))
        header.append(contentsOf: lacing)
        var page = header + body
        let crc = checksum(page)
        page.replaceSubrange(22..<26, with: withUnsafeBytes(of: crc.littleEndian) { Data($0) })
        sequence += 1
        return page
    }

    private static let table: [UInt32] = (0..<256).map { index in
        var value = UInt32(index) << 24
        for _ in 0..<8 {
            value = value & 0x8000_0000 != 0 ? (value << 1) ^ 0x04C1_1DB7 : value << 1
        }
        return value
    }

    private static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0
        for byte in data {
            crc = (crc << 8) ^ table[Int(((crc >> 24) ^ UInt32(byte)) & 0xFF)]
        }
        return crc
    }
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}

private final class Cursor: @unchecked Sendable {
    var value = 0
}

enum OpusCodec {
    static let pcmFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false)!

    static func opusFormat(channels: Int, framesPerPacket: UInt32 = 960) -> AVAudioFormat? {
        var description = AudioStreamBasicDescription(
            mSampleRate: 48000, mFormatID: kAudioFormatOpus, mFormatFlags: 0, mBytesPerPacket: 0,
            mFramesPerPacket: framesPerPacket, mBytesPerFrame: 0, mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 0, mReserved: 0
        )
        return AVAudioFormat(streamDescription: &description)
    }

    static func frameCount(_ packet: Data) -> UInt32 {
        guard let toc = packet.first else { return 960 }
        let config = Int(toc >> 3)
        let duration: Double
        switch config {
        case 0...11: duration = [10, 20, 40, 60][config % 4]
        case 12...15: duration = [10, 20][config % 2]
        default: duration = [2.5, 5, 10, 20][config % 4]
        }
        let frames: Int
        switch toc & 3 {
        case 0: frames = 1
        case 1, 2: frames = 2
        default: frames = packet.count > 1 ? Int(packet[packet.startIndex + 1] & 0x3F) : 1
        }
        return UInt32(duration * 48 * Double(max(frames, 1)))
    }

    static func encode(_ samples: [Float]) -> Data? {
        guard !samples.isEmpty, let opus = opusFormat(channels: 1),
              let converter = AVAudioConverter(from: pcmFormat, to: opus),
              let source = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: AVAudioFrameCount(samples.count)) else { return nil }
        converter.bitRate = 32000
        source.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        let fed = Cursor()
        var packets: [Data] = []
        while true {
            let output = AVAudioCompressedBuffer(format: opus, packetCapacity: 32, maximumPacketSize: max(converter.maximumOutputPacketSize, 1500))
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, inputStatus in
                if fed.value > 0 {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                fed.value = 1
                inputStatus.pointee = .haveData
                return source
            }
            for index in 0..<Int(output.packetCount) {
                guard let description = output.packetDescriptions?[index] else { continue }
                packets.append(Data(bytes: output.data.advanced(by: Int(description.mStartOffset)), count: Int(description.mDataByteSize)))
            }
            if status == .endOfStream || status == .error || (status == .inputRanDry && output.packetCount == 0) { break }
        }
        guard !packets.isEmpty else { return nil }
        let preSkip = Int(converter.primeInfo.leadingFrames) > 0 ? Int(converter.primeInfo.leadingFrames) : 312
        return OggOpus.write(packets: packets, preSkip: preSkip, totalSamples: samples.count)
    }

    static func decode(_ data: Data) -> AVAudioPCMBuffer? {
        guard let stream = OggOpus.read(data), !stream.packets.isEmpty,
              let opus = opusFormat(channels: stream.channels, framesPerPacket: 0),
              let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: AVAudioChannelCount(stream.channels), interleaved: false),
              let converter = AVAudioConverter(from: opus, to: output) else { return nil }
        let maxSize = stream.packets.map(\.count).max() ?? 1500
        var batches: [AVAudioCompressedBuffer] = []
        for start in stride(from: 0, to: stream.packets.count, by: 100) {
            let slice = stream.packets[start..<min(start + 100, stream.packets.count)]
            let buffer = AVAudioCompressedBuffer(format: opus, packetCapacity: AVAudioPacketCount(slice.count), maximumPacketSize: maxSize)
            var offset: Int64 = 0
            for (index, packet) in slice.enumerated() {
                packet.withUnsafeBytes { buffer.data.advanced(by: Int(offset)).copyMemory(from: $0.baseAddress!, byteCount: packet.count) }
                buffer.packetDescriptions?[index] = AudioStreamPacketDescription(mStartOffset: offset, mVariableFramesInPacket: frameCount(packet), mDataByteSize: UInt32(packet.count))
                offset += Int64(packet.count)
            }
            buffer.packetCount = AVAudioPacketCount(slice.count)
            buffer.byteLength = UInt32(offset)
            batches.append(buffer)
        }
        let next = Cursor()
        let batchList = batches
        var chunks: [[Float]] = Array(repeating: [], count: stream.channels)
        while true {
            guard let chunk = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: 96000) else { return nil }
            var error: NSError?
            let status = converter.convert(to: chunk, error: &error) { _, inputStatus in
                guard next.value < batchList.count else {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                inputStatus.pointee = .haveData
                defer { next.value += 1 }
                return batchList[next.value]
            }
            for channel in 0..<stream.channels {
                chunks[channel].append(contentsOf: UnsafeBufferPointer(start: chunk.floatChannelData![channel], count: Int(chunk.frameLength)))
            }
            if status != .haveData { break }
        }
        let skip = min(stream.preSkip, chunks[0].count)
        let frames = chunks[0].count - skip
        guard frames > 0, let result = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: AVAudioFrameCount(frames)) else { return nil }
        result.frameLength = AVAudioFrameCount(frames)
        for channel in 0..<stream.channels {
            chunks[channel].withUnsafeBufferPointer { result.floatChannelData![channel].update(from: $0.baseAddress!.advanced(by: skip), count: frames) }
        }
        return result
    }

    static func waveform(_ samples: [Float], bins: Int = 64) -> [UInt8] {
        guard !samples.isEmpty else { return Array(repeating: 0, count: bins) }
        let size = max(samples.count / bins, 1)
        let peaks = (0..<bins).map { bin -> Float in
            let start = min(bin * size, samples.count - 1)
            let end = min(start + size, samples.count)
            return samples[start..<end].reduce(0) { max($0, abs($1)) }
        }
        let top = max(peaks.max() ?? 1, 0.0001)
        return peaks.map { UInt8(min(100, max(0, ($0 / top) * 100))) }
    }
}

private final class TapProcessor: @unchecked Sendable {
    private let converter: AVAudioConverter?
    private let ratio: Double

    init(input: AVAudioFormat) {
        converter = AVAudioConverter(from: input, to: OpusCodec.pcmFormat)
        ratio = 48000 / input.sampleRate
    }

    func process(_ buffer: AVAudioPCMBuffer) -> [Float] {
        guard let converter else { return [] }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 64)
        guard let output = AVAudioPCMBuffer(pcmFormat: OpusCodec.pcmFormat, frameCapacity: capacity) else { return [] }
        let given = Cursor()
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if given.value > 0 {
                status.pointee = .noDataNow
                return nil
            }
            given.value = 1
            status.pointee = .haveData
            return buffer
        }
        return Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
    }
}

@MainActor
@Observable
final class VoiceRecorder {
    var isRecording = false
    var isPaused = false
    var levels: [Float] = []
    var denied = false
    private(set) var samples: [Float] = []
    @ObservationIgnored private var engine: AVAudioEngine?

    var elapsed: TimeInterval { Double(samples.count) / 48000 }

    func start() async {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .audio) else { denied = true; return }
        default:
            denied = true
            return
        }
        samples = []
        levels = []
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { return }
        let processor = TapProcessor(input: format)
        input.installTap(onBus: 0, bufferSize: 4096, format: format, block: Self.tapBlock(processor: processor) { [weak self] converted, level in
            guard let self, self.isRecording, !self.isPaused else { return }
            self.samples.append(contentsOf: converted)
            self.levels.append(level)
        })
        do {
            try engine.start()
            self.engine = engine
            isPaused = false
            isRecording = true
        } catch {
            input.removeTap(onBus: 0)
        }
    }

    nonisolated private static func tapBlock(processor: TapProcessor, deliver: @escaping @MainActor @Sendable ([Float], Float) -> Void) -> AVAudioNodeTapBlock {
        { buffer, _ in
            let converted = processor.process(buffer)
            guard !converted.isEmpty else { return }
            let rms = sqrt(converted.reduce(0) { $0 + $1 * $1 } / Float(converted.count))
            Task { @MainActor in deliver(converted, min(1, rms * 6)) }
        }
    }

    func pause() {
        engine?.pause()
        isPaused = true
    }

    func resume() {
        guard let engine else { return }
        try? engine.start()
        isPaused = false
    }

    func cancel() {
        stopEngine()
        samples = []
        levels = []
    }

    func finish() -> [Float] {
        stopEngine()
        let captured = samples
        samples = []
        levels = []
        return captured
    }

    private func stopEngine() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        isRecording = false
        isPaused = false
    }
}

@MainActor
@Observable
final class VoicePlayer: NSObject, AVAudioPlayerDelegate {
    static let shared = VoicePlayer()
    var currentID: String?
    var isPlaying = false
    var progress: Double = 0
    var currentTime: TimeInterval = 0
    var rate: Float = 1
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var timer: Timer?

    static var cacheDirectory: URL {
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("WattApp/audio")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func toggle(id: String, path: String) {
        if currentID == id, let player {
            if player.isPlaying { player.pause(); isPlaying = false; stopTimer() } else { player.play(); isPlaying = true; startTimer() }
            return
        }
        stop()
        currentID = id
        Task {
            guard let url = await Self.playableURL(for: path), currentID == id else { return }
            guard let player = try? AVAudioPlayer(contentsOf: url) else { return }
            player.delegate = self
            player.enableRate = true
            player.rate = rate
            player.prepareToPlay()
            player.play()
            self.player = player
            isPlaying = true
            startTimer()
        }
    }

    func seek(id: String, to fraction: Double) {
        guard currentID == id, let player else { return }
        player.currentTime = player.duration * min(max(fraction, 0), 1)
        tick()
    }

    func cycleRate() {
        rate = rate == 1 ? 1.5 : rate == 1.5 ? 2 : 1
        player?.rate = rate
    }

    func stop() {
        player?.stop()
        player = nil
        stopTimer()
        currentID = nil
        isPlaying = false
        progress = 0
        currentTime = 0
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.stop() }
    }

    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            Task { @MainActor in VoicePlayer.shared.tick() }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard let player, player.duration > 0 else { return }
        currentTime = player.currentTime
        progress = player.currentTime / player.duration
    }

    static func playableURL(for path: String) async -> URL? {
        let source = URL(fileURLWithPath: path)
        guard source.pathExtension.lowercased() == "ogg" || source.pathExtension.lowercased() == "opus" else { return source }
        let key = SHA256.hash(data: Data(path.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        let target = cacheDirectory.appendingPathComponent(key + ".caf")
        if FileManager.default.fileExists(atPath: target.path) { return target }
        return await Task.detached {
            guard let data = try? Data(contentsOf: source), let buffer = OpusCodec.decode(data),
                  let file = try? AVAudioFile(forWriting: target, settings: buffer.format.settings, commonFormat: .pcmFormatFloat32, interleaved: false) else { return nil }
            do {
                try file.write(from: buffer)
                return target
            } catch {
                return nil
            }
        }.value
    }
}

enum VoiceDraft {
    static func make(_ samples: [Float], directory: URL) async -> Attachment? {
        await Task.detached {
            guard let data = OpusCodec.encode(samples) else { return nil }
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent(UUID().uuidString + ".ogg")
            guard (try? data.write(to: url)) != nil else { return nil }
            var attachment = Attachment(url: url, kind: .voice)
            attachment.seconds = max(1, Int((Double(samples.count) / 48000).rounded()))
            attachment.waveform = OpusCodec.waveform(samples)
            return attachment
        }.value
    }
}

func formatDuration(_ seconds: TimeInterval) -> String {
    let total = max(0, Int(seconds.rounded(.down)))
    return String(format: "%d:%02d", total / 60, total % 60)
}

struct WaveformBars: View {
    let values: [Float]
    var progress: Double = 0
    var played: Color
    var pending: Color
    var count = 40
    var stretch = true
    var knob: Color?
    var onSeek: ((Double) -> Void)?

    private var samples: [Float] {
        if !stretch {
            return Array(values.suffix(count)) + Array(repeating: 0, count: max(0, count - values.count))
        }
        guard !values.isEmpty else { return Array(repeating: 0.15, count: count) }
        return (0..<count).map { index in
            let position = Double(index) / Double(max(count - 1, 1)) * Double(values.count - 1)
            return values[Int(position.rounded())]
        }
    }

    var body: some View {
        GeometryReader { proxy in
            let spacing: CGFloat = 2
            let width = max((proxy.size.width - spacing * CGFloat(count - 1)) / CGFloat(count), 1)
            HStack(alignment: .center, spacing: spacing) {
                ForEach(Array(samples.enumerated()), id: \.offset) { index, value in
                    Capsule()
                        .fill(Double(index) / Double(count) < progress ? played : pending)
                        .frame(width: width, height: max(3, CGFloat(value) * proxy.size.height))
                }
            }
            .frame(maxHeight: .infinity)
            .overlay(alignment: .leading) {
                if onSeek != nil {
                    Circle()
                        .fill(knob ?? played)
                        .frame(width: 12, height: 12)
                        .offset(x: max(0, proxy.size.width * progress - 6))
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onEnded { value in
                onSeek?(Double(value.location.x / max(proxy.size.width, 1)))
            })
        }
    }
}

struct VoiceMessageBody: View {
    @Environment(ChatStore.self) private var store
    @Environment(\.colorScheme) private var scheme
    let message: Message
    let timestamp: AnyView
    @State private var player = VoicePlayer.shared

    private var isCurrent: Bool { player.currentID == message.id }
    private var available: Bool { message.mediaPath.map { FileManager.default.fileExists(atPath: $0) } ?? false }
    private var values: [Float] { (message.waveform ?? []).map { Float($0) / 100 } }

    private var avatarPath: String? {
        if message.isOutgoing { return store.selfJID.flatMap { store.contactAvatars[$0] } }
        guard let sender = message.senderJID else { return nil }
        return store.contactAvatars[sender] ?? store.chat(sender)?.avatarPath
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            if message.isOutgoing { avatar }
            Button {
                if let path = message.mediaPath, available { player.toggle(id: message.id, path: path) }
            } label: {
                Image(systemName: isCurrent && player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(available ? Color.primary.opacity(0.85) : Color.secondary.opacity(0.4))
                    .frame(width: 30, height: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerStyle(available ? .link : nil)
            .help(available ? "" : "Áudio indisponível neste Mac")
            .padding(.leading, 6)
            VStack(alignment: .leading, spacing: 3) {
                WaveformBars(
                    values: values,
                    progress: isCurrent ? player.progress : 0,
                    played: Color.primary.opacity(0.9),
                    pending: Color.primary.opacity(0.45),
                    knob: message.isOutgoing ? .white : Palette.readTick,
                    onSeek: { player.seek(id: message.id, to: $0) }
                )
                .frame(width: 160, height: 28)
                .padding(.top, 6)
                HStack {
                    Text(formatDuration(isCurrent && player.currentTime > 0 ? player.currentTime : Double(message.duration ?? 0)))
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                    Spacer()
                    timestamp
                }
                .frame(width: 160)
            }
            if !message.isOutgoing { avatar }
        }
        .padding(.vertical, 2)
        .onAppear {
            if message.isOutgoing, let jid = store.selfJID { store.requestContactAvatar(jid) }
            else if let sender = message.senderJID { store.requestContactAvatar(sender) }
        }
    }

    private var avatar: some View {
        ZStack { avatarContent }
            .frame(width: 50, height: 46)
    }

    @ViewBuilder
    private var avatarContent: some View {
        if isCurrent {
            Button { player.cycleRate() } label: {
                Text(player.rate == 1 ? "1×" : player.rate == 1.5 ? "1,5×" : "2×")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 42, height: 26)
                    .background(Capsule().fill(Color.white.opacity(0.25)))
                    .frame(width: 50, height: 46)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerStyle(.link)
        } else {
            AvatarView(name: message.senderName ?? "", colorIndex: (message.senderJID ?? "").count, size: 46, imagePath: avatarPath)
                .overlay(alignment: message.isOutgoing ? .bottomTrailing : .bottomLeading) {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(message.isOutgoing ? Color.secondary : Palette.readTick)
                        .shadow(color: .black.opacity(0.6), radius: 1.5)
                        .offset(x: message.isOutgoing ? 6 : -6, y: 1)
                }
        }
    }
}

struct RecordingBar: View {
    @Bindable var recorder: VoiceRecorder
    var onSend: () -> Void
    @State private var blink = false

    var body: some View {
        HStack(spacing: 10) {
            circleButton(symbol: "trash", size: 16, help: "Descartar", action: recorder.cancel)
            HStack(spacing: 12) {
                Circle()
                    .fill(Color(red: 0.86, green: 0.2, blue: 0.25))
                    .frame(width: 10, height: 10)
                    .opacity(recorder.isPaused ? 1 : (blink ? 0.25 : 1))
                    .animation(recorder.isPaused ? nil : .easeInOut(duration: 0.6).repeatForever(), value: blink)
                Text(formatDuration(recorder.elapsed))
                    .font(.system(size: 15).monospacedDigit())
                    .frame(width: 40, alignment: .leading)
                GeometryReader { proxy in
                    let count = max(Int(proxy.size.width / 5), 8)
                    WaveformBars(
                        values: Array(recorder.levels.suffix(count)),
                        played: Color.primary.opacity(0.6),
                        pending: Color.primary.opacity(0.6),
                        count: count,
                        stretch: false
                    )
                }
                .frame(maxWidth: .infinity)
                .frame(height: 24)
            }
            .padding(.horizontal, 16)
            .frame(height: 36)
            .background(RoundedRectangle(cornerRadius: 20).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.secondary.opacity(0.2)))
            circleButton(symbol: recorder.isPaused ? "mic.fill" : "pause.fill", size: 15, help: recorder.isPaused ? "Continuar gravando" : "Pausar") {
                if recorder.isPaused { recorder.resume() } else { recorder.pause() }
            }
            Button(action: onSend) {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .rotationEffect(.degrees(45))
                    .offset(x: -1)
                    .foregroundStyle(.black)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Palette.accent))
            }
            .buttonStyle(.plain)
            .pointerStyle(.link)
            .keyboardShortcut(.return, modifiers: [])
            .help("Enviar")
        }
        .frame(height: 36)
        .onAppear { blink = true }
    }

    private func circleButton(symbol: String, size: CGFloat, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: 36, height: 36)
                .background(Circle().fill(Color.primary.opacity(0.1)))
                .overlay(Circle().stroke(Color.primary.opacity(0.08)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .help(help)
    }
}
