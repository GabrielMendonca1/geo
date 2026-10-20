import Carbon.HIToolbox
import Foundation

var checks = 0
var failures = 0

func check(_ name: String, _ condition: @autoclosure () -> Bool) {
    checks += 1
    if condition() {
        print("ok   · \(name)")
    } else {
        failures += 1
        print("FAIL · \(name)")
    }
}

let bindings = FilesSelectionHotKeys.approvedBindings
let convert = bindings.first { $0.action == .convert }
let tools = bindings.first { $0.action == .tools }

check("exactly two approved selection shortcuts", bindings.count == 2)
check("shortcut actions have independent Carbon IDs", Set(bindings.map(\.action.rawValue)).count == 2)
check("convert is Control+Option+Space", convert?.keyCode == UInt32(kVK_Space) && convert?.modifiers == UInt32(controlKey | optionKey))
check("tools is Shift+Control+Option+Space", tools?.keyCode == UInt32(kVK_Space) && tools?.modifiers == UInt32(shiftKey | controlKey | optionKey))
check("convert does not include Shift", convert.map { $0.modifiers & UInt32(shiftKey) == 0 } == true)
check("neither shortcut includes Command", bindings.allSatisfy { $0.modifiers & UInt32(cmdKey) == 0 })

let root = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? FileManager.default.currentDirectoryPath)
let hotKeyURL = root.appendingPathComponent("Sources/FileTools/Selection/FilesSelectionHotKeys.swift")
let appURL = root.appendingPathComponent("Sources/App/AppDelegate.swift")
let dictationURL = root.appendingPathComponent("Sources/Dictation/Hotkey.swift")
let hotKeySource = (try? String(contentsOf: hotKeyURL, encoding: .utf8)) ?? ""
let appSource = (try? String(contentsOf: appURL, encoding: .utf8)) ?? ""
let dictationSource = (try? String(contentsOf: dictationURL, encoding: .utf8)) ?? ""

check("handler is limited to hot-key pressed events", hotKeySource.contains("kEventHotKeyPressed") && !hotKeySource.contains("kEventHotKeyReleased"))
check("handler filters owned signature and action ID", hotKeySource.contains("identifier.signature == signature") && hotKeySource.contains("Action(rawValue: identifier.id)"))
check("unrelated selection hot keys remain unhandled", hotKeySource.contains("return OSStatus(eventNotHandledErr)"))

let dictationHotKey = Hotkey.shared
let dictationIdentifier = EventHotKeyID(signature: dictationHotKey.signature, id: dictationHotKey.identifierID)
let foreignSignature = EventHotKeyID(signature: 0x46_4F_52_45, id: dictationHotKey.identifierID)
let foreignID = EventHotKeyID(signature: dictationHotKey.signature, id: dictationHotKey.identifierID + 1)
check("dictation accepts its exact signature and ID", dictationHotKey.handle(dictationIdentifier) == noErr)
check("dictation rejects an unmatched signature", dictationHotKey.handle(foreignSignature) == OSStatus(eventNotHandledErr))
check("dictation rejects an unmatched ID", dictationHotKey.handle(foreignID) == OSStatus(eventNotHandledErr))
check("dictation callback filters event class and kind", dictationSource.contains("GetEventClass(event) == OSType(kEventClassKeyboard)") && dictationSource.contains("GetEventKind(event) == UInt32(kEventHotKeyPressed)"))
check("dictation parameter failures remain unhandled", dictationSource.contains("guard status == noErr else { return OSStatus(eventNotHandledErr) }"))
check("registration failure has user-readable detail", hotKeySource.contains("registrationError =") && appSource.contains("Atalhos de Arquivos indisponíveis"))
check("startup registers selection shortcuts", appSource.contains("registerFilesSelectionHotKeys()"))
check("shutdown unregisters selection shortcuts", appSource.contains("filesSelectionHotKeys.unregister()"))
check("shortcut failure has a separate disabled menu line", appSource.contains("filesShortcutErrorItem.isEnabled = false") && appSource.contains("appTailItems.insert(contentsOf: [filesShortcutErrorItem, filesShortcutRetryItem]"))
check("shortcut failure offers explicit retry", appSource.contains("#selector(menuRetryFilesSelectionHotKeys)") && appSource.contains("@objc private func menuRetryFilesSelectionHotKeys()"))
check("successful shortcut retry clears the app error", appSource.contains("if filesSelectionHotKeys.register() {\n            filesShortcutError = nil"))
let statusStart = appSource.range(of: "private func statusText()")
let recordingStart = appSource.range(of: "private func recordingStatus()")
let statusSource = statusStart.flatMap { start in recordingStart.map { String(appSource[start.lowerBound..<$0.lowerBound]) } } ?? ""
check("shortcut failure does not hijack dictation status", !statusSource.contains("filesShortcutError"))
check("shortcut failure does not force the error icon", !appSource.contains("blockingError != nil || filesShortcutError != nil"))
check("convert action invokes selection convert mode", appSource.contains("files.invokeSelection(mode: .convert)"))
check("tools action invokes selection tools mode", appSource.contains("files.invokeSelection(mode: .tools)"))
check("primary Arquivos menu explains selection shortcuts and permissions", appSource.contains("Arquivos — seleção ⌃⌥Space / ⇧⌃⌥Space e permissões…") && appSource.contains("files.showSelectionSettings()"))
let selectionMenuRange = appSource.range(of: "selectionItem = NSMenuItem")
check("selection menu exists and the utility dashboard is gone", selectionMenuRange != nil && !appSource.contains("painel utilitário"))
check("dictation remains Option+Space", dictationSource.contains("UInt32(kVK_Space)") && dictationSource.contains("UInt32(optionKey)"))

print("\npasses: \(checks - failures)  failures: \(failures)")
exit(failures == 0 ? 0 : 1)
