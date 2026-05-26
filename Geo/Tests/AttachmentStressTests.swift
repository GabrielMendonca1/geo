import AppKit
import XCTest
@testable import Geo

private final class MockAttachmentService: AttachmentService, @unchecked Sendable {
    var copyAttachmentCalls: [(source: URL, directory: URL)] = []
    var saveImageDataCalls: [(data: Data, ext: String, directory: URL)] = []
    var saveImageCalls: [(image: NSImage, directory: URL)] = []
    var ensureDirectoryCalls: [URL] = []
    var uniqueURLCalls: [(fileName: String, directory: URL)] = []

    var copyAttachmentResult: (URL, URL) -> URL? = { _, dir in dir.appendingPathComponent("mock-copy.bin") }
    var saveImageDataResult: (Data, String, URL) -> URL? = { _, ext, dir in
        dir.appendingPathComponent("mock-image.\(ext)")
    }
    var saveImageResult: (NSImage, URL) -> URL? = { _, dir in
        dir.appendingPathComponent("mock-nsimage.png")
    }
    var ensureDirectoryResult: Bool = true

    private let lock = NSLock()

    func ensureDirectory(at directory: URL) -> Bool {
        lock.lock(); defer { lock.unlock() }
        ensureDirectoryCalls.append(directory)
        return ensureDirectoryResult
    }

    func copyAttachment(from source: URL, to directory: URL) -> URL? {
        lock.lock(); defer { lock.unlock() }
        copyAttachmentCalls.append((source, directory))
        return copyAttachmentResult(source, directory)
    }

    func saveImage(_ image: NSImage, to directory: URL) -> URL? {
        lock.lock(); defer { lock.unlock() }
        saveImageCalls.append((image, directory))
        return saveImageResult(image, directory)
    }

    func saveImageData(_ data: Data, extension ext: String, to directory: URL) -> URL? {
        lock.lock(); defer { lock.unlock() }
        saveImageDataCalls.append((data, ext, directory))
        return saveImageDataResult(data, ext, directory)
    }

    func uniqueURL(for fileName: String, in directory: URL) -> URL {
        lock.lock(); defer { lock.unlock() }
        uniqueURLCalls.append((fileName, directory))
        return directory.appendingPathComponent(fileName)
    }

    func deleteAttachmentsDirectory(for blockURL: URL) {}
    func deleteAttachment(relativePath: String, baseDirectory: URL) {}
}

private func makeTempBlockURL() -> URL {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("attachment-tests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("MyBlock.md")
}

private func makeTextView(_ initial: String = "", at location: Int? = nil) -> NSTextView {
    let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
    tv.string = initial
    let loc = location ?? (initial as NSString).length
    tv.setSelectedRange(NSRange(location: loc, length: 0))
    return tv
}

private func pasteboardWithFileURLs(_ urls: [URL]) -> NSPasteboard {
    let pb = NSPasteboard(name: NSPasteboard.Name("AttachmentStressTests-\(UUID().uuidString)"))
    pb.clearContents()
    pb.writeObjects(urls as [NSURL])
    return pb
}

private func pasteboardWithPNGData(_ data: Data) -> NSPasteboard {
    let pb = NSPasteboard(name: NSPasteboard.Name("AttachmentStressTests-\(UUID().uuidString)"))
    pb.clearContents()
    pb.setData(data, forType: .png)
    return pb
}

private func writeTinyPNG(to url: URL) throws {
    let image = NSImage(size: NSSize(width: 8, height: 8))
    image.lockFocus()
    NSColor.red.setFill()
    NSRect(x: 0, y: 0, width: 8, height: 8).fill()
    image.unlockFocus()
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "test", code: 0)
    }
    try png.write(to: url)
}

final class AttachmentStressTests: XCTestCase {

    // MARK: 1. Path-traversal / sanitization — disk and markdown both safe

