import AppKit
import UniformTypeIdentifiers
import os.log

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "geo", category: "AttachmentHandler")

struct AttachmentHandler {
    let blockURL: URL
    private let attachmentService: any AttachmentService

    init(
        blockURL: URL,
        attachmentService: any AttachmentService = FileAttachmentService()
    ) {
        self.blockURL = blockURL
        self.attachmentService = attachmentService
    }

    func handlePaste(from pasteboard: NSPasteboard, in textView: NSTextView) -> Bool {
        let attachmentsDirectory = attachmentsDirectoryURL()
        var snippets: [String] = []
        var didPrepareDirectory = false

        logger.info("handlePaste: blockURL=\(blockURL.path, privacy: .public)")
        logger.info("handlePaste: attachmentsDir=\(attachmentsDirectory.path, privacy: .public)")

        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            logger.info("handlePaste: found \(urls.count) file URLs")
            guard ensureAttachmentsDirectory(
                at: attachmentsDirectory,
                didPrepareDirectory: &didPrepareDirectory
            ) else {
                logger.error("handlePaste: failed to create attachments directory")
                return false
            }
            var successCount = 0
            var failureCount = 0
            for url in urls {
                if let snippet = storeURLAttachment(url, in: attachmentsDirectory) {
                    snippets.append(snippet)
                    successCount += 1
                } else {
                    failureCount += 1
                    logger.error("handlePaste: failed to store dropped URL: \(url.lastPathComponent, privacy: .public)")
                }
            }
            if failureCount > 0 {
                logger.error("handlePaste: \(failureCount, privacy: .public) of \(urls.count, privacy: .public) drops failed")
            }
            _ = successCount
        }

        if snippets.isEmpty {
            if let data = pasteboard.data(forType: .png), !data.isEmpty {
                logger.info("handlePaste: found raw PNG data (\(data.count) bytes)")
                if !isValidPNGData(data) {
                    logger.error("handlePaste: PNG data failed signature/size validation — rejecting")
                    return false
                }
                guard ensureAttachmentsDirectory(
                    at: attachmentsDirectory,
                    didPrepareDirectory: &didPrepareDirectory
                ) else {
                    logger.error("handlePaste: failed to create attachments directory for PNG")
                    return false
                }
                if let destination = attachmentService.saveImageData(data, extension: "png", to: attachmentsDirectory),
                   let snippet = attachmentMarkdown(for: destination, isImage: true) {
                    snippets.append(snippet)
                    logger.info("handlePaste: saved PNG → \(snippet, privacy: .public)")
                }
            }
        }

        if snippets.isEmpty {
            if let data = pasteboard.data(forType: .tiff), !data.isEmpty {
                logger.info("handlePaste: found raw TIFF data (\(data.count) bytes)")
                guard ensureAttachmentsDirectory(
                    at: attachmentsDirectory,
                    didPrepareDirectory: &didPrepareDirectory
                ) else {
                    return false
                }
                let saved = compressAndSave(tiffData: data, to: attachmentsDirectory)
                if let snippet = saved {
                    snippets.append(snippet)
                    logger.info("handlePaste: saved TIFF → \(snippet, privacy: .public)")
                }
            }
        }

        if snippets.isEmpty {
            if let image = NSImage(pasteboard: pasteboard) {
                logger.info("handlePaste: fallback to NSImage (size=\(image.size.width)x\(image.size.height))")
                guard ensureAttachmentsDirectory(
                    at: attachmentsDirectory,
                    didPrepareDirectory: &didPrepareDirectory
                ) else {
                    return false
                }
                if let destination = attachmentService.saveImage(image, to: attachmentsDirectory),
                   let snippet = attachmentMarkdown(for: destination, isImage: true) {
                    snippets.append(snippet)
                    logger.info("handlePaste: saved NSImage → \(snippet, privacy: .public)")
                }
            }
        }

        guard !snippets.isEmpty else {
            logger.error("handlePaste: no image data could be saved")
            return false
        }

        insertAttachmentSnippets(snippets, into: textView)
        logger.info("handlePaste: inserted \(snippets.count) snippets into editor")
        return true
    }

    private func storeURLAttachment(_ url: URL, in directory: URL) -> String? {
        let isImage = isImageFile(url)
        if isImage, let image = NSImage(contentsOf: url), image.isValid, image.size.width > 0 {
            if let destination = attachmentService.saveImage(image, to: directory) {
                return attachmentMarkdown(for: destination, isImage: true)
            }
            return nil
        }
        guard let destination = attachmentService.copyAttachment(from: url, to: directory) else { return nil }
        return attachmentMarkdown(for: destination, isImage: isImage)
    }

    private func compressAndSave(tiffData: Data, to directory: URL) -> String? {
        if let rep = NSBitmapImageRep(data: tiffData),
           let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) {
            if let destination = attachmentService.saveImageData(jpeg, extension: "jpg", to: directory) {
                return attachmentMarkdown(for: destination, isImage: true)
            }
        }
        if let destination = attachmentService.saveImageData(tiffData, extension: "tiff", to: directory) {
            return attachmentMarkdown(for: destination, isImage: true)
        }
        return nil
    }

    private func ensureAttachmentsDirectory(
        at directory: URL,
        didPrepareDirectory: inout Bool
    ) -> Bool {
        guard !didPrepareDirectory else { return true }
        guard attachmentService.ensureDirectory(at: directory) else {
            logger.error("ensureAttachmentsDirectory: service failed to create \(directory.path, privacy: .public)")
            return false
        }
        didPrepareDirectory = true
        return true
    }

    private func attachmentsDirectoryURL() -> URL {
        let blocksDirectory = blockURL.deletingLastPathComponent()
        let blockFolderName = blockURL.deletingPathExtension().lastPathComponent
        return blocksDirectory
            .appendingPathComponent("Attachments", isDirectory: true)
            .appendingPathComponent(blockFolderName, isDirectory: true)
    }

    private func attachmentMarkdown(for url: URL, isImage: Bool) -> String? {
        let blockFolderName = blockURL.deletingPathExtension().lastPathComponent
        let fileName = sanitizeAttachmentFilename(url.lastPathComponent)
        let relativePath = "Attachments/\(blockFolderName)/\(fileName)"
        let encodedPath = relativePath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? relativePath
        let title = fileName
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
            .replacingOccurrences(of: "(", with: "\\(")
            .replacingOccurrences(of: ")", with: "\\)")
        if isImage {
            return "![\(title)](\(encodedPath))"
        }
        return "[\(title)](\(encodedPath))"
    }

    private func insertAttachmentSnippets(_ snippets: [String], into textView: NSTextView) {
        let insertionText = snippets.joined(separator: "\n\n")
        let selection = textView.selectedRange()
        let nsText = textView.string as NSString
        let needsLeadingNewline = selection.location > 0 && nsText.character(at: selection.location - 1) != 10
        let needsTrailingNewline = selection.location < nsText.length && nsText.character(at: selection.location) != 10
        var finalText = insertionText
        if needsLeadingNewline {
            finalText = "\n" + finalText
        }
        if needsTrailingNewline {
            finalText += "\n"
        }
        textView.insertText(finalText, replacementRange: selection)
        textView.didChangeText()
    }

    private func isImageFile(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .image)
    }
}
