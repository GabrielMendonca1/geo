import Foundation
import os.log

private let compositeCommandLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "geo", category: "CompositeCommand")

struct CompositeCommand: EditorCommand {
    let name: String
    let commands: [EditorCommand]

    func execute(on blocks: inout [EditorBlock]) -> BlockFocusRequest? {
        var lastFocus: BlockFocusRequest?
        var executed: [EditorCommand] = []
        executed.reserveCapacity(commands.count)
        for command in commands {
            let snapshot = blocks
            let focus = command.execute(on: &blocks)
            if focus != nil {
                lastFocus = focus
                executed.append(command)
                continue
            }
            if blocks == snapshot {
                rollback(executed: executed, blocks: &blocks)
                assertionFailure("CompositeCommand '\(name)' child '\(command.name)' appears to have failed; rolling back \(executed.count) prior commands")
                compositeCommandLogger.error("CompositeCommand '\(self.name, privacy: .public)' child '\(command.name, privacy: .public)' appears to have failed; rolled back \(executed.count) prior commands")
                return nil
            }
            executed.append(command)
        }
        return lastFocus
    }

    func undo(on blocks: inout [EditorBlock]) -> BlockFocusRequest? {
        var lastFocus: BlockFocusRequest?
        for command in commands.reversed() {
            if let focus = command.undo(on: &blocks) {
                lastFocus = focus
            }
        }
        return lastFocus
    }

    private func rollback(executed: [EditorCommand], blocks: inout [EditorBlock]) {
        for command in executed.reversed() {
            _ = command.undo(on: &blocks)
        }
    }
}
