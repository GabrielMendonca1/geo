import Foundation
import os.log

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "geo", category: "TemplateService")

@MainActor
final class TemplateService: ObservableObject {
    static let shared = TemplateService()

    @Published private(set) var templates: [BlockTemplate] = []

    struct BlockTemplate: Identifiable, Codable {
        let id: String
        var name: String
        var description: String
        var markdown: String
        var icon: String
        var createdAt: Date
    }

    struct ExpandedTemplate {
        let markdown: String
        let cursorOffset: Int?
    }

    let templatesDirectory: URL

    init() {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.homeDirectoryForCurrentUser
        self.templatesDirectory = base.appendingPathComponent("Geo/Templates", isDirectory: true)
    }

    func loadTemplates() {
        let fm = FileManager.default
        let isFirstLaunch = !fm.fileExists(atPath: templatesDirectory.path)

        try? fm.createDirectory(at: templatesDirectory, withIntermediateDirectories: true)

        if isFirstLaunch {
            createBuiltInTemplates()
        }

        var loaded: [BlockTemplate] = []
        guard let files = try? fm.contentsOfDirectory(at: templatesDirectory, includingPropertiesForKeys: [.creationDateKey]) else {
            templates = []
            return
        }

        for file in files where file.pathExtension == "md" {
            guard let content = try? String(contentsOf: file, encoding: .utf8) else { continue }
            if let template = parseTemplateFile(content: content, url: file) {
                loaded.append(template)
            }
        }

        templates = loaded.sorted { $0.createdAt < $1.createdAt }
    }

