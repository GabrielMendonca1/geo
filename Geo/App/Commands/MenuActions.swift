import SwiftUI
import AppKit
import os.log

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "geo", category: "MenuActions")

@MainActor
struct MenuActions {
    static func bringMainWindowToFront() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.canBecomeKey && !($0 is NSPanel) }) {
            window.makeKeyAndOrderFront(nil)
        }
    }

    static func showTab(_ tab: AppTab, environment: AppEnvironment) {
        bringMainWindowToFront()
        environment.navigationRepository.selectTab(tab)
    }

    static func showSettings(environment: AppEnvironment) {
        showTab(.settings, environment: environment)
    }

    static func createAndOpenTodo(openWindow: OpenWindowAction, environment: AppEnvironment) {
        let todoTemplate = BlockTemplate.todo.make()
        Task {
            do {
                let block = try await environment.blocksRepository.create(
                    title: todoTemplate.title,
                    markdown: todoTemplate.markdown
                )
                await MainActor.run {
                    openEditor(for: block.id, openWindow: openWindow)
                }
            } catch {
                logger.error("Failed to create todo block: \(error.localizedDescription)")
            }
        }
    }

    static func createAndOpenNote(openWindow: OpenWindowAction, environment: AppEnvironment) {
        Task {
            do {
                let block = try await environment.blocksRepository.create(title: "New Note", markdown: "")
                await MainActor.run {
                    openEditor(for: block.id, openWindow: openWindow)
                }
            } catch {
                logger.error("Failed to create note block: \(error.localizedDescription)")
            }
        }
    }

    static func openBlockEditor(_ blockId: String, openWindow: OpenWindowAction) {
        openEditor(for: blockId, openWindow: openWindow)
    }

    static func openTaskCreateForm(environment: AppEnvironment) {
        showTab(.tasks, environment: environment)
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .openTaskCreateForm, object: nil)
        }
    }

    static func openTaskForm(taskId: String, environment: AppEnvironment) {
        showTab(.tasks, environment: environment)
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .openTaskForm,
                object: nil,
                userInfo: ["taskId": taskId]
            )
        }
    }

    private static func openEditor(for blockId: String, openWindow: OpenWindowAction) {
        Task { @MainActor in
            NSApp.activate(ignoringOtherApps: true)

            if !NSApp.isActive {
                for await _ in NotificationCenter.default.notifications(named: NSApplication.didBecomeActiveNotification) {
                    break
                }
            }

            openWindow(id: "editor", value: blockId)
        }
    }
}
