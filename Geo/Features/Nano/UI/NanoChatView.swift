import SwiftUI

struct NanoChatView: View {
    @ObservedObject var store: NanoConversationStore
    @State private var draft: String = ""
    @State private var attachments: [NanoAttachment] = []

    var body: some View {
        VStack(spacing: 0) {
            if store.messages.isEmpty && !store.isSending {
                emptyState
            } else {
                NanoMessageList(messages: store.messages)
                    .frame(maxHeight: .infinity)
            }

            if let error = store.error {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color(red: 0.95, green: 0.32, blue: 0.32))
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
            }

            ZStack(alignment: .bottomLeading) {
                NanoChatInputBar(
                    draft: $draft,
                    attachments: $attachments,
                    isSending: store.isSending,
                    onSend: send,
                    onStop: { Task { await store.cancel() } }
                )
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
                .padding(.top, 4)

                NanoSlashCommandOverlay(draft: $draft) { cmd in
                    if cmd.id == "clear" {
                        draft = ""
                        Task { await store.reset() }
                    } else {
                        draft = cmd.expansion
                    }
                }
                .padding(.horizontal, 14)
                .offset(y: -64)
                .frame(maxWidth: 480, alignment: .leading)
            }
        }
        .task { await store.hydrate() }
    }

    private var emptyState: some View {
        VStack(spacing: 18) {
            Spacer()
            VStack(spacing: 8) {
                Image(systemName: "sparkle")
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(Color(red: 0.0, green: 0.33, blue: 1.0).opacity(0.85))
                Text("Talk to geo")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)
                Text("Same brain as your WhatsApp · Gmail · Telegram agent.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 6) {
                ForEach(starterPrompts, id: \.self) { prompt in
                    Button {
                        draft = prompt
                        Task { await tickSend() }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.secondary.opacity(0.6))
                            Text(prompt)
                                .font(.system(size: 12.5))
                                .foregroundStyle(.primary)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .frame(maxWidth: 360)
                        .background(Color.secondary.opacity(0.08))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var starterPrompts: [String] {
        [
            "What's on today?",
            "Show recent notes about this week",
            "Summarize unread WhatsApp threads",
            "Dispatch an agent to clean up TODOs",
        ]
    }

    private func send() {
        let text = draft
        let payload = attachments
        draft = ""
        attachments = []
        Task { await store.send(text, attachments: payload) }
    }

    private func tickSend() async {
        // brief delay so the chip click registers and the prompt is visible
        try? await Task.sleep(nanoseconds: 60_000_000)
        send()
    }
}
