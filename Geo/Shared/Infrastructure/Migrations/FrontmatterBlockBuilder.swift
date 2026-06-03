import Foundation

enum FrontmatterBlockBuilder {
    static func block(
        id: String?,
        type: String,
        status: String?,
        layer: String,
        tags: [String],
        fullWidth: Bool
    ) -> String {
        var lines: [String] = []
        if let id, !id.isEmpty {
            lines.append("id: \(FrontmatterYAML.emitScalar(id))")
        }
        lines.append("type: \(FrontmatterYAML.emitScalar(type))")
        if let status, !status.isEmpty {
            lines.append("status: \(FrontmatterYAML.emitScalar(status))")
        }
        lines.append("layer: \(FrontmatterYAML.emitScalar(layer))")
        if !tags.isEmpty {
            lines.append("tags: \(FrontmatterYAML.emitInlineList(tags))")
        }
        if fullWidth {
            lines.append("full_width: true")
        }
        return "---\n" + lines.joined(separator: "\n") + "\n---\n"
    }
}
