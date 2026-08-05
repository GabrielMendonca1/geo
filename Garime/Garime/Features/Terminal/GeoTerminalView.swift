import UIKit
import SwiftTerm

final class GeoTerminalView: TerminalView {
    var onSend: (([UInt8]) -> Void)?
    var onPaste: (() -> Void)?

    private let smartKeys = SmartKeysView(width: UIScreen.main.bounds.width)

    override init(frame: CGRect) {
        super.init(frame: frame)
        smartKeys.onBytes = { [weak self] bytes in self?.onSend?(bytes) }
        smartKeys.onPaste = { [weak self] in self?.onPaste?() }
        smartKeys.applicationCursor = { [weak self] in self?.getTerminal().applicationCursor ?? false }
        inputAccessoryView = smartKeys
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func applyPendingModifiers(_ bytes: [UInt8]) -> [UInt8] {
        smartKeys.transform(bytes)
    }

    override func mouseModeChanged(source: Terminal) {}
}
