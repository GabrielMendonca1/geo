import Foundation
import CoreGraphics

enum TitleBarMetrics {
    static let stripHeight: CGFloat = 42

    enum TrafficLight {
        static let diameter: CGFloat = 14
        static let spacing: CGFloat = 11
        static let leadingInset: CGFloat = 14
    }

    enum NavIcon {
        static let symbolSize: CGFloat = 16
        static let hitWidth: CGFloat = 64
        static let pillSize: CGFloat = 32
        static let pillCornerRadius: CGFloat = 8
    }

    enum Accessory {
        static let symbolSize: CGFloat = 16
        static let hitWidth: CGFloat = 54
        static let width: CGFloat = 58
    }
}
