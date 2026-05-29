import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

@MainActor
final class SettingsViewModel: ObservableObject {
    @Published var alwaysOnTop = false {
        didSet { persistIfNeeded { $0.persistAlwaysOnTop(alwaysOnTop) } }
    }
    @Published var editorFontSize = EditorTypographyPreferences.defaultSize {
        didSet { persistIfNeeded { $0.persistEditorFontSize(editorFontSize) } }
    }

    @Published private(set) var screenshotFolder = ScreenshotFolderPreference.current
    @Published private(set) var isScreenshotFolderValid = false
    @Published private(set) var accessibilityPermission: PermissionState = .unknown
    @Published private(set) var inputMonitoringPermission: PermissionState = .unknown
    @Published private(set) var notificationAuthorizationStatus: UNAuthorizationStatus = .notDetermined
    @Published private(set) var captureSnapshot = SettingsCaptureSnapshot()
    @Published var setupMessage: String?
    @Published var ocrTestMessage: String?
    @Published var backupMessage: String?

    private var repository: (any SettingsRepository)?
    private var isBound = false
    private var isApplyingSnapshot = false

    func bindIfNeeded(repository: any SettingsRepository) {
        guard !isBound else { return }
        bind(repository: repository)
    }

    func bind(repository: any SettingsRepository) {
        self.repository = repository
        isBound = true
        sanitizeTypographyPreferences()
        apply(repository.loadSnapshot())
    }

    var notificationsGranted: Bool {
        switch notificationAuthorizationStatus {
        case .authorized, .provisional:
            return true
        default:
            return false
        }
    }

    var notificationStatusLabel: String {
        switch notificationAuthorizationStatus {
        case .authorized:
            return "Allowed"
        case .provisional:
            return "Temporarily allowed"
        case .denied:
            return "Denied"
        case .notDetermined:
            return "Not requested"
        @unknown default:
            return "Unknown"
        }
    }

    var completedSetupItems: Int {
        [
            accessibilityPermission.isGranted,
            inputMonitoringPermission.isGranted,
            notificationsGranted,
            isScreenshotFolderValid
        ].filter { $0 }.count
    }

    var totalSetupItems: Int { 4 }

    var setupComplete: Bool {
        completedSetupItems == totalSetupItems
    }

    func refreshStatus() async {
        guard let repository else { return }
        repository.refreshPermissions()
        _ = await repository.refreshNotificationAuthorizationStatus()
        apply(repository.loadSnapshot())
    }

    func refreshCaptureStatus() {
        guard let repository else { return }
        captureSnapshot = repository.loadSnapshot().captureSnapshot
    }

    func requestPermission(_ id: String) {
        Task {
            guard let repository else { return }
            _ = await repository.requestPermission(id)
            await refreshStatus()
        }
    }

    func openPermissionSettings(for id: String) {
        repository?.openPermissionSettings(for: id)
    }

    func resolveNotifications() {
        Task {
            guard let repository else { return }
            if notificationAuthorizationStatus == .denied {
                repository.openNotificationSettings()
            } else {
                _ = await repository.requestNotificationAuthorization()
            }
            await refreshStatus()
        }
    }

    func openNotificationSettings() {
        repository?.openNotificationSettings()
    }

    func fixSetup() {
        Task {
            guard let repository else { return }
            setupMessage = "Applying recommended setup actions..."

            _ = await repository.requestAllPermissions()

            if notificationAuthorizationStatus == .notDetermined {
                _ = await repository.requestNotificationAuthorization()
            } else if notificationAuthorizationStatus == .denied {
                repository.openNotificationSettings()
            }

            if !isScreenshotFolderValid {
                setDesktop()
            }

            await refreshStatus()
            refreshCaptureStatus()

            setupMessage = setupComplete
                ? "Setup complete."
                : "Some items still need manual approval in System Settings."
        }
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = screenshotFolder
        panel.prompt = "Choose"

        if panel.runModal() == .OK, let url = panel.url {
            updateScreenshotFolder(to: url)
        }
    }

