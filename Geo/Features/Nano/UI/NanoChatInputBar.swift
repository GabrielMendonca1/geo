import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct NanoChatInputBar: View {
    @Binding var draft: String
    @Binding var attachments: [NanoAttachment]
    let isSending: Bool
    let onSend: () -> Void
    let onStop: () -> Void

    @FocusState private var focused: Bool
    @State private var isDropTargeted: Bool = false

    private var canSend: Bool {
        (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty) && !isSending
    }

    var body: some View {
        VStack(spacing: 6) {
            if !attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(attachments) { attachment in
                            NanoAttachmentChip(attachment: attachment) {
                                attachments.removeAll { $0.id == attachment.id }
                            }
                        }
                    }
                    .padding(.horizontal, 2)
                }
                .frame(height: 42)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            HStack(alignment: .center, spacing: 8) {
                Button(action: pickFile) {
                    Image(systemName: "paperclip")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .help("Attach a file or image")

                inputField

                Button(action: { isSending ? onStop() : onSend() }) {
                    Image(systemName: isSending ? "stop.circle.fill" : "arrow.up.circle.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(canSend || isSending ? Color(red: 0.0, green: 0.33, blue: 1.0) : Color.secondary.opacity(0.4))
                        .symbolEffect(.pulse, isActive: isSending)
                }
                .buttonStyle(.plain)
                .disabled(!canSend && !isSending)
                .keyboardShortcut(.return, modifiers: [.command])
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.secondary.opacity(isDropTargeted ? 0.16 : 0.07))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    isDropTargeted
                        ? Color(red: 0.0, green: 0.33, blue: 1.0).opacity(0.5)
                        : Color.primary.opacity(focused ? 0.14 : 0.06),
                    lineWidth: isDropTargeted ? 1.5 : 1
                )
        )
        .onDrop(of: [.fileURL, .image], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers: providers)
        }
        .animation(.easeInOut(duration: 0.15), value: attachments.count)
        .animation(.easeInOut(duration: 0.15), value: isDropTargeted)
        .onAppear {
            DispatchQueue.main.async { focused = true }
        }
    }

    @ViewBuilder
    private var inputField: some View {
        TextField("Message geo… (⌘↩ to send)", text: $draft, axis: .vertical)
            .textFieldStyle(.plain)
            .lineLimit(1...6)
            .font(.system(size: 14))
            .focused($focused)
            .disabled(isSending)
            .onSubmit { if canSend { onSend() } }
            .onPasteCommand(of: [.png, .tiff, .jpeg, .image]) { providers in
                Task { await handlePastedImage(providers: providers) }
            }
    }

    private func pickFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        if panel.runModal() == .OK {
            for url in panel.urls { addFile(url: url) }
        }
    }

    private func addFile(url: URL) {
        let ext = url.pathExtension.lowercased()
        if ["png", "jpg", "jpeg", "gif", "webp", "heic", "tiff"].contains(ext),
           let img = NSImage(contentsOf: url) {
            attachments.append(NanoAttachment(kind: .image(img, fileName: url.lastPathComponent)))
        } else {
            attachments.append(NanoAttachment(kind: .file(url)))
        }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers {
            if provider.canLoadObject(ofClass: NSImage.self) {
                provider.loadObject(ofClass: NSImage.self) { obj, _ in
                    guard let img = obj as? NSImage else { return }
                    DispatchQueue.main.async {
                        attachments.append(NanoAttachment(kind: .image(img, fileName: "pasted-image.png")))
                    }
                }
                handled = true
                continue
            }
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    var url: URL?
                    if let data = item as? Data, let parsed = URL(dataRepresentation: data, relativeTo: nil) {
                        url = parsed
                    } else if let direct = item as? URL {
                        url = direct
                    }
                    guard let url else { return }
                    DispatchQueue.main.async { addFile(url: url) }
                }
                handled = true
            }
        }
        return handled
    }

    private func handlePastedImage(providers: [NSItemProvider]) async {
        for provider in providers {
            guard provider.canLoadObject(ofClass: NSImage.self) else { continue }
            let image: NSImage? = await withCheckedContinuation { cont in
                provider.loadObject(ofClass: NSImage.self) { obj, _ in
                    cont.resume(returning: obj as? NSImage)
                }
            }
            if let image {
                await MainActor.run {
                    attachments.append(NanoAttachment(kind: .image(image, fileName: "pasted-\(Int(Date().timeIntervalSince1970)).png")))
                }
            }
        }
    }
}
