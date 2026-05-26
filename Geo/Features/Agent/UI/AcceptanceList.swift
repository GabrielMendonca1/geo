import SwiftUI

struct AcceptanceList: View {
    @Binding var draft: String
    var focused: FocusState<Bool>.Binding
    let onChange: () -> Void
    let onToggle: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("ACCEPTANCE")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            if let items = TaskNodeDocument.parseChecklistItems(draft, strict: false), !focused.wrappedValue {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(items.indices, id: \.self) { idx in
                        Button {
                            onToggle(idx)
                        } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Image(systemName: items[idx].done ? "checkmark.square.fill" : "square")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(items[idx].done ? Color.accentColor.opacity(0.9) : .secondary)
                                Text(items[idx].text)
                                    .font(.system(size: 13))
                                    .foregroundStyle(items[idx].done ? .secondary : .primary)
                                    .strikethrough(items[idx].done, color: .secondary)
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ZStack(alignment: .topLeading) {
                    if !focused.wrappedValue && draft.isEmpty {
                        Text("Add acceptance criteria…  (use `- [ ] item` for checkboxes)")
                            .font(.system(size: 13).italic())
                            .foregroundStyle(.secondary)
                            .opacity(0.55)
                            .padding(.vertical, 8)
                            .padding(.horizontal, 5)
                            .allowsHitTesting(false)
                            .onHover { hovering in
                                if hovering { NSCursor.iBeam.push() } else { NSCursor.pop() }
                            }
                    }
                    TextEditor(text: $draft)
                        .focused(focused)
                        .font(.system(size: 13))
                        .scrollContentBackground(.hidden)
                        .background(Color.clear)
                        .frame(minHeight: 22)
                        .fixedSize(horizontal: false, vertical: true)
                        .onChange(of: draft) { _, _ in onChange() }
                }
            }
        }
    }
}