    func setDesktop() {
        guard let repository else { return }
        updateScreenshotFolder(to: repository.defaultDesktopFolder())
    }

    func revealScreenshotFolder() {
        repository?.revealInFinder(screenshotFolder)
    }

    func runOCRSelfTest() {
        Task {
            guard let repository else { return }
            let recognized = await repository.runOCRSelfTest()
            ocrTestMessage = "Recognized: \(recognized)"
            refreshCaptureStatus()
        }
    }

    func triggerTestNotification() {
        repository?.triggerTestNotification()
    }

    private var dataDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return base.appendingPathComponent("Geo")
    }

    func revealDataFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([dataDirectory])
    }

    func exportBackup() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Export Here"
        panel.message = "Choose a folder for the Geo backup archive."
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        backupMessage = "Exporting backup…"
        Task { @MainActor in
            let store = AppContainer.live.blocksStore
            let pending = store.snapshotPendingSaves()
            store.flushPendingMetadata()
            for t in pending { _ = await t.value }
            do {
                let url = try await Task.detached(priority: .userInitiated) {
                    try BackupService.shared.exportArchive(to: destination)
                }.value
                NSWorkspace.shared.activateFileViewerSelecting([url])
                backupMessage = "Backup saved to \(url.lastPathComponent)."
            } catch {
                backupMessage = "Export failed: \(error.localizedDescription)"
            }
        }
    }

    func restoreBackup() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.zip]
        panel.prompt = "Restore"
        panel.message = "Choose a Geo backup archive."
        guard panel.runModal() == .OK, let archiveURL = panel.url else { return }

        let info: ArchiveInfo
        do {
            info = try BackupService.shared.validateArchive(at: archiveURL)
        } catch {
            backupMessage = "Invalid archive: \(error.localizedDescription)"
            return
        }

        let confirm = NSAlert()
        confirm.alertStyle = .warning
        confirm.messageText = "Restore from \(archiveURL.lastPathComponent)?"
        confirm.informativeText = "This archive contains \(info.blockCount) block(s). Restoring replaces all current Geo data (a snapshot of your current data is kept). Geo must relaunch to finish."
        confirm.addButton(withTitle: "Restore & Quit")
        confirm.addButton(withTitle: "Cancel")
        guard confirm.runModal() == .alertFirstButtonReturn else { return }

        do {
            try BackupService.shared.stageRestore(from: archiveURL)
        } catch {
            backupMessage = "Restore failed: \(error.localizedDescription)"
            return
        }

        let staged = NSAlert()
        staged.messageText = "Restore staged"
        staged.informativeText = "Geo will now quit. Relaunch it to finish restoring your data."
        staged.addButton(withTitle: "Quit Now")
        staged.runModal()
        NSApp.terminate(nil)
    }

    private func updateScreenshotFolder(to url: URL) {
        repository?.updateScreenshotFolder(to: url)
        apply(repository?.loadSnapshot())
    }

    private func sanitizeTypographyPreferences() {
        let clampedSize = EditorTypographyPreferences.clampedSize(editorFontSize)
        if editorFontSize != clampedSize {
            editorFontSize = clampedSize
        }
    }

    private func apply(_ snapshot: SettingsSnapshot?) {
        guard let snapshot else { return }
        isApplyingSnapshot = true
        alwaysOnTop = snapshot.alwaysOnTop
        editorFontSize = snapshot.editorFontSize
        screenshotFolder = snapshot.screenshotFolder
        isScreenshotFolderValid = snapshot.isScreenshotFolderValid
        accessibilityPermission = snapshot.accessibility
        inputMonitoringPermission = snapshot.inputMonitoring
        notificationAuthorizationStatus = snapshot.notificationAuthorizationStatus
        captureSnapshot = snapshot.captureSnapshot
        isApplyingSnapshot = false

        sanitizeTypographyPreferences()
    }

    private func persistIfNeeded(_ operation: (any SettingsRepository) -> Void) {
        guard !isApplyingSnapshot, let repository else { return }
        operation(repository)
    }
}
