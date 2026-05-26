import SwiftUI

struct TemplatePickerSheet: View {
    @EnvironmentObject private var templateService: TemplateService
    @Environment(\.dismiss) private var dismiss
    let onSelect: (TemplateService.BlockTemplate) -> Void

    @State private var isCreating = false
    @State private var editingTemplate: TemplateService.BlockTemplate?
    @State private var formName = ""
    @State private var formDescription = ""
    @State private var formIcon = "doc.text"
    @State private var formMarkdown = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            templateList
        }
        .frame(width: 380, height: 400)
        .sheet(isPresented: $isCreating) {
            templateForm(title: "New Template", onSave: createTemplate)
        }
        .sheet(item: $editingTemplate) { template in
            templateForm(title: "Edit Template", onSave: { updateTemplate(original: template) })
        }
    }

    private var header: some View {
        HStack {
            Text("Templates")
                .font(.headline)
            Spacer()
            Button {
                resetForm()
                isCreating = true
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var templateList: some View {
        Group {
            if templateService.templates.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 32))
                        .foregroundColor(.secondary.opacity(0.5))
                    Text("No templates")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(templateService.templates) { template in
                            templateRow(template)
                        }
                    }
                }
            }
        }
    }

    private func templateRow(_ template: TemplateService.BlockTemplate) -> some View {
        Button {
            onSelect(template)
            dismiss()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: template.icon)
                    .font(.title3)
                    .foregroundColor(GeoStyle.Colors.geoBlue)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(template.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.primary)
                    if !template.description.isEmpty {
                        Text(template.description)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .plainNoFocusButton()
        .contextMenu {
            Button {
                formName = template.name
                formDescription = template.description
                formIcon = template.icon
                formMarkdown = template.markdown
                editingTemplate = template
            } label: {
                Label("Edit", systemImage: "pencil")
            }
            Button(role: .destructive) {
                templateService.deleteTemplate(template)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private func templateForm(title: String, onSave: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
            TextField("Name", text: $formName)
                .textFieldStyle(.roundedBorder)
            TextField("Description", text: $formDescription)
                .textFieldStyle(.roundedBorder)
            TextField("SF Symbol Icon", text: $formIcon)
                .textFieldStyle(.roundedBorder)
            Text("Markdown")
                .font(.subheadline.weight(.medium))
            TextEditor(text: $formMarkdown)
                .font(.system(size: 12, design: .monospaced))
                .frame(minHeight: 120)
                .border(Color(.separatorColor))
            HStack {
                Spacer()
                Button("Cancel") {
                    isCreating = false
                    editingTemplate = nil
                }
                Button("Save") {
                    onSave()
                    isCreating = false
                    editingTemplate = nil
                }
                .keyboardShortcut(.defaultAction)
                .disabled(formName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 400, height: 400)
    }

    private func resetForm() {
        formName = ""
        formDescription = ""
        formIcon = "doc.text"
        formMarkdown = ""
    }

    private func createTemplate() {
        let template = TemplateService.BlockTemplate(
            id: UUID().uuidString,
            name: formName.trimmingCharacters(in: .whitespaces),
            description: formDescription.trimmingCharacters(in: .whitespaces),
            markdown: formMarkdown,
            icon: formIcon.trimmingCharacters(in: .whitespaces),
            createdAt: Date()
        )
        templateService.saveTemplate(template)
    }

    private func updateTemplate(original: TemplateService.BlockTemplate) {
        if original.name != formName.trimmingCharacters(in: .whitespaces) {
            templateService.deleteTemplate(original)
        }
        let updated = TemplateService.BlockTemplate(
            id: original.id,
            name: formName.trimmingCharacters(in: .whitespaces),
            description: formDescription.trimmingCharacters(in: .whitespaces),
            markdown: formMarkdown,
            icon: formIcon.trimmingCharacters(in: .whitespaces),
            createdAt: original.createdAt
        )
        templateService.saveTemplate(updated)
    }
}
