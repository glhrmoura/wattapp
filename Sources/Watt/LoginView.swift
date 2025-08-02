import SwiftUI
import CoreImage.CIFilterBuiltins

struct LoginView: View {
    @Environment(ChatStore.self) private var store

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 32)
            HStack(alignment: .center, spacing: 64) {
                instructions
                    .frame(maxWidth: 400, alignment: .leading)
                VStack(spacing: 16) {
                    qrArea
                        .frame(width: 264, height: 264)
                    Text("O código é atualizado automaticamente")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 56)
            .padding(.vertical, 52)
            .background(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(Color.primary.opacity(0.035))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
            )
            Spacer(minLength: 32)
            HStack(spacing: 6) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 10))
                Text("Suas mensagens pessoais são protegidas com a criptografia de ponta a ponta.")
                    .font(.system(size: 12))
            }
            .foregroundStyle(.tertiary)
            .padding(.bottom, 28)
        }
        .padding(.horizontal, 48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var instructions: some View {
        VStack(alignment: .leading, spacing: 32) {
            VStack(alignment: .leading, spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 52, height: 52)
                    .padding(.leading, -4)
                Text("Entrar no Watt")
                    .font(.system(size: 30, weight: .semibold))
                Text("Use o WhatsApp do seu celular para conectar este Mac.")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 18) {
                step(1, Text("Abra o ") + Text("WhatsApp").bold() + Text(" no seu celular"))
                step(2, Text("Toque em ") + Text("Mais opções ⋮").bold() + Text(" ou ") + Text("Configurações ⚙︎").bold())
                step(3, Text("Toque em ") + Text("Aparelhos conectados").bold() + Text(" e depois em ") + Text("Conectar aparelho").bold())
                step(4, Text("Aponte o celular para esta tela para escanear o código"))
            }
        }
    }

    @ViewBuilder
    private var qrArea: some View {
        switch store.connection {
        case .waitingQR(let code):
            if let image = QRCode.image(for: code) {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .padding(18)
                    .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.white))
                    .transition(.opacity)
            }
        case .pairing:
            VStack(spacing: 12) {
                ProgressView()
                Text("Conectando e sincronizando conversas…")
                    .font(.system(size: 13))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
        case .failed(let message):
            VStack(spacing: 12) {
                Image(systemName: "wifi.exclamationmark").font(.largeTitle).foregroundStyle(.secondary)
                Text(message).multilineTextAlignment(.center).foregroundStyle(.secondary)
                Button("Tentar novamente") { store.startBridge() }
                    .pointerStyle(.link)
            }
        default:
            ProgressView()
        }
    }

    private func step(_ number: Int, _ text: Text) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text("\(number)")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Color.black)
                .frame(width: 24, height: 24)
                .background(Circle().fill(Palette.accent))
            text
                .font(.system(size: 15))
                .foregroundStyle(.primary.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 3)
        }
    }
}

enum QRCode {
    static func image(for string: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "L"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let cg = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: output.extent.width, height: output.extent.height))
    }
}

struct ConnectionIndicator: View {
    @Environment(ChatStore.self) private var store

    var body: some View {
        switch store.connection {
        case .connected:
            EmptyView()
        case .failed(let message):
            Button {
                store.startBridge()
            } label: {
                Image(systemName: "wifi.exclamationmark")
                    .foregroundStyle(.red)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerStyle(.link)
            .help("\(message) — clique para reconectar")
        default:
            ProgressView()
                .progressViewStyle(.circular)
                .controlSize(.small)
                .frame(width: 32, height: 32)
                .help("Conectando…")
        }
    }
}
