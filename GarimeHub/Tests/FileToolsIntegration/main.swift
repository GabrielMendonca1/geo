import Foundation
import AppKit
import CoreImage
import PDFKit
import Darwin

private final class WorkspaceByteProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    private var peak: Int64 = 0

    func sample() {
        let manager = FileManager.default
        let temporary = manager.temporaryDirectory
        let roots = (try? manager.contentsOfDirectory(at: temporary, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        var bytes: Int64 = 0
        for root in roots where root.lastPathComponent.hasPrefix("garime-filetools-") && !root.lastPathComponent.hasPrefix("garime-filetools-tests.") {
            if let items = manager.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) {
                for case let item as URL in items {
                    let values = try? item.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                    if values?.isRegularFile == true { bytes += Int64(values?.fileSize ?? 0) }
                }
            }
        }
        lock.lock()
        peak = max(peak, bytes)
        lock.unlock()
    }

    func stop() {
        lock.lock()
        stopped = true
        lock.unlock()
    }

    var shouldStop: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    var maximumBytes: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return peak
    }
}

@main
enum FileToolsIntegrationTests {
    static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let backend = FileToolsBackend()
        var checks = 0
        var sourceBugs: [String] = []

        func check(_ condition: @autoclosure () -> Bool, _ label: String) throws {
            guard condition() else { throw NSError(domain: "FileToolsTests", code: 1, userInfo: [NSLocalizedDescriptionKey: label]) }
            checks += 1
            print("ok - \(label)")
        }
        func mediaDuration(_ url: URL) throws -> Double {
            let process = Process(), pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffprobe")
            process.arguments = ["-v", "error", "-show_entries", "format=duration", "-of", "default=nw=1:nk=1", url.path]
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0, let value = Double(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) else { throw NSError(domain: "FileToolsTests", code: 13) }
            return value
        }
        func mediaStreams(_ url: URL) throws -> String {
            let process = Process(), pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffprobe")
            process.arguments = ["-v", "error", "-show_entries", "stream=codec_type,width,height", "-of", "csv=p=0", url.path]
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw NSError(domain: "FileToolsTests", code: 22) }
            return String(decoding: data, as: UTF8.self)
        }
        func mediaChannels(_ url: URL) throws -> Int {
            let process = Process(), pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffprobe")
            process.arguments = ["-v", "error", "-select_streams", "a:0", "-show_entries", "stream=channels", "-of", "default=nw=1:nk=1", url.path]
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0, let channels = Int(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) else { throw NSError(domain: "FileToolsTests", code: 27) }
            return channels
        }
        func imageMetadata(_ url: URL) throws -> String {
            let process = Process(), pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/exiftool")
            process.arguments = ["-s", url.path]
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw NSError(domain: "FileToolsTests", code: 29) }
            return String(decoding: data, as: UTF8.self)
        }
        func mediaMetadata(_ url: URL) throws -> String {
            let process = Process(), pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffprobe")
            process.arguments = ["-v", "error", "-show_entries", "format_tags:stream_tags", "-of", "default=nw=1", url.path]
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw NSError(domain: "FileToolsTests", code: 28) }
            return String(decoding: data, as: UTF8.self)
        }
        func transcode(_ input: URL, _ output: URL) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
            process.arguments = ["-hide_banner", "-loglevel", "error", "-y", "-i", input.path, output.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw NSError(domain: "FileToolsTests", code: 20) }
        }
        func unzip(_ arguments: [String]) throws -> Data {
            let process = Process(), pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            process.arguments = arguments
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw NSError(domain: "FileToolsTests", code: 10) }
            return data
        }

        let image = root.appendingPathComponent("fixture.png")
        let cancelledCommit = FileToolsCancellation(timeout: 10)
        cancelledCommit.cancel()
        do {
            try cancelledCommit.authorizeCommit()
            throw NSError(domain: "FileToolsTests", code: 12, userInfo: [NSLocalizedDescriptionKey: "commit cancelado foi autorizado"])
        } catch FileToolsError.cancelled {
            checks += 1
            print("ok - autorização atômica de commit recusa token cancelado")
        }
        for timeout in [-1.0, 0.0, .nan, .infinity] {
            do {
                _ = try await backend.perform(.init(inputURL: image, operation: .convert(to: .webp), outputDirectory: root, timeout: timeout))
                throw NSError(domain: "FileToolsTests", code: 7, userInfo: [NSLocalizedDescriptionKey: "timeout inválido foi aceito"])
            } catch FileToolsError.invalidRequest {
                checks += 1
                print("ok - rejeita timeout inválido sem trap")
            }
        }
        for operation in [FileToolsOperation.trim(start: .infinity, duration: 1), .trim(start: 0, duration: .infinity), .snapshot(time: .infinity), .split(segmentDuration: .infinity)] {
            do {
                _ = try await backend.perform(.init(inputURL: root.appendingPathComponent("silent.mp4"), operation: operation, outputDirectory: root))
                throw NSError(domain: "FileToolsTests", code: 23, userInfo: [NSLocalizedDescriptionKey: "segundos não finitos foram aceitos"])
            } catch FileToolsError.invalidRequest {
                checks += 1
                print("ok - worker rejeita parâmetro temporal não finito")
            }
        }
        do {
            let relative = URL(string: "file:relative.png")!
            _ = try await backend.perform(.init(inputURL: relative, operation: .convert(to: .png), outputDirectory: root))
            throw NSError(domain: "FileToolsTests", code: 24, userInfo: [NSLocalizedDescriptionKey: "file URL relativa foi aceita"])
        } catch FileToolsError.invalidRequest {
            checks += 1
            print("ok - backend exige file URL absoluta")
        }

        setenv("GS_OPTIONS", "-dNOSAFER -dLastPage=1", 1)
        setenv("FFREPORT", "file=/tmp/filetools-should-not-exist.log", 1)
        let cleanEnvironment = try SafeProcess.run(executable: URL(fileURLWithPath: "/usr/bin/env"), arguments: [], timeout: 2, cancellation: FileToolsCancellation(timeout: 2)).stdout
        unsetenv("GS_OPTIONS"); unsetenv("FFREPORT")
        try check(!cleanEnvironment.contains("GS_OPTIONS") && !cleanEnvironment.contains("FFREPORT"), "subprocesso recebe ambiente saneado sem opções injetáveis")

        let monitored = root.appendingPathComponent("explicit-monitor", isDirectory: true)
        try FileManager.default.createDirectory(at: monitored, withIntermediateDirectories: false)
        do {
            _ = try SafeProcess.run(executable: root.appendingPathComponent("budget-writer"), arguments: [monitored.appendingPathComponent("large.bin").path], timeout: 5, outputDirectory: monitored, maximumOutputBytes: 1_024, cancellation: FileToolsCancellation(timeout: 5))
            throw NSError(domain: "FileToolsTests", code: 25, userInfo: [NSLocalizedDescriptionKey: "monitor explícito não interrompeu saída"])
        } catch FileToolsError.outputTooLarge {
            checks += 1
            print("ok - diretório de saída explícito é monitorado ao vivo")
        }

        let qrText = "garime://adversarial-qr"
        let qrFilter = CIFilter(name: "CIQRCodeGenerator")!
        qrFilter.setValue(Data(qrText.utf8), forKey: "inputMessage")
        let qrImage = qrFilter.outputImage!.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        let qrURL = root.appendingPathComponent("qr.png")
        try CIContext().writePNGRepresentation(of: qrImage, to: qrURL, format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        let qrResult = try await backend.perform(.init(inputURL: qrURL, operation: .scanQRCode, outputDirectory: root))
        try check(qrResult.outputURLs.isEmpty && qrResult.message == qrText, "Vision lê QR real de imagem")
        let qrGIFURL = root.appendingPathComponent("qr.gif")
        try transcode(qrURL, qrGIFURL)
        let qrGIFResult = try await backend.perform(.init(inputURL: qrGIFURL, operation: .scanQRCode, outputDirectory: root))
        try check(qrGIFResult.message == qrText, "GIF permanece imagem válida para leitura QR")
        let qrGIFPNG = try await backend.perform(.init(inputURL: qrGIFURL, operation: .convert(to: .png), outputDirectory: root))
        try check(NSImage(contentsOf: qrGIFPNG.outputURLs[0]) != nil, "GIF mantém conversões de imagem")

        let qrNSImage = NSImage(contentsOf: qrURL)!
        let qrPDF = PDFDocument()
        qrPDF.insert(PDFPage(image: qrNSImage)!, at: 0)
        qrPDF.documentAttributes = [PDFDocumentAttribute.titleAttribute: "segredo"]
        let qrPDFURL = root.appendingPathComponent("qr.pdf")
        try check(qrPDF.write(to: qrPDFURL), "cria PDF QR de teste")
        let qrPDFResult = try await backend.perform(.init(inputURL: qrPDFURL, operation: .scanQRCode, outputDirectory: root))
        try check(qrPDFResult.message == qrText, "Vision lê QR real de PDF")

        let saturated = try await backend.perform(.init(inputURL: image, operation: .convert(to: .webp), outputDirectory: root, timeout: .greatestFiniteMagnitude))
        try check(saturated.committed, "timeout finito enorme satura sem overflow")
        let webp = try await backend.perform(.init(inputURL: image, operation: .convert(to: .webp), outputDirectory: root))
        try check(webp.committed && webp.outputURLs.count == 1 && webp.outputURLs[0].pathExtension == "webp", "converte PNG real para WEBP com commit explícito")
        let second = try await backend.perform(.init(inputURL: image, operation: .convert(to: .webp), outputDirectory: root))
        try check(second.outputURLs[0] != webp.outputURLs[0], "nunca sobrescreve saída")

        let taggedImage = root.appendingPathComponent("tagged.jpg")
        let croppedImage = try await backend.perform(.init(inputURL: taggedImage, operation: .crop(x: 8, y: 6, width: 32, height: 24), outputDirectory: root))
        let croppedImageStreams = try mediaStreams(croppedImage.outputURLs[0])
        try check(croppedImageStreams.contains("video,32,24"), "cropImage recorta fixture real para 32×24")
        let compressedImage = try await backend.perform(.init(inputURL: taggedImage, operation: .compress(quality: 45), outputDirectory: root))
        let compressedImageStreams = try mediaStreams(compressedImage.outputURLs[0])
        try check(compressedImageStreams.contains("video,64,48"), "compress de imagem preserva dimensões decodificáveis")
        let taggedImageMetadata = try imageMetadata(taggedImage)
        try check(taggedImageMetadata.contains("garime-metadata-marker"), "fixture de imagem contém metadado rastreável")
        let cleanImage = try await backend.perform(.init(inputURL: taggedImage, operation: .removeMetadata, outputDirectory: root))
        let cleanImageMetadata = try imageMetadata(cleanImage.outputURLs[0])
        let cleanImageStreams = try mediaStreams(cleanImage.outputURLs[0])
        try check(!cleanImageMetadata.contains("garime-metadata-marker") && cleanImageStreams.contains("video,64,48"), "removeMetadata de imagem elimina marcador e preserva dimensões")

        let collageInputs = [image, root.appendingPathComponent("green.png"), root.appendingPathComponent("wide.png")]
        let batchKinds = backend.batchCapabilities(for: collageInputs).operations
        try check(batchKinds.count == 2 && batchKinds.contains(where: { $0.rawValue == "merge" }) && batchKinds.contains(where: { $0.rawValue == "collage" }), "capability multi-input anuncia merge e collage de imagens")
        let batchCollage = try await backend.perform(FileToolsBatchRequest(inputURLs: collageInputs, operation: .collage(layout: .horizontal, columns: 2, spacing: 5, background: "transparent"), outputDirectory: root))
        try check(NSImage(contentsOf: batchCollage.outputURLs[0]) != nil, "API batch da UI executa collage transparente")
        for layout in [FileToolsCollageLayout.grid, .row, .column, .featured] {
            let collage = try await backend.perform(.init(inputURLs: collageInputs, operation: .collage(options: .init(layout: layout, canvasWidth: 640, columns: 2, spacing: 7, margin: 11, backgroundHex: "#123456", fit: .cover), format: .png), outputDirectory: root))
            guard let rendered = NSImage(contentsOf: collage.outputURLs[0]) else { throw NSError(domain: "FileToolsTests", code: 14) }
            try check(rendered.size.width == 640 && rendered.size.height > 0, "collage \(layout) renderiza imagens reais")
        }
        let collagePDF = try await backend.perform(.init(inputURLs: collageInputs, operation: .collage(options: .init(layout: .grid), format: .pdf), outputDirectory: root))
        try check(PDFDocument(url: collagePDF.outputURLs[0])?.pageCount == 1, "collage exporta PDF real")
        let imageMerge = try await backend.perform(.init(inputURLs: collageInputs, operation: .merge(to: .pdf), outputDirectory: root))
        try check(PDFDocument(url: imageMerge.outputURLs[0])?.pageCount == 3, "merge imagens cria PDF multipágina em ordem")
        let pdfMerge = try await backend.perform(.init(inputURLs: [imageMerge.outputURLs[0], imageMerge.outputURLs[0]], operation: .merge(to: .pdf), outputDirectory: root))
        try check(PDFDocument(url: pdfMerge.outputURLs[0])?.pageCount == 6, "merge combina PDFs reais")
        let sourcePDF = PDFDocument(url: imageMerge.outputURLs[0])!
        let sourcePageSizes = (0..<sourcePDF.pageCount).map { sourcePDF.page(at: $0)!.bounds(for: .mediaBox).size }
        let splitPDF = try await backend.perform(.init(inputURL: imageMerge.outputURLs[0], operation: .split(segmentDuration: 1), outputDirectory: root))
        let splitPDFSizes = splitPDF.outputURLs.compactMap { PDFDocument(url: $0)?.page(at: 0)?.bounds(for: .mediaBox).size }
        try check(splitPDF.outputURLs.count == 3 && splitPDF.outputURLs.allSatisfy { PDFDocument(url: $0)?.pageCount == 1 } && splitPDFSizes == sourcePageSizes, "splitPDF publica uma página por arquivo preservando dimensões")

        let textURL = root.appendingPathComponent("long-utf8.txt")
        let textPDF = try await backend.perform(.init(inputURL: textURL, operation: .convert(to: .pdf), outputDirectory: root))
        let renderedTextPDF = PDFDocument(url: textPDF.outputURLs[0])
        try check((renderedTextPDF?.pageCount ?? 0) >= 2 && renderedTextPDF?.string?.contains("coração") == true, "TXT UTF-8 vira PDF paginado e pesquisável")
        let textPNG = try await backend.perform(.init(inputURL: textURL, operation: .convert(to: .png), outputDirectory: root))
        try check(textPNG.outputURLs.count >= 2 && textPNG.outputURLs.allSatisfy { NSImage(contentsOf: $0) != nil }, "TXT UTF-8 vira PNGs paginados")
        let textJPG = try await backend.perform(.init(inputURL: textURL, operation: .convert(to: .jpg), outputDirectory: root))
        try check(textJPG.outputURLs.count == textPNG.outputURLs.count && textJPG.outputURLs.allSatisfy { $0.pathExtension == "jpg" }, "TXT UTF-8 vira JPGs paginados")
        do {
            _ = try await backend.perform(.init(inputURL: root.appendingPathComponent("invalid-utf8.txt"), operation: .convert(to: .pdf), outputDirectory: root))
            throw NSError(domain: "FileToolsTests", code: 18)
        } catch FileToolsError.invalidRequest {
            checks += 1
            print("ok - TXT inválido não é aceito como UTF-8")
        }
        do {
            _ = try await backend.perform(.init(inputURL: textURL, operation: .convert(to: .pdf), outputDirectory: root, maximumInputBytes: 10))
            throw NSError(domain: "FileToolsTests", code: 19)
        } catch FileToolsError.outputTooLarge {
            checks += 1
            print("ok - TXT respeita maximumInputBytes")
        }
        do {
            _ = try await backend.perform(.init(inputURL: textURL, operation: .convert(to: .pdf), outputDirectory: root, maximumPages: 1))
            throw NSError(domain: "FileToolsTests", code: 15)
        } catch FileToolsError.outputTooLarge {
            checks += 1
            print("ok - paginação respeita maximumPages")
        }
        do {
            _ = try await backend.perform(.init(inputURLs: collageInputs, operation: .collage(), outputDirectory: root, maximumInputCount: 2))
            throw NSError(domain: "FileToolsTests", code: 16)
        } catch FileToolsError.invalidRequest {
            checks += 1
            print("ok - multi-input respeita maximumInputCount")
        }
        do {
            _ = try await backend.perform(.init(inputURLs: collageInputs, operation: .collage(), outputDirectory: root, maximumImagePixels: 10))
            throw NSError(domain: "FileToolsTests", code: 17)
        } catch FileToolsError.outputTooLarge {
            checks += 1
            print("ok - collage respeita maximumImagePixels")
        }
        do {
            _ = try await backend.perform(.init(inputURLs: collageInputs, operation: .collage(options: .init(layout: .grid, canvasWidth: 7_000, columns: 2), format: .png), outputDirectory: root, maximumImagePixels: 100_000_000))
            throw NSError(domain: "FileToolsTests", code: 26)
        } catch FileToolsError.outputTooLarge {
            checks += 1
            print("ok - collage aplica teto de memória menor que o limite genérico")
        }

        try check(backend.capabilities(for: image).conversionTargets.contains(.docx), "imagem anuncia DOCX quando ZIP do sistema está disponível")
        let imageDOCX = try await backend.perform(.init(inputURL: image, operation: .convert(to: .docx), outputDirectory: root))
        let docxListing = String(decoding: try unzip(["-Z1", imageDOCX.outputURLs[0].path]), as: UTF8.self)
        let docxXML = String(decoding: try unzip(["-p", imageDOCX.outputURLs[0].path, "word/document.xml"]), as: UTF8.self)
        let embeddedPNG = try unzip(["-p", imageDOCX.outputURLs[0].path, "word/media/image1.png"])
        try check(docxListing.contains("word/_rels/document.xml.rels") && docxListing.contains("word/media/image1.png") && docxXML.contains("r:embed=\"rId1\"") && embeddedPNG.starts(with: [0x89, 0x50, 0x4e, 0x47]), "imagem→DOCX gera OOXML ZIP íntegro com PNG realmente incorporado")
        try check(imageDOCX.message?.contains("sem deformação") == true && imageDOCX.message?.contains("não há OCR") == true, "imagem→DOCX declara fidelidade e ausência de OCR")

        let svg = root.appendingPathComponent("fixture.svg")
        let unsafeSVG = root.appendingPathComponent("external.svg")
        try check(backend.capabilities(for: svg).operations.isEmpty && backend.capabilities(for: svg).conversionTargets.isEmpty, "SVG não anuncia capacidade")
        for candidate in [svg, unsafeSVG] {
            do {
                _ = try await backend.perform(.init(inputURL: candidate, operation: .convert(to: .png), outputDirectory: root))
                throw NSError(domain: "FileToolsTests", code: 11, userInfo: [NSLocalizedDescriptionKey: "SVG foi aceito"])
            } catch FileToolsError.unsupported {
                checks += 1
                print("ok - SVG é explicitamente bloqueado na execução")
            }
        }

        let audio = root.appendingPathComponent("fixture.wav")
        let trimmed = try await backend.perform(.init(inputURL: audio, operation: .trim(start: 0.1, duration: 0.25), outputDirectory: root))
        let trimmedSize = try trimmed.outputURLs[0].resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        try check(trimmedSize > 44, "trimAudio produz mídia")
        let taggedAudio = root.appendingPathComponent("tagged.flac")
        let normalized = try await backend.perform(.init(inputURL: taggedAudio, operation: .normalize, outputDirectory: root))
        let normalizedDuration = try mediaDuration(normalized.outputURLs[0])
        let normalizedStreams = try mediaStreams(normalized.outputURLs[0])
        try check((1.0...1.4).contains(normalizedDuration) && normalizedStreams.contains("audio"), "normalizeAudio produz áudio real com duração válida")
        let stereo = try await backend.perform(.init(inputURL: taggedAudio, operation: .channels(2), outputDirectory: root))
        let stereoChannels = try mediaChannels(stereo.outputURLs[0])
        try check(stereoChannels == 2, "audioChannels converte fixture mono real para estéreo")
        do {
            let audioVideo = try await backend.perform(.init(inputURL: taggedAudio, operation: .convert(to: .mp4), outputDirectory: root))
            let audioVideoStreams = try mediaStreams(audioVideo.outputURLs[0])
            let audioVideoDuration = try mediaDuration(audioVideo.outputURLs[0])
            try check(audioVideoStreams.contains("video,1280,720") && audioVideoStreams.contains("audio") && (1.0...1.4).contains(audioVideoDuration), "audioToVideo cria MP4 1280×720 com áudio e duração válida")
        } catch {
            let bug = "audioToVideo falhou em fixture FLAC real: \(error)"
            sourceBugs.append(bug)
            print("not ok - \(bug)")
        }
        let compressedAudio = try await backend.perform(.init(inputURL: taggedAudio, operation: .compress(quality: 40), outputDirectory: root))
        let compressedAudioStreams = try mediaStreams(compressedAudio.outputURLs[0])
        let compressedAudioDuration = try mediaDuration(compressedAudio.outputURLs[0])
        try check(compressedAudio.outputURLs[0].pathExtension == "m4a" && compressedAudioStreams.contains("audio") && (1.0...1.4).contains(compressedAudioDuration), "compress de áudio gera M4A decodificável")
        let taggedAudioMetadata = try mediaMetadata(taggedAudio)
        try check(taggedAudioMetadata.contains("garime-metadata-marker"), "fixture de áudio contém metadado rastreável")
        let cleanAudio = try await backend.perform(.init(inputURL: taggedAudio, operation: .removeMetadata, outputDirectory: root))
        let cleanAudioMetadata = try mediaMetadata(cleanAudio.outputURLs[0])
        let cleanAudioStreams = try mediaStreams(cleanAudio.outputURLs[0])
        try check(!cleanAudioMetadata.contains("garime-metadata-marker") && cleanAudioStreams.contains("audio"), "removeMetadata de áudio elimina marcador e preserva stream")
        let parts = try await backend.perform(.init(inputURL: audio, operation: .split(segmentDuration: 0.2), outputDirectory: root))
        try check(parts.outputURLs.count >= 2 && parts.outputURLs.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }, "split publica segmentos reais, não o padrão percentual")
        let audioMerge = try await backend.perform(.init(inputURLs: [audio, root.appendingPathComponent("fixture2.wav")], operation: .merge(to: .wav), outputDirectory: root, maximumOutputBytes: 250_000))
        let audioMergeDuration = try mediaDuration(audioMerge.outputURLs[0])
        try check(audioMergeDuration > 1.8, "concatena áudios sem cobrar snapshots no orçamento de saída")
        let videoMerge = try await backend.perform(.init(inputURLs: [root.appendingPathComponent("silent.mp4"), root.appendingPathComponent("silent2.mp4")], operation: .merge(to: .mp4), outputDirectory: root))
        let videoMergeDuration = try mediaDuration(videoMerge.outputURLs[0])
        try check(videoMergeDuration > 1.8, "concatena vídeos reais")
        let heterogeneousMerge = try await backend.perform(.init(inputURLs: [root.appendingPathComponent("heterogeneous-audio.mp4"), root.appendingPathComponent("silent.mp4")], operation: .merge(to: .mov), outputDirectory: root))
        let heterogeneousStreams = try mediaStreams(heterogeneousMerge.outputURLs[0])
        let heterogeneousDuration = try mediaDuration(heterogeneousMerge.outputURLs[0])
        try check(heterogeneousDuration > 1.8 && heterogeneousStreams.contains("video,64,48") && heterogeneousStreams.contains("audio"), "merge MOV normaliza dimensões/fps e preenche silêncio sem descartar áudio")

        let mp4MOV = try await backend.perform(.init(inputURL: root.appendingPathComponent("silent.mp4"), operation: .convert(to: .mov), outputDirectory: root))
        let mp4MOVDuration = try mediaDuration(mp4MOV.outputURLs[0])
        try check(mp4MOV.outputURLs[0].pathExtension == "mov" && mp4MOVDuration > 0.9, "MP4 exporta MOV real")
        let mkv = try await backend.perform(.init(inputURL: root.appendingPathComponent("fixture.mov"), operation: .convert(to: .mkv), outputDirectory: root))
        let mkvMOV = try await backend.perform(.init(inputURL: mkv.outputURLs[0], operation: .convert(to: .mov), outputDirectory: root))
        let mkvMOVDuration = try mediaDuration(mkvMOV.outputURLs[0])
        try check(mkvMOVDuration > 0.9, "MKV exporta MOV real")
        let gif = root.appendingPathComponent("fixture.gif")
        for format in [FileToolsFormat.mp4, .mov, .mkv] {
            let result = try await backend.perform(.init(inputURL: gif, operation: .convert(to: format), outputDirectory: root))
            let duration = try mediaDuration(result.outputURLs[0])
            try check(result.outputURLs[0].pathExtension == format.rawValue && duration > 0.7, "GIF exporta \(format.rawValue.uppercased()) real")
        }

        let taggedVideo = root.appendingPathComponent("tagged.mp4")
        let croppedVideo = try await backend.perform(.init(inputURL: taggedVideo, operation: .crop(x: 8, y: 6, width: 32, height: 24), outputDirectory: root))
        let croppedVideoStreams = try mediaStreams(croppedVideo.outputURLs[0])
        try check(croppedVideoStreams.contains("video,32,24") && croppedVideoStreams.contains("audio"), "cropVideo recorta para 32×24 e preserva áudio")
        let mutedVideo = try await backend.perform(.init(inputURL: taggedVideo, operation: .mute, outputDirectory: root))
        let mutedStreams = try mediaStreams(mutedVideo.outputURLs[0])
        try check(mutedStreams.contains("video,64,48") && !mutedStreams.contains("audio"), "muteVideo remove faixa de áudio e preserva vídeo")
        let trimmedVideo = try await backend.perform(.init(inputURL: taggedVideo, operation: .trim(start: 0.2, duration: 0.45), outputDirectory: root))
        let trimmedVideoDuration = try mediaDuration(trimmedVideo.outputURLs[0])
        let trimmedVideoStreams = try mediaStreams(trimmedVideo.outputURLs[0])
        try check((0.35...0.65).contains(trimmedVideoDuration) && trimmedVideoStreams.contains("video,64,48"), "trimVideo respeita intervalo em fixture real")
        let snapshot = try await backend.perform(.init(inputURL: taggedVideo, operation: .snapshot(time: 0.4), outputDirectory: root))
        let snapshotStreams = try mediaStreams(snapshot.outputURLs[0])
        try check(snapshot.outputURLs[0].pathExtension == "png" && snapshotStreams.contains("video,64,48"), "videoSnapshots extrai quadro PNG nas dimensões do vídeo")
        let videoParts = try await backend.perform(.init(inputURL: taggedVideo, operation: .split(segmentDuration: 0.35), outputDirectory: root))
        let splitDuration = try videoParts.outputURLs.reduce(0.0) { $0 + (try mediaDuration($1)) }
        try check(videoParts.outputURLs.count >= 2 && splitDuration >= 1.0 && videoParts.outputURLs.allSatisfy { (try? mediaStreams($0).contains("video,64,48")) == true }, "splitVideo publica múltiplos segmentos reproduzíveis por ffprobe")
        let compressedVideo = try await backend.perform(.init(inputURL: taggedVideo, operation: .compress(quality: 45), outputDirectory: root))
        let compressedVideoStreams = try mediaStreams(compressedVideo.outputURLs[0])
        let compressedVideoDuration = try mediaDuration(compressedVideo.outputURLs[0])
        try check(compressedVideoStreams.contains("video,64,48") && compressedVideoStreams.contains("audio") && (1.0...1.4).contains(compressedVideoDuration), "compress de vídeo preserva dimensões, áudio e duração")
        let taggedVideoMetadata = try mediaMetadata(taggedVideo)
        try check(taggedVideoMetadata.contains("garime-metadata-marker"), "fixture de vídeo contém metadado rastreável")
        let cleanVideo = try await backend.perform(.init(inputURL: taggedVideo, operation: .removeMetadata, outputDirectory: root))
        let cleanVideoMetadata = try mediaMetadata(cleanVideo.outputURLs[0])
        let cleanVideoStreams = try mediaStreams(cleanVideo.outputURLs[0])
        try check(!cleanVideoMetadata.contains("garime-metadata-marker") && cleanVideoStreams.contains("video,64,48"), "removeMetadata de vídeo elimina marcador e preserva dimensões")

        let sped = try await backend.perform(.init(inputURL: root.appendingPathComponent("silent.mp4"), operation: .speed(2), outputDirectory: root))
        try check(sped.outputURLs.count == 1, "changeVideoSpeed aceita vídeo sem faixa de áudio")

        let gifCaps = backend.capabilities(for: URL(fileURLWithPath: "/tmp/a.gif"))
        let heifCaps = backend.capabilities(for: URL(fileURLWithPath: "/tmp/a.heif"))
        let aiffCaps = backend.capabilities(for: URL(fileURLWithPath: "/tmp/a.aiff"))
        let cafCaps = backend.capabilities(for: URL(fileURLWithPath: "/tmp/a.caf"))
        try check(gifCaps.operations.contains(.scanQRCode) && heifCaps.operations.contains(.crop) && aiffCaps.operations.contains(.normalize) && cafCaps.operations.contains(.channels), "extensões GIF/HEIF/AIFF/CAF alinham com famílias da UI")
        try check(gifCaps.conversionTargets.contains(.jpg) && gifCaps.conversionTargets.contains(.mov) && gifCaps.conversionTargets.contains(.mkv) && !gifCaps.conversionTargets.contains(.mp3), "GIF anuncia vídeo sem perder destinos de imagem")

        let cleanPDF = try await backend.perform(.init(inputURL: qrPDFURL, operation: .removeMetadata, outputDirectory: root))
        let cleanedDocument = PDFDocument(url: cleanPDF.outputURLs[0])!
        try check(cleanedDocument.documentAttributes?[PDFDocumentAttribute.titleAttribute] == nil, "remoção de metadados PDF regrava sem título")

        if backend.capabilities(for: qrPDFURL).conversionTargets.contains(.docx) {
            let docx = try await backend.perform(.init(inputURL: qrPDFURL, operation: .convert(to: .docx), outputDirectory: root))
            try check(docx.outputURLs[0].pathExtension == "docx" && docx.message?.contains("layout") == true, "PDF→DOCX é real e declara limite de layout")
        }
        if backend.capabilities(for: qrPDFURL).operations.contains(.compress) {
            setenv("GS_OPTIONS", "-dLastPage=0 -dNOSAFER", 1)
            let compressed = try await backend.perform(.init(inputURL: qrPDFURL, operation: .compress(quality: 70), outputDirectory: root))
            unsetenv("GS_OPTIONS")
            let originalSize = try qrPDFURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            let compressedSize = try compressed.outputURLs[0].resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            try check(PDFDocument(url: compressed.outputURLs[0])?.pageCount == 1 && compressedSize <= originalSize, "Ghostscript usa SAFER, ignora GS_OPTIONS e nunca publica crescimento silencioso")
            if compressedSize == originalSize { try check(compressed.message?.contains("original foi preservado") == true, "compressão PDF explica preservação do original") }
        }

        let leadingDash = root.appendingPathComponent("-leading.txt")
        let leadingArchive = try await backend.perform(.init(inputURL: leadingDash, operation: .convert(to: .tar), outputDirectory: root))
        try check(leadingArchive.committed && leadingArchive.outputURLs[0].pathExtension == "tar", "TAR trata basename iniciado por hífen como caminho")

        let directoryCapabilities = backend.capabilities(for: root.appendingPathComponent("deep", isDirectory: true))
        try check(directoryCapabilities.operations == [.convert] && directoryCapabilities.conversionTargets.contains(.tar) && !directoryCapabilities.conversionTargets.contains(.gzip) && !directoryCapabilities.conversionTargets.contains(.zip), "diretório anuncia somente conversões aceitas pelo backend")

        let archive = root.appendingPathComponent("safe.tar")
        let extracted = try await backend.perform(.init(inputURL: archive, operation: .extract, outputDirectory: root))
        try check(extracted.committed && FileManager.default.fileExists(atPath: extracted.outputURLs[0].appendingPathComponent("inside.txt").path), "extrai TAR seguro em transação publicada")
        let safeZIP = root.appendingPathComponent("safe.zip")
        let extractedZIP = try await backend.perform(.init(inputURL: safeZIP, operation: .extract, outputDirectory: root))
        try check(FileManager.default.fileExists(atPath: extractedZIP.outputURLs[0].appendingPathComponent("inside.txt").path), "extrai ZIP seguro em transação publicada")
        let convertedZIP = try await backend.perform(.init(inputURL: archive, operation: .convert(to: .zip), outputDirectory: root))
        let convertedZIPListing = String(decoding: try unzip(["-Z1", convertedZIP.outputURLs[0].path]), as: UTF8.self)
        try check(convertedZIP.outputURLs[0].pathExtension == "zip" && convertedZIPListing.split(separator: "\n").contains("inside.txt"), "TAR exporta ZIP real com conteúdo extraído")
        let zippedFile = try await backend.perform(.init(inputURL: leadingDash, operation: .convert(to: .zip), outputDirectory: root))
        let zippedFileListing = String(decoding: try unzip(["-Z1", zippedFile.outputURLs[0].path]), as: UTF8.self)
        try check(zippedFileListing.contains("-leading.txt"), "ZIP usa snapshot por FD e trata nome iniciado por hífen")

        for hostile in ["traversal.zip", "symlink.zip"] {
            do {
                _ = try await backend.perform(.init(inputURL: root.appendingPathComponent(hostile), operation: .extract, outputDirectory: root))
                throw NSError(domain: "FileToolsTests", code: 21, userInfo: [NSLocalizedDescriptionKey: "ZIP hostil foi aceito"])
            } catch FileToolsError.unsafeArchive {
                checks += 1
                print("ok - bloqueia ZIP hostil \(hostile)")
            }
        }

        let fifoStarted = Date()
        do {
            _ = try await backend.perform(.init(inputURL: root.appendingPathComponent("source-fifo.tar"), operation: .extract, outputDirectory: root, timeout: 1))
            throw NSError(domain: "FileToolsTests", code: 8, userInfo: [NSLocalizedDescriptionKey: "FIFO de origem foi aceito"])
        } catch FileToolsError.unsafeArchive {
            try check(Date().timeIntervalSince(fifoStarted) < 0.5, "rejeita FIFO de origem sem bloqueio")
        }
        do {
            _ = try await backend.perform(.init(inputURL: root.appendingPathComponent("source-link.tar"), operation: .extract, outputDirectory: root))
            throw NSError(domain: "FileToolsTests", code: 9, userInfo: [NSLocalizedDescriptionKey: "symlink de origem foi aceito"])
        } catch FileToolsError.unsafeArchive {
            checks += 1
            print("ok - rejeita symlink de origem com O_NOFOLLOW")
        }

        do {
            _ = try await backend.perform(.init(inputURL: root.appendingPathComponent("traversal.tar"), operation: .extract, outputDirectory: root))
            throw NSError(domain: "FileToolsTests", code: 2, userInfo: [NSLocalizedDescriptionKey: "travessia foi aceita"])
        } catch FileToolsError.unsafeArchive {
            checks += 1
            print("ok - bloqueia path traversal")
        }

        for (name, request, label) in [
            ("fifo", FileToolsRequest(inputURL: root.appendingPathComponent("fifo.tar"), operation: .extract, outputDirectory: root), "bloqueia FIFO"),
            ("depth", FileToolsRequest(inputURL: root.appendingPathComponent("deep.tar"), operation: .extract, outputDirectory: root, maximumArchiveDepth: 2), "limita profundidade"),
            ("members", FileToolsRequest(inputURL: root.appendingPathComponent("deep.tar"), operation: .extract, outputDirectory: root, maximumArchiveMembers: 2), "limita membros"),
        ] {
            do {
                _ = try await backend.perform(request)
                throw NSError(domain: "FileToolsTests", code: 4, userInfo: [NSLocalizedDescriptionKey: "\(name) foi aceito"])
            } catch FileToolsError.unsafeArchive {
                checks += 1
                print("ok - \(label)")
            }
        }
        do {
            _ = try await backend.perform(.init(inputURL: root.appendingPathComponent("large.tar"), operation: .extract, outputDirectory: root, maximumOutputBytes: 8))
            throw NSError(domain: "FileToolsTests", code: 5, userInfo: [NSLocalizedDescriptionKey: "expanded limit foi aceito"])
        } catch FileToolsError.outputTooLarge {
            checks += 1
            print("ok - limita bytes expandidos")
        }

        let bombProbe = WorkspaceByteProbe()
        let bombProbeTask = Task.detached {
            while !bombProbe.shouldStop {
                bombProbe.sample()
                usleep(5_000)
            }
            bombProbe.sample()
        }
        let bombStarted = Date()
        var bombWasRejected = false
        do {
            _ = try await backend.perform(.init(inputURL: root.appendingPathComponent("bomb.gz"), operation: .extract, outputDirectory: root, timeout: 5, maximumOutputBytes: 1_048_576))
        } catch FileToolsError.outputTooLarge {
            bombWasRejected = true
        } catch {
            bombProbe.stop()
            await bombProbeTask.value
            throw error
        }
        bombProbe.stop()
        await bombProbeTask.value
        try check(bombWasRejected && Date().timeIntervalSince(bombStarted) < 2 && bombProbe.maximumBytes < 268_435_456, "GZIP bomb é interrompido com bytes e tempo transitórios limitados")

        let cancelDestination = root.appendingPathComponent("cancel-output", isDirectory: true)
        try FileManager.default.createDirectory(at: cancelDestination, withIntermediateDirectories: true)
        let stubborn = FileToolsBackend(ffmpegURL: root.appendingPathComponent("stubborn-ffmpeg"))
        let started = Date()
        let cancellationTask = Task {
            try await stubborn.perform(.init(inputURL: image, operation: .crop(x: 0, y: 0, width: 4, height: 4), outputDirectory: cancelDestination, timeout: 20))
        }
        try await Task.sleep(for: .milliseconds(200))
        cancellationTask.cancel()
        do {
            _ = try await cancellationTask.value
            throw NSError(domain: "FileToolsTests", code: 6, userInfo: [NSLocalizedDescriptionKey: "cancelamento retornou sucesso"])
        } catch FileToolsError.cancelled {
            let files = try FileManager.default.contentsOfDirectory(at: cancelDestination, includingPropertiesForKeys: nil)
            try check(Date().timeIntervalSince(started) < 2 && files.isEmpty, "cancelamento escala para SIGKILL e não publica")
        }

        let descendantDestination = root.appendingPathComponent("descendant-output", isDirectory: true)
        try FileManager.default.createDirectory(at: descendantDestination, withIntermediateDirectories: true)
        let descendant = FileToolsBackend(ffmpegURL: root.appendingPathComponent("descendant-ffmpeg"))
        let descendantStarted = Date()
        let descendantResult = try await descendant.perform(.init(inputURL: image, operation: .crop(x: 0, y: 0, width: 4, height: 4), outputDirectory: descendantDestination, timeout: 2))
        try check(descendantResult.committed && Date().timeIntervalSince(descendantStarted) < 1.5, "retorna sem esperar descendente que reteve pipes")

        do {
            _ = try await backend.perform(.init(inputURL: image, operation: .convert(to: .rar), outputDirectory: root))
            throw NSError(domain: "FileToolsTests", code: 3, userInfo: [NSLocalizedDescriptionKey: "RAR sem encoder foi aceito"])
        } catch FileToolsError.unsupported {
            checks += 1
            print("ok - RAR encode é explicitamente bloqueado sem encoder")
        }
        print("FileTools: \(checks) checks passaram")
        if !sourceBugs.isEmpty {
            throw NSError(domain: "FileToolsTests", code: 30, userInfo: [NSLocalizedDescriptionKey: sourceBugs.joined(separator: "\n")])
        }
    }
}
