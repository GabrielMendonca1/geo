import SwiftUI
import AppKit

enum AlwaysOnTop {
    static let settingsKey = "window.setting.isAlwaysOnTop"
}

struct TitleBarLock: View {
    @Binding var isAlwaysOnTop: Bool

    var body: some View {
        Button {
            isAlwaysOnTop.toggle()
        } label: {
            Image(systemName: isAlwaysOnTop ? "lock.fill" : "lock.open.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(isAlwaysOnTop ? .accentColor : .secondary.opacity(0.6))
                .frame(width: 20, height: 20)
        }
        .padding(4)
        .plainNoFocusButton()
        .help(isAlwaysOnTop ? "Unlock window" : "Keep window on top")
    }
}

struct TitleBarTag: View {
    let tag: Tag?
    @Binding var isMenuPresented: Bool
    let menuContent: () -> AnyView
    @State private var isHovering = false

    var body: some View {
        Button {
            isMenuPresented.toggle()
        } label: {
            HStack(spacing: 4) {
                if let tag {
                    Circle()
                        .fill(tag.color.swiftUIColor)
                        .frame(width: 8, height: 8)
                    Text(tag.name)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.primary)
                } else {
                    Image(systemName: "tag")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary)
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
        .plainNoFocusButton()
        .onHover { isHovering = $0 }
        .popover(isPresented: $isMenuPresented, arrowEdge: .bottom) {
            menuContent()
        }
    }
}

struct TitleBarFullWidth: View {
    @Binding var isFullWidth: Bool

    var body: some View {
        Button {
            isFullWidth.toggle()
        } label: {
            Image(systemName: isFullWidth ? "arrow.down.right.and.arrow.up.left.square.fill" : "arrow.up.left.and.arrow.down.right.square.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(isFullWidth ? .accentColor : .secondary.opacity(0.6))
                .frame(width: 20, height: 20)
        }
        .padding(4)
        .plainNoFocusButton()
        .help(isFullWidth ? "Exit full width" : "Full width")
    }
}

struct TitleBarOutline: View {
    @Binding var isMenuPresented: Bool

    var body: some View {
        Button {
            isMenuPresented.toggle()
        } label: {
            Image(systemName: "list.bullet.indent")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary.opacity(0.6))
                .frame(width: 20, height: 20)
        }
        .padding(4)
        .plainNoFocusButton()
        .popover(isPresented: $isMenuPresented, arrowEdge: .bottom) {
            outlineContent()
        }
        .help("Outline")
    }

    private let outlineContent: () -> AnyView

    init(isMenuPresented: Binding<Bool>, outlineContent: @escaping () -> AnyView) {
        self._isMenuPresented = isMenuPresented
        self.outlineContent = outlineContent
    }
}
