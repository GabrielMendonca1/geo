import AppKit
import ApplicationServices
import Carbon
import Foundation

struct WorkspaceFrontmostApplicationProvider: FrontmostApplicationProviding {
    private let waitSeconds: Double

    init(waitSeconds: Double = 0.5) {
        self.waitSeconds = max(0.05, waitSeconds)
    }

    func frontmostApplication() -> FileSelectionSource? {
        if Thread.isMainThread { return Self.read() }
        let box = FrontmostBox()
        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            box.value = Self.read()
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + waitSeconds) == .success else { return nil }
        return box.value
    }

    private static func read() -> FileSelectionSource? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bundleIdentifier = app.bundleIdentifier
        else { return nil }
        return FileSelectionSource(pid: app.processIdentifier, bundleIdentifier: bundleIdentifier)
    }
}

private final class FrontmostBox {
    var value: FileSelectionSource?
}

final class FinderFileSelectionProvider: FileSelectionProviding, FileSelectionPermissionProviding {
    private static let finderBundleIdentifier = "com.apple.finder"
    private static let overflowErrorNumber = 8001
    private static let source = """
    with timeout of 2 seconds
        tell application "Finder"
            set chosenItems to selection
            if (count of chosenItems) > 128 then error number 8001
            set chosenURLs to {}
            repeat with chosenItem in chosenItems
                set end of chosenURLs to URL of chosenItem
            end repeat
            return chosenURLs
        end tell
    end timeout
    """

    private let maximumItems: Int

    init(maximumItems: Int = 128) {
        self.maximumItems = max(1, maximumItems)
    }

    func preflightPermission() -> Bool {
        permissionState() == .granted
    }

    func permissionState() -> FileSelectionPermissionState {
        switch permission(asking: false) {
        case noErr:
            return .granted
        case OSStatus(errAEEventNotPermitted):
            return .denied
        case OSStatus(errAEEventWouldRequireUserConsent):
            return .undetermined
        default:
            return .unavailable
        }
    }

    @discardableResult
    func requestPermission() -> Bool {
        permission(asking: true) == noErr
    }

    func selection(for source: FileSelectionSource) throws -> RawFileSelection {
        guard source.bundleIdentifier == Self.finderBundleIdentifier else {
            throw FileSelectionFailure.unsupported
        }
        switch permissionState() {
        case .granted:
            break
        case .denied, .undetermined:
            throw FileSelectionFailure.permissionDenied
        case .unavailable:
            throw FileSelectionFailure.providerError
        }
        guard let script = NSAppleScript(source: Self.source) else {
            throw FileSelectionFailure.providerError
        }
        var details: NSDictionary?
        let descriptor = script.executeAndReturnError(&details)
        if let details {
            throw Self.failure(forScriptError: details)
        }
        let urls = try Self.urls(from: descriptor, maximumItems: maximumItems)
        return RawFileSelection(selectedURLs: urls, documentURL: nil)
    }

    static func urls(from descriptor: NSAppleEventDescriptor, maximumItems: Int) throws -> [URL] {
        guard descriptor.descriptorType == typeAEList else {
            throw FileSelectionFailure.providerError
        }
        let count = descriptor.numberOfItems
        guard count <= maximumItems else { throw FileSelectionFailure.tooManyItems }
        guard count > 0 else { return [] }
        var urls: [URL] = []
        for index in 1...count {
            guard let item = descriptor.atIndex(index),
                  item.descriptorType != typeAEList,
                  let value = item.stringValue,
                  value.count <= 4096,
                  let url = URL(string: value),
                  url.scheme?.lowercased() == "file"
            else { throw FileSelectionFailure.invalidURL }
            urls.append(url)
        }
        return urls
    }

    static func failure(forScriptError details: NSDictionary) -> FileSelectionFailure {
        let number = details[NSAppleScript.errorNumber] as? Int ?? 0
        switch number {
        case Int(errAETimeout), Int(errAEWaitCanceled):
            return .timeout
        case Int(errAEEventNotPermitted), Int(errAEEventWouldRequireUserConsent), Int(errAEPrivilegeError):
            return .permissionDenied
        case overflowErrorNumber:
            return .tooManyItems
        default:
            return .providerError
        }
    }

    private func permission(asking: Bool) -> OSStatus {
        let target = NSAppleEventDescriptor(bundleIdentifier: Self.finderBundleIdentifier)
        return withExtendedLifetime(target) {
            guard let descriptor = target.aeDesc else { return OSStatus(paramErr) }
            return AEDeterminePermissionToAutomateTarget(
                descriptor,
                AEEventClass(kCoreEventClass),
                AEEventID(kAEGetData),
                asking
            )
        }
    }
}

