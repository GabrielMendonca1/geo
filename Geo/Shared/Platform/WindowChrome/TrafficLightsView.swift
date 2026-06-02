import SwiftUI
import AppKit

enum TrafficLightButton {
    case close
    case minimize
    case zoom
}

@Observable
class TrafficLightsViewModel {
    var isHovering = false

    func helpText(for button: TrafficLightButton) -> String {
        switch button {
        case .close: return "Close"
        case .minimize: return "Minimize"
        case .zoom: return "Zoom"
        }
    }

    func fillColor(for button: TrafficLightButton) -> Color {
        guard isHovering else { return Color.secondary.opacity(0.55) }
        switch button {
        case .close: return .red
        case .minimize: return .yellow
        case .zoom: return .green
        }
    }
}

struct TrafficLightsView: View {
    @State private var viewModel = TrafficLightsViewModel()
    @State private var window: NSWindow?

    var body: some View {
        HStack(spacing: TitleBarMetrics.TrafficLight.spacing) {
            trafficLightButton(.close) { window?.close() }
            trafficLightButton(.minimize) { window?.miniaturize(nil) }
            trafficLightButton(.zoom) { window?.zoom(nil) }
        }
        .padding(.vertical, 2)
        .padding(.horizontal, TitleBarMetrics.TrafficLight.leadingInset)
        .frame(height: TitleBarMetrics.stripHeight)
        .background(WindowReflection(window: $window))
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                viewModel.isHovering = hovering
            }
        }
    }

    private func trafficLightButton(_ button: TrafficLightButton, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Circle()
                .fill(viewModel.fillColor(for: button))
                .frame(width: TitleBarMetrics.TrafficLight.diameter, height: TitleBarMetrics.TrafficLight.diameter)
                .overlay(Circle().strokeBorder(Color.secondary.opacity(0.3), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .help(viewModel.helpText(for: button))
    }
}

struct TitleBarSettingsButton: View {
    @Environment(\.tabRouter) private var tabRouter

    var body: some View {
        Button {
            tabRouter.selectTab(.settings)
        } label: {
            ZStack {
                Color.clear
                Image(systemName: "gearshape")
                    .font(.system(size: TitleBarMetrics.Accessory.symbolSize, weight: .semibold))
                    .foregroundColor(tabRouter.selectedTab == .settings ? Color(light: .black, dark: .white) : .secondary.opacity(0.7))
            }
            .frame(width: TitleBarMetrics.Accessory.hitWidth, height: TitleBarMetrics.stripHeight)
            .contentShape(Rectangle())
        }
        .plainNoFocusButton()
        .hoverTooltip(title: "Settings", shortcut: "⌘,")
    }
}

struct TitleBarNavigationTabs: View {
    @Bindable var tabRouter: TabRouter

    var body: some View {
        NavigationSegmentedControl(selection: $tabRouter.selectedTab)
    }
}

struct TitleBarLogoView: View {

    var body: some View {
        Image("MenuBarIcon")
            .renderingMode(.template)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: TitleBarMetrics.Accessory.symbolSize, height: TitleBarMetrics.Accessory.symbolSize)
            .foregroundColor(Palette.tertiaryForeground.opacity(0.7))
            .frame(width: TitleBarMetrics.Accessory.hitWidth, height: TitleBarMetrics.stripHeight)
    }
}

extension View {
    func titleBarTrafficLights(isVisible: Bool = true) -> some View {
        modifier(TitleBarHostAccessoryModifier(isVisible: isVisible, layout: .leading) {
            NSHostingView(rootView: TrafficLightsView())
        } sizing: { hv in
            CGSize(width: hv.fittingSize.width, height: TitleBarMetrics.stripHeight)
        })
    }

    func titleBarSettingsButton() -> some View {
        modifier(TitleBarHostAccessoryModifier(isVisible: true, layout: .leading) {
            NSHostingView(rootView: TitleBarSettingsButton())
        } sizing: { _ in
            CGSize(width: TitleBarMetrics.Accessory.width, height: TitleBarMetrics.stripHeight)
        })
    }

    func titleBarNavigationTabs(navigationStore: NavigationStore) -> some View {
        modifier(TitleBarHostAccessoryModifier(isVisible: true, layout: .leading) {
            NSHostingView(rootView: TitleBarNavigationTabs(tabRouter: navigationStore.tabRouter))
        } sizing: { hv in
            CGSize(width: hv.fittingSize.width, height: TitleBarMetrics.stripHeight)
        })
    }

    func titleBarLogo() -> some View {
        modifier(TitleBarHostAccessoryModifier(isVisible: true, layout: .trailing) {
            NSHostingView(rootView: TitleBarLogoView())
        } sizing: { _ in
            CGSize(width: TitleBarMetrics.Accessory.width, height: TitleBarMetrics.stripHeight)
        })
    }

