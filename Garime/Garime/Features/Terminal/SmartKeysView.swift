import UIKit

final class SmartKeysView: UIInputView {
    var onBytes: (([UInt8]) -> Void)?
    var onPaste: (() -> Void)?
    var applicationCursor: () -> Bool = { false }

    /// Em modo herdr a barra ganha uma segunda linha com os atalhos do multiplexador.
    var herdrMode = false {
        didSet {
            guard oldValue != herdrMode else { return }
            rebuild()
        }
    }

    private enum Action {
        case esc
        case tab
        case ctrl
        case arrow(String)
        case literal(String)
        case paste
        /// ctrl+b sozinho (o prefixo do herdr/tmux).
        case prefix
        /// ctrl+b seguido de uma tecla, enviados juntos.
        case herdr(UInt8)
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

    private static let herdrKeys: [KeySpec] = [
        KeySpec(title: "pfx", action: .prefix),
        KeySpec(title: "‹tab", action: .herdr(0x70)),
        KeySpec(title: "tab›", action: .herdr(0x6e)),
        KeySpec(title: "◀", action: .herdr(0x68)),
        KeySpec(title: "▼", action: .herdr(0x6a)),
        KeySpec(title: "▲", action: .herdr(0x6b)),
        KeySpec(title: "▶", action: .herdr(0x6c)),
        KeySpec(title: "zoom", action: .herdr(0x7a)),
        KeySpec(title: "ws", action: .herdr(0x77)),
        KeySpec(title: "ir", action: .herdr(0x67)),
        KeySpec(title: "bar", action: .herdr(0x62)),
        KeySpec(title: "sair", action: .herdr(0x71)),
    ]

    private static let mainRow = 0
    private static let herdrRow = 1

    private var ctrlArmed = false
    private weak var ctrlButton: UIButton?
    private weak var prefixButton: UIButton?
    private var prefixTimer: Timer?
    private var holdTimer: Timer?
    private var repeatTimer: Timer?
    private let keysAreGlass: Bool = {
        if #available(iOS 26.0, *) { return true }
        return false
    }()

    private var barHeight: CGFloat { herdrMode ? 88 : 44 }

    init(width: CGFloat) {
        super.init(frame: CGRect(x: 0, y: 0, width: width, height: 44), inputViewStyle: .keyboard)
        backgroundColor = .clear
        autoresizingMask = .flexibleWidth
        buildStack()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: barHeight)
    }

    func transform(_ bytes: [UInt8]) -> [UInt8] {
        guard ctrlArmed else { return bytes }
        setCtrl(false)
        guard let first = bytes.first, let mapped = Self.controlByte(first) else { return bytes }
        return [mapped] + bytes.dropFirst()
    }

    private func rebuild() {
        cancelRepeat()
        prefixTimer?.invalidate()
        prefixTimer = nil
        ctrlArmed = false
        ctrlButton = nil
        prefixButton = nil
        subviews.forEach { $0.removeFromSuperview() }
        frame.size.height = barHeight
        invalidateIntrinsicContentSize()
        buildStack()
    }

    private func specs(_ row: Int) -> [KeySpec] {
        row == Self.herdrRow ? Self.herdrKeys : Self.keys
    }

    private func spec(for tag: Int) -> KeySpec {
        specs(tag / 100)[tag % 100]
    }

    private func buildStack() {
        let columns = UIStackView()
        columns.axis = .vertical
        columns.distribution = .fillEqually
        columns.spacing = 5
        columns.translatesAutoresizingMaskIntoConstraints = false

        let host = makeStackHost()
        addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: leadingAnchor),
            host.trailingAnchor.constraint(equalTo: trailingAnchor),
            host.topAnchor.constraint(equalTo: topAnchor),
            host.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        let container = (host as? UIVisualEffectView)?.contentView ?? host
        container.addSubview(columns)
        NSLayoutConstraint.activate([
            columns.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 5),
            columns.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -5),
            columns.topAnchor.constraint(equalTo: container.topAnchor, constant: 5),
            columns.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -5),
        ])

        if herdrMode {
            columns.addArrangedSubview(makeRow(Self.herdrRow))
        }
        columns.addArrangedSubview(makeRow(Self.mainRow))
    }

    private func makeRow(_ row: Int) -> UIStackView {
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.distribution = .fillEqually
        stack.spacing = 5
        var wrapped: [UIView] = []

        for (index, key) in specs(row).enumerated() {
            let button = makeButton(
                title: key.title,
                symbol: key.symbol,
                tag: row * 100 + index,
                fontSize: row == Self.herdrRow ? 10 : 13
            )
            switch key.action {
            case .arrow:
                button.addTarget(self, action: #selector(arrowDown(_:)), for: .touchDown)
                button.addTarget(self, action: #selector(arrowUp(_:)), for: [.touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit])
            case .ctrl:
                ctrlButton = button
                button.addTarget(self, action: #selector(tapped(_:)), for: .touchUpInside)
            case .prefix:
                prefixButton = button
                button.addTarget(self, action: #selector(tapped(_:)), for: .touchUpInside)
            default:
                button.addTarget(self, action: #selector(tapped(_:)), for: .touchUpInside)
            }
            let view = wrap(button)
            wrapped.append(view)
            stack.addArrangedSubview(view)
        }
        // Largura fatiada na mão: senão rótulos maiores (zoom, sair) empurram a linha pra fora da tela.
        if !wrapped.isEmpty {
            let slice = 1 / CGFloat(wrapped.count)
            let inset = stack.spacing * CGFloat(wrapped.count - 1) * slice
            for view in wrapped {
                view.widthAnchor.constraint(
                    equalTo: stack.widthAnchor, multiplier: slice, constant: -inset
                ).isActive = true
            }
        }
        return stack
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
        capsule.setContentCompressionResistancePriority(.fittingSizeLevel, for: .horizontal)
        capsule.setContentHuggingPriority(.fittingSizeLevel, for: .horizontal)
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

    private func makeButton(title: String, symbol: String?, tag: Int, fontSize: CGFloat = 13) -> UIButton {
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
        button.titleLabel?.font = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .medium)
        button.titleLabel?.adjustsFontSizeToFitWidth = true
        button.titleLabel?.minimumScaleFactor = 0.5
        button.titleLabel?.lineBreakMode = .byClipping
        button.setContentCompressionResistancePriority(.fittingSizeLevel, for: .horizontal)
        button.setContentHuggingPriority(.fittingSizeLevel, for: .horizontal)
        button.titleLabel?.setContentCompressionResistancePriority(.fittingSizeLevel, for: .horizontal)
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
        let key = spec(for: sender.tag)
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
        case .prefix:
            setCtrl(false)
            flashPrefix()
            emit([0x02])
        case .herdr(let letter):
            setCtrl(false)
            emit([0x02, letter])
        case .arrow:
            break
        }
    }

    /// Destaca a tecla `pfx` por um segundo, como o `ctrl` armado.
    private func flashPrefix() {
        prefixTimer?.invalidate()
        setPrefixHighlight(true)
        prefixTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: false) { [weak self] _ in
            self?.setPrefixHighlight(false)
        }
    }

    private func setPrefixHighlight(_ on: Bool) {
        prefixButton?.backgroundColor = on ? SlatePalette.text : (keysAreGlass ? .clear : SlatePalette.elevated)
        prefixButton?.setTitleColor(on ? SlatePalette.card : SlatePalette.text, for: .normal)
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
        guard case .arrow(let direction) = spec(for: sender.tag).action else { return }
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
