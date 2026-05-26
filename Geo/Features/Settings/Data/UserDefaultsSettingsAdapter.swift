import AppKit
import Foundation
import UserNotifications

@MainActor
struct UserDefaultsSettingsAdapter: SettingsRepository, @unchecked Sendable {
    private let permissionService: any PermissionService
    private let notificationService: any NotificationService
    private let screenshotWatcher: ScreenshotWatcher
    private let ocrService: OCRService
    private let logStore: LogStore
    private let userDefaults: UserDefaults
    private let fileManager: FileManager

    init(
        permissionService: any PermissionService,
        notificationService: any NotificationService,
        screenshotWatcher: ScreenshotWatcher,
        ocrService: OCRService,
        logStore: LogStore,
        userDefaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) {
        self.permissionService = permissionService
        self.notificationService = notificationService
        self.screenshotWatcher = screenshotWatcher
        self.ocrService = ocrService
        self.logStore = logStore
        self.userDefaults = userDefaults
        self.fileManager = fileManager
    }

    func loadSnapshot() -> SettingsSnapshot {
        let screenshotFolder = ScreenshotFolderPreference.current

        return SettingsSnapshot(
            alwaysOnTop: userDefaults.bool(forKey: AlwaysOnTop.settingsKey),
            editorFontSize: userDefaults.object(forKey: EditorTypographyPreferences.fontSizeKey) as? Double
                ?? EditorTypographyPreferences.defaultSize,
            screenshotFolder: screenshotFolder,
            isScreenshotFolderValid: isReadableDirectory(screenshotFolder),
            accessibility: permissionService.checkPermission("accessibility"),
            inputMonitoring: permissionService.checkPermission("inputMonitoring"),
            notificationAuthorizationStatus: notificationService.authorizationStatus,
            captureSnapshot: SettingsCaptureSnapshot(
                fileName: screenshotWatcher.lastProcessedURL?.lastPathComponent,
                processedAt: screenshotWatcher.lastProcessedURL == nil ? nil : screenshotWatcher.lastProcessedTime,
                textLength: screenshotWatcher.lastOCRText?.count
            )
        )
    }

    func persistAlwaysOnTop(_ isEnabled: Bool) {
        userDefaults.set(isEnabled, forKey: AlwaysOnTop.settingsKey)
    }

    func persistEditorFontSize(_ size: Double) {
        userDefaults.set(size, forKey: EditorTypographyPreferences.fontSizeKey)
    }

    func refreshPermissions() {
        permissionService.refreshPermissions()
    }

    func requestPermission(_ id: String) async -> PermissionState {
        await permissionService.requestPermission(id)
    }

    func requestAllPermissions() async -> [String: PermissionState] {
        await permissionService.requestAllPermissions()
    }

    func openPermissionSettings(for id: String) {
        permissionService.openSettings(for: id)
    }

    func refreshNotificationAuthorizationStatus() async -> UNAuthorizationStatus {
        await notificationService.refreshAuthorizationStatus()
    }

    func requestNotificationAuthorization() async -> Bool {
        await notificationService.requestAuthorization()
    }

    func openNotificationSettings() {
        notificationService.openSettings()
    }

    func triggerTestNotification() {
        notificationService.triggerTestNotification()
    }

    func updateScreenshotFolder(to url: URL) {
        ScreenshotFolderPreference.save(url)
        screenshotWatcher.updateWatchDirectory(to: url)
    }

    func defaultDesktopFolder() -> URL {
        fileManager.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser
    }

    func revealInFinder(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    func runOCRSelfTest() async -> String {
        let image = makeOCRTestImage()

        final class ResumeOnce: @unchecked Sendable {
            private var done = false
            func claim() -> Bool {
                guard !done else { return false }
                done = true
                return true
            }
        }

        let once = ResumeOnce()
        return await withCheckedContinuation { continuation in
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
                guard once.claim() else { return }
                continuation.resume(returning: "OCR self-test timed out")
            }

            ocrService.process(image) { [logStore] recognized in
                DispatchQueue.main.async {
                    guard once.claim() else { return }
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(recognized, forType: .string)
                    logStore.addLog("OCR Self-Test", text: recognized)
                    continuation.resume(returning: recognized)
                }
            }
        }
    }

    private func isReadableDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
        return exists && isDirectory.boolValue && fileManager.isReadableFile(atPath: url.path)
    }

    private func makeOCRTestImage() -> NSImage {
        let size = NSSize(width: 480, height: 200)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.textBackgroundColor.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()

        let text = "OCR test from Geo"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 18, weight: .medium),
            .foregroundColor: NSColor.labelColor
        ]
        NSAttributedString(string: text, attributes: attributes)
            .draw(at: NSPoint(x: 20, y: size.height / 2 - 10))
        image.unlockFocus()
        return image
    }
}
