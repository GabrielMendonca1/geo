import SwiftUI

struct NanoMessageList: View {
    let messages: [NanoMessage]
    @State private var visibleWindow: Int = 50

    private var visibleMessages: [NanoMessage] {
        if messages.count <= visibleWindow { return messages }
        return Array(messages.suffix(visibleWindow))
    }

    private var hiddenCount: Int {
        max(0, messages.count - visibleMessages.count)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if hiddenCount > 0 {
                            Button {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    visibleWindow += 50
                                }
                            } label: {
                                HStack {
                                    Spacer()
                                    Text("Show \(min(50, hiddenCount)) earlier message\(hiddenCount == 1 ? "" : "s")")
                                        .font(.system(size: 11.5))
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                }
                                .padding(.vertical, 8)
                                .background(Color.secondary.opacity(0.06))
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                        ForEach(visibleMessages) { message in
                            NanoMessageBubble(message: message)
                                .id(message.id)
                                .transition(.opacity.combined(with: .offset(y: 6)))
                        }
                        Color.clear.frame(height: 1).id("__tail")
                    }
                    .frame(maxWidth: 760, alignment: .leading)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .animation(.spring(response: 0.35, dampingFraction: 0.85), value: messages.count)
            }
            .onChange(of: messages.count) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo("__tail", anchor: .bottom)
                }
            }
            .onChange(of: messages.last?.text) { _, _ in
                proxy.scrollTo("__tail", anchor: .bottom)
            }
        }
    }
}
