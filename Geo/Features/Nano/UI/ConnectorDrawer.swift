import AppKit
import SwiftUI

struct ConnectorDrawer: View {
    let id: String
    @EnvironmentObject private var service: HermesStatusService
    @Environment(\.dismiss) private var dismiss

    @State private var telegramToken: String = ""
    @State private var tokenSaveError: String?
    @State private var tokenSaved: Bool = false
    @State private var confirmDisconnect: Bool = false

    private var connector: HermesConnector? {
        service.connectors.first(where: { $0.id == id })
    }

    private var title: String {
        connector?.name ?? id.capitalized
    }

    private var icon: String {
        connector?.icon ?? "puzzlepiece.fill"
    }

    private var tint: Color {
        connector?.tint ?? .accentColor
    }

    private var isConnected: Bool {
        if case .connected = connector?.status { return true }
        return false
    }

    private var isPairing: Bool {
        if case .connecting = connector?.status { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            statePill
            Group {
                switch id {
                case "whatsapp": whatsappBody
                case "gmail": gmailBody
                case "telegram": telegramBody
                default: EmptyView()
                }
            }
            if let identity = connector?.identity, !identity.isEmpty {
                Text(identity)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            actionButtons
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(minWidth: 420, minHeight: 360)
        .confirmationDialog(
            "Disconnect \(title)?",
            isPresented: $confirmDisconnect
        ) {
            Button("Disconnect", role: .destructive) {
                service.requestDisconnect(id)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The agent will stop receiving messages from \(title) until you reconnect.")
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 22))
                .foregroundStyle(tint)
            Text(title)
                .font(.title3.weight(.semibold))
            Spacer()
        }
    }

    private var statePill: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(connector?.status.dot ?? .gray)
                .frame(width: 9, height: 9)
            Text(stateLabel)
                .font(.caption.weight(.medium))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(Color.secondary.opacity(0.12)))
    }

    private var stateLabel: String {
        guard let connector else { return "Unknown" }
        switch connector.status {
        case .disconnected: return "Disconnected"
        case .connecting:
            if let detail = connector.detail, detail.lowercased().contains("qr") { return "Scan QR" }
            return "Connecting"
        case .connected:
            if let identity = connector.identity, !identity.isEmpty { return "Connected (\(identity))" }
            return "Connected"
        case .error(let msg): return "Error: \(msg)"
        }
    }

    @ViewBuilder
    private var whatsappBody: some View {
        if isPairing {
            qrPanel
        } else if !isConnected {
            Text("Pair WhatsApp to let the agent read and reply to messages.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var gmailBody: some View {
        if !isConnected {
            Text("Authorize Gmail so the agent can read and send mail on your behalf.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var telegramBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Paste your Telegram bot token. The agent will pair using this bot.")
                .font(.caption)
                .foregroundStyle(.secondary)
            SecureField("Bot token", text: $telegramToken)
                .textFieldStyle(.roundedBorder)
            HStack(spacing: 8) {
                Button("Save token") { saveTelegramToken() }
                    .buttonStyle(.bordered)
                    .disabled(telegramToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if tokenSaved {
                    Label("Saved", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }
            if let tokenSaveError {
                Text(tokenSaveError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private var actionButtons: some View {
        HStack(spacing: 8) {
            Button(pairLabel) { service.requestPair(id) }
                .buttonStyle(.borderedProminent)
                .disabled(isPairing || isConnected)
            Button("Disconnect") { confirmDisconnect = true }
                .buttonStyle(.bordered)
                .disabled(!isConnected)
        }
    }

    private var pairLabel: String {
        switch id {
        case "gmail": return "Authorize"
        case "telegram": return "Pair"
        default: return "Pair"
        }
    }

    private var qrPanel: some View {
        VStack(alignment: .center, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white)
                    .frame(width: 256, height: 256)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                    )
                if let qr = service.whatsappQR {
                    Image(nsImage: qr)
                        .resizable()
                        .interpolation(.none)
                        .scaledToFit()
                        .padding(8)
                        .frame(width: 256, height: 256)
                } else {
                    VStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Generating QR…")
                            .font(.caption)
                            .foregroundStyle(.black.opacity(0.55))
                    }
                }
            }
            Text("WhatsApp → Settings → Linked Devices → Link a Device")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    private func saveTelegramToken() {
        let trimmed = telegramToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        tokenSaved = false
        tokenSaveError = nil
        Task {
            do {
                try await service.saveTelegramBotToken(trimmed)
                tokenSaved = true
                telegramToken = ""
                try? await Task.sleep(nanoseconds: 800_000_000)
                dismiss()
            } catch {
                tokenSaveError = "Hermes refused token: \(error.localizedDescription)"
            }
        }
    }
}
