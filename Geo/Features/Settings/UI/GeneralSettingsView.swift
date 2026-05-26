import AppKit
import SwiftUI

private enum SettingsSection: String, CaseIterable, Identifiable {
    case setup
    case capture
    case history
    case appearance
    case ai
    case nanoHermes
    case advanced

    var id: String { rawValue }

    var title: String {
        switch self {
        case .setup:
            return "Setup"
        case .capture:
            return "Capture & OCR"
        case .history:
            return "History"
        case .appearance:
            return "Behavior"
        case .ai:
            return "AI"
        case .nanoHermes:
            return "Hermes"
        case .advanced:
            return "Advanced"
        }
    }

    var icon: String {
        switch self {
        case .setup:
            return "checklist"
        case .capture:
            return "camera.viewfinder"
        case .history:
            return "clock.arrow.circlepath"
        case .appearance:
            return "slider.horizontal.3"
        case .ai:
            return "sparkles"
        case .nanoHermes:
            return "antenna.radiowaves.left.and.right"
        case .advanced:
            return "wrench.and.screwdriver"
        }
    }
}

struct GeneralSettingsView: View {
    @Environment(\.appEnvironment) private var appEnvironment
    @StateObject private var viewModel = SettingsViewModel()
    @StateObject private var captureVM = CaptureViewModel()

    @State private var selectedPane: SettingsSection = .setup

    private var editorFontSizeBinding: Binding<Double> {
        Binding(
            get: { EditorTypographyPreferences.clampedSize(viewModel.editorFontSize) },
            set: { viewModel.editorFontSize = EditorTypographyPreferences.clampedSize($0) }
        )
    }

