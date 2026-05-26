import AppKit

struct TextViewHeightCalculator {

    static let minimumHeight: CGFloat = 22

    static func calculateHeight(for textView: NSTextView) -> NSSize {
        guard let lm = textView.layoutManager, let tc = textView.textContainer else {
            return NSSize(width: NSView.noIntrinsicMetric, height: minimumHeight)
        }
        lm.ensureLayout(for: tc)
        let rect = lm.usedRect(for: tc)
        return NSSize(width: NSView.noIntrinsicMetric, height: max(ceil(rect.height), minimumHeight))
    }

    static func sizeThatFits(width: CGFloat, textView: NSTextView) -> CGSize? {
        guard let lm = textView.layoutManager, let tc = textView.textContainer else { return nil }
        let effectiveWidth = max(1, width)
        if abs(tc.containerSize.width - effectiveWidth) > 0.5 {
            tc.containerSize = NSSize(width: effectiveWidth, height: .greatestFiniteMagnitude)
        }
        lm.ensureLayout(for: tc)
        let rect = lm.usedRect(for: tc)
        let insetHeight = textView.textContainerInset.height * 2
        return CGSize(width: effectiveWidth, height: max(ceil(rect.height) + insetHeight, minimumHeight))
    }
}
