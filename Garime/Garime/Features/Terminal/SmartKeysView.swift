import UIKit

final class SmartKeysView: UIInputView {
    var onBytes: (([UInt8]) -> Void)?
    var onPaste: (() -> Void)?
    var applicationCursor: () -> Bool = { false }

    private enum Action {
        case esc
        case tab
        case ctrl
        case arrow(String)
        case literal(String)
        case paste
    }

    private struct KeySpec {
        let title: String
        let action: Action
        var symbol: String? = nil
    }

    private static let keys: [KeySpec] = [
        KeySpec(title: "esc", action: .esc),
        KeySpec(title: "tab", action: .tab),
        KeySpec(title: "ctrl", action: .ctrl),
        KeySpec(title: "←", action: .arrow("D")),
        KeySpec(title: "↓", action: .arrow("B")),
        KeySpec(title: "↑", action: .arrow("A")),
        KeySpec(title: "→", action: .arrow("C")),
        KeySpec(title: "-", action: .literal("-")),
        KeySpec(title: "|", action: .literal("|")),
        KeySpec(title: "~", action: .literal("~")),
        KeySpec(title: "/", action: .literal("/")),
        KeySpec(title: "", action: .paste, symbol: "doc.on.clipboard"),
    ]

    private var ctrlArmed = false
    private weak var ctrlButton: UIButton?
    private var holdTimer: Timer?
    private var repeatTimer: Timer?
    private let keysAreGlass: Bool = {
        if #available(iOS 26.0, *) { return true }
        return false
    }()

    init(width: CGFloat) {
        super.init(frame: CGRect(x: 0, y: 0, width: width, height: 44), inputViewStyle: .keyboard)
        backgroundColor = .clear
        autoresizingMask = .flexibleWidth
        buildStack()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: 44)
    }

    func transform(_ bytes: [UInt8]) -> [UInt8] {
        guard ctrlArmed else { return bytes }
        setCtrl(false)
        guard let first = bytes.first, let mapped = Self.controlByte(first) else { return bytes }
        return [mapped] + bytes.dropFirst()
    }

    private func buildStack() {
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.distribution = .fillEqually
        stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false

        let host = makeStackHost()
        addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: leadingAnchor),
            host.trailingAnchor.constraint(equalTo: trailingAnchor),
            host.topAnchor.constraint(equalTo: topAnchor),
            host.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        let container = (host as? UIVisualEffectView)?.contentView ?? host
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 5),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -5),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 5),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -5),
        ])

        for (index, key) in Self.keys.enumerated() {
            let button = makeButton(title: key.title, symbol: key.symbol, tag: index)
            switch key.action {
            case .arrow:
                button.addTarget(self, action: #selector(arrowDown(_:)), for: .touchDown)
                button.addTarget(self, action: #selector(arrowUp(_:)), for: [.touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit])
            case .ctrl:
                ctrlButton = button
                button.addTarget(self, action: #selector(tapped(_:)), for: .touchUpInside)
            default:
                button.addTarget(self, action: #selector(tapped(_:)), for: .touchUpInside)
            }
            stack.addArrangedSubview(wrap(button))
        }
    }

    private func makeStackHost() -> UIView {
        if #available(iOS 26.0, *) {
            let effect = UIGlassContainerEffect()
            effect.spacing = 5
            let view = UIVisualEffectView(effect: effect)
            view.translatesAutoresizingMaskIntoConstraints = false
            return view
        }
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }

    private func wrap(_ button: UIButton) -> UIView {
        guard #available(iOS 26.0, *) else { return button }
        let effect = UIGlassEffect(style: .regular)
        effect.isInteractive = true
        let capsule = UIVisualEffectView(effect: effect)
        capsule.clipsToBounds = true
        capsule.layer.cornerRadius = 17
        capsule.layer.cornerCurve = .continuous
        button.translatesAutoresizingMaskIntoConstraints = false
        capsule.contentView.addSubview(button)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: capsule.contentView.leadingAnchor),
            button.trailingAnchor.constraint(equalTo: capsule.contentView.trailingAnchor),
            button.topAnchor.constraint(equalTo: capsule.contentView.topAnchor),
            button.bottomAnchor.constraint(equalTo: capsule.contentView.bottomAnchor),
        ])
        return capsule
    }

    private func makeButton(title: String, symbol: String?, tag: Int) -> UIButton {
        let button = UIButton(type: .system)
        button.tag = tag
        if let symbol {
            let config = UIImage.SymbolConfiguration(pointSize: 13, weight: .medium)
            button.setImage(UIImage(systemName: symbol, withConfiguration: config), for: .normal)
            button.tintColor = SlatePalette.text
        } else {
            button.setTitle(title, for: .normal)
        }
        button.setTitleColor(SlatePalette.text, for: .normal)
        button.titleLabel?.font = UIFont.monospacedSystemFont(ofSize: 13, weight: .medium)
        button.titleLabel?.adjustsFontSizeToFitWidth = true
        button.titleLabel?.minimumScaleFactor = 0.8
        if keysAreGlass {
            button.backgroundColor = .clear
        } else {
            button.backgroundColor = SlatePalette.elevated
            button.layer.cornerRadius = 17
            button.layer.cornerCurve = .continuous
        }
        return button
    }

    @objc private func tapped(_ sender: UIButton) {
        let key = Self.keys[sender.tag]
        switch key.action {
        case .ctrl:
            setCtrl(!ctrlArmed)
        case .esc:
            setCtrl(false)
            emit(Array("\u{1b}".utf8))
        case .tab:
            setCtrl(false)
            emit([0x09])
        case .literal(let text):
            emit(transform(Array(text.utf8)))
        case .paste:
            setCtrl(false)
            onPaste?()
        case .arrow:
            break
        }
    }

    @objc private func arrowDown(_ sender: UIButton) {
        cancelRepeat()
        setCtrl(false)
        sendArrow(sender)
        holdTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self, weak sender] _ in
            guard let self, let sender else { return }
            self.repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self, weak sender] _ in
                guard let self, let sender else { return }
                self.sendArrow(sender)
            }
        }
    }

    @objc private func arrowUp(_ sender: UIButton) {
        cancelRepeat()
    }

    private func cancelRepeat() {
        holdTimer?.invalidate()
        holdTimer = nil
        repeatTimer?.invalidate()
        repeatTimer = nil
    }

    private func sendArrow(_ sender: UIButton) {
        guard case .arrow(let direction) = Self.keys[sender.tag].action else { return }
        let prefix = applicationCursor() ? "\u{1b}O" : "\u{1b}["
        emit(Array((prefix + direction).utf8))
    }

    private func setCtrl(_ armed: Bool) {
        guard ctrlArmed != armed else { return }
        ctrlArmed = armed
        ctrlButton?.backgroundColor = armed ? SlatePalette.text : (keysAreGlass ? .clear : SlatePalette.elevated)
        ctrlButton?.setTitleColor(armed ? SlatePalette.card : SlatePalette.text, for: .normal)
    }

    private func emit(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        onBytes?(bytes)
    }

    private static func controlByte(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 0x61...0x7a, 0x41...0x5a, 0x5b...0x5f:
            return byte & 0x1f
        case 0x20, 0x40:
            return 0
        case 0x2d:
            return 0x1f
        case 0x3f:
            return 0x7f
        default:
            return nil
        }
    }
}
