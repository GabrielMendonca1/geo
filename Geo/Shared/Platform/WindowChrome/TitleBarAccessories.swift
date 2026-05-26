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

class TitleBarTagViewController<MenuContent: View>: NSTitlebarAccessoryViewController {
    private var hostingView: NSHostingView<TitleBarTag>
    private var isMenuPresented: Binding<Bool>
    private var menuContent: () -> MenuContent

    init(tag: Tag?, isMenuPresented: Binding<Bool>, menuContent: @escaping () -> MenuContent) {
        self.isMenuPresented = isMenuPresented
        self.menuContent = menuContent
        self.hostingView = NSHostingView(rootView: TitleBarTag(
            tag: tag,
            isMenuPresented: isMenuPresented,
            menuContent: { AnyView(menuContent()) }
        ))
        super.init(nibName: nil, bundle: nil)
        self.view = hostingView
        self.layoutAttribute = .leading
        updateFrame()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setVisible(_ isVisible: Bool) {
        self.isHidden = !isVisible
        hostingView.isHidden = !isVisible
    }

    func update(tag: Tag?, isMenuPresented: Binding<Bool>, menuContent: @escaping () -> MenuContent) {
        self.isMenuPresented = isMenuPresented
        self.menuContent = menuContent
        hostingView.rootView = TitleBarTag(
            tag: tag,
            isMenuPresented: isMenuPresented,
            menuContent: { AnyView(menuContent()) }
        )
        updateFrame()
    }

    private func updateFrame() {
        let fittingSize = hostingView.fittingSize
        self.view.frame = NSRect(x: 0, y: 0, width: max(28, fittingSize.width), height: 28)
    }
}

struct TitleBarTagModifier<MenuContent: View>: ViewModifier {
    let tag: Tag?
    @Binding var isMenuPresented: Bool
    let menuContent: () -> MenuContent
    let isVisible: Bool
    @State private var window: NSWindow?
    @State private var accessoryController: TitleBarTagViewController<MenuContent>?

    func body(content: Content) -> some View {
        content
            .background(WindowReflection(window: $window))
            .onChange(of: window) { oldValue, newValue in
                updateAccessory(for: newValue)
            }
            .onChange(of: tag?.id) {
                updateTag()
            }
            .onChange(of: isVisible) { oldValue, newValue in
                updateVisibility(newValue)
            }
            .onDisappear {
                removeAccessory()
            }
    }

    private func updateAccessory(for window: NSWindow?) {
        guard let window else { return }
        removeAccessory()

        let controller = TitleBarTagViewController(
            tag: tag,
            isMenuPresented: $isMenuPresented,
            menuContent: menuContent
        )
        window.addTitlebarAccessoryViewController(controller)
        controller.setVisible(isVisible)
        self.accessoryController = controller
    }

    private func updateTag() {
        guard let window else { return }
        if let controller = accessoryController {
            controller.update(
                tag: tag,
                isMenuPresented: $isMenuPresented,
                menuContent: menuContent
            )
            controller.setVisible(isVisible)
        } else {
            let controller = TitleBarTagViewController(
                tag: tag,
                isMenuPresented: $isMenuPresented,
                menuContent: menuContent
            )
            window.addTitlebarAccessoryViewController(controller)
            controller.setVisible(isVisible)
            accessoryController = controller
        }
    }

    private func updateVisibility(_ isVisible: Bool) {
        accessoryController?.setVisible(isVisible)
    }

    private func removeAccessory() {
        if let controller = accessoryController {
            controller.removeFromParent()
            accessoryController = nil
        }
    }
}

class TitleBarLockViewController: NSTitlebarAccessoryViewController {
    private let hostingView: NSHostingView<TitleBarLock>

