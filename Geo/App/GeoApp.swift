import SwiftUI
import AppKit
import Combine
import os.log

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "geo", category: "GeoApp")

enum RepositoryError: Error, Equatable {
    case notFound
    case invalidInput
    case storageFailure
}

extension RepositoryError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .notFound:
            return "Item not found."
        case .invalidInput:
            return "Invalid input."
        case .storageFailure:
            return "Storage operation failed."
        }
    }
}

struct AppEnvironment: Sendable {
    let blocksRepository: any BlocksRepository
    let tasksRepository: any TasksRepository
    let tagsRepository: any TagsRepository
    let captureRepository: any CaptureRepository
    let dayRepository: any DayRepository
    let shelfRepository: any ShelfRepository
    let navigationRepository: any NavigationRepository
    let settingsRepository: any SettingsRepository
    let attachmentService: any AttachmentService
    let usageTracker: any UsageTracker
    let holidayService: any HolidayServiceProviding
}

final class AppContainer {
    static let live = AppContainer()

    let logStore: LogStore
    let blocksStore: BlocksStore
    let tasksStore: TasksStore
    let dayStore: DayStore
    let tagStore: TagStore
    let shelfStore: ShelfStore
    let holidayService: any HolidayServiceProviding
    let watcher: ScreenshotWatcher
    let navigationStore: NavigationStore
    let hotkeyManager: GlobalHotkeyManager
    let notificationManager: NotificationManager
    let notchStateStore: NotchStateStore
    let notchWindowController: NotchWindowController
    let dayManager: DayManager
    let mcpServer: MCPServer
    let httpServer: GeoHTTPServer
    let templateService: TemplateService
    let nanoHermesService: HermesStatusService
    let environment: AppEnvironment