    var body: some View {
        HStack(spacing: 0) {
            List {
                ForEach(SettingsSection.allCases) { pane in
                    Button {
                        selectedPane = pane
                    } label: {
                        SettingsSidebarRow(
                            title: pane.title,
                            icon: pane.icon,
                            isSelected: selectedPane == pane
                        )
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                    .listRowBackground(selectedPane == pane ? Color.accentColor.opacity(0.14) : Color.clear)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .background(Palette.secondaryBackground)
            .frame(minWidth: 220, idealWidth: 240, maxWidth: 250)
            .onMoveCommand { direction in
                movePaneSelection(direction)
            }

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    switch selectedPane {
                    case .setup:
                        setupPane
                    case .capture:
                        capturePane
                    case .history:
                        historyPane
                    case .appearance:
                        appearancePane
                    case .ai:
                        aiPane
                    case .nanoHermes:
                        nanoHermesPane
                    case .advanced:
                        advancedPane
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .task {
            viewModel.bindIfNeeded(repository: appEnvironment.settingsRepository)
            await viewModel.refreshStatus()
            viewModel.refreshCaptureStatus()
            captureVM.bindIfNeeded(repository: appEnvironment.captureRepository)
        }
    }

    private var setupPane: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsSectionHeader(
                title: "Setup",
                subtitle: "Finish the essentials so capture, OCR, and reminders work reliably."
            )

            SettingsCard(
                title: "Checklist",
                description: "Only critical setup items are shown here."
            ) {
                HStack(spacing: 12) {
                    ProgressView(
                        value: Double(viewModel.completedSetupItems),
                        total: Double(viewModel.totalSetupItems)
                    )
                    Text("\(viewModel.completedSetupItems) of \(viewModel.totalSetupItems) complete")
                        .font(.subheadline)
                        .foregroundStyle(Palette.tertiaryForeground)
                }

                SetupChecklistRow(
                    title: "Accessibility",
                    detail: "Required for global shortcuts and automated paste.",
                    isComplete: viewModel.accessibilityPermission.isGranted,
                    actionTitle: viewModel.accessibilityPermission.isGranted ? "Open" : "Allow",
                    action: {
                        if viewModel.accessibilityPermission.isGranted {
                            viewModel.openPermissionSettings(for: "accessibility")
                        } else {
                            viewModel.requestPermission("accessibility")
                        }
                    }
                )

                SetupChecklistRow(
                    title: "Input Monitoring",
                    detail: "Lets Geo detect keyboard events for shortcut workflows.",
                    isComplete: viewModel.inputMonitoringPermission.isGranted,
                    actionTitle: viewModel.inputMonitoringPermission.isGranted ? "Open" : "Allow",
                    action: {
                        if viewModel.inputMonitoringPermission.isGranted {
                            viewModel.openPermissionSettings(for: "inputMonitoring")
                        } else {
                            viewModel.requestPermission("inputMonitoring")
                        }
                    }
                )

                SetupChecklistRow(
                    title: "Notifications",
                    detail: "Current status: \(viewModel.notificationStatusLabel).",
                    isComplete: viewModel.notificationsGranted,
                    actionTitle: viewModel.notificationAuthorizationStatus == .denied ? "Open" : "Allow",
                    action: viewModel.resolveNotifications
                )

                SetupChecklistRow(
                    title: "Screenshot Folder",
                    detail: viewModel.screenshotFolder.path,
                    isComplete: viewModel.isScreenshotFolderValid,
                    actionTitle: viewModel.isScreenshotFolderValid ? "Reveal" : "Choose",
                    action: {
                        if viewModel.isScreenshotFolderValid {
                            viewModel.revealScreenshotFolder()
                        } else {
                            viewModel.chooseFolder()
                        }
                    }
                )

                HStack(spacing: 10) {
                    Button(viewModel.setupComplete ? "All Set" : "Fix Setup") {
                        viewModel.fixSetup()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.accentColor)
                    .disabled(viewModel.setupComplete)

                    Button("Refresh") {
                        refreshStatus()
                    }
                    .buttonStyle(.bordered)
                }

                if let setupMessage = viewModel.setupMessage, !setupMessage.isEmpty {
                    Text(setupMessage)
                        .font(.caption)
                        .foregroundStyle(Palette.tertiaryForeground)
                }
            }
        }
    }

    private var capturePane: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsSectionHeader(
                title: "Capture & OCR",
                subtitle: "Control where screenshots are watched and verify OCR output."
            )

            SettingsCard(
                title: "Screenshot Source",
                description: "Geo watches this folder and auto-processes new screenshots."
            ) {
                Text(viewModel.screenshotFolder.path)
                    .font(.caption)
                    .monospaced()
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Palette.background)
                    .cornerRadius(8)

                HStack(spacing: 10) {
                    Button("Choose Folder…") {
                        viewModel.chooseFolder()
                    }
                    .buttonStyle(.bordered)

                    Button("Use Desktop") {
                        viewModel.setDesktop()
                    }
                    .buttonStyle(.bordered)

                    Button("Reveal in Finder") {
                        viewModel.revealScreenshotFolder()
                    }
                    .buttonStyle(.bordered)
                }
            }

            SettingsCard(
                title: "OCR Self-Test",
                description: "Creates a test image and runs OCR to verify the full pipeline."
            ) {
                HStack(spacing: 10) {
                    Button("Run OCR Test") {
                        viewModel.runOCRSelfTest()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.accentColor)

                    if let ocrTestMessage = viewModel.ocrTestMessage, !ocrTestMessage.isEmpty {
                        Text(ocrTestMessage)
                            .font(.caption)
                            .foregroundStyle(Palette.tertiaryForeground)
                            .lineLimit(2)
                    }
                }
            }

            SettingsCard(
                title: "Latest Capture",
                description: "Quick health check for the watch and OCR flow."
            ) {
                if let fileName = viewModel.captureSnapshot.fileName {
                    Text("File: \(fileName)")
                        .font(.subheadline)

                    if let processedAt = viewModel.captureSnapshot.processedAt {
                        Text("Processed: \(DateFormatter.localizedString(from: processedAt, dateStyle: .none, timeStyle: .medium))")
                            .font(.caption)
                            .foregroundStyle(Palette.tertiaryForeground)
                    }

                    if let textLength = viewModel.captureSnapshot.textLength {
                        Text("Recognized text length: \(textLength) characters")
                            .font(.caption)
                            .foregroundStyle(Palette.tertiaryForeground)
                    }
                } else {
                    Text("No capture processed yet in this app session.")
                        .font(.subheadline)
                        .foregroundStyle(Palette.tertiaryForeground)
                }

                Button("Refresh Capture Status") {
                    viewModel.refreshCaptureStatus()
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var historyPane: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsSectionHeader(
                title: "History",
                subtitle: "Every screenshot Geo has processed, with extracted text and per-item actions."
            )

            SettingsCard(
                title: "Captures",
                description: "\(captureVM.filteredCaptures.count) of \(captureVM.captures.count) shown"
            ) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(Palette.tertiaryForeground)
                    TextField("Search OCR text or filename…", text: $captureVM.filterText)
                        .textFieldStyle(.roundedBorder)
                }

                OCRsListView(viewModel: captureVM)
                    .frame(minHeight: 360, maxHeight: 520)
            }
        }
    }

    private var appearancePane: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsSectionHeader(
                title: "Behavior",
                subtitle: "Control window behavior and editor typography."
            )

            SettingsCard(
                title: "Window Behavior",
                description: "Control whether editor windows stay in front while you work."
            ) {
                Toggle("Keep windows always on top", isOn: $viewModel.alwaysOnTop)
                Text(viewModel.alwaysOnTop
                    ? "Windows stay above other apps until you turn this off."
                    : "Windows use normal macOS layering."
                )
                .font(.caption)
                .foregroundStyle(Palette.tertiaryForeground)
            }