    func saveTemplate(_ template: BlockTemplate) {
        let fm = FileManager.default
        try? fm.createDirectory(at: templatesDirectory, withIntermediateDirectories: true)

        let fileContent = serializeTemplate(template)
        let filename = template.name
            .replacingOccurrences(of: "/", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let url = templatesDirectory
            .appendingPathComponent(filename.isEmpty ? template.id : filename)
            .appendingPathExtension("md")

        do {
            try fileContent.write(to: url, atomically: true, encoding: .utf8)
            loadTemplates()
        } catch {
            logger.error("Failed to save template: \(error)")
        }
    }

    func deleteTemplate(_ template: BlockTemplate) {
        let fm = FileManager.default
        let filename = template.name
            .replacingOccurrences(of: "/", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let url = templatesDirectory
            .appendingPathComponent(filename.isEmpty ? template.id : filename)
            .appendingPathExtension("md")

        try? fm.removeItem(at: url)
        loadTemplates()
    }

    func expandVariables(in markdown: String, title: String) -> ExpandedTemplate {
        let now = Date()
        let gregorian = Calendar(identifier: .gregorian)
        let posix = Locale(identifier: "en_US_POSIX")
        let tz = TimeZone.current
        let dateFormatter = DateFormatter()
        dateFormatter.calendar = gregorian
        dateFormatter.timeZone = tz
        dateFormatter.locale = posix
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let timeFormatter = DateFormatter()
        timeFormatter.calendar = gregorian
        timeFormatter.timeZone = tz
        timeFormatter.locale = posix
        timeFormatter.dateFormat = "HH:mm"
        let datetimeFormatter = DateFormatter()
        datetimeFormatter.calendar = gregorian
        datetimeFormatter.timeZone = tz
        datetimeFormatter.locale = posix
        datetimeFormatter.dateFormat = "yyyy-MM-dd HH:mm"

        let effectiveTitle = title.isEmpty ? "Untitled" : title

        var result = markdown
        result = result.replacingOccurrences(of: "{{title}}", with: effectiveTitle)
        result = result.replacingOccurrences(of: "{{date}}", with: dateFormatter.string(from: now))
        result = result.replacingOccurrences(of: "{{time}}", with: timeFormatter.string(from: now))
        result = result.replacingOccurrences(of: "{{datetime}}", with: datetimeFormatter.string(from: now))

        let cursorMarker = "{{cursor}}"
        var cursorOffset: Int?
        if let range = result.range(of: cursorMarker) {
            cursorOffset = result.distance(from: result.startIndex, to: range.lowerBound)
            result = result.replacingOccurrences(of: cursorMarker, with: "")
        }

        return ExpandedTemplate(markdown: result, cursorOffset: cursorOffset)
    }

    private func parseTemplateFile(content: String, url: URL) -> BlockTemplate? {
        guard content.hasPrefix("---\n") else { return nil }

        let parts = content.dropFirst(4).components(separatedBy: "\n---\n")
        guard parts.count >= 2 else { return nil }

        let frontmatter = parts[0]
        let body = parts.dropFirst().joined(separator: "\n---\n")

        var name = url.deletingPathExtension().lastPathComponent
        var description = ""
        var icon = "doc.text"

        for line in frontmatter.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("name:") {
                name = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            } else if trimmed.hasPrefix("description:") {
                description = String(trimmed.dropFirst(12)).trimmingCharacters(in: .whitespaces)
            } else if trimmed.hasPrefix("icon:") {
                icon = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            }
        }

        let creationDate = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()

        return BlockTemplate(
            id: url.lastPathComponent,
            name: name,
            description: description,
            markdown: body,
            icon: icon,
            createdAt: creationDate
        )
    }

    private func serializeTemplate(_ template: BlockTemplate) -> String {
        var lines: [String] = ["---"]
        lines.append("name: \(template.name)")
        lines.append("description: \(template.description)")
        lines.append("icon: \(template.icon)")
        lines.append("---")
        lines.append(template.markdown)
        return lines.joined(separator: "\n")
    }

    private func createBuiltInTemplates() {
        let meetingNotes = BlockTemplate(
            id: "meeting-notes",
            name: "Meeting Notes",
            description: "Template for meeting agendas",
            markdown: "",
            icon: "person.3.fill",
            createdAt: Date()
        )
        let meetingMarkdown = """
        # {{title}}

        **Date:** {{date}}
        **Attendees:** {{cursor}}

        ## Agenda
        -

        ## Notes
        -

        ## Action Items
        - [ ]
        """
        saveBuiltIn(meetingNotes, markdown: dedent(meetingMarkdown))

        let journal = BlockTemplate(
            id: "daily-journal",
            name: "Daily Journal",
            description: "Daily reflection and planning",
            markdown: "",
            icon: "book.fill",
            createdAt: Date()
        )
        let journalMarkdown = """
        # Journal — {{date}}

        **Mood:** {{cursor}}

        ## Goals for Today
        - [ ]

        ## Reflections
        -

        ## Gratitude
        -
        """
        saveBuiltIn(journal, markdown: dedent(journalMarkdown))

        let projectBrief = BlockTemplate(
            id: "project-brief",
            name: "Project Brief",
            description: "Project overview document",
            markdown: "",
            icon: "folder.fill",
            createdAt: Date()
        )
        let projectMarkdown = """
        # {{title}}

        ## Overview
        {{cursor}}

        ## Goals
        -

        ## Timeline
        | Phase | Start | End |
        |-------|-------|-----|
        |       |       |     |

        ## Stakeholders
        -
        """
        saveBuiltIn(projectBrief, markdown: dedent(projectMarkdown))
    }

    private func saveBuiltIn(_ template: BlockTemplate, markdown: String) {
        let full = BlockTemplate(
            id: template.id,
            name: template.name,
            description: template.description,
            markdown: markdown,
            icon: template.icon,
            createdAt: template.createdAt
        )
        let fileContent = serializeTemplate(full)
        let url = templatesDirectory
            .appendingPathComponent(template.name)
            .appendingPathExtension("md")
        try? fileContent.write(to: url, atomically: true, encoding: .utf8)
    }

    private func dedent(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        let nonEmptyLines = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard let first = nonEmptyLines.first else { return text }
        let leadingSpaces = first.prefix(while: { $0 == " " }).count
        guard leadingSpaces > 0 else { return text }
        return lines.map { line in
            if line.hasPrefix(String(repeating: " ", count: leadingSpaces)) {
                return String(line.dropFirst(leadingSpaces))
            }
            return line
        }.joined(separator: "\n")
    }
}