    init() {
        let ocrService = OCRService.shared
        let markdownConverter = MarkdownConverter.shared
        let indexCoordinator = IndexCoordinator.shared
        let storageMigration = StorageMigrationService.shared
        let permissionRegistry = MainActor.assumeIsolated { PermissionRegistry.shared }

        let tagStore = MainActor.assumeIsolated { TagStore() }
        let tasksStore = MainActor.assumeIsolated { TasksStore() }
        let dayStore = MainActor.assumeIsolated { DayStore() }
        let navigationStore = NavigationStore()
        let shelfStore = MainActor.assumeIsolated { ShelfStore.shared }
        let holidayService = HolidayService.shared
        let logStore = MainActor.assumeIsolated { LogStore() }

        let captureAdapter = CaptureStoreRepositoryAdapter(logStore: logStore)
        let dayStoreAdapter = DayStoreRepositoryAdapter(dayStore: dayStore)
        let dayManager = DayManager(dayRepository: dayStoreAdapter, captureRepository: captureAdapter)
        MainActor.assumeIsolated { logStore.configure(dayManager: dayManager) }

        let blocksStore = MainActor.assumeIsolated {
            BlocksStore(
                indexCoordinator: indexCoordinator,
                dayManager: dayManager,
                storageMigration: storageMigration,
                markdownConverter: markdownConverter
            )
        }

        let watcher = ScreenshotWatcher(logStore: logStore, ocrService: ocrService)
        let shelfStoreAdapter = ShelfStoreRepositoryAdapter(shelfStore: shelfStore)

        let hotkeyManager = GlobalHotkeyManager(screenshotWatcher: watcher, logStore: logStore) { [navigationStore] tab in
            navigationStore.selectTab(tab)
        }
        let notificationManager = MainActor.assumeIsolated {
            NotificationManager { [navigationStore] tab in navigationStore.selectTab(tab) }
        }
        let notchStateStore = MainActor.assumeIsolated { NotchStateStore() }

        let permissionService = PermissionRegistryAdapter(permissionRegistry: permissionRegistry)
        let notificationService = MainActor.assumeIsolated { NotificationManagerAdapter(notificationManager: notificationManager) }
        let settingsRepository = MainActor.assumeIsolated {
            UserDefaultsSettingsAdapter(
                permissionService: permissionService,
                notificationService: notificationService,
                screenshotWatcher: watcher,
                ocrService: ocrService,
                logStore: logStore
            )
        }
        let navigationRepository = NavigationStoreAdapter(navigationStore: navigationStore)
        let blocksAdapter = BlocksStoreRepositoryAdapter(blocksStore: blocksStore)
        let tasksAdapter = TasksStoreRepositoryAdapter(tasksStore: tasksStore)
        let tagsAdapter = TagStoreRepositoryAdapter(tagStore: tagStore)

        let templateService = MainActor.assumeIsolated { TemplateService.shared }

        let mcpTools = MainActor.assumeIsolated {
            BlockTools.register(blocks: blocksAdapter, tags: tagsAdapter, days: dayStoreAdapter)
                + TaskTools.register(tasks: tasksAdapter)
                + DayTools.register(days: dayStoreAdapter, blocks: blocksAdapter)
                + TagTools.register(tags: tagsAdapter, blocks: blocksAdapter)
                + AITools.register()
        }
        let mcpAuthGuard = MCPAuthGuard()
        let registry = MCPToolRegistry(tools: mcpTools)
        let mcpServer = MCPServer(registry: registry, authGuard: mcpAuthGuard)
        mcpServer.subscriptionManager = SubscriptionManager(blocks: blocksAdapter, tasks: tasksAdapter)

        let apiRouter = GeoAPIRouter(registry: registry, blocks: blocksAdapter)
        let httpServer = GeoHTTPServer(router: apiRouter)

        let nanoHermesService = MainActor.assumeIsolated { HermesStatusService() }

        let appEnvironment = AppEnvironment(
            blocksRepository: blocksAdapter,
            tasksRepository: tasksAdapter,
            tagsRepository: tagsAdapter,
            captureRepository: captureAdapter,
            dayRepository: dayStoreAdapter,
            shelfRepository: shelfStoreAdapter,
            navigationRepository: navigationRepository,
            settingsRepository: settingsRepository,
            attachmentService: FileAttachmentService(),
            usageTracker: FABUsageTracker(),
            holidayService: holidayService
        )

        let notchWindowController = MainActor.assumeIsolated {
            NotchWindowController(stateStore: notchStateStore, environment: appEnvironment)
        }

        self.logStore = logStore
        self.blocksStore = blocksStore
        self.tasksStore = tasksStore
        self.dayStore = dayStore
        self.tagStore = tagStore
        self.shelfStore = shelfStore
        self.holidayService = holidayService
        self.watcher = watcher
        self.navigationStore = navigationStore
        self.hotkeyManager = hotkeyManager
        self.notificationManager = notificationManager
        self.notchStateStore = notchStateStore
        self.notchWindowController = notchWindowController
        self.dayManager = dayManager
        self.mcpServer = mcpServer
        self.httpServer = httpServer
        self.templateService = templateService
        self.nanoHermesService = nanoHermesService
        self.environment = appEnvironment
    }
}

private struct AppEnvironmentKey: EnvironmentKey { static let defaultValue = AppContainer.live.environment }
private struct NavigationStoreKey: EnvironmentKey { static let defaultValue = AppContainer.live.navigationStore }
private struct TabRouterKey: EnvironmentKey { static let defaultValue = AppContainer.live.navigationStore.tabRouter }

extension EnvironmentValues {
    var appEnvironment: AppEnvironment {
        get { self[AppEnvironmentKey.self] } set { self[AppEnvironmentKey.self] = newValue }
    }
    var navigationStore: NavigationStore {
        get { self[NavigationStoreKey.self] } set { self[NavigationStoreKey.self] = newValue }
    }
    var tabRouter: TabRouter {
        get { self[TabRouterKey.self] } set { self[TabRouterKey.self] = newValue }
    }
}

