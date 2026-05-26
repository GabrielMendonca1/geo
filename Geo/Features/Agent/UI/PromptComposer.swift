import SwiftUI

struct PromptComposer: View {
    @Binding var text: String
    var focused: FocusState<Bool>.Binding
    let placeholder: String
    let canSubmit: Bool
    let onSubmit: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Color.primary.opacity(0.06)).frame(height: 1)
            inputBox
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color(Palette.background))
        }
        .onAppear { focused.wrappedValue = true }
    }

    private var inputBox: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Text("\(placeholder) ⌘↩")
                    .font(.system(size: 14))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 10)
                    .padding(.leading, 14)
                    .allowsHitTesting(false)
            }
            TextEditor(text: $text)
                .focused(focused)
                .font(.system(size: 14))
                .scrollContentBackground(.hidden)
                .background(Color.clear)
                .padding(.vertical, 6)
                .padding(.leading, 9)
                .padding(.trailing, 46)
                .frame(minHeight: 42, maxHeight: 200)
                .fixedSize(horizontal: false, vertical: true)
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    focused.wrappedValue
                        ? Color.accentColor.opacity(0.5)
                        : Color.primary.opacity(0.10),
                    lineWidth: 1
                )
        )
        .overlay(alignment: .bottomTrailing) {
            sendButton
                .padding(5)
        }
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onTapGesture { focused.wrappedValue = true }
        .animation(.easeOut(duration: 0.12), value: focused.wrappedValue)
    }

    private var sendButton: some View {
        Button {
            onSubmit()
        } label: {
            Image(systemName: "arrow.up")
                .font(.system(size: 12, weight: .heavy))
                .foregroundStyle(canSubmit ? Color.white : Color.secondary)
                .frame(width: 28, height: 28)
                .background(
                    Circle()
                        .fill(canSubmit ? Color.accentColor : Color.primary.opacity(0.10))
                )
        }
        .buttonStyle(.plain)
        .disabled(!canSubmit)
        .keyboardShortcut(.return, modifiers: .command)
        .help("Send (⌘↩)")
    }
}