    func titleBarSearch(text: Binding<String>, isPresented: Binding<Bool>, isVisible: Bool = true) -> some View {
        modifier(TitleBarHostAccessoryModifier(
            isVisible: isVisible,
            layout: .leading,
            makeHost: {
                NSHostingView(rootView: TitleBarSearchControl(text: text, isPresented: isPresented))
            },
            sizing: { _ in
                let collapsed = TitleBarMetrics.Accessory.width
                let expanded: CGFloat = text.wrappedValue.isEmpty ? 152 : 232
                return CGSize(
                    width: isPresented.wrappedValue ? expanded : collapsed,
                    height: TitleBarMetrics.stripHeight
                )
            },
            sizingKey: "\(text.wrappedValue)|\(isPresented.wrappedValue)"
        ))
    }
}

private extension NSUserInterfaceItemIdentifier {
    static let geoTitleBarGlass = NSUserInterfaceItemIdentifier("geo.titleBarGlass")
}

extension NSWindow {
    func fixTitlebarBackground() {
        titlebarSeparatorStyle = .none
        if let frameView = contentView?.superview {
            for subview in frameView.subviews where subview !== contentView {
                hideTitlebarVisualEffects(in: subview)
                hideAccessorySeparators(in: subview)
            }
        }
    }

    private func hideTitlebarVisualEffects(in view: NSView) {
        if view is NSVisualEffectView, view.identifier?.rawValue != "geo.titleBarGlass" {
            view.isHidden = true
        }
        for subview in view.subviews { hideTitlebarVisualEffects(in: subview) }
    }

    private func installTitleBarGlass() {
        guard let frameView = contentView?.superview else { return }
        if frameView.subviews.contains(where: { $0.identifier == .geoTitleBarGlass }) { return }
        let effect = NSVisualEffectView()
        effect.identifier = .geoTitleBarGlass
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.alphaValue = 0.78
        effect.state = .followsWindowActiveState
        effect.translatesAutoresizingMaskIntoConstraints = false
        if let contentView {
            frameView.addSubview(effect, positioned: .above, relativeTo: contentView)
        } else {
            frameView.addSubview(effect)
        }
        let titlebarContainer = frameView.subviews.first {
            String(describing: type(of: $0)).contains("TitlebarContainerView")
        }
        var constraints: [NSLayoutConstraint] = [
            effect.topAnchor.constraint(equalTo: frameView.topAnchor),
            effect.leadingAnchor.constraint(equalTo: frameView.leadingAnchor),
            effect.trailingAnchor.constraint(equalTo: frameView.trailingAnchor)
        ]
        if let titlebarContainer {
            constraints.append(effect.bottomAnchor.constraint(equalTo: titlebarContainer.bottomAnchor))
        } else {
            constraints.append(effect.heightAnchor.constraint(equalToConstant: TitleBarMetrics.stripHeight))
        }
        NSLayoutConstraint.activate(constraints)
    }

    private func hideAccessorySeparators(in view: NSView) {
        let isThinSeparator = view.frame.width <= 2 && view.frame.height > 5 && !(view is NSVisualEffectView)
        if isThinSeparator { view.isHidden = true }
        for subview in view.subviews { hideAccessorySeparators(in: subview) }
    }
}

final class GeoTitleBarAccessoryController: NSTitlebarAccessoryViewController {
    private let host: NSView

    init(host: NSView, layout: NSLayoutConstraint.Attribute, size: CGSize) {
        self.host = host
        super.init(nibName: nil, bundle: nil)
        self.view = host
        self.layoutAttribute = layout
        self.view.frame = NSRect(origin: .zero, size: size)
        host.wantsLayer = true
        host.layer?.backgroundColor = .clear
    }

    required init?(coder: NSCoder) { fatalError() }

    func setVisible(_ isVisible: Bool) {
        self.isHidden = !isVisible
        host.isHidden = !isVisible
    }
}

struct TitleBarHostAccessoryModifier<Host: NSView>: ViewModifier {
    let isVisible: Bool
    let layout: NSLayoutConstraint.Attribute
    let makeHost: () -> Host
    let sizing: (Host) -> CGSize
    let sizingKey: AnyHashable
    @State private var window: NSWindow?
    @State private var controller: GeoTitleBarAccessoryController?

    init(
        isVisible: Bool,
        layout: NSLayoutConstraint.Attribute,
        makeHost: @escaping () -> Host,
        sizing: @escaping (Host) -> CGSize,
        sizingKey: AnyHashable = 0
    ) {
        self.isVisible = isVisible
        self.layout = layout
        self.makeHost = makeHost
        self.sizing = sizing
        self.sizingKey = sizingKey
    }

    func body(content: Content) -> some View {
        content
            .background(WindowReflection(window: $window))
            .onChange(of: window) { _, newValue in attach(to: newValue) }
            .onChange(of: isVisible) { _, newValue in controller?.setVisible(newValue) }
            .onChange(of: sizingKey) { _, _ in updateSize() }
            .onDisappear { detach() }
    }

    private func attach(to window: NSWindow?) {
        guard let window else { return }
        detach()
        let host = makeHost()
        let c = GeoTitleBarAccessoryController(host: host, layout: layout, size: sizing(host))
        window.addTitlebarAccessoryViewController(c)
        c.setVisible(isVisible)
        controller = c
    }

    private func updateSize() {
        guard let controller, let host = controller.view as? Host else { return }
        controller.view.frame.size = sizing(host)
    }

    private func detach() {
        controller?.removeFromParent()
        controller = nil
    }
}
