import Foundation
import AppKit
import PDFKit
import Vision
import ImageIO
import CoreText
import Darwin

public final class FileToolsBackend: @unchecked Sendable {
    private let ffmpegURL: URL?
    private let fm = FileManager.default

    public init(ffmpegURL: URL? = nil) {
        self.ffmpegURL = ffmpegURL ?? Self.findExecutable("ffmpeg", extras: ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"])
    }

    public func capabilities(for inputURL: URL) -> FileToolsCapabilities {
        let rar: [FileToolsFormat] = Self.findExecutable("rar", extras: ["/opt/homebrew/bin/rar", "/usr/local/bin/rar"]) == nil ? [] : [.rar]
        if (try? inputURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            return .init(operations: [.convert], conversionTargets: [.tar] + rar)
        }
        let package: [FileToolsFormat] = [.tar, .gzip, .zip] + rar
        switch category(inputURL) {
        case .image:
            let docx: [FileToolsFormat] = Self.findExecutable("zip", extras: ["/usr/bin/zip"]) == nil ? [] : [.docx]
            let animation: [FileToolsFormat] = inputURL.pathExtension.lowercased() == "gif" ? [.mp4, .mov, .mkv] : []
            return .init(operations: [.convert, .compress, .removeMetadata, .crop, .scanQRCode, .collage, .merge], conversionTargets: [.png, .jpg, .webp, .heic, .tiff, .pdf] + docx + animation + package)
        case .svg:
            return .init(operations: [], conversionTargets: [])
        case .video:
            return .init(operations: [.convert, .compress, .removeMetadata, .mute, .trim, .crop, .speed, .snapshot, .split, .merge], conversionTargets: [.mp4, .mov, .mkv, .gif, .mp3, .m4a] + package)
        case .audio:
            return .init(operations: [.convert, .compress, .removeMetadata, .normalize, .trim, .channels, .split, .merge], conversionTargets: [.wav, .flac, .m4a, .mp3, .mp4] + package)
        case .pdf:
            var operations: [FileToolsOperationKind] = [.convert, .removeMetadata, .split, .scanQRCode, .merge]
            if Self.findExecutable("gs", extras: ["/opt/homebrew/bin/gs", "/usr/local/bin/gs"]) != nil { operations.insert(.compress, at: 1) }
            var targets: [FileToolsFormat] = [.txt, .png, .jpg]
            if Self.findExecutable("pdftotext", extras: ["/opt/homebrew/bin/pdftotext", "/usr/local/bin/pdftotext"]) != nil,
               Self.findExecutable("zip", extras: ["/usr/bin/zip"]) != nil { targets.append(.docx) }
            return .init(operations: operations, conversionTargets: targets + package)
        case .text:
            return .init(operations: [.convert], conversionTargets: [.pdf, .png, .jpg] + package)
        case .archive:
            return .init(operations: [.convert, .extract], conversionTargets: package)
        case .office:
            let office = Self.officeExecutable() == nil ? [] : Self.officeTargets(inputURL.pathExtension)
            return .init(operations: [.convert], conversionTargets: office + package)
        case .other:
            return .init(operations: [.convert], conversionTargets: package)
        }
    }

    public func supportedOperations(for inputURL: URL) -> [FileToolsOperationKind] {
        capabilities(for: inputURL).operations
    }

    public func batchCapabilities(for urls: [URL]) -> FileToolsBatchCapabilities {
        guard urls.count >= 2 else { return .init(operations: []) }
        let categories = urls.map(category)
        if categories.allSatisfy({ $0 == .image }) { return .init(operations: [.merge, .collage]) }
        if categories.allSatisfy({ $0 == .image || $0 == .pdf }) || categories.allSatisfy({ $0 == .video }) || categories.allSatisfy({ $0 == .audio }) {
            return .init(operations: [.merge])
        }
        return .init(operations: [])
    }

    public func perform(_ request: FileToolsBatchRequest) async throws -> FileToolsResult {
        let operation: FileToolsOperation
        switch request.operation {
        case .merge:
            let categories = request.inputURLs.map(category)
            if categories.allSatisfy({ $0 == .image || $0 == .pdf }) { operation = .merge(to: .pdf) }
            else if categories.allSatisfy({ $0 == .video }) { operation = .merge(to: .mp4) }
            else if categories.allSatisfy({ $0 == .audio }) { operation = .merge(to: .m4a) }
            else { throw FileToolsError.unsupported("conjunto incompatível para merge") }
        case .collage(let layout, let columns, let spacing, let background):
            guard columns >= 1, spacing >= 0 else { throw FileToolsError.invalidRequest("ajustes de collage inválidos") }
            operation = .collage(options: .init(layout: layout, columns: columns, spacing: spacing, backgroundHex: background), format: .png)
        }
        return try await perform(.init(
            inputURLs: request.inputURLs, operation: operation, outputDirectory: request.outputDirectory,
            timeout: request.timeout, maximumOutputBytes: request.maximumOutputBytes,
            maximumInputBytes: request.maximumInputBytes, maximumInputCount: request.maximumInputCount,
            maximumPages: request.maximumPages, maximumImagePixels: request.maximumImagePixels
        ))
    }

    public func perform(_ request: FileToolsRequest) async throws -> FileToolsResult {
        guard request.timeout.isFinite, request.timeout > 0 else {
            throw FileToolsError.invalidRequest("timeout deve ser positivo e finito")
        }
        let cancellation = FileToolsCancellation(timeout: request.timeout)
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) { [self] in
                try performSync(request, cancellation: cancellation)
            }.value
        } onCancel: {
            cancellation.cancel()
        }
    }

    private func performSync(_ request: FileToolsRequest, cancellation: FileToolsCancellation) throws -> FileToolsResult {
        guard !request.inputURLs.isEmpty, request.inputURLs.count <= request.maximumInputCount else {
            throw FileToolsError.invalidRequest("quantidade de entradas fora do limite")
        }
        guard request.inputURLs.allSatisfy({ $0.isFileURL && $0.path.hasPrefix("/") }) else { throw FileToolsError.invalidRequest("somente URLs absolutas de arquivo são aceitas") }
        guard request.timeout.isFinite, request.timeout > 0, request.maximumOutputBytes > 0,
              request.maximumInputBytes > 0, request.maximumInputCount > 0, request.maximumPages > 0,
              request.maximumImagePixels > 0, request.maximumArchiveMembers > 0, request.maximumArchiveDepth > 0,
              request.maximumArchivePathBytes > 0 else { throw FileToolsError.invalidRequest("limites devem ser positivos") }
        try cancellation.checkpoint()
        var totalInputBytes: Int64 = 0
        for input in request.inputURLs {
            var info = stat()
            guard lstat(input.path, &info) == 0 else { throw FileToolsError.invalidRequest("arquivo de entrada inexistente") }
            if info.st_mode & S_IFMT == S_IFREG {
                totalInputBytes = try addingBudget(totalInputBytes, info.st_size, maximum: request.maximumInputBytes)
            } else if !isExtraction(request.operation) && (request.inputURLs.count > 1 || !isArchiveCreation(request.operation) || info.st_mode & S_IFMT != S_IFDIR) {
                throw FileToolsError.invalidRequest("entrada deve ser arquivo regular")
            }
        }
        if request.inputURLs.count > 1 {
            switch request.operation {
            case .collage, .merge: break
            default: throw FileToolsError.invalidRequest("operação aceita somente uma entrada")
            }
        }
        let destination = request.outputDirectory ?? request.inputURL.deletingLastPathComponent()
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        let workspaceRoot = fm.temporaryDirectory.appendingPathComponent("garime-filetools-\(UUID().uuidString)", isDirectory: true)
        let workspace = workspaceRoot.appendingPathComponent("output", isDirectory: true)
        let inputWorkspace = workspaceRoot.appendingPathComponent("inputs", isDirectory: true)
        try fm.createDirectory(at: workspace, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.createDirectory(at: inputWorkspace, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: workspaceRoot.path)
        defer { try? fm.removeItem(at: workspaceRoot) }

        var effectiveInputs = request.inputURLs
        if request.inputURLs.count > 1 {
            let snapshots = inputWorkspace.appendingPathComponent("input-snapshots", isDirectory: true)
            try fm.createDirectory(at: snapshots, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            effectiveInputs = []
            var snapshotBytes: Int64 = 0
            for (index, input) in request.inputURLs.enumerated() {
                try cancellation.checkpoint()
                let name = String(format: "%04d.%@", index, mediaExtension(input))
                let snapshot = snapshots.appendingPathComponent(name)
                try copyRegularFile(from: input, to: snapshot, maximumBytes: request.maximumInputBytes - snapshotBytes, cancellation: cancellation)
                let size = try snapshot.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                snapshotBytes = try addingBudget(snapshotBytes, Int64(size), maximum: request.maximumInputBytes)
                effectiveInputs.append(snapshot)
            }
        }

        let generated: [URL]
        var message: String?
        switch request.operation {
        case .convert(let format):
            let inputCategory = category(request.inputURL)
            generated = try convert(request.inputURL, category: inputCategory, to: format, workspace: workspace, request: request, cancellation: cancellation)
            if format == .docx {
                message = inputCategory == .pdf
                    ? "DOCX contém texto extraído por página; layout, imagens, tabelas e estilos do PDF não são preservados."
                    : "DOCX contém a imagem real incorporada, renderizada como PNG compatível e ajustada à página sem deformação; não há OCR nem texto editável."
            }
        case .compress(let quality):
            generated = try compress(request.inputURL, category: category(request.inputURL), quality: quality, workspace: workspace, request: request, cancellation: cancellation)
            if category(request.inputURL) == .pdf,
               let output = generated.first,
               let inputSize = try? request.inputURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
               let outputSize = try? output.resourceValues(forKeys: [.fileSizeKey]).fileSize,
               outputSize >= inputSize {
                try fm.removeItem(at: output)
                try copyRegularFile(from: request.inputURL, to: output, maximumBytes: request.maximumOutputBytes, cancellation: cancellation)
                message = "A recompressão PDF não reduziria o arquivo; o original foi preservado sem aumento silencioso."
            }
        case .removeMetadata: generated = try removeMetadata(request.inputURL, category: category(request.inputURL), workspace: workspace, request: request, cancellation: cancellation)
        case .crop(let x, let y, let width, let height):
            guard x >= 0, y >= 0, width > 0, height > 0 else { throw FileToolsError.invalidRequest("recorte inválido") }
            generated = [try ffmpeg(request.inputURL, output: workspace.appendingPathComponent("cropped.\(mediaExtension(request.inputURL))"), arguments: ["-vf", "crop=\(width):\(height):\(x):\(y)", "-c:a", "copy"], request: request, cancellation: cancellation)]
        case .scanQRCode:
            let values = try scanQRCodes(request.inputURL, maximumPages: request.maximumPages, cancellation: cancellation)
            generated = []
            message = values.joined(separator: "\n")
        case .mute:
            guard category(request.inputURL) == .video else { throw FileToolsError.unsupported("mute exige vídeo") }
            generated = [try ffmpeg(request.inputURL, output: workspace.appendingPathComponent("muted.\(mediaExtension(request.inputURL))"), arguments: ["-an", "-c:v", "copy"], request: request, cancellation: cancellation)]
        case .trim(let start, let duration):
            guard start.isFinite, duration.isFinite, start >= 0, duration > 0 else { throw FileToolsError.invalidRequest("intervalo deve ser finito e válido") }
            guard [.video, .audio].contains(category(request.inputURL)) else { throw FileToolsError.unsupported("trim exige áudio ou vídeo") }
            generated = [try ffmpeg(request.inputURL, output: workspace.appendingPathComponent("trimmed.\(mediaExtension(request.inputURL))"), arguments: ["-ss", String(start), "-t", String(duration)], request: request, cancellation: cancellation)]
        case .speed(let speed):
            guard speed.isFinite, category(request.inputURL) == .video, speed >= 0.25, speed <= 4 else { throw FileToolsError.invalidRequest("velocidade deve ser finita e estar entre 0.25 e 4") }
            let atempo = Self.atempoFilter(speed)
            let audio = try hasAudioStream(request.inputURL, request: request, cancellation: cancellation)
            let arguments = audio
                ? ["-filter_complex", "[0:v]setpts=PTS/\(speed)[v];[0:a]\(atempo)[a]", "-map", "[v]", "-map", "[a]", "-movflags", "+faststart"]
                : ["-vf", "setpts=PTS/\(speed)", "-an", "-movflags", "+faststart"]
            generated = [try ffmpeg(request.inputURL, output: workspace.appendingPathComponent("speed.mp4"), arguments: arguments, request: request, cancellation: cancellation)]
        case .snapshot(let time):
            guard time.isFinite, category(request.inputURL) == .video, time >= 0 else { throw FileToolsError.invalidRequest("snapshot exige vídeo e tempo finito não negativo") }
            generated = [try ffmpeg(request.inputURL, output: workspace.appendingPathComponent("snapshot.png"), arguments: ["-ss", String(time), "-frames:v", "1"], request: request, cancellation: cancellation)]
        case .split(let duration):
            guard duration.isFinite, duration > 0 else { throw FileToolsError.invalidRequest("duração deve ser positiva e finita") }
            generated = try split(request.inputURL, category: category(request.inputURL), duration: duration, workspace: workspace, request: request, cancellation: cancellation)
        case .normalize:
            guard category(request.inputURL) == .audio else { throw FileToolsError.unsupported("normalização exige áudio") }
            generated = [try ffmpeg(request.inputURL, output: workspace.appendingPathComponent("normalized.\(mediaExtension(request.inputURL))"), arguments: ["-af", "loudnorm"], request: request, cancellation: cancellation)]
        case .channels(let channels):
            guard category(request.inputURL) == .audio, channels == 1 || channels == 2 else { throw FileToolsError.invalidRequest("canais devem ser 1 ou 2") }
            generated = [try ffmpeg(request.inputURL, output: workspace.appendingPathComponent("\(channels == 1 ? "mono" : "stereo").\(mediaExtension(request.inputURL))"), arguments: ["-ac", String(channels)], request: request, cancellation: cancellation)]
        case .extract:
            guard request.inputURLs.count == 1 else { throw FileToolsError.invalidRequest("extração aceita uma entrada") }
            generated = [try extract(request.inputURL, workspace: workspace, inputWorkspace: inputWorkspace, request: request, cancellation: cancellation)]
        case .collage(let options, let format):
            generated = [try collage(effectiveInputs, options: options, format: format, workspace: workspace, request: request, cancellation: cancellation)]
        case .merge(let format):
            generated = [try merge(effectiveInputs, to: format, workspace: workspace, request: request, cancellation: cancellation)]
        }
        try cancellation.checkpoint()
        try enforceSize(generated, maximum: request.maximumOutputBytes, cancellation: cancellation)
        try cancellation.checkpoint()
        let published = try publishTransaction(generated, to: destination, preferredStem: request.inputURL.deletingPathExtension().lastPathComponent, cancellation: cancellation)
        return FileToolsResult(outputURLs: published, message: message, committed: true)
    }

    private enum Category: Equatable { case image, svg, video, audio, pdf, text, archive, office, other }

    private func category(_ url: URL) -> Category {
        let ext = url.pathExtension.lowercased()
        if ext == "svg" { return .svg }
        if ["jpg", "jpeg", "png", "webp", "heic", "heif", "tif", "tiff", "bmp", "gif"].contains(ext) { return .image }
        if ["mp4", "m4v", "mov", "mkv", "avi", "webm"].contains(ext) { return .video }
        if ["wav", "flac", "m4a", "mp3", "aac", "ogg", "opus", "aiff", "aif", "caf"].contains(ext) { return .audio }
        if ext == "pdf" { return .pdf }
        if ext == "txt" { return .text }
        if ["zip", "tar", "tgz", "gz", "gzip", "rar"].contains(ext) { return .archive }
        if Self.officeTargets(ext) != [] { return .office }
        return .other
    }

    private func convert(_ input: URL, category: Category, to format: FileToolsFormat, workspace: URL, request: FileToolsRequest, cancellation: FileToolsCancellation) throws -> [URL] {
        if category == .svg {
            throw FileToolsError.unsupported("SVG desabilitado até existir renderizador isolado seguro")
        }
        if [.gzip, .tar, .rar, .zip].contains(format) {
            if category == .archive, format == .zip {
                let expanded = try extract(input, workspace: workspace, request: request, cancellation: cancellation)
                return [try makeZIP(fromDirectoryContents: expanded, workspace: workspace, request: request, cancellation: cancellation)]
            }
            return [try makeArchive(input, format: format, workspace: workspace, request: request, cancellation: cancellation)]
        }
        switch category {
        case .image:
            if input.pathExtension.lowercased() == "gif", [.mp4, .mov, .mkv].contains(format) {
                return [try ffmpeg(input, output: workspace.appendingPathComponent("converted.\(format.rawValue)"), arguments: ["-pix_fmt", "yuv420p"], request: request, cancellation: cancellation)]
            }
            guard [.png, .jpg, .webp, .heic, .tiff, .pdf, .docx].contains(format) else { throw FileToolsError.unsupported("imagem → \(format.rawValue)") }
            if format == .docx {
                return [try imageDOCX(input, workspace: workspace, request: request, cancellation: cancellation)]
            }
            let output = workspace.appendingPathComponent("converted.\(format.rawValue)")
            if format == .pdf {
                try run(required("sips", extras: ["/usr/bin/sips"]), ["-s", "format", "pdf", input.path, "--out", output.path], request, cancellation, outputDirectory: workspace)
                return [output]
            }
            if format == .webp {
                try run(required("cwebp", extras: ["/opt/homebrew/bin/cwebp", "/usr/local/bin/cwebp"]), ["-quiet", input.path, "-o", output.path], request, cancellation, outputDirectory: workspace)
                return [output]
            }
            if format == .heic {
                try run(required("sips", extras: ["/usr/bin/sips"]), ["-s", "format", "heic", input.path, "--out", output.path], request, cancellation, outputDirectory: workspace)
                return [output]
            }
            let arguments = input.pathExtension.lowercased() == "gif" ? ["-frames:v", "1"] : []
            return [try ffmpeg(input, output: output, arguments: arguments, request: request, cancellation: cancellation)]
        case .video:
            guard [.mp4, .mov, .mkv, .gif, .mp3, .m4a].contains(format) else { throw FileToolsError.unsupported("vídeo → \(format.rawValue)") }
            var args: [String] = []
            if format == .mp3 || format == .m4a { args = ["-vn"] }
            return [try ffmpeg(input, output: workspace.appendingPathComponent("converted.\(format.rawValue)"), arguments: args, request: request, cancellation: cancellation)]
        case .audio:
            guard [.wav, .flac, .m4a, .mp3, .mp4].contains(format) else { throw FileToolsError.unsupported("áudio → \(format.rawValue)") }
            let output = workspace.appendingPathComponent("converted.\(format.rawValue)")
            if format == .mp4 {
                return [try ffmpeg(input, output: output, arguments: ["-f", "lavfi", "-i", "color=c=black:s=1280x720", "-shortest", "-c:v", "libx264", "-c:a", "aac"], inputFirst: true, request: request, cancellation: cancellation)]
            }
            return [try ffmpeg(input, output: output, arguments: [], request: request, cancellation: cancellation)]
        case .pdf:
            guard let sourceDocument = PDFDocument(url: input), sourceDocument.pageCount <= request.maximumPages else { throw FileToolsError.outputTooLarge }
            if format == .txt {
                let output = workspace.appendingPathComponent("converted.txt")
                try run(required("pdftotext", extras: ["/opt/homebrew/bin/pdftotext", "/usr/local/bin/pdftotext"]), [input.path, output.path], request, cancellation, outputDirectory: workspace)
                return [output]
            }
            if format == .png || format == .jpg {
                let base = workspace.appendingPathComponent("page").path
                let tool = try required("pdftoppm", extras: ["/opt/homebrew/bin/pdftoppm", "/usr/local/bin/pdftoppm"])
                try run(tool, [format == .png ? "-png" : "-jpeg", input.path, base], request, cancellation, outputDirectory: workspace)
                let expected = format == .jpg ? "jpg" : format.rawValue
                return try fm.contentsOfDirectory(at: workspace, includingPropertiesForKeys: nil).filter { $0.pathExtension.lowercased() == expected }.sorted { $0.path < $1.path }
            }
            if format == .docx { return [try pdfToTextOnlyDOCX(input, workspace: workspace, request: request, cancellation: cancellation)] }
            throw FileToolsError.unsupported("PDF → \(format.rawValue)")
        case .text:
            guard [.pdf, .png, .jpg].contains(format) else { throw FileToolsError.unsupported("TXT → \(format.rawValue)") }
            return try renderText(input, format: format, workspace: workspace, request: request, cancellation: cancellation)
        case .office:
            guard Self.officeTargets(input.pathExtension).contains(format) else { throw FileToolsError.unsupported("\(input.pathExtension) → \(format.rawValue)") }
            return [try office(input, to: format, workspace: workspace, request: request, cancellation: cancellation)]
        default: throw FileToolsError.unsupported("conversão desse tipo")
        }
    }

    private func compress(_ input: URL, category: Category, quality: Int, workspace: URL, request: FileToolsRequest, cancellation: FileToolsCancellation) throws -> [URL] {
        guard (1...100).contains(quality) else { throw FileToolsError.invalidRequest("qualidade deve estar entre 1 e 100") }
        switch category {
        case .image:
            return [try ffmpeg(input, output: workspace.appendingPathComponent("compressed.\(mediaExtension(input))"), arguments: ["-q:v", String(max(2, 31 - quality * 29 / 100))], request: request, cancellation: cancellation)]
        case .video:
            let crf = max(18, 40 - quality * 22 / 100)
            return [try ffmpeg(input, output: workspace.appendingPathComponent("compressed.mp4"), arguments: ["-c:v", "libx264", "-crf", String(crf), "-preset", "medium", "-c:a", "aac", "-b:a", "128k", "-movflags", "+faststart"], request: request, cancellation: cancellation)]
        case .audio:
            return [try ffmpeg(input, output: workspace.appendingPathComponent("compressed.m4a"), arguments: ["-c:a", "aac", "-b:a", quality >= 70 ? "192k" : quality >= 40 ? "128k" : "64k"], request: request, cancellation: cancellation)]
        case .pdf:
            let gs = try required("gs", extras: ["/opt/homebrew/bin/gs", "/usr/local/bin/gs"])
            let output = workspace.appendingPathComponent("compressed.pdf")
            let preset = quality <= 25 ? "/screen" : quality <= 50 ? "/ebook" : quality <= 75 ? "/printer" : "/prepress"
            try run(gs, ["-dSAFER", "-sDEVICE=pdfwrite", "-dCompatibilityLevel=1.4", "-dPDFSETTINGS=\(preset)", "-dNOPAUSE", "-dQUIET", "-dBATCH", "-sOutputFile=\(output.path)", input.path], request, cancellation, outputDirectory: workspace)
            return [output]
        default: throw FileToolsError.unsupported("compressão desse tipo")
        }
    }

    private func removeMetadata(_ input: URL, category: Category, workspace: URL, request: FileToolsRequest, cancellation: FileToolsCancellation) throws -> [URL] {
        if category == .pdf {
            try cancellation.checkpoint()
            guard let document = PDFDocument(url: input) else { throw FileToolsError.processFailed("PDF inválido") }
            document.documentAttributes = [:]
            let output = workspace.appendingPathComponent("clean.pdf")
            guard document.write(to: output) else { throw FileToolsError.processFailed("não foi possível regravar PDF") }
            return [output]
        }
        guard [.image, .video, .audio].contains(category) else { throw FileToolsError.unsupported("remoção de metadados desse tipo") }
        return [try ffmpeg(input, output: workspace.appendingPathComponent("clean.\(mediaExtension(input))"), arguments: ["-map_metadata", "-1", "-map_chapters", "-1"], request: request, cancellation: cancellation)]
    }

    private func renderText(_ input: URL, format: FileToolsFormat, workspace: URL, request: FileToolsRequest, cancellation: FileToolsCancellation) throws -> [URL] {
        let values = try input.resourceValues(forKeys: [.fileSizeKey])
        guard Int64(values.fileSize ?? 0) <= min(request.maximumInputBytes, 64 * 1_024 * 1_024) else { throw FileToolsError.outputTooLarge }
        try cancellation.checkpoint()
        let data = try Data(contentsOf: input, options: .mappedIfSafe)
        guard let text = String(data: data, encoding: .utf8) else { throw FileToolsError.invalidRequest("TXT deve ser UTF-8 válido") }
        let font = CTFontCreateWithName("Menlo" as CFString, 12, nil)
        let attributed = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.black])
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let pageSize = CGSize(width: 595, height: 842)
        let textRect = CGRect(x: 48, y: 48, width: pageSize.width - 96, height: pageSize.height - 96)
        let path = CGPath(rect: textRect, transform: nil)
        var ranges: [CFRange] = []
        var location = 0
        repeat {
            try cancellation.checkpoint()
            guard ranges.count < request.maximumPages else { throw FileToolsError.outputTooLarge }
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: location, length: 0), path, nil)
            var visible = CTFrameGetVisibleStringRange(frame)
            if attributed.length == 0 { visible = CFRange(location: 0, length: 0) }
            guard attributed.length == 0 || visible.length > 0 else { throw FileToolsError.processFailed("texto não pôde ser paginado") }
            ranges.append(visible)
            location += visible.length
        } while location < attributed.length

        func draw(_ context: CGContext, range: CFRange) {
            context.saveGState()
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(origin: .zero, size: pageSize))
            let frame = CTFramesetterCreateFrame(framesetter, range, path, nil)
            CTFrameDraw(frame, context)
            context.restoreGState()
        }

        if format == .pdf {
            let output = workspace.appendingPathComponent("converted.pdf")
            guard let consumer = CGDataConsumer(url: output as CFURL) else { throw FileToolsError.processFailed("não foi possível criar PDF") }
            var mediaBox = CGRect(origin: .zero, size: pageSize)
            guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { throw FileToolsError.processFailed("não foi possível criar PDF") }
            for range in ranges {
                try cancellation.checkpoint()
                context.beginPDFPage(nil)
                draw(context, range: range)
                context.endPDFPage()
            }
            context.closePDF()
            return [output]
        }

        let scale = 2
        let pixelWidth = Int(pageSize.width) * scale
        let pixelHeight = Int(pageSize.height) * scale
        let totalPixels = Int64(pixelWidth) * Int64(pixelHeight) * Int64(ranges.count)
        guard totalPixels <= request.maximumImagePixels else { throw FileToolsError.outputTooLarge }
        var outputs: [URL] = []
        for (index, range) in ranges.enumerated() {
            try cancellation.checkpoint()
            guard let context = CGContext(data: nil, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw FileToolsError.processFailed("não foi possível criar página") }
            context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
            draw(context, range: range)
            guard let image = context.makeImage() else { throw FileToolsError.processFailed("não foi possível finalizar página") }
            let output = workspace.appendingPathComponent(String(format: "page-%03d.%@", index + 1, format.rawValue))
            try writeImage(image, to: output, format: format)
            outputs.append(output)
        }
        return outputs
    }

    private func collage(_ inputs: [URL], options: FileToolsCollageOptions, format: FileToolsFormat, workspace: URL, request: FileToolsRequest, cancellation: FileToolsCancellation) throws -> URL {
        guard inputs.count >= 2, inputs.allSatisfy({ category($0) == .image }) else { throw FileToolsError.invalidRequest("collage exige duas ou mais imagens") }
        guard [.png, .jpg, .pdf].contains(format), options.canvasWidth >= 320, options.canvasWidth <= 8_192,
              options.spacing >= 0, options.margin >= 0, options.margin * 2 < options.canvasWidth,
              let background = color(hex: options.backgroundHex) else { throw FileToolsError.invalidRequest("ajustes de collage inválidos") }
        var sourcePixels: Int64 = 0
        for input in inputs {
            try cancellation.checkpoint()
            guard let dimensions = imagePixelDimensions(input) else { throw FileToolsError.processFailed("imagem inválida") }
            let (pixels, overflow) = Int64(dimensions.width).multipliedReportingOverflow(by: Int64(dimensions.height))
            guard !overflow else { throw FileToolsError.outputTooLarge }
            sourcePixels = try addingBudget(sourcePixels, pixels, maximum: request.maximumImagePixels)
        }
        let width = options.canvasWidth
        let usable = width - options.margin * 2
        var cells: [CGRect] = []
        let height: Int
        switch options.layout {
        case .grid:
            let columns = options.columns ?? Int(ceil(sqrt(Double(inputs.count))))
            guard columns > 0, columns <= inputs.count else { throw FileToolsError.invalidRequest("colunas do grid inválidas") }
            let rows = (inputs.count + columns - 1) / columns
            let cellWidth = max(1, (usable - options.spacing * (columns - 1)) / columns)
            let cellHeight = max(1, cellWidth * 3 / 4)
            height = options.margin * 2 + rows * cellHeight + options.spacing * (rows - 1)
            for index in inputs.indices {
                let row = index / columns, column = index % columns
                cells.append(CGRect(x: options.margin + column * (cellWidth + options.spacing), y: options.margin + (rows - row - 1) * (cellHeight + options.spacing), width: cellWidth, height: cellHeight))
            }
        case .row, .horizontal:
            let cellWidth = max(1, (usable - options.spacing * (inputs.count - 1)) / inputs.count)
            let cellHeight = max(1, cellWidth * 3 / 4)
            height = options.margin * 2 + cellHeight
            for index in inputs.indices { cells.append(CGRect(x: options.margin + index * (cellWidth + options.spacing), y: options.margin, width: cellWidth, height: cellHeight)) }
        case .column, .vertical:
            let cellHeight = max(1, usable * 3 / 4)
            height = options.margin * 2 + inputs.count * cellHeight + options.spacing * (inputs.count - 1)
            for index in inputs.indices { cells.append(CGRect(x: options.margin, y: options.margin + (inputs.count - index - 1) * (cellHeight + options.spacing), width: usable, height: cellHeight)) }
        case .featured:
            let heroHeight = max(1, usable * 9 / 16)
            let remaining = inputs.count - 1
            let columns = min(3, max(1, remaining))
            let rows = (remaining + columns - 1) / columns
            let cellWidth = max(1, (usable - options.spacing * (columns - 1)) / columns)
            let cellHeight = max(1, cellWidth * 3 / 4)
            height = options.margin * 2 + heroHeight + options.spacing + rows * cellHeight + options.spacing * (rows - 1)
            cells.append(CGRect(x: options.margin, y: height - options.margin - heroHeight, width: usable, height: heroHeight))
            for offset in 0..<remaining {
                let row = offset / columns, column = offset % columns
                cells.append(CGRect(x: options.margin + column * (cellWidth + options.spacing), y: options.margin + (rows - row - 1) * (cellHeight + options.spacing), width: cellWidth, height: cellHeight))
            }
        }
        guard height > 0, height <= 32_768 else { throw FileToolsError.invalidRequest("collage excede a altura permitida") }
        let (canvasPixels, overflow) = Int64(width).multipliedReportingOverflow(by: Int64(height))
        let maximumCollageCanvasPixels: Int64 = 32_000_000
        guard !overflow, canvasPixels <= min(request.maximumImagePixels, maximumCollageCanvasPixels) else { throw FileToolsError.outputTooLarge }
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw FileToolsError.processFailed("não foi possível criar canvas") }
        context.setFillColor(background)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        for (input, cell) in zip(inputs, cells) {
            try cancellation.checkpoint()
            guard let source = CGImageSourceCreateWithURL(input as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { throw FileToolsError.processFailed("não foi possível decodificar imagem") }
            let sourceRatio = CGFloat(image.width) / CGFloat(image.height)
            let cellRatio = cell.width / cell.height
            let scale = options.fit == .cover
                ? (sourceRatio > cellRatio ? cell.height / CGFloat(image.height) : cell.width / CGFloat(image.width))
                : (sourceRatio > cellRatio ? cell.width / CGFloat(image.width) : cell.height / CGFloat(image.height))
            let drawSize = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
            let drawRect = CGRect(x: cell.midX - drawSize.width / 2, y: cell.midY - drawSize.height / 2, width: drawSize.width, height: drawSize.height)
            context.saveGState()
            context.clip(to: cell)
            context.interpolationQuality = .high
            context.draw(image, in: drawRect)
            context.restoreGState()
        }
        guard let result = context.makeImage() else { throw FileToolsError.processFailed("não foi possível finalizar collage") }
        let output = workspace.appendingPathComponent("collage.\(format.rawValue)")
        if format == .pdf {
            let document = PDFDocument()
            guard let page = PDFPage(image: NSImage(cgImage: result, size: NSSize(width: width, height: height))) else { throw FileToolsError.processFailed("não foi possível criar página PDF") }
            document.insert(page, at: 0)
            guard document.write(to: output) else { throw FileToolsError.processFailed("não foi possível gravar collage PDF") }
        } else {
            try writeImage(result, to: output, format: format)
        }
        return output
    }

    private func merge(_ inputs: [URL], to format: FileToolsFormat, workspace: URL, request: FileToolsRequest, cancellation: FileToolsCancellation) throws -> URL {
        guard inputs.count >= 2 else { throw FileToolsError.invalidRequest("merge exige duas ou mais entradas") }
        let categories = inputs.map(category)
        if format == .pdf, categories.allSatisfy({ $0 == .image || $0 == .pdf }) {
            let output = workspace.appendingPathComponent("merged.pdf")
            let result = PDFDocument()
            var pageIndex = 0
            var imagePixels: Int64 = 0
            for input in inputs {
                try cancellation.checkpoint()
                if category(input) == .pdf {
                    guard let document = PDFDocument(url: input) else { throw FileToolsError.processFailed("PDF inválido") }
                    guard pageIndex + document.pageCount <= request.maximumPages else { throw FileToolsError.outputTooLarge }
                    for index in 0..<document.pageCount {
                        try cancellation.checkpoint()
                        guard let page = document.page(at: index)?.copy() as? PDFPage else { throw FileToolsError.processFailed("página PDF inválida") }
                        result.insert(page, at: pageIndex)
                        pageIndex += 1
                    }
                } else {
                    guard let dimensions = imagePixelDimensions(input) else { throw FileToolsError.processFailed("imagem inválida") }
                    let (pixels, overflow) = Int64(dimensions.width).multipliedReportingOverflow(by: Int64(dimensions.height))
                    guard !overflow else { throw FileToolsError.outputTooLarge }
                    imagePixels = try addingBudget(imagePixels, pixels, maximum: request.maximumImagePixels)
                    guard pageIndex < request.maximumPages, let image = NSImage(contentsOf: input), let page = PDFPage(image: image) else { throw FileToolsError.processFailed("imagem inválida") }
                    result.insert(page, at: pageIndex)
                    pageIndex += 1
                }
            }
            guard result.write(to: output) else { throw FileToolsError.processFailed("não foi possível gravar PDF unido") }
            return output
        }
        guard let ffmpegURL else { throw FileToolsError.dependencyMissing("ffmpeg") }
        if categories.allSatisfy({ $0 == .audio }), [.wav, .flac, .m4a, .mp3].contains(format) {
            let output = workspace.appendingPathComponent("merged.\(format.rawValue)")
            var arguments = ["-hide_banner", "-nostdin", "-y"]
            for input in inputs { arguments += ["-i", input.path] }
            let links = inputs.indices.map { "[\($0):a]" }.joined()
            arguments += ["-filter_complex", "\(links)concat=n=\(inputs.count):v=0:a=1[a]", "-map", "[a]", "-fs", String(request.maximumOutputBytes), output.path]
            try run(ffmpegURL, arguments, request, cancellation, outputDirectory: workspace)
            return output
        }
        if categories.allSatisfy({ $0 == .video }), [.mp4, .mov, .mkv].contains(format) {
            let output = workspace.appendingPathComponent("merged.\(format.rawValue)")
            let infos = try inputs.map { try videoInfo($0, request: request, cancellation: cancellation) }
            let targetWidth = infos.map(\.width).max() ?? 0
            let targetHeight = infos.map(\.height).max() ?? 0
            guard targetWidth > 0, targetHeight > 0, targetWidth <= 7_680, targetHeight <= 4_320 else {
                throw FileToolsError.unsupported("vídeos têm dimensões inválidas ou acima do limite de normalização")
            }
            let width = targetWidth + targetWidth % 2
            let height = targetHeight + targetHeight % 2
            let audioFlags = try inputs.map { try hasAudioStream($0, request: request, cancellation: cancellation) }
            var arguments = ["-hide_banner", "-nostdin", "-y"]
            for input in inputs { arguments += ["-i", input.path] }
            var filters: [String] = []
            for index in inputs.indices {
                filters.append("[\(index):v]scale=\(width):\(height):force_original_aspect_ratio=decrease,pad=\(width):\(height):(ow-iw)/2:(oh-ih)/2,setsar=1,fps=30,format=yuv420p,setpts=PTS-STARTPTS[v\(index)]")
                if audioFlags[index] {
                    filters.append("[\(index):a]aresample=48000,aformat=sample_fmts=fltp:channel_layouts=stereo,asetpts=PTS-STARTPTS[a\(index)]")
                } else {
                    filters.append("anullsrc=r=48000:cl=stereo,atrim=duration=\(infos[index].duration),asetpts=PTS-STARTPTS[a\(index)]")
                }
            }
            let links = inputs.indices.map { "[v\($0)][a\($0)]" }.joined()
            filters.append("\(links)concat=n=\(inputs.count):v=1:a=1[v][a]")
            arguments += ["-filter_complex", filters.joined(separator: ";"), "-map", "[v]", "-map", "[a]",
                          "-c:v", "libx264", "-c:a", "aac", "-movflags", "+faststart", "-fs", String(request.maximumOutputBytes), output.path]
            try run(ffmpegURL, arguments, request, cancellation, outputDirectory: workspace)
            return output
        }
        throw FileToolsError.unsupported("tipos ou destino incompatíveis para merge")
    }

    private func split(_ input: URL, category: Category, duration: TimeInterval, workspace: URL, request: FileToolsRequest, cancellation: FileToolsCancellation) throws -> [URL] {
        if category == .pdf {
            guard let document = PDFDocument(url: input), document.pageCount <= request.maximumPages else { throw FileToolsError.outputTooLarge }
            let pattern = workspace.appendingPathComponent("page-%03d.pdf").path
            try run(required("pdfseparate", extras: ["/opt/homebrew/bin/pdfseparate", "/usr/local/bin/pdfseparate"]), [input.path, pattern], request, cancellation, outputDirectory: workspace)
        } else if category == .video || category == .audio {
            guard let ffmpegURL else { throw FileToolsError.dependencyMissing("ffmpeg") }
            let pattern = workspace.appendingPathComponent("part-%03d.\(mediaExtension(input))")
            try run(ffmpegURL, ["-hide_banner", "-nostdin", "-y", "-i", input.path, "-f", "segment", "-segment_time", String(duration), "-reset_timestamps", "1", "-c", "copy", pattern.path], request, cancellation, outputDirectory: workspace)
        } else { throw FileToolsError.unsupported("divisão exige PDF, áudio ou vídeo") }
        let outputs = try fm.contentsOfDirectory(at: workspace, includingPropertiesForKeys: nil).filter { !$0.hasDirectoryPath }.sorted { $0.path < $1.path }
        guard !outputs.isEmpty else { throw FileToolsError.processFailed("divisão não produziu saída") }
        return outputs
    }

    private func ffmpeg(_ input: URL, output: URL, arguments: [String], inputFirst: Bool = true, request: FileToolsRequest, cancellation: FileToolsCancellation) throws -> URL {
        guard let ffmpegURL else { throw FileToolsError.dependencyMissing("ffmpeg") }
        var args = ["-hide_banner", "-nostdin", "-y"]
        if inputFirst { args += ["-i", input.path] + arguments } else { args += arguments + ["-i", input.path] }
        args += ["-fs", String(request.maximumOutputBytes), output.path]
        try run(ffmpegURL, args, request, cancellation, outputDirectory: output.deletingLastPathComponent())
        guard fm.fileExists(atPath: output.path) else { throw FileToolsError.processFailed("ffmpeg não produziu saída") }
        return output
    }

    private func makeArchive(_ input: URL, format: FileToolsFormat, workspace: URL, request: FileToolsRequest, cancellation: FileToolsCancellation) throws -> URL {
        switch format {
        case .tar:
            let output = workspace.appendingPathComponent("archive.tar")
            try run(required("tar", extras: ["/usr/bin/tar"]), ["-cf", output.path, "-C", input.deletingLastPathComponent().path, "./\(input.lastPathComponent)"], request, cancellation, outputDirectory: workspace)
            return output
        case .gzip:
            guard !((try? input.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false) else { throw FileToolsError.unsupported("GZIP aceita um arquivo; use TAR para diretórios") }
            let copied = workspace.appendingPathComponent("archive.\(input.pathExtension).gz")
            let plain = copied.deletingPathExtension()
            try copyRegularFile(from: input, to: plain, cancellation: cancellation)
            try run(required("gzip", extras: ["/usr/bin/gzip"]), ["-f", plain.path], request, cancellation, outputDirectory: workspace)
            return copied
        case .rar:
            guard let rar = Self.findExecutable("rar", extras: ["/opt/homebrew/bin/rar", "/usr/local/bin/rar"]) else { throw FileToolsError.unsupported("criação RAR bloqueada: encoder rar não instalado (nenhuma instalação/licença automática)") }
            let output = workspace.appendingPathComponent("archive.rar")
            try run(rar, ["a", "-idq", output.path, input.path], request, cancellation, outputDirectory: workspace)
            return output
        case .zip:
            var info = stat()
            guard lstat(input.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw FileToolsError.unsupported("ZIP seguro aceita arquivo regular; diretórios exigem snapshot recursivo") }
            let staging = workspace.deletingLastPathComponent().appendingPathComponent("inputs/zip-input", isDirectory: true)
            try fm.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let snapshot = staging.appendingPathComponent(input.lastPathComponent)
            try copyRegularFile(from: input, to: snapshot, cancellation: cancellation)
            let output = workspace.appendingPathComponent("archive.zip")
            try run(required("zip", extras: ["/usr/bin/zip"]), ["-q", "-X", output.path, "--", "./\(snapshot.lastPathComponent)"], request, cancellation, currentDirectory: staging, outputDirectory: workspace)
            return output
        default: throw FileToolsError.unsupported("formato de arquivo")
        }
    }

    private func makeZIP(fromDirectoryContents directory: URL, workspace: URL, request: FileToolsRequest, cancellation: FileToolsCancellation) throws -> URL {
        let output = workspace.appendingPathComponent("archive.zip")
        try run(required("zip", extras: ["/usr/bin/zip"]), ["-q", "-X", "-r", output.path, "--", "."], request, cancellation, currentDirectory: directory, outputDirectory: workspace)
        return output
    }

    private func extract(_ input: URL, workspace: URL, inputWorkspace explicitInputWorkspace: URL? = nil, request: FileToolsRequest, cancellation: FileToolsCancellation) throws -> URL {
        guard category(input) == .archive else { throw FileToolsError.unsupported("extração exige arquivo ZIP/TAR/GZIP/RAR") }
        try cancellation.checkpoint()
        let inputWorkspace = explicitInputWorkspace ?? workspace.deletingLastPathComponent().appendingPathComponent("inputs", isDirectory: true)
        let lowerName = input.lastPathComponent.lowercased()
        let isPlainGzip = (lowerName.hasSuffix(".gz") || lowerName.hasSuffix(".gzip")) && !lowerName.hasSuffix(".tar.gz") && !lowerName.hasSuffix(".tgz")
        let snapshotExtension = isPlainGzip ? "gz" : input.pathExtension
        let snapshot = inputWorkspace.appendingPathComponent("archive-snapshot-\(UUID().uuidString).\(snapshotExtension)")
        try copyRegularFile(from: input, to: snapshot, cancellation: cancellation)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: snapshot.path)
        try cancellation.checkpoint()

        let root = workspace.appendingPathComponent("extracted", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if isPlainGzip {
            try run(required("gzip", extras: ["/usr/bin/gzip"]), ["-d", snapshot.path], request, cancellation, outputDirectory: inputWorkspace)
            let inflated = snapshot.deletingPathExtension()
            let output = root.appendingPathComponent(input.deletingPathExtension().lastPathComponent)
            try cancellation.checkpoint()
            try fm.moveItem(at: inflated, to: output)
            try validateExpandedTree(root, request: request, cancellation: cancellation)
            return root
        }

        let tar = try required("tar", extras: ["/usr/bin/tar"])
        let listing = try run(tar, ["-tf", snapshot.path], request, cancellation).stdout
        let paths = listing.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        guard paths.count <= request.maximumArchiveMembers else { throw FileToolsError.unsafeArchive("membros demais") }
        for path in paths {
            try cancellation.checkpoint()
            let components = path.split(separator: "/", omittingEmptySubsequences: true)
            if path.utf8.count > request.maximumArchivePathBytes || components.count > request.maximumArchiveDepth ||
                path.hasPrefix("/") || components.contains("..") || path.unicodeScalars.contains(where: { $0.value < 0x20 }) {
                throw FileToolsError.unsafeArchive("caminho inválido ou acima do limite")
            }
        }
        let verbose = try run(tar, ["-tvf", snapshot.path], request, cancellation).stdout
        let metadata = verbose.split(separator: "\n", omittingEmptySubsequences: true)
        guard metadata.count == paths.count else { throw FileToolsError.unsafeArchive("listagem ambígua") }
        var declaredBytes: Int64 = 0
        for line in metadata {
            try cancellation.checkpoint()
            guard let type = line.first, type == "-" || type == "d" else {
                throw FileToolsError.unsafeArchive("tipo especial não permitido")
            }
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count > 4, let size = Int64(fields[4]), size >= 0 else {
                throw FileToolsError.unsafeArchive("metadados não reconhecidos")
            }
            declaredBytes = try addingBudget(declaredBytes, size, maximum: request.maximumOutputBytes)
        }
        try cancellation.checkpoint()
        try run(tar, ["-xf", snapshot.path, "-C", root.path], request, cancellation, outputDirectory: root)
        try validateExpandedTree(root, request: request, cancellation: cancellation)
        return root
    }

    @discardableResult private func run(
        _ executable: URL,
        _ arguments: [String],
        _ request: FileToolsRequest,
        _ cancellation: FileToolsCancellation,
        currentDirectory: URL? = nil,
        outputDirectory: URL? = nil
    ) throws -> SafeProcessOutput {
        let remaining = try cancellation.remaining()
        return try SafeProcess.run(
            executable: executable,
            arguments: arguments,
            timeout: remaining,
            outputDirectory: outputDirectory,
            maximumOutputBytes: request.maximumOutputBytes,
            currentDirectory: currentDirectory,
            cancellation: cancellation
        )
    }

    private func hasAudioStream(_ input: URL, request: FileToolsRequest, cancellation: FileToolsCancellation) throws -> Bool {
        let probe = try required("ffprobe", extras: ["/opt/homebrew/bin/ffprobe", "/usr/local/bin/ffprobe"])
        let output = try run(probe, ["-v", "error", "-select_streams", "a", "-show_entries", "stream=index", "-of", "csv=p=0", input.path], request, cancellation)
        return !output.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func videoInfo(_ input: URL, request: FileToolsRequest, cancellation: FileToolsCancellation) throws -> (width: Int, height: Int, duration: Double) {
        let probe = try required("ffprobe", extras: ["/opt/homebrew/bin/ffprobe", "/usr/local/bin/ffprobe"])
        let output = try run(probe, ["-v", "error", "-select_streams", "v:0", "-show_entries", "stream=width,height:format=duration", "-of", "default=noprint_wrappers=1", input.path], request, cancellation)
        var values: [String: String] = [:]
        for line in output.stdout.split(separator: "\n") {
            let pair = line.split(separator: "=", maxSplits: 1).map(String.init)
            if pair.count == 2 { values[pair[0]] = pair[1] }
        }
        guard let width = values["width"].flatMap(Int.init), let height = values["height"].flatMap(Int.init),
              let duration = values["duration"].flatMap(Double.init), duration.isFinite, duration > 0 else {
            throw FileToolsError.unsupported("não foi possível determinar dimensões e duração do vídeo antes do merge")
        }
        return (width, height, duration)
    }

    private func scanQRCodes(_ input: URL, maximumPages: Int, cancellation: FileToolsCancellation) throws -> [String] {
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        var values: [String] = []
        func collect() {
            for observation in request.results ?? [] {
                if let payload = observation.payloadStringValue, !values.contains(payload) { values.append(payload) }
            }
        }
        switch category(input) {
        case .image:
            try cancellation.checkpoint()
            try VNImageRequestHandler(url: input).perform([request])
            collect()
        case .pdf:
            guard let document = PDFDocument(url: input) else { throw FileToolsError.processFailed("PDF inválido") }
            guard document.pageCount <= maximumPages else { throw FileToolsError.outputTooLarge }
            for index in 0..<document.pageCount {
                try cancellation.checkpoint()
                guard let page = document.page(at: index) else { continue }
                let box = page.bounds(for: .mediaBox)
                let scale = min(3.0, max(1.0, 2_048.0 / max(box.width, box.height)))
                let size = NSSize(width: max(1, box.width * scale), height: max(1, box.height * scale))
                let image = page.thumbnail(of: size, for: .mediaBox)
                var rect = NSRect(origin: .zero, size: image.size)
                guard let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { continue }
                try VNImageRequestHandler(cgImage: cgImage).perform([request])
                collect()
            }
        default: throw FileToolsError.unsupported("leitura QR exige imagem ou PDF")
        }
        guard !values.isEmpty else { throw FileToolsError.processFailed("nenhum QR Code encontrado") }
        return values
    }

    private func rasterizeForOffice(_ input: URL, workspace: URL, request: FileToolsRequest, cancellation: FileToolsCancellation) throws -> URL {
        let output = workspace.appendingPathComponent("converted.png")
        try run(required("sips", extras: ["/usr/bin/sips"]), ["-s", "format", "png", input.path, "--out", output.path], request, cancellation, outputDirectory: workspace)
        guard fm.fileExists(atPath: output.path), imagePixelDimensions(output) != nil else {
            throw FileToolsError.processFailed("o sistema não conseguiu renderizar a imagem")
        }
        return output
    }

    private func imagePixelDimensions(_ input: URL) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithURL(input as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { return nil }
        return (width, height)
    }

    private func imageDOCX(_ input: URL, workspace: URL, request: FileToolsRequest, cancellation: FileToolsCancellation) throws -> URL {
        let raster = try rasterizeForOffice(input, workspace: workspace, request: request, cancellation: cancellation)
        guard let dimensions = imagePixelDimensions(raster) else { throw FileToolsError.processFailed("imagem rasterizada inválida") }
        let pageWidth = 5_943_600.0
        let pageHeight = 8_229_600.0
        let naturalWidth = Double(dimensions.width) * 9_525.0
        let naturalHeight = Double(dimensions.height) * 9_525.0
        let scale = min(1.0, pageWidth / naturalWidth, pageHeight / naturalHeight)
        let width = max(1, Int64((naturalWidth * scale).rounded()))
        let height = max(1, Int64((naturalHeight * scale).rounded()))

        let package = workspace.appendingPathComponent("docx-image-package", isDirectory: true)
        let rootRels = package.appendingPathComponent("_rels", isDirectory: true)
        let word = package.appendingPathComponent("word", isDirectory: true)
        let wordRels = word.appendingPathComponent("_rels", isDirectory: true)
        let media = word.appendingPathComponent("media", isDirectory: true)
        try fm.createDirectory(at: rootRels, withIntermediateDirectories: true)
        try fm.createDirectory(at: wordRels, withIntermediateDirectories: true)
        try fm.createDirectory(at: media, withIntermediateDirectories: true)
        try fm.moveItem(at: raster, to: media.appendingPathComponent("image1.png"))
        try """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Default Extension="png" ContentType="image/png"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/></Types>
        """.write(to: package.appendingPathComponent("[Content_Types].xml"), atomically: true, encoding: .utf8)
        try """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>
        """.write(to: rootRels.appendingPathComponent(".rels"), atomically: true, encoding: .utf8)
        try """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="media/image1.png"/></Relationships>
        """.write(to: wordRels.appendingPathComponent("document.xml.rels"), atomically: true, encoding: .utf8)
        try """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?><w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture"><w:body><w:p><w:r><w:drawing><wp:inline distT="0" distB="0" distL="0" distR="0"><wp:extent cx="\(width)" cy="\(height)"/><wp:docPr id="1" name="Embedded image"/><a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture"><pic:pic><pic:nvPicPr><pic:cNvPr id="0" name="image1.png"/><pic:cNvPicPr/></pic:nvPicPr><pic:blipFill><a:blip r:embed="rId1"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill><pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="\(width)" cy="\(height)"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr></pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r></w:p><w:sectPr/></w:body></w:document>
        """.write(to: word.appendingPathComponent("document.xml"), atomically: true, encoding: .utf8)
        try cancellation.checkpoint()
        let output = workspace.appendingPathComponent("converted.docx")
        try run(required("zip", extras: ["/usr/bin/zip"]), ["-q", "-X", "-r", output.path, "[Content_Types].xml", "_rels", "word"], request, cancellation, currentDirectory: package, outputDirectory: workspace)
        return output
    }

    private func pdfToTextOnlyDOCX(_ input: URL, workspace: URL, request: FileToolsRequest, cancellation: FileToolsCancellation) throws -> URL {
        let textURL = workspace.appendingPathComponent("pdf-text.txt")
        try run(required("pdftotext", extras: ["/opt/homebrew/bin/pdftotext", "/usr/local/bin/pdftotext"]), ["-layout", input.path, textURL.path], request, cancellation, outputDirectory: workspace)
        try cancellation.checkpoint()
        let text = try String(contentsOf: textURL, encoding: .utf8)
        let escaped = text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        let paragraphs = escaped.components(separatedBy: .newlines).map { "<w:p><w:r><w:t xml:space=\"preserve\">\($0)</w:t></w:r></w:p>" }.joined()
        let package = workspace.appendingPathComponent("docx-package", isDirectory: true)
        let rels = package.appendingPathComponent("_rels", isDirectory: true)
        let word = package.appendingPathComponent("word", isDirectory: true)
        try fm.createDirectory(at: rels, withIntermediateDirectories: true)
        try fm.createDirectory(at: word, withIntermediateDirectories: true)
        try """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/></Types>
        """.write(to: package.appendingPathComponent("[Content_Types].xml"), atomically: true, encoding: .utf8)
        try """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>
        """.write(to: rels.appendingPathComponent(".rels"), atomically: true, encoding: .utf8)
        try "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"><w:body>\(paragraphs)<w:sectPr/></w:body></w:document>".write(to: word.appendingPathComponent("document.xml"), atomically: true, encoding: .utf8)
        try cancellation.checkpoint()
        let output = workspace.appendingPathComponent("converted.docx")
        try run(required("zip", extras: ["/usr/bin/zip"]), ["-q", "-r", output.path, "[Content_Types].xml", "_rels", "word"], request, cancellation, currentDirectory: package, outputDirectory: workspace)
        return output
    }

    private func copyRegularFile(from source: URL, to destination: URL, maximumBytes: Int64 = .max, cancellation: FileToolsCancellation) throws {
        let readerFD = Darwin.open(source.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard readerFD >= 0 else { throw FileToolsError.unsafeArchive("entrada deve ser arquivo regular acessível sem seguir links") }
        defer { Darwin.close(readerFD) }
        var initial = stat()
        guard fstat(readerFD, &initial) == 0, initial.st_mode & S_IFMT == S_IFREG, initial.st_size >= 0 else {
            throw FileToolsError.unsafeArchive("entrada deve ser arquivo regular")
        }
        guard initial.st_size <= maximumBytes else { throw FileToolsError.outputTooLarge }
        let writerFD = Darwin.open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard writerFD >= 0 else { throw FileToolsError.processFailed("não foi possível criar snapshot privado") }
        defer { Darwin.close(writerFD) }
        let reader = FileHandle(fileDescriptor: readerFD, closeOnDealloc: false)
        let writer = FileHandle(fileDescriptor: writerFD, closeOnDealloc: false)
        var copied: Int64 = 0
        do {
            while true {
                try cancellation.checkpoint()
                let chunk = try reader.read(upToCount: 1_048_576) ?? Data()
                if chunk.isEmpty { break }
                let (next, overflow) = copied.addingReportingOverflow(Int64(chunk.count))
                guard !overflow, next <= initial.st_size else { throw FileToolsError.unsafeArchive("entrada mudou durante o snapshot") }
                try writer.write(contentsOf: chunk)
                copied = next
            }
            guard fsync(writerFD) == 0 else { throw FileToolsError.processFailed("não foi possível sincronizar snapshot privado") }
            var final = stat()
            var currentPath = stat()
            guard fstat(readerFD, &final) == 0, lstat(source.path, &currentPath) == 0,
                  copied == initial.st_size,
                  stableIdentity(initial, final), stableIdentity(initial, currentPath) else {
                throw FileToolsError.unsafeArchive("entrada mudou durante o snapshot")
            }
        } catch {
            unlink(destination.path)
            throw error
        }
    }

    private func stableIdentity(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino &&
        lhs.st_mode == rhs.st_mode && lhs.st_size == rhs.st_size &&
        lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec &&
        lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec &&
        lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec &&
        lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }

    private func addingBudget(_ current: Int64, _ addition: Int64, maximum: Int64) throws -> Int64 {
        let (sum, overflow) = current.addingReportingOverflow(addition)
        if overflow || sum > maximum { throw FileToolsError.outputTooLarge }
        return sum
    }

    private func validateExpandedTree(_ root: URL, request: FileToolsRequest, cancellation: FileToolsCancellation) throws {
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]) else { return }
        var count = 0
        var bytes: Int64 = 0
        for case let item as URL in enumerator {
            try cancellation.checkpoint()
            count += 1
            guard count <= request.maximumArchiveMembers else { throw FileToolsError.unsafeArchive("membros demais após extração") }
            let relative = String(item.path.dropFirst(root.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if relative.utf8.count > request.maximumArchivePathBytes || relative.split(separator: "/").count > request.maximumArchiveDepth {
                throw FileToolsError.unsafeArchive("profundidade ou nome acima do limite")
            }
            let values = try item.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true, values.isRegularFile == true || values.isDirectory == true else {
                throw FileToolsError.unsafeArchive("tipo especial após extração")
            }
            if values.isRegularFile == true { bytes = try addingBudget(bytes, Int64(values.fileSize ?? 0), maximum: request.maximumOutputBytes) }
        }
    }

    private func isArchiveCreation(_ operation: FileToolsOperation) -> Bool {
        if case .convert(let format) = operation { return format == .tar || format == .zip }
        return false
    }

    private func isExtraction(_ operation: FileToolsOperation) -> Bool {
        if case .extract = operation { return true }
        return false
    }

    private func color(hex: String) -> CGColor? {
        if hex.lowercased() == "transparent" { return CGColor(red: 0, green: 0, blue: 0, alpha: 0) }
        let value = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard value.count == 6, let rgb = UInt32(value, radix: 16) else { return nil }
        return CGColor(red: CGFloat((rgb >> 16) & 255) / 255, green: CGFloat((rgb >> 8) & 255) / 255, blue: CGFloat(rgb & 255) / 255, alpha: 1)
    }

    private func writeImage(_ image: CGImage, to output: URL, format: FileToolsFormat) throws {
        let type: CFString = format == .jpg ? "public.jpeg" as CFString : "public.png" as CFString
        guard let destination = CGImageDestinationCreateWithURL(output as CFURL, type, 1, nil) else { throw FileToolsError.processFailed("não foi possível criar imagem") }
        let properties: CFDictionary = format == .jpg ? [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary : [:] as CFDictionary
        CGImageDestinationAddImage(destination, image, properties)
        guard CGImageDestinationFinalize(destination) else { throw FileToolsError.processFailed("não foi possível gravar imagem") }
    }

    static func officeTargets(_ fileExtension: String) -> [FileToolsFormat] {
        let ext = fileExtension.lowercased()
        let targets: [FileToolsFormat]
        switch ext {
        case "xlsx", "xls", "ods", "csv": targets = [.pdf, .xlsx, .csv]
        case "docx", "doc", "odt", "rtf": targets = [.pdf, .docx, .txt]
        case "pptx", "ppt", "odp": targets = [.pdf]
        default: return []
        }
        return targets.filter { $0.rawValue != ext }
    }

    private static func officeExecutable() -> URL? {
        findExecutable("soffice", extras: ["/opt/homebrew/bin/soffice", "/usr/local/bin/soffice", "/Applications/LibreOffice.app/Contents/MacOS/soffice"])
    }

    private func office(_ input: URL, to format: FileToolsFormat, workspace: URL, request: FileToolsRequest, cancellation: FileToolsCancellation) throws -> URL {
        guard let soffice = Self.officeExecutable() else { throw FileToolsError.dependencyMissing("soffice (LibreOffice)") }
        let filter: String
        switch format {
        case .pdf: filter = "pdf"
        case .xlsx: filter = "xlsx:Calc MS Excel 2007 XML"
        case .csv: filter = "csv:Text - txt - csv (StarCalc):44,34,76,1"
        case .docx: filter = "docx:MS Word 2007 XML"
        case .txt: filter = "txt:Text (encoded):UTF8"
        default: throw FileToolsError.unsupported("office → \(format.rawValue)")
        }
        let scratch = workspace.deletingLastPathComponent().appendingPathComponent("inputs/office-\(UUID().uuidString)", isDirectory: true)
        let profile = scratch.appendingPathComponent("profile", isDirectory: true)
        let outdir = scratch.appendingPathComponent("out", isDirectory: true)
        try fm.createDirectory(at: outdir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let snapshot = scratch.appendingPathComponent("source.\(input.pathExtension.lowercased())")
        try copyRegularFile(from: input, to: snapshot, maximumBytes: request.maximumInputBytes, cancellation: cancellation)
        try run(soffice, [
            "-env:UserInstallation=" + profile.absoluteString,
            "--headless", "--norestore", "--nolockcheck", "--nodefault", "--nologo",
            "--convert-to", filter, "--outdir", outdir.path, snapshot.path,
        ], request, cancellation, currentDirectory: scratch)
        let produced = outdir.appendingPathComponent("source.\(format.rawValue)")
        guard fm.fileExists(atPath: produced.path) else { throw FileToolsError.unsupported("o LibreOffice não gerou \(format.rawValue)") }
        let output = workspace.appendingPathComponent("converted.\(format.rawValue)")
        try fm.moveItem(at: produced, to: output)
        return output
    }

    private func required(_ name: String, extras: [String]) throws -> URL {
        guard let result = Self.findExecutable(name, extras: extras) else { throw FileToolsError.dependencyMissing(name) }
        return result
    }

    private static func findExecutable(_ name: String, extras: [String]) -> URL? {
        let paths = extras + ["/usr/bin/\(name)", "/bin/\(name)"]
        return paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }).map { URL(fileURLWithPath: $0) }
    }

    private func mediaExtension(_ input: URL) -> String {
        let ext = input.pathExtension.lowercased()
        return ext == "jpeg" ? "jpg" : (ext.isEmpty ? "bin" : ext)
    }

    private func enforceSize(_ urls: [URL], maximum: Int64, cancellation: FileToolsCancellation) throws {
        var total: Int64 = 0
        for url in urls {
            try cancellation.checkpoint()
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey])
            if values.isRegularFile == true {
                total = try addingBudget(total, Int64(values.fileSize ?? 0), maximum: maximum)
            } else if values.isDirectory == true, let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) {
                for case let child as URL in enumerator {
                    try cancellation.checkpoint()
                    let childValues = try child.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                    if childValues.isRegularFile == true { total = try addingBudget(total, Int64(childValues.fileSize ?? 0), maximum: maximum) }
                }
            } else { throw FileToolsError.processFailed("saída não é arquivo regular nem diretório") }
        }
    }

    private func publishTransaction(_ sources: [URL], to directory: URL, preferredStem: String, cancellation: FileToolsCancellation) throws -> [URL] {
        guard !sources.isEmpty else {
            try cancellation.authorizeCommit()
            return []
        }
        try cancellation.checkpoint()
        let staging = directory.appendingPathComponent(".garime-filetools-publish-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: staging.path)
        guard let identity = privateDirectoryIdentity(staging) else {
            throw FileToolsError.processFailed("staging de publicação não é privado")
        }
        var published = false
        defer {
            if !published { cleanupOwnedStaging(staging, identity: identity) }
        }
        var names: [String] = []
        var reserved = Set<String>()
        for source in sources {
            let name = publicationName(for: source, preferredStem: preferredStem, additionallyReserved: reserved)
            reserved.insert(name)
            try fm.moveItem(at: source, to: staging.appendingPathComponent(name))
            names.append(name)
        }
        for index in 0..<10_000 {
            let number = index == 0 ? "" : "-\(index + 1)"
            let candidate = directory.appendingPathComponent("\(preferredStem)-result\(number)", isDirectory: true)
            try cancellation.authorizeCommit()
            if renamex_np(staging.path, candidate.path, UInt32(RENAME_EXCL)) == 0 {
                published = true
                return names.map { candidate.appendingPathComponent($0) }
            }
            if errno != EEXIST { throw FileToolsError.processFailed("não foi possível publicar transação") }
        }
        throw FileToolsError.processFailed("não foi possível reservar nome de saída")
    }

    private func privateDirectoryIdentity(_ directory: URL) -> stat? {
        var value = stat()
        guard lstat(directory.path, &value) == 0,
              value.st_mode & S_IFMT == S_IFDIR,
              value.st_uid == geteuid(),
              value.st_mode & 0o077 == 0 else { return nil }
        return value
    }

    private func cleanupOwnedStaging(_ directory: URL, identity: stat) {
        guard let current = privateDirectoryIdentity(directory),
              current.st_dev == identity.st_dev,
              current.st_ino == identity.st_ino else { return }
        try? fm.removeItem(at: directory)
    }

    private func publicationName(for source: URL, preferredStem: String, additionallyReserved: Set<String>) -> String {
        let ext = source.pathExtension
        let suffix = source.deletingPathExtension().lastPathComponent
        let descriptive = suffix == "converted" || suffix == "archive" ? preferredStem : "\(preferredStem)-\(suffix)"
        for index in 0..<10_000 {
            let number = index == 0 ? "" : "-\(index + 1)"
            let name = descriptive + number + (ext.isEmpty ? "" : ".\(ext)")
            if !additionallyReserved.contains(name) { return name }
        }
        return "\(UUID().uuidString)" + (ext.isEmpty ? "" : ".\(ext)")
    }

    private static func atempoFilter(_ speed: Double) -> String {
        var remaining = speed, factors: [Double] = []
        while remaining > 2 { factors.append(2); remaining /= 2 }
        while remaining < 0.5 { factors.append(0.5); remaining /= 0.5 }
        factors.append(remaining)
        return factors.map { "atempo=\($0)" }.joined(separator: ",")
    }
}
