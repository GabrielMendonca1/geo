import SwiftUI

struct ConversationOrbView: View {
    let state: VoiceSessionController.State
    let transcript: String

    var body: some View {
        VStack(spacing: 14) {
            OrbShape(state: state)
                .frame(width: 116, height: 116)
            Text(caption)
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
            if !transcript.isEmpty {
                Text(transcript)
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.primary)
                    .lineLimit(4)
                    .padding(.horizontal, 20)
            }
        }
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24))
    }

    private var caption: String {
        switch state {
        case .idle: return "toque no orbe pra conversar"
        case .listening: return "ouvindo…"
        case .thinking: return "pensando…"
        case .speaking: return "falando…"
        }
    }
}

private struct OrbShape: View {
    let state: VoiceSessionController.State
    @State private var pulse = false

    var body: some View {
        ZStack {
            Circle()
                .fill(color.opacity(0.22))
                .scaleEffect(pulse ? 1.28 : 0.9)
            Circle()
                .fill(
                    RadialGradient(
                        colors: [color.opacity(0.95), color.opacity(0.55)],
                        center: .center,
                        startRadius: 4,
                        endRadius: 60
                    )
                )
                .scaleEffect(pulse ? 1.04 : 0.94)
        }
        .onAppear { animate() }
        .onChange(of: state) { _, _ in animate() }
    }

    private var color: Color {
        switch state {
        case .idle: return .gray
        case .listening: return Color(red: 0, green: 0.333, blue: 1)
        case .thinking: return .purple
        case .speaking: return .green
        }
    }

    private func animate() {
        pulse = false
        let duration: Double
        switch state {
        case .idle: duration = 0
        case .listening: duration = 0.9
        case .thinking: duration = 1.4
        case .speaking: duration = 0.5
        }
        guard duration > 0 else { return }
        withAnimation(.easeInOut(duration: duration).repeatForever(autoreverses: true)) {
            pulse = true
        }
    }
}
