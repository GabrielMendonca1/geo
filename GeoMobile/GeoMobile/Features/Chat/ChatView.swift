import SwiftUI

struct ChatView: View {
    @StateObject private var viewModel = ChatViewModel()
    @StateObject private var voice = VoiceSessionController()

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.messages.isEmpty {
                    AirStateCard(
                        icon: "waveform",
                        title: "Fala com o geo",
                        message: "Toque no orbe pra conversar, ou digite e segure o mic."
                    )
                } else {
                    messageList
                        .background(SkyBackground())
                }
            }
            .overlay(alignment: .top) {
                if voice.isActive {
                    ConversationOrbView(state: voice.state, transcript: voice.transcript)
                        .padding(.horizontal)
                        .padding(.top, 8)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: voice.isActive)
            .safeAreaInset(edge: .bottom) { inputBar }
            .navigationTitle("Chat")
            .settingsToolbar()
        }
        .task { [weak viewModel, weak voice] in
            guard let viewModel, let voice else { return }
            voice.bind(viewModel)
            voice.onPermissionDenied = { [weak viewModel] in
                viewModel?.appendSystem("sem acesso ao microfone ou ao reconhecimento de fala — habilite nos Ajustes do iPhone")
            }
        }
        .onChange(of: voice.transcript) { _, transcript in
            if voice.isHolding {
                viewModel.draft = transcript
            }
        }
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(viewModel.messages) { message in
                        MessageBubble(
                            message: message,
                            showsCursor: viewModel.isStreaming
                                && message.role == "assistant"
                                && message.id == viewModel.messages.last?.id
                        )
                        .id(message.id)
                    }
                    if viewModel.isStreaming, viewModel.messages.last?.role != "assistant" {
                        HStack {
                            PulsingCursor()
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(Color.hazeGrey, in: RoundedRectangle(cornerRadius: 16))
                            Spacer(minLength: 48)
                        }
                        .id("pending")
                    }
                }
                .padding(.horizontal)
                .padding(.top, 8)
                .padding(.bottom, 8)
            }
            .onChange(of: viewModel.messages.last?.text) { _, _ in
                if let id = viewModel.messages.last?.id {
                    proxy.scrollTo(id, anchor: .bottom)
                }
            }
        }
    }

    private var inputBar: some View {
        HStack(spacing: 10) {
            conversationButton
            TextField("Mensagem pro geo", text: $viewModel.draft, axis: .vertical)
                .lineLimit(1...4)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.hazeGrey, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                )
            micButton
            sendButton
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var conversationButton: some View {
        Button {
            voice.toggleConversation()
        } label: {
            Image(systemName: voice.isActive ? "waveform.circle.fill" : "waveform.circle")
                .font(.title2)
                .foregroundStyle(voice.isActive ? Color.accentColor : .secondary)
        }
        .disabled(voice.isHolding)
    }

    private var micButton: some View {
        Image(systemName: voice.isHolding ? "mic.fill" : "mic")
            .font(.title3)
            .foregroundStyle(voice.isHolding ? Color.red : Color.accentColor)
            .frame(width: 36, height: 36)
            .background(Color.cardSurface, in: Circle())
            .scaleEffect(voice.isHolding ? 1.15 : 1)
            .animation(.easeInOut(duration: 0.15), value: voice.isHolding)
            .opacity(voice.isActive ? 0.35 : 1)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        voice.beginHold()
                    }
                    .onEnded { _ in
                        Task {
                            let text = await voice.endHold().trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !text.isEmpty else { return }
                            viewModel.draft = text
                            await viewModel.send()
                        }
                    }
            )
    }

    private var sendButton: some View {
        Button {
            Task { await viewModel.send() }
        } label: {
            Image(systemName: "arrow.up.circle.fill")
                .font(.title2)
        }
        .disabled(viewModel.isStreaming || viewModel.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
}

private struct MessageBubble: View {
    let message: ChatMessage
    let showsCursor: Bool

    var body: some View {
        switch message.role {
        case "user":
            HStack {
                Spacer(minLength: 48)
                Text(message.text)
                    .foregroundStyle(Color.cloudWhite)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color.actionBlue, in: RoundedRectangle(cornerRadius: AirRadius.card, style: .continuous))
            }
        case "assistant":
            HStack {
                HStack(alignment: .bottom, spacing: 3) {
                    Text(message.text)
                        .foregroundStyle(Color.charcoalText)
                    if showsCursor {
                        PulsingCursor()
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color.cardSurface, in: RoundedRectangle(cornerRadius: AirRadius.card, style: .continuous))
                Spacer(minLength: 48)
            }
        default:
            Text(message.text)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }
    }
}

private struct PulsingCursor: View {
    @State private var dim = false

    var body: some View {
        Text("▍")
            .foregroundStyle(.secondary)
            .opacity(dim ? 0.15 : 1)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true)) {
                    dim = true
                }
            }
    }
}

#Preview {
    ChatView()
}