            SettingsCard(
                title: "Editor Typography",
                description: "Applies only to markdown editor content in block editor windows."
            ) {
                HStack(spacing: 10) {
                    Text("Size")
                        .font(.subheadline.weight(.medium))
                    Slider(
                        value: editorFontSizeBinding,
                        in: EditorTypographyPreferences.minSize...EditorTypographyPreferences.maxSize,
                        step: EditorTypographyPreferences.step
                    )
                    Text("\(Int(editorFontSizeBinding.wrappedValue)) pt")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(Palette.tertiaryForeground)
                        .frame(width: 44, alignment: .trailing)
                }

                Stepper(
                    value: editorFontSizeBinding,
                    in: EditorTypographyPreferences.minSize...EditorTypographyPreferences.maxSize,
                    step: EditorTypographyPreferences.step
                ) {
                    Text("Adjust in 1 pt increments")
                        .font(.caption)
                        .foregroundStyle(Palette.tertiaryForeground)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Preview")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Palette.tertiaryForeground)

                    Text("Heading")
                        .font(
                            FontManager.geistMonoFont(
                                size: CGFloat(editorFontSizeBinding.wrappedValue * 1.2),
                                weight: .semibold
                            )
                        )

                    Text("The quick brown fox jumps over the lazy dog.")
                        .font(
                            FontManager.geistMonoFont(
                                size: CGFloat(editorFontSizeBinding.wrappedValue)
                            )
                        )
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.background)
                .cornerRadius(8)
            }
        }
    }

    private var aiPane: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsSectionHeader(
                title: "AI",
                subtitle: "Configure the Anthropic API key that powers natural-language quick-add."
            )

            SettingsCard(
                title: "Anthropic API Key",
                description: "Stored securely in the macOS Keychain. Used only when the local parser is unsure."
            ) {
                AIKeySettingsView()
            }
        }
    }

    private var nanoHermesPane: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsSectionHeader(
                title: "Hermes",
                subtitle: "The hermes gateway runs as a LaunchAgent and bridges WhatsApp, Gmail, and Telegram for the agent."
            )

            NanoHermesSettingsView()
        }
    }

    private var advancedPane: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsSectionHeader(
                title: "Advanced",
                subtitle: "Diagnostics and system-level actions."
            )

            SettingsCard(
                title: "Diagnostics",
                description: "Use these tools when troubleshooting setup or reminder behavior."
            ) {
                HStack(spacing: 10) {
                    Button("Run OCR Test") {
                        viewModel.runOCRSelfTest()
                    }
                    .buttonStyle(.bordered)

                    Button("Send Test Notification") {
                        viewModel.triggerTestNotification()
                    }
                    .buttonStyle(.bordered)
                }

                Button("Refresh Permission Status") {
                    refreshStatus()
                }
                .buttonStyle(.bordered)
            }

            SettingsCard(
                title: "System Shortcuts",
                description: "Jump directly to specific macOS settings panes."
            ) {
                HStack(spacing: 10) {
                    Button("Accessibility") {
                        viewModel.openPermissionSettings(for: "accessibility")
                    }
                    .buttonStyle(.bordered)

                    Button("Input Monitoring") {
                        viewModel.openPermissionSettings(for: "inputMonitoring")
                    }
                    .buttonStyle(.bordered)

                    Button("Notifications") {
                        viewModel.openNotificationSettings()
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    private func movePaneSelection(_ direction: MoveCommandDirection) {
        let panes = SettingsSection.allCases
        guard let currentIndex = panes.firstIndex(of: selectedPane) else { return }

        let nextIndex: Int
        switch direction {
        case .up, .left:
            nextIndex = max(0, currentIndex - 1)
        case .down, .right:
            nextIndex = min(panes.count - 1, currentIndex + 1)
        @unknown default:
            return
        }

        selectedPane = panes[nextIndex]
    }

    private func refreshStatus() {
        Task {
            await viewModel.refreshStatus()
            viewModel.refreshCaptureStatus()
        }
    }
}

private struct SettingsSidebarRow: View {
    let title: String
    let icon: String
    let isSelected: Bool

    var body: some View {
        Label(title, systemImage: icon)
            .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
            .foregroundStyle(Palette.foreground)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
    }
}

private struct SettingsSectionHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.title2.weight(.semibold))
                .foregroundStyle(Palette.foreground)
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(Palette.tertiaryForeground)
        }
    }
}

private struct SettingsCard<Content: View>: View {
    let title: String
    let description: String
    let content: Content

    init(title: String, description: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.description = description
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
                .foregroundStyle(Palette.foreground)

            Text(description)
                .font(.caption)
                .foregroundStyle(Palette.tertiaryForeground)

            content
        }
        .padding(16)
        .background(Palette.secondaryBackground)
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.primary.opacity(0.18), lineWidth: 1)
        )
    }
}

private struct SetupChecklistRow: View {
    let title: String
    let detail: String
    let isComplete: Bool
    let actionTitle: String?
    let action: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: isComplete ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(isComplete ? Color.green : Color.orange)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Palette.foreground)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(Palette.tertiaryForeground)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            if let actionTitle, let action {
                Button(actionTitle) {
                    action()
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 4)
    }
}