@main
struct GeoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    private let container: AppContainer
    @StateObject private var blocksViewModel: BlocksViewModel
    @StateObject private var watcher: ScreenshotWatcher
    @State private var showOnboarding: Bool = !UserDefaults.standard.bool(forKey: "ai.geo.onboarding.completed")

    init() {
        PerformanceTracker.shared.markStartupBegin()
        if !ProcessInfo.processInfo.isRunningTests {
            BackupService.shared.applyPendingRestoreIfNeeded()
        }
        let container = AppContainer.live
        self.container = container
        _blocksViewModel = StateObject(wrappedValue: BlocksViewModel())
        _watcher = StateObject(wrappedValue: container.watcher)
    }

    var body: some Scene {
        WindowGroup("") {
            MainView()
                .environmentObject(blocksViewModel)
                .environmentObject(container.blocksStore)
                .environmentObject(container.tasksStore)
                .environmentObject(container.dayStore)
                .environmentObject(container.nanoHermesService)
                .environment(\.navigationStore, container.navigationStore)
                .environment(\.tabRouter, container.navigationStore.tabRouter)
                .environment(\.appEnvironment, container.environment)
                .frame(minWidth: 1200, minHeight: 800)
                .task {
                    blocksViewModel.bindIfNeeded(
                        blocksRepository: container.environment.blocksRepository,
                        tagsRepository: container.environment.tagsRepository,
                        blocksStore: container.blocksStore
                    )
                }
                .sheet(isPresented: $showOnboarding) {
                    OnboardingPermissionsView()
                }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            AboutCommand()
            AlwaysOnTopCommand()

            GeoCommands()
        }

        WindowGroup("Block Editor", id: "editor", for: String.self) { $blockId in
            BlockEditorWindowWrapper(blockId: blockId)
                .environmentObject(blocksViewModel)
                .environmentObject(container.blocksStore)
                .environment(\.navigationStore, container.navigationStore)
                .environment(\.appEnvironment, container.environment)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 430, height: 600)
        .windowResizability(.contentMinSize)
        .commandsRemoved()
    }
}

struct BlockEditorWindowWrapper: View {
    let blockId: String?
    @Environment(\.appEnvironment) private var appEnvironment
    @EnvironmentObject private var viewModel: BlocksViewModel
    @State private var forceRawEditor: Bool = false
    @StateObject private var actionsHolder = BlockEditorActionsHolder()

