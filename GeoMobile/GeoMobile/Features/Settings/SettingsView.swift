import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var baseURL = BridgeConfig.baseURLString
    @State private var token = BridgeConfig.token
    @State private var termToken = BridgeConfig.termToken
    @State private var isTesting = false
    @State private var testResult: String?
    @State private var urlError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("URL", text: $baseURL)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    SecureField("Token", text: $token)
                    SecureField("Terminal token", text: $termToken)
                    if let urlError {
                        Text(urlError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                } header: {
                    Text("Bridge")
                } footer: {
                    Text("URL must be https, or http to a tailnet IP (100.64.0.0/10)")
                }
                .listRowBackground(Color.cardSurface)
                Section {
                    Button {
                        Task { await testConnection() }
                    } label: {
                        if isTesting {
                            ProgressView()
                        } else {
                            Text("Test Connection")
                                .fontWeight(.medium)
                                .foregroundStyle(Color.actionBlue)
                        }
                    }
                    .disabled(isTesting)
                    if let testResult {
                        Text(testResult)
                            .font(.caption)
                            .foregroundStyle(testResult == "Connected" ? .green : .red)
                    }
                }
                .listRowBackground(Color.cardSurface)
            }
            .scrollContentBackground(.hidden)
            .background(SkyBackground())
            .tint(.actionBlue)
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        if save() {
                            dismiss()
                        }
                    }
                }
            }
        }
    }

    @discardableResult
    private func save() -> Bool {
        BridgeConfig.token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        BridgeConfig.termToken = termToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard BridgeConfig.isAllowedBaseURL(trimmedURL) else {
            urlError = "URL must be https, or http to a tailnet IP (100.64.0.0/10)"
            return false
        }
        BridgeConfig.baseURLString = trimmedURL
        urlError = nil
        return true
    }

    private func testConnection() async {
        save()
        isTesting = true
        defer { isTesting = false }
        do {
            try await BridgeClient.shared.health()
            testResult = "Connected"
        } catch {
            testResult = error.localizedDescription
        }
    }
}

#Preview {
    SettingsView()
}
