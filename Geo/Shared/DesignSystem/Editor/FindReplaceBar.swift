import SwiftUI

struct FindReplaceBar: View {
    @Binding var searchText: String
    @Binding var replaceText: String
    @Binding var showReplace: Bool
    let matchCount: Int
    let currentMatch: Int
    let onNext: () -> Void
    let onPrevious: () -> Void
    let onReplace: () -> Void
    let onReplaceAll: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Button(action: { showReplace.toggle() }) {
                    Image(systemName: showReplace ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(showReplace ? "Hide replace" : "Show replace")

                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    TextField("Find", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .accessibilityLabel("Find in document")
                        .onSubmit { onNext() }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(.quaternary)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .frame(maxWidth: 260)

                if !searchText.isEmpty {
                    Text(matchCount > 0 ? "\(currentMatch + 1) of \(matchCount)" : "No results")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 60)
                }

                Button(action: onPrevious) {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Previous match")
                .disabled(matchCount == 0)

                Button(action: onNext) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Next match")
                .disabled(matchCount == 0)

                Spacer()

                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss find")
            }

            if showReplace {
                HStack(spacing: 8) {
                    Color.clear.frame(width: 16, height: 1)

                    TextField("Replace", text: $replaceText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .accessibilityLabel("Replace text")
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(.quaternary)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .frame(maxWidth: 260)

                    Button("Replace", action: onReplace)
                        .controlSize(.small)
                        .accessibilityLabel("Replace")
                        .disabled(matchCount == 0)

                    Button("All", action: onReplaceAll)
                        .controlSize(.small)
                        .accessibilityLabel("Replace all")
                        .disabled(matchCount == 0)

                    Spacer()
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }
}
