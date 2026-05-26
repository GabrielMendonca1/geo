import SwiftUI
import AppKit

struct NanoMessageBubble: View {
    let message: NanoMessage
    @State private var hovered: Bool = false

    var body: some View {
        HStack(alignment: .top) {
            if message.role == .user { Spacer(minLength: 60) }

            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 6) {
                if !message.toolCalls.isEmpty {
                    NanoToolCallGroupView(calls: message.toolCalls)
                }
                contentView
                if hovered && !message.text.isEmpty && !message.isStreaming {
                    hoverActions
                        .transition(.opacity)
                }
            }

            if message.role == .assistant { Spacer(minLength: 60) }
        }
        .onHover { hovered = $0 }
        .animation(.easeInOut(duration: 0.12), value: hovered)
    }

    @ViewBuilder private var contentView: some View {
        switch message.role {
        case .user:
            if !message.text.isEmpty {
                Text(message.text)
                    .font(.system(size: 14))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color(red: 0.0, green: 0.33, blue: 1.0).opacity(0.12))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Color(red: 0.0, green: 0.33, blue: 1.0).opacity(0.22), lineWidth: 0.5)
                    )
                    .textSelection(.enabled)
            }
        case .assistant:
            if message.isStreaming && message.text.isEmpty {
                TypingIndicator()
                    .padding(.vertical, 4)
            } else if !message.text.isEmpty {
                MarkdownView(message.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var hoverActions: some View {
        HStack(spacing: 8) {
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(message.text, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Copy message")
        }
        .padding(.top, 2)
    }
}

private struct TypingIndicator: View {
    @State private var phase: Int = 0
    private let timer = Timer.publish(every: 0.32, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3) { i in
                Circle()
                    .fill(Color.secondary.opacity(0.55))
                    .frame(width: 5, height: 5)
                    .scaleEffect(phase == i ? 1.4 : 1.0)
                    .opacity(phase == i ? 1.0 : 0.45)
                    .animation(.easeInOut(duration: 0.32), value: phase)
            }
        }
        .onReceive(timer) { _ in
            phase = (phase + 1) % 3
        }
    }
}
