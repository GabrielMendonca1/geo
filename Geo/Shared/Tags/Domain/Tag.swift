import Foundation

struct TagColor: Codable, Hashable {
    let red: Double
    let green: Double
    let blue: Double
    let alpha: Double

    init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    var prefersDarkText: Bool {
        relativeLuminance() > 0.6
    }

    private func relativeLuminance() -> Double {
        func toLinear(_ channel: Double) -> Double {
            if channel <= 0.04045 {
                return channel / 12.92
            }
            return pow((channel + 0.055) / 1.055, 2.4)
        }
        let r = toLinear(red)
        let g = toLinear(green)
        let b = toLinear(blue)
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }
}

struct Tag: Identifiable, Codable, Hashable {
    let id: String
    var name: String
    var color: TagColor
}

enum TagStoreError: LocalizedError, Equatable {
    case emptyName
    case duplicateName
    case notFound

    var errorDescription: String? {
        switch self {
        case .emptyName:
            return "Tag name cannot be empty."
        case .duplicateName:
            return "A tag with this name already exists."
        case .notFound:
            return "Tag not found."
        }
    }
}
