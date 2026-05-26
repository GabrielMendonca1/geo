import SwiftUI

struct AIKeySettingsView: View {
    @State private var keyInput: String = ""
    @State private var hasSavedKey: Bool = AIKeychainService.readKey() != nil
    @State private var errorText: String?
    @State private var showSaved: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("AI Task Parsing")
                .font(.headline)

            Text("Uses Claude Haiku for natural-language quick-add when the local parser isn't confident. Key stored in Keychain.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                SecureField("sk-ant-…", text: $keyInput)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 280)
                Button("Save") { save() }
                    .disabled(keyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if hasSavedKey {
                    Button("Clear", role: .destructive) { clear() }
                }
            }

            if let errorText {
                Label(errorText, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if showSaved {
                Label("Saved", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }

            if hasSavedKey && keyInput.isEmpty && !showSaved {
                Label("Key is configured", systemImage: "key.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .frame(width: 480, alignment: .leading)
    }

    private func save() {
        let trimmed = keyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorText = "Enter a key before saving."
            return
        }
        let ok = AIKeychainService.saveKey(trimmed)
        if ok {
            errorText = nil
            showSaved = true
            hasSavedKey = true
            keyInput = ""
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                showSaved = false
            }
        } else {
            errorText = "Failed to save key to Keychain."
        }
    }

    private func clear() {
        let ok = AIKeychainService.deleteKey()
        if ok {
            hasSavedKey = false
            showSaved = false
            errorText = nil
            keyInput = ""
        } else {
            errorText = "Failed to delete key from Keychain."
        }
    }
}

#Preview {
    AIKeySettingsView()
}