final class AXFileSelectionProvider: FileSelectionProviding, FileSelectionPermissionProviding {
    private let maximumSelectedChildren: Int
    private let maximumStringLength: Int
    private let messagingTimeout: Double
    private let totalTimeout: Double

    init(
        maximumSelectedChildren: Int = 128,
        maximumStringLength: Int = 4096,
        messagingTimeout: Double = 1,
        totalTimeout: Double = 2
    ) {
        self.maximumSelectedChildren = max(1, maximumSelectedChildren)
        self.maximumStringLength = max(1, maximumStringLength)
        self.messagingTimeout = max(0.05, messagingTimeout)
        self.totalTimeout = max(self.messagingTimeout, totalTimeout)
    }

    func preflightPermission() -> Bool {
        AXIsProcessTrusted()
    }

    func permissionState() -> FileSelectionPermissionState {
        AXIsProcessTrusted() ? .granted : .denied
    }

    @discardableResult
    func requestPermission() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    func selection(for source: FileSelectionSource) throws -> RawFileSelection {
        guard preflightPermission() else { throw FileSelectionFailure.permissionDenied }
        let deadline = FileSelectionDeadline(seconds: totalTimeout)
        let app = AXUIElementCreateApplication(source.pid)
        var selectedValue: CFTypeRef?
        let selectedStatus = try copyAttribute(
            kAXSelectedChildrenAttribute as CFString,
            element: app,
            deadline: deadline,
            into: &selectedValue
        )
        let selectedElements: [AXUIElement]
        let selectionAvailability: FileSelectionAvailability
        if selectedStatus == .success {
            guard let values = selectedValue as? [AnyObject] else {
                throw FileSelectionFailure.unsupported
            }
            guard values.count <= maximumSelectedChildren else {
                throw FileSelectionFailure.tooManyItems
            }
            selectedElements = try values.map { value in
                guard CFGetTypeID(value) == AXUIElementGetTypeID() else {
                    throw FileSelectionFailure.unsupported
                }
                return unsafeBitCast(value, to: AXUIElement.self)
            }
            selectionAvailability = selectedElements.isEmpty ? .noSelection : .selected
        } else if selectedStatus == .noValue {
            selectedElements = []
            selectionAvailability = .noSelection
        } else {
            selectedElements = []
            selectionAvailability = .unsupported
        }
        var selectedURLs: [URL] = []
        for element in selectedElements {
            guard let url = try fileURLAttribute(
                kAXURLAttribute as CFString,
                element: element,
                deadline: deadline
            ) else {
                throw FileSelectionFailure.unsupported
            }
            selectedURLs.append(url)
        }
        let documentURL = try? fileURLAttribute(
            kAXDocumentAttribute as CFString,
            element: app,
            deadline: deadline
        )
        return RawFileSelection(
            selectedURLs: selectedURLs,
            documentURL: documentURL ?? nil,
            selectionAvailability: selectionAvailability
        )
    }

    private func copyAttribute(
        _ attribute: CFString,
        element: AXUIElement,
        deadline: FileSelectionDeadline,
        into value: inout CFTypeRef?
    ) throws -> AXError {
        let remaining = deadline.remainingSeconds
        guard remaining > 0 else { throw FileSelectionFailure.timeout }
        let timeoutStatus = AXUIElementSetMessagingTimeout(
            element,
            Float(min(messagingTimeout, remaining))
        )
        guard timeoutStatus == .success || timeoutStatus == .invalidUIElement else {
            throw map(timeoutStatus)
        }
        let status = AXUIElementCopyAttributeValue(element, attribute, &value)
        switch status {
        case .success, .noValue, .attributeUnsupported:
            return status
        default:
            throw map(status)
        }
    }

    private func fileURLAttribute(
        _ attribute: CFString,
        element: AXUIElement,
        deadline: FileSelectionDeadline
    ) throws -> URL? {
        var value: CFTypeRef?
        let status = try copyAttribute(attribute, element: element, deadline: deadline, into: &value)
        guard status == .success else { return nil }
        if let url = value as? URL { return url }
        if let string = value as? String {
            guard string.count <= maximumStringLength else { throw FileSelectionFailure.invalidURL }
            return URL(string: string)
        }
        throw FileSelectionFailure.unsupported
    }

    private func map(_ error: AXError) -> FileSelectionFailure {
        switch error {
        case .apiDisabled:
            return .permissionDenied
        case .cannotComplete:
            return .timeout
        case .attributeUnsupported, .actionUnsupported, .notImplemented:
            return .unsupported
        case .noValue:
            return .noSelection
        default:
            return .providerError
        }
    }
}
