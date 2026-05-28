import AppKit
import SwiftUI

struct GeoCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.appEnvironment) private var appEnvironment

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") {
                MenuActions.showSettings(environment: appEnvironment)
            }
            .keyboardShortcut(",", modifiers: [.command])
        }

        CommandGroup(replacing: .newItem) {
            Button("New Note") {
                MenuActions.createAndOpenNote(openWindow: openWindow, environment: appEnvironment)
            }
            .keyboardShortcut("n", modifiers: [.command])

            Button("New To-Do") {
                MenuActions.createAndOpenTodo(openWindow: openWindow, environment: appEnvironment)
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])

            Divider()

            Button("Close Window") {
                NSApp.keyWindow?.performClose(nil)
            }
            .keyboardShortcut("w", modifiers: [.command])
        }

        CommandGroup(after: .toolbar) {
            Divider()

            ForEach(Array(AppTab.defaultNavigationOrder.enumerated()), id: \.element) { index, tab in
                Button("Show \(tab.displayTitle)") {
                    MenuActions.showTab(tab, environment: appEnvironment)
                }
                .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: [.command])
            }
        }
    }
}