    var body: some View {
        NavigationStack {
            if let blockId {
                if let block = viewModel.block(withID: blockId) {
                    let actions = actionsHolder.actions(viewModel: viewModel, focusedId: blockId)
                    BlockEditorView(block: block, actions: actions)
                        .equatable()
                } else if viewModel.hasLoadedInitialSnapshot {
                    Text("Block not found")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                Text("Block not found")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task {
            viewModel.bindIfNeeded(
                blocksRepository: appEnvironment.blocksRepository,
                tagsRepository: appEnvironment.tagsRepository
            )
        }
        .frame(
            minWidth: 280,
            idealWidth: 430,
            minHeight: 320,
            idealHeight: 600
        )
    }
}

@MainActor
final class BlockEditorActionsHolder: ObservableObject {
    private var cached: BlockEditorActions?
    private var cachedFocusedId: String?

    func actions(viewModel: BlocksViewModel, focusedId: String) -> BlockEditorActions {
        if let cached, cachedFocusedId == focusedId {
            return cached
        }
        let new = BlockEditorActions(viewModel: viewModel, focusedId: focusedId)
        cached = new
        cachedFocusedId = focusedId
        return new
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    private let container = AppContainer.live
    private var permissionStateCancellable: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        PerformanceTracker.shared.markStartupEnd()

        guard !ProcessInfo.processInfo.isRunningTests else { return }

        DayMigrationService.shared.migrateIfNeeded()
        Task { [container] in
            await FrontmatterStripMigrationService.shared.runIfNeeded()
            let fileService = await MainActor.run { container.blocksStore.fileService }
            let metadata = await MainActor.run { container.blocksStore.metadataService.blocksMetadata }
            await IndexCoordinator.shared.repairIntegrity(fileService: fileService, metadata: metadata)
            await MainActor.run {
                container.blocksStore.reload()
            }
            let hydrated = await IndexCoordinator.shared.fetchAllMetadata()
            await MainActor.run {
                container.blocksStore.metadataService.hydrateFromIndex(hydrated)
            }
            let sidecarURL = fileService.blocksDirectory.appendingPathComponent(".blocks-metadata.json")
            let bakURL = sidecarURL.appendingPathExtension("bak")
            if FileManager.default.fileExists(atPath: sidecarURL.path)
                && !FileManager.default.fileExists(atPath: bakURL.path) {
                do {
                    try FileManager.default.moveItem(at: sidecarURL, to: bakURL)
                    logger.info("metadata-sidecar: renamed to .bak (SQLite is now authoritative)")
                } catch {
                    logger.error("metadata-sidecar: failed to rename to .bak: \(error.localizedDescription)")
                }
            }
        }
        container.templateService.loadTemplates()
        container.notchWindowController.show()
        container.notificationManager.configure(tasksRepository: container.environment.tasksRepository)
        container.notificationManager.startMonitoring()
        container.watcher.startWatching()
        Task { @MainActor in container.nanoHermesService.start() }

        do {
            try container.mcpServer.start()
        } catch {
            logger.error("Failed to start MCP server: \(error.localizedDescription)")
        }

        APITokenStore.shared.ensureBootstrapTokens()
        do {
            try container.httpServer.start()
        } catch {
            logger.error("Failed to start HTTP API server: \(error.localizedDescription)")
        }

        PermissionRegistry.shared.refreshAll()
        Task { @MainActor in
            self.startProtectedMonitoringIfAuthorized()
        }
        permissionStateCancellable = PermissionRegistry.shared.$states
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in
                    self.startProtectedMonitoringIfAuthorized()
                }
            }

        Task {
            _ = await PermissionRegistry.shared.requestAll()
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        let mdURLs = urls.filter { $0.pathExtension.lowercased() == "md" || $0.pathExtension.lowercased() == "markdown" }
        guard !mdURLs.isEmpty else { return }

        Task { @MainActor in
            let blocksRepo = container.environment.blocksRepository
            for url in mdURLs {
                guard let content = try? String(contentsOf: url, encoding: .utf8) else { continue }
                let title = url.deletingPathExtension().lastPathComponent
                _ = try? await blocksRepo.create(title: title, markdown: content)
            }
            container.navigationStore.selectTab(.nodes)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard !ProcessInfo.processInfo.isRunningTests else { return }
        let pending = container.blocksStore.snapshotPendingSaves()
        if !pending.isEmpty {
            let flushSemaphore = DispatchSemaphore(value: 0)
            Task.detached(priority: .userInitiated) {
                for t in pending { _ = await t.value }
                flushSemaphore.signal()
            }
            _ = flushSemaphore.wait(timeout: .now() + 5.0)
        }
        container.blocksStore.flushPendingMetadata()
        permissionStateCancellable?.cancel()
        permissionStateCancellable = nil
        container.hotkeyManager.stopMonitoring()
        container.notificationManager.stopMonitoring()
        container.watcher.stopWatching()
        container.mcpServer.stop()
        container.httpServer.stop()
        MainActor.assumeIsolated { container.nanoHermesService.stop() }
    }

    @MainActor
    private func startProtectedMonitoringIfAuthorized() {
        let permissions = PermissionRegistry.shared
        guard permissions.accessibility.isGranted, permissions.inputMonitoring.isGranted else { return }
        container.hotkeyManager.startMonitoring()
    }
}