    init(isAlwaysOnTop: Binding<Bool>) {
        self.hostingView = NSHostingView(rootView: TitleBarLock(isAlwaysOnTop: isAlwaysOnTop))
        super.init(nibName: nil, bundle: nil)
        self.view = hostingView
        self.layoutAttribute = .leading

        self.view.frame = NSRect(x: 0, y: 0, width: 28, height: 28)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setVisible(_ isVisible: Bool) {
        self.isHidden = !isVisible
        hostingView.isHidden = !isVisible
    }
}

struct TitleBarLockModifier: ViewModifier {
    @Binding var isAlwaysOnTop: Bool
    let isVisible: Bool
    @State private var window: NSWindow?
    @State private var accessoryController: TitleBarLockViewController?

    func body(content: Content) -> some View {
        content
            .background(WindowReflection(window: $window))
            .onChange(of: window) { oldValue, newValue in
                updateAccessory(for: newValue)
                newValue?.alwaysOnTop = isAlwaysOnTop
            }
            .onChange(of: isAlwaysOnTop) { oldValue, newValue in
                window?.alwaysOnTop = newValue
            }
            .onChange(of: isVisible) { oldValue, newValue in
                updateVisibility(newValue)
            }
            .onDisappear {
                removeAccessory()
            }
    }

    private func updateAccessory(for window: NSWindow?) {
        guard let window = window else { return }

        removeAccessory()

        let controller = TitleBarLockViewController(isAlwaysOnTop: $isAlwaysOnTop)
        window.addTitlebarAccessoryViewController(controller)
        controller.setVisible(isVisible)
        self.accessoryController = controller
    }

    private func updateVisibility(_ isVisible: Bool) {
        accessoryController?.setVisible(isVisible)
    }