    func testCopiedFileNameVsMarkdownNameSanitizedConsistently() throws {
        let blocksDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("path-traversal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: blocksDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: blocksDir) }

        let sourceDir = blocksDir.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        let evilSource = sourceDir.appendingPathComponent("..hack.png")
        try Data([0x89, 0x50]).write(to: evilSource)

        let attachmentsDir = blocksDir.appendingPathComponent("Attachments", isDirectory: true)
        try FileManager.default.createDirectory(at: attachmentsDir, withIntermediateDirectories: true)

        let service = FileAttachmentService()
        guard let destination = service.copyAttachment(from: evilSource, to: attachmentsDir) else {
            return XCTFail("copyAttachment must succeed for a valid source file")
        }

        XCTAssertFalse(destination.lastPathComponent.contains(".."),
                       "On-disk filename must not contain `..` — got \(destination.lastPathComponent)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path),
                      "Sanitized file must exist on disk")

        let expectedSanitized = sanitizeAttachmentFilename("..hack.png")
        XCTAssertEqual(destination.lastPathComponent, expectedSanitized,
                       "Disk name must equal the canonical sanitized name (used by markdown too)")
    }

    // MARK: 2. sanitizeFilename dot-run handling

    func testSanitizeFilenameDotRunsStripped() throws {
        let mock = MockAttachmentService()
        let blockURL = makeTempBlockURL()

        mock.copyAttachmentResult = { src, dir in dir.appendingPathComponent(src.lastPathComponent) }

        let inputs = ["....png", "...hack.png", "a..b..c.png", ".."]
        for name in inputs {
            let src = URL(fileURLWithPath: "/tmp/\(name)")
            let tv = makeTextView()
            let pb = pasteboardWithFileURLs([src])
            let handler = AttachmentHandler(blockURL: blockURL, attachmentService: mock)
            _ = handler.handlePaste(from: pb, in: tv)
            XCTAssertFalse(
                tv.string.contains(".."),
                "Sanitizer must strip `..` for input '\(name)'. Got: \(tv.string)"
            )
        }

        let weird = URL(fileURLWithPath: "/tmp/....png")
        let tv = makeTextView()
        let pb = pasteboardWithFileURLs([weird])
        let handler = AttachmentHandler(blockURL: blockURL, attachmentService: mock)
        _ = handler.handlePaste(from: pb, in: tv)
        XCTAssertTrue(
            tv.string.contains(".png"),
            "Extension must be preserved when collapsing dot-runs. Inserted: \(tv.string)"
        )
    }

    // MARK: 3. Control character / RTL override stripped

    func testSanitizeFilenameStripsControlCharacters() throws {
        let blockURL = makeTempBlockURL()
        let mock = MockAttachmentService()
        mock.copyAttachmentResult = { src, dir in dir.appendingPathComponent(src.lastPathComponent) }

        let rtl = "evil\u{202E}gnp.exe"
        let src = URL(fileURLWithPath: "/tmp/\(rtl)")
        let pb = pasteboardWithFileURLs([src])
        let tv = makeTextView()
        let handler = AttachmentHandler(blockURL: blockURL, attachmentService: mock)
        _ = handler.handlePaste(from: pb, in: tv)

        XCTAssertFalse(
            tv.string.contains("\u{202E}"),
            "RTL override must be stripped. Inserted: \(tv.string)"
        )
        for scalar in tv.string.unicodeScalars {
            XCTAssertFalse((0x202A...0x202E).contains(scalar.value),
                           "BiDi override leaked: \(String(format: "U+%04X", scalar.value))")
            XCTAssertFalse((0x2066...0x2069).contains(scalar.value),
                           "BiDi isolate leaked: \(String(format: "U+%04X", scalar.value))")
        }
    }

    // MARK: 4. uniqueURL concurrent calls all get distinct paths

    func testUniqueURLDistinctUnderConcurrentRequests() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("uniqueurl-race-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let service = FileAttachmentService()
        let target = "image-collision.png"

        let queue = DispatchQueue(label: "race", attributes: .concurrent)
        let group = DispatchGroup()
        var results: [URL] = []
        let lock = NSLock()

        for _ in 0..<32 {
            group.enter()
            queue.async {
                let u = service.uniqueURL(for: target, in: tmp)
                lock.lock(); results.append(u); lock.unlock()
                group.leave()
            }
        }
        group.wait()

        let uniqueSet = Set(results.map(\.path))
        XCTAssertEqual(
            uniqueSet.count, 32,
            "Concurrent uniqueURL callers must each receive a distinct path via O_EXCL reservation. Set: \(uniqueSet)"
        )
    }

    // MARK: 5. File URL drops for images route through saveImage (cap applies)

    func testFileURLDropForImageUsesSaveImage() throws {
        let blockURL = makeTempBlockURL()
        let tempDir = blockURL.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let imageURL = tempDir.appendingPathComponent("real-photo.png")
        try writeTinyPNG(to: imageURL)

        let mock = MockAttachmentService()
        mock.saveImageResult = { _, dir in dir.appendingPathComponent("real-photo.png") }
        mock.copyAttachmentResult = { _, _ in XCTFail("copy should not be used for image drops"); return nil }

        let pb = pasteboardWithFileURLs([imageURL])
        let tv = makeTextView()
        let handler = AttachmentHandler(blockURL: blockURL, attachmentService: mock)
        _ = handler.handlePaste(from: pb, in: tv)

        XCTAssertEqual(mock.saveImageCalls.count, 1, "Image file drops must route through saveImage so the 1920px cap applies")
        XCTAssertTrue(mock.copyAttachmentCalls.isEmpty, "Image URL must not use raw copy path")
    }

    // MARK: 5b. Non-image URL drops still use copy

    func testFileURLDropForNonImageUsesCopy() throws {
        let blockURL = makeTempBlockURL()
        defer { try? FileManager.default.removeItem(at: blockURL.deletingLastPathComponent()) }

        let mock = MockAttachmentService()
        mock.copyAttachmentResult = { src, dir in dir.appendingPathComponent(src.lastPathComponent) }

        let pb = pasteboardWithFileURLs([URL(fileURLWithPath: "/tmp/doc.pdf")])
        let tv = makeTextView()
        let handler = AttachmentHandler(blockURL: blockURL, attachmentService: mock)
        _ = handler.handlePaste(from: pb, in: tv)

        XCTAssertEqual(mock.copyAttachmentCalls.count, 1)
        XCTAssertTrue(mock.saveImageCalls.isEmpty)
    }

    // MARK: 6. Multiple snippet join uses double newline (paragraph separators)

    func testMultipleSnippetsJoinUsesDoubleNewline() throws {
        let blockURL = makeTempBlockURL()
        let mock = MockAttachmentService()
        mock.copyAttachmentResult = { src, dir in dir.appendingPathComponent(src.lastPathComponent) }

        let pb = pasteboardWithFileURLs([
            URL(fileURLWithPath: "/tmp/a.pdf"),
            URL(fileURLWithPath: "/tmp/b.pdf"),
            URL(fileURLWithPath: "/tmp/c.pdf")
        ])
        let tv = makeTextView()
        let handler = AttachmentHandler(blockURL: blockURL, attachmentService: mock)
        _ = handler.handlePaste(from: pb, in: tv)

        let body = tv.string
        XCTAssertTrue(body.contains("\n\n"),
                      "Snippets must be separated by `\\n\\n` so each forms its own paragraph. Body: \(body)")

        let paragraphs = body
            .trimmingCharacters(in: .newlines)
            .components(separatedBy: "\n\n")
            .filter { !$0.isEmpty }
        XCTAssertEqual(paragraphs.count, 3, "Three drops must produce three paragraph snippets. Body: \(body)")
    }

    // MARK: 7. Trailing whitespace sanitized consistently

    func testTrailingWhitespaceFilenameSanitized() throws {
        let blockURL = makeTempBlockURL()
        let mock = MockAttachmentService()

        let src = URL(fileURLWithPath: "/tmp/photo.pdf ")
        mock.copyAttachmentResult = { src, dir in dir.appendingPathComponent(src.lastPathComponent) }

        let pb = pasteboardWithFileURLs([src])
        let tv = makeTextView()
        let handler = AttachmentHandler(blockURL: blockURL, attachmentService: mock)
        _ = handler.handlePaste(from: pb, in: tv)

        XCTAssertTrue(tv.string.contains("photo.pdf"),
                      "Markdown must reference the trimmed name. Inserted: \(tv.string)")
        XCTAssertFalse(tv.string.contains("photo.pdf )"),
                       "Markdown must not contain a trailing space inside the link text. Inserted: \(tv.string)")
    }

    // MARK: 8. attachmentMarkdown title escapes parens

    func testAttachmentMarkdownTitleParensEscaped() throws {
        let blockURL = makeTempBlockURL()
        let mock = MockAttachmentService()
        let src = URL(fileURLWithPath: "/tmp/foo(bar).pdf")
        mock.copyAttachmentResult = { src, dir in dir.appendingPathComponent(src.lastPathComponent) }

        let pb = pasteboardWithFileURLs([src])
        let tv = makeTextView()
        let handler = AttachmentHandler(blockURL: blockURL, attachmentService: mock)
        _ = handler.handlePaste(from: pb, in: tv)

        XCTAssertTrue(tv.string.contains("\\("),
                      "Parens in alt text must be escaped. Inserted: \(tv.string)")
        XCTAssertTrue(tv.string.contains("\\)"),
                      "Parens in alt text must be escaped. Inserted: \(tv.string)")
    }

    // MARK: 9. Compound extension collision suffix is stable

    func testCompoundExtensionCollisionStable() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("compound-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let service = FileAttachmentService()
        let original = tmp.appendingPathComponent("foo.tar.gz")
        try Data([0x1F, 0x8B]).write(to: original)

        let next = service.uniqueURL(for: "foo.tar.gz", in: tmp)
        XCTAssertEqual(next.pathExtension, "gz",
                       "Final extension preserved after collision rename: \(next.lastPathComponent)")
        XCTAssertTrue(next.lastPathComponent.hasPrefix("foo.tar-"),
                      "Collision suffix lands between stem and final extension: \(next.lastPathComponent)")
        XCTAssertNotEqual(next.lastPathComponent, "foo.tar.gz",
                          "Must not collide with the existing file")
    }

    // MARK: 10. Empty filename fallback has extension

    func testEmptyFilenameFallbackHasExtension() throws {
        XCTAssertEqual(sanitizeAttachmentFilename(""), "attachment.bin",
                       "Empty input must fall back to attachment.bin")
        XCTAssertEqual(sanitizeAttachmentFilename("   "), "attachment.bin",
                       "Whitespace-only input must fall back to attachment.bin")
        XCTAssertEqual(sanitizeAttachmentFilename(".."), "attachment.bin",
                       "Bare `..` input must fall back to attachment.bin")
    }

    // MARK: 11. Partial-failure drop returns true when some succeed

    func testPartialFailureDropReturnsTrueWhenSomeSucceed() throws {
        let blockURL = makeTempBlockURL()
        let mock = MockAttachmentService()
        var callCount = 0
        mock.copyAttachmentResult = { src, dir in
            callCount += 1
            if callCount == 2 { return nil }
            return dir.appendingPathComponent(src.lastPathComponent)
        }

        let pb = pasteboardWithFileURLs([
            URL(fileURLWithPath: "/tmp/a.pdf"),
            URL(fileURLWithPath: "/tmp/b.pdf"),
            URL(fileURLWithPath: "/tmp/c.pdf")
        ])
        let tv = makeTextView()
        let handler = AttachmentHandler(blockURL: blockURL, attachmentService: mock)
        let ok = handler.handlePaste(from: pb, in: tv)

        XCTAssertTrue(ok, "Returns true when at least one snippet was inserted")
        XCTAssertTrue(tv.string.contains("a.pdf"))
        XCTAssertFalse(tv.string.contains("b.pdf"), "Failed copy is logged but not inserted")
        XCTAssertTrue(tv.string.contains("c.pdf"))
    }

    // MARK: 11b. All-failed drop returns false

    func testAllFailedDropReturnsFalse() throws {
        let blockURL = makeTempBlockURL()
        let mock = MockAttachmentService()
        mock.copyAttachmentResult = { _, _ in nil }

        let pb = pasteboardWithFileURLs([
            URL(fileURLWithPath: "/tmp/a.pdf"),
            URL(fileURLWithPath: "/tmp/b.pdf")
        ])
        let tv = makeTextView()
        let handler = AttachmentHandler(blockURL: blockURL, attachmentService: mock)
        let ok = handler.handlePaste(from: pb, in: tv)

        XCTAssertFalse(ok, "Returns false when every copy failed")
        XCTAssertTrue(tv.string.isEmpty)
    }

    // MARK: 12. insertSnippet at position 0 in empty buffer skips leading newline

    func testInsertSnippetAtPositionZeroNoLeadingNewline() throws {
        let blockURL = makeTempBlockURL()
        let mock = MockAttachmentService()
        mock.copyAttachmentResult = { src, dir in dir.appendingPathComponent(src.lastPathComponent) }

        let pb = pasteboardWithFileURLs([URL(fileURLWithPath: "/tmp/x.pdf")])
        let tv = makeTextView("", at: 0)
        let handler = AttachmentHandler(blockURL: blockURL, attachmentService: mock)
        _ = handler.handlePaste(from: pb, in: tv)

        XCTAssertFalse(tv.string.hasPrefix("\n"),
                       "At position 0 in an empty buffer the inserted markdown must NOT start with a newline. Got: \(tv.string.debugDescription)")
    }

    // MARK: 13. Long filename truncated before copy

    func testVeryLongFilenameTruncated() throws {
        let longBase = String(repeating: "a", count: 300)
        let raw = "\(longBase).pdf"
        let sanitized = sanitizeAttachmentFilename(raw)

        XCTAssertLessThanOrEqual(sanitized.utf8.count, 255,
                                 "Sanitized filename must fit within filesystem limits: \(sanitized.count) bytes")
        XCTAssertTrue(sanitized.hasSuffix(".pdf"),
                      "Extension must be preserved after truncation: \(sanitized)")
    }

    // MARK: 14. Truncated PNG rejected

    func testTruncatedPNGRejected() throws {
        let blockURL = makeTempBlockURL()
        let mock = MockAttachmentService()
        let truncated = Data([0x89, 0x50, 0x4E])

        mock.saveImageDataResult = { _, _, _ in
            XCTFail("Truncated PNG must not be saved")
            return nil
        }

        let pb = pasteboardWithPNGData(truncated)
        let tv = makeTextView()
        let handler = AttachmentHandler(blockURL: blockURL, attachmentService: mock)
        let ok = handler.handlePaste(from: pb, in: tv)

        XCTAssertFalse(ok, "Handler must reject invalid PNG data")
        XCTAssertTrue(tv.string.isEmpty, "Nothing inserted for invalid PNG")
        XCTAssertTrue(mock.saveImageDataCalls.isEmpty)
    }

    // MARK: 14b. Valid PNG accepted

    func testValidPNGAccepted() throws {
        let blockURL = makeTempBlockURL()
        let mock = MockAttachmentService()
        let signature = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let body = Data(repeating: 0, count: 32)
        let valid = signature + body

        var saved: Data?
        mock.saveImageDataResult = { data, ext, dir in
            saved = data
            return dir.appendingPathComponent("image.\(ext)")
        }

        let pb = pasteboardWithPNGData(valid)
        let tv = makeTextView()
        let handler = AttachmentHandler(blockURL: blockURL, attachmentService: mock)
        let ok = handler.handlePaste(from: pb, in: tv)

        XCTAssertTrue(ok)
        XCTAssertEqual(saved, valid)
    }

    // MARK: 15. ensureDirectory failure aborts paste cleanly

    func testEnsureDirectoryFailureAbortsPaste() throws {
        let blockURL = makeTempBlockURL()
        let mock = MockAttachmentService()
        mock.ensureDirectoryResult = false
        mock.copyAttachmentResult = { _, _ in XCTFail("copy should not be attempted"); return nil }

        let pb = pasteboardWithFileURLs([URL(fileURLWithPath: "/tmp/a.pdf")])
        let tv = makeTextView()
        let handler = AttachmentHandler(blockURL: blockURL, attachmentService: mock)
        let ok = handler.handlePaste(from: pb, in: tv)

        XCTAssertFalse(ok)
        XCTAssertTrue(tv.string.isEmpty)
        XCTAssertTrue(mock.copyAttachmentCalls.isEmpty)
    }

    func testSaveImage_CMYKSourceProducesValidFile() throws {
        let width = 8
        let height = 8
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 200, count: bytesPerRow * height)
        for i in stride(from: 0, to: pixels.count, by: 4) {
            pixels[i] = 0
            pixels[i + 1] = 200
            pixels[i + 2] = 200
            pixels[i + 3] = 0
        }
        let cs = CGColorSpaceCreateDeviceCMYK()
        let ctx = pixels.withUnsafeMutableBufferPointer { buf -> CGContext? in
            CGContext(
                data: buf.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: cs,
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            )
        }
        guard let cg = ctx?.makeImage() else {
            XCTFail("could not build CMYK CGImage")
            return
        }
        let nsimg = NSImage(cgImage: cg, size: NSSize(width: width, height: height))

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("geo-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let service = FileAttachmentService()
        let saved = service.saveImage(nsimg, to: tempDir)

        XCTAssertNotNil(saved, "saveImage must succeed for CMYK source")
        guard let saved else { return }
        let data = try Data(contentsOf: saved)
        XCTAssertGreaterThan(data.count, 0)
        let isJPEG = data.starts(with: [0xFF, 0xD8, 0xFF])
        let isPNG = data.starts(with: [0x89, 0x50, 0x4E, 0x47])
        XCTAssertTrue(isJPEG || isPNG, "saved file must be JPEG or PNG")
    }

    func testAttachmentHandler_usesLiveBlockUrl_notStaleCapture() throws {
        let parent = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rename-mid-paste-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }

        let oldURL = parent.appendingPathComponent("OldName.md")
        let newURL = parent.appendingPathComponent("NewName.md")

        let mock = MockAttachmentService()
        mock.copyAttachmentResult = { src, dir in dir.appendingPathComponent(src.lastPathComponent) }

        let pb = pasteboardWithFileURLs([URL(fileURLWithPath: "/tmp/note.pdf")])
        let tv = makeTextView()
        let handler = AttachmentHandler(blockURL: newURL, attachmentService: mock)
        let ok = handler.handlePaste(from: pb, in: tv)

        XCTAssertTrue(ok)
        XCTAssertEqual(mock.copyAttachmentCalls.count, 1)
        let targetDir = mock.copyAttachmentCalls[0].directory
        XCTAssertEqual(
            targetDir.path,
            parent.appendingPathComponent("Attachments").appendingPathComponent("NewName").path,
            "Attachment must save under the live (renamed) block's Attachments folder, not the stale capture"
        )
        XCTAssertFalse(
            targetDir.path.contains("/Attachments/OldName"),
            "Must not save under the old block folder after rename. Got: \(targetDir.path)"
        )

        XCTAssertTrue(tv.string.contains("Attachments/NewName/note.pdf"),
                      "Markdown link must reference renamed folder. Inserted: \(tv.string)")
        XCTAssertFalse(tv.string.contains("Attachments/OldName"),
                       "Markdown must not reference old folder. Inserted: \(tv.string)")

        _ = oldURL
    }
}
