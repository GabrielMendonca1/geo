import SwiftUI
import Sparkle

final class UpdaterViewModel: ObservableObject {
    @Published var canCheckForUpdates = false

    init(updater: SPUUpdater) {
        updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheckForUpdates)
    }
}

struct CheckForUpdatesCommand: Commands {
    let updater: SPUUpdater

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            CheckForUpdatesButton(updater: updater)
        }
    }
}

struct CheckForUpdatesButton: View {
    @StateObject private var model: UpdaterViewModel
    private let updater: SPUUpdater

    init(updater: SPUUpdater) {
        self.updater = updater
        _model = StateObject(wrappedValue: UpdaterViewModel(updater: updater))
    }

    var body: some View {
        Button("Check for Updates…", action: updater.checkForUpdates)
            .disabled(!model.canCheckForUpdates)
    }
}
