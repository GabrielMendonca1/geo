import SwiftUI

struct OnboardingSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let sessions: [VitalsSession]
    let selected: Int?
    let onPick: (Int) async -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(title)
                        .font(.system(size: 22, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.slateText)

                    Text("Qual sessão é hoje?")
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(Color.slateTextDim)

                    VStack(spacing: 0) {
                        ForEach(Array(sessions.enumerated()), id: \.element.id) { index, session in
                            if index > 0 {
                                Divider().overlay(Color.slateStroke.opacity(0.4))
                            }
                            Button {
                                Task {
                                    await onPick(session.index)
                                    dismiss()
                                }
                            } label: {
                                row(session)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .glassSurface(shape: RoundedRectangle(cornerRadius: SlateRadius.card, style: .continuous))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 20)
            }
            .scrollContentBackground(.hidden)
            .navigationBarHidden(true)
        }
        .glassSheet(detents: [.large])
        .tint(Color.slateText)
    }

    private func row(_ session: VitalsSession) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(session.short.lowercased())
                .font(.system(size: 15, weight: .bold, design: .monospaced))
                .foregroundStyle(Color.slateText)
            Text(session.name.lowercased())
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Color.slateTextDim)
            Spacer(minLength: 8)
            if session.index == selected {
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(BodyMapPalette.highlight)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .contentShape(Rectangle())
    }
}
