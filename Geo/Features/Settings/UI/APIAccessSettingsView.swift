import SwiftUI
import AppKit

struct APIAccessSettingsView: View {
    @State private var tokens: [TokenSummary] = []
    @State private var port: UInt16 = 0
    @State private var newCallerId: String = ""
    @State private var newScope: TokenScope = .read
    @State private var newExpiry: Date = Date().addingTimeInterval(60 * 60 * 24 * 90)
    @State private var hasExpiry: Bool = false
    @State private var freshToken: String?
    @State private var copyConfirmation: String?

    private let tokenStore: APITokenStore = .shared

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            endpointCard
            tokensCard
            addTokenCard
        }
        .onAppear {
            refresh()
        }
        .sheet(item: revealBinding) { reveal in
            tokenRevealSheet(reveal: reveal)
        }
    }

    private var endpointCard: some View {
        APICard(title: "Endpoint", description: "Local-only HTTP API. Bind to 127.0.0.1.") {
            HStack(spacing: 10) {
                Text(endpointURL)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(endpointURL, forType: .string)
                    copyConfirmation = "Copied URL"
                    Task { try? await Task.sleep(nanoseconds: 1_500_000_000); copyConfirmation = nil }
                }
                .buttonStyle(.bordered)
            }
            if let msg = copyConfirmation {
                Text(msg).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var tokensCard: some View {
        APICard(title: "Tokens", description: "Bearer tokens stored hashed in macOS Keychain.") {
            if tokens.isEmpty {
                Text("No tokens yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 8) {
                    ForEach(tokens, id: \.callerId) { tok in
                        tokenRow(tok)
                    }
                }
            }
            HStack {
                Button("Refresh") { refresh() }.buttonStyle(.bordered)
            }
        }
    }

    private var addTokenCard: some View {
        APICard(title: "Add token", description: "Caller ID labels the consumer (e.g. hermes-runtime, cli-tool).") {
            VStack(alignment: .leading, spacing: 12) {
                TextField("Caller ID", text: $newCallerId)
                    .textFieldStyle(.roundedBorder)
                Picker("Scope", selection: $newScope) {
                    Text("read").tag(TokenScope.read)
                    Text("read+write").tag(TokenScope.readWrite)
                    Text("read+write+destructive").tag(TokenScope.readWriteDestructive)
                }
                .pickerStyle(.segmented)
                Toggle("Has expiry", isOn: $hasExpiry)
                if hasExpiry {
                    DatePicker("Expires", selection: $newExpiry, displayedComponents: [.date])
                }
                HStack {
                    Spacer()
                    Button("Generate token") { generate() }
                        .buttonStyle(.borderedProminent)
                        .disabled(newCallerId.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func tokenRow(_ tok: TokenSummary) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(tok.callerId).font(.subheadline.weight(.semibold))
                Text("scope: \(tok.scope.rawValue) · last used: \(formatDate(tok.lastUsedAt)) · expires: \(formatDate(tok.expiresAt))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Revoke", role: .destructive) {
                _ = tokenStore.revoke(callerId: tok.callerId)
                refresh()
            }
            .buttonStyle(.bordered)
        }
        .padding(8)
        .background(Color.gray.opacity(0.08))
        .cornerRadius(6)
    }

    private func tokenRevealSheet(reveal: TokenReveal) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Token for \(reveal.callerId)")
                .font(.headline)
            Text("Copy this now — it will not be shown again.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(reveal.raw)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .padding(10)
                .background(Color.gray.opacity(0.12))
                .cornerRadius(6)
            HStack {
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(reveal.raw, forType: .string)
                }
                .buttonStyle(.borderedProminent)
                Spacer()
                Button("Close") { freshToken = nil }
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private var revealBinding: Binding<TokenReveal?> {
        Binding(
            get: { freshToken.map { TokenReveal(callerId: newCallerId, raw: $0) } },
            set: { _ in freshToken = nil }
        )
    }

    private var endpointURL: String {
        port == 0 ? "(starting…)" : "http://127.0.0.1:\(port)"
    }

    private func refresh() {
        tokens = tokenStore.list()
        port = readPortFromAPIInfo()
    }

    private func generate() {
        let id = newCallerId.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty else { return }
        let raw = tokenStore.add(callerId: id, scope: newScope, expiresAt: hasExpiry ? newExpiry : nil)
        freshToken = raw
        refresh()
    }

    private func formatDate(_ d: Date?) -> String {
        guard let d else { return "—" }
        let f = DateFormatter(); f.dateStyle = .short; f.timeStyle = .short
        return f.string(from: d)
    }

    private func readPortFromAPIInfo() -> UInt16 {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Geo/api.json")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let p = obj["port"] as? Int else {
            return 0
        }
        return UInt16(p)
    }
}

private struct TokenReveal: Identifiable {
    let callerId: String
    let raw: String
    var id: String { raw }
}

private struct APICard<Content: View>: View {
    let title: String
    let description: String
    let content: Content

    init(title: String, description: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.description = description
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            Text(description).font(.caption).foregroundStyle(.secondary)
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.gray.opacity(0.06))
        .cornerRadius(12)
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.15), lineWidth: 1))
    }
}
