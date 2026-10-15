import AppKit

final class FilesServices: NSObject {
    private let invoke: ([URL], FilesWheelMode) -> Void

    init(invoke: @escaping ([URL], FilesWheelMode) -> Void) {
        self.invoke = invoke
    }

    convenience init(files: FilesController) {
        self.init { [weak files] urls, mode in files?.invokeFiles(urls, mode: mode) }
    }

    static func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
        let objects = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) ?? []
        return objects.compactMap { $0 as? URL }
    }

    @objc func convertFiles(
        _ pasteboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        deliver(pasteboard, mode: .convert, error: error)
    }

    @objc func fileTools(
        _ pasteboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        deliver(pasteboard, mode: .tools, error: error)
    }

    private func deliver(
        _ pasteboard: NSPasteboard,
        mode: FilesWheelMode,
        error: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        let urls = Self.fileURLs(from: pasteboard)
        guard !urls.isEmpty else {
            error.pointee = "Nenhum arquivo recebido do Finder." as NSString
            return
        }
        let invoke = self.invoke
        DispatchQueue.main.async { invoke(urls, mode) }
    }
}