    private func removeAccessory() {
        if let controller = accessoryController {
            controller.removeFromParent()
            accessoryController = nil
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

class TitleBarFullWidthViewController: NSTitlebarAccessoryViewController {
    private let hostingView: NSHostingView<TitleBarFullWidth>

    init(isFullWidth: Binding<Bool>) {
        self.hostingView = NSHostingView(rootView: TitleBarFullWidth(isFullWidth: isFullWidth))
        super.init(nibName: nil, bundle: nil)
        self.view = hostingView
        self.layoutAttribute = .leading

        self.view.frame = NSRect(x: 0, y: 0, width: 28, height: 28)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setVisible(_ isVisible: Bool) {
        self.isHidden = !isVisible
        hostingView.isHidden = !isVisible
    }
}

struct TitleBarFullWidthModifier: ViewModifier {
    @Binding var isFullWidth: Bool
    let isVisible: Bool
    @State private var window: NSWindow?
    @State private var accessoryController: TitleBarFullWidthViewController?

    func body(content: Content) -> some View {
        content
            .background(WindowReflection(window: $window))
            .onChange(of: window) { oldValue, newValue in
                updateAccessory(for: newValue)
            }
            .onChange(of: isVisible) { oldValue, newValue in
                updateVisibility(newValue)
            }
            .onDisappear {
                removeAccessory()
            }
    }

    private func updateAccessory(for window: NSWindow?) {
        guard let window = window else { return }

        removeAccessory()

        let controller = TitleBarFullWidthViewController(isFullWidth: $isFullWidth)
        window.addTitlebarAccessoryViewController(controller)
        controller.setVisible(isVisible)
        self.accessoryController = controller
    }

    private func updateVisibility(_ isVisible: Bool) {
        accessoryController?.setVisible(isVisible)
    }

    private func removeAccessory() {
        if let controller = accessoryController {
            controller.removeFromParent()
            accessoryController = nil
        }
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

class TitleBarOutlineViewController<MenuContent: View>: NSTitlebarAccessoryViewController {
    private var hostingView: NSHostingView<TitleBarOutline>
    private var isMenuPresented: Binding<Bool>
    private var menuContent: () -> MenuContent

    init(isMenuPresented: Binding<Bool>, menuContent: @escaping () -> MenuContent) {
        self.isMenuPresented = isMenuPresented
        self.menuContent = menuContent
        self.hostingView = NSHostingView(rootView: TitleBarOutline(
            isMenuPresented: isMenuPresented,
            outlineContent: { AnyView(menuContent()) }
        ))
        super.init(nibName: nil, bundle: nil)
        self.view = hostingView
        self.layoutAttribute = .leading
        self.view.frame = NSRect(x: 0, y: 0, width: 28, height: 28)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setVisible(_ isVisible: Bool) {
        self.isHidden = !isVisible
        hostingView.isHidden = !isVisible
    }

    func update(isMenuPresented: Binding<Bool>, menuContent: @escaping () -> MenuContent) {
        self.isMenuPresented = isMenuPresented
        self.menuContent = menuContent
        hostingView.rootView = TitleBarOutline(
            isMenuPresented: isMenuPresented,
            outlineContent: { AnyView(menuContent()) }
        )
    }
}

struct TitleBarOutlineModifier<MenuContent: View>: ViewModifier {
    @Binding var isMenuPresented: Bool
    let menuContent: () -> MenuContent
    let isVisible: Bool
    @State private var window: NSWindow?
    @State private var accessoryController: TitleBarOutlineViewController<MenuContent>?

    func body(content: Content) -> some View {
        content
            .background(WindowReflection(window: $window))
            .onChange(of: window) { oldValue, newValue in
                updateAccessory(for: newValue)
            }
            .onChange(of: isVisible) { oldValue, newValue in
                updateVisibility(newValue)
            }
            .onDisappear {
                removeAccessory()
            }
    }

    private func updateAccessory(for window: NSWindow?) {
        guard let window else { return }
        removeAccessory()

        let controller = TitleBarOutlineViewController(
            isMenuPresented: $isMenuPresented,
            menuContent: menuContent
        )
        window.addTitlebarAccessoryViewController(controller)
        controller.setVisible(isVisible)
        self.accessoryController = controller
    }

    private func updateVisibility(_ isVisible: Bool) {
        accessoryController?.setVisible(isVisible)
    }

    private func removeAccessory() {
        if let controller = accessoryController {
            controller.removeFromParent()
            accessoryController = nil
        }
    }
}

extension View {
    func titleBarLock(isAlwaysOnTop: Binding<Bool>) -> some View {
        self.modifier(TitleBarLockModifier(isAlwaysOnTop: isAlwaysOnTop, isVisible: true))
    }

    func titleBarLock(isAlwaysOnTop: Binding<Bool>, isVisible: Bool) -> some View {
        self.modifier(TitleBarLockModifier(isAlwaysOnTop: isAlwaysOnTop, isVisible: isVisible))
    }

    func titleBarFullWidth(isFullWidth: Binding<Bool>) -> some View {
        self.modifier(TitleBarFullWidthModifier(isFullWidth: isFullWidth, isVisible: true))
    }

    func titleBarFullWidth(isFullWidth: Binding<Bool>, isVisible: Bool) -> some View {
        self.modifier(TitleBarFullWidthModifier(isFullWidth: isFullWidth, isVisible: isVisible))
    }

    func titleBarTag<MenuContent: View>(
        tag: Tag?,
        isMenuPresented: Binding<Bool>,
        @ViewBuilder menuContent: @escaping () -> MenuContent
    ) -> some View {
        self.modifier(TitleBarTagModifier(
            tag: tag,
            isMenuPresented: isMenuPresented,
            menuContent: menuContent,
            isVisible: true
        ))
    }

    func titleBarTag<MenuContent: View>(
        tag: Tag?,
        isMenuPresented: Binding<Bool>,
        isVisible: Bool,
        @ViewBuilder menuContent: @escaping () -> MenuContent
    ) -> some View {
        self.modifier(TitleBarTagModifier(
            tag: tag,
            isMenuPresented: isMenuPresented,
            menuContent: menuContent,
            isVisible: isVisible
        ))
    }

    func titleBarOutline<MenuContent: View>(
        isMenuPresented: Binding<Bool>,
        isVisible: Bool,
        @ViewBuilder menuContent: @escaping () -> MenuContent
    ) -> some View {
        self.modifier(TitleBarOutlineModifier(
            isMenuPresented: isMenuPresented,
            menuContent: menuContent,
            isVisible: isVisible
        ))
    }
}
