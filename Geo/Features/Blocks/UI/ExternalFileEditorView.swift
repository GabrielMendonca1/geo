import SwiftUI
import AppKit

struct ExternalFileEditorView: View {
    let url: URL

    @StateObject private var model: ExternalFileEditorModel
    @State private var window: NSWindow?
    @State private var closeObserver: NSObjectProtocol?

    init(url: URL) {
        self.url = url
        _model = StateObject(wrappedValue: ExternalFileEditorModel(url: url))
    }

    var body: some View {
        Group {
            if let document = model.document {
                BlockListView(
                    document: document,
                    contentBaseURL: url.deletingLastPathComponent()
                )
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Palette.background.ignoresSafeArea())
        .background(WindowReflection(window: $window))
        .navigationTitle(url.deletingPathExtension().lastPathComponent)
        .onAppear { model.load() }
        .onDisappear {
            model.flush()
            if let closeObserver {
                NotificationCenter.default.removeObserver(closeObserver)
            }
        }
        .onChange(of: window) { _, newValue in
            configureWindow(newValue)
        }
    }

    private func configureWindow(_ window: NSWindow?) {
        guard let window else { return }
        if let closeObserver {
            NotificationCenter.default.removeObserver(closeObserver)
        }
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { _ in
            model.flush()
        }
    }
}

@MainActor
final class ExternalFileEditorModel: ObservableObject {
    private let url: URL
    @Published private(set) var document: BlockEditorDocument?

    private var autosave: DispatchWorkItem?
    private var lastWritten: String?
    private var modificationDate: Date?
    private var watcher: FileWatcherService?

    init(url: URL) {
        self.url = url
    }

    func load() {
        guard document == nil else { return }
        let contents = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        modificationDate = diskModificationDate()
        lastWritten = contents
        let doc = BlockEditorDocument(markdown: contents)
        doc.seedEmptyParagraphIfNeeded()
        doc.onDirty = { [weak self] in self?.scheduleSave() }
        document = doc
        startWatching()
    }

    private func scheduleSave() {
        autosave?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.save() }
        autosave = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: item)
    }

    func flush() {
        autosave?.cancel()
        autosave = nil
        save()
    }

    private func save() {
        guard let document else { return }
        let markdown = document.serialize()
        guard markdown != lastWritten else { return }

        if let modificationDate, let onDisk = diskModificationDate(), onDisk > modificationDate {
            reloadFromDisk()
            return
        }

        guard (try? markdown.write(to: url, atomically: true, encoding: .utf8)) != nil else { return }
        lastWritten = markdown
        modificationDate = diskModificationDate()
    }

    private func reloadFromDisk() {
        guard let document else { return }
        let contents = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        document.loadMarkdown(contents)
        document.seedEmptyParagraphIfNeeded()
        lastWritten = contents
        modificationDate = diskModificationDate()
    }

    private func startWatching() {
        let service = FileWatcherService(url: url.deletingLastPathComponent())
        service.onChange = { [weak self] (_: [URL]) in
            Task { @MainActor [weak self] in
                self?.handleExternalChange()
            }
        }
        service.start()
        watcher = service
    }

    private func handleExternalChange() {
        guard let document else { return }
        guard let onDisk = diskModificationDate() else { return }
        guard let modificationDate, onDisk > modificationDate else { return }
        let contents = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        guard contents != document.serialize() else {
            self.modificationDate = onDisk
            return
        }
        reloadFromDisk()
    }

    private func diskModificationDate() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
    }
}
