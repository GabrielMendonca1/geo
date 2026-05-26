import SwiftUI

struct SettingsWindow: View {
    var body: some View {
        GeneralSettingsView()
            .frame(minWidth: 760, minHeight: 560)
    }

    static func show() {
        if NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) {
            return
        }
        NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
    }
}

struct SettingsWindow_Previews: PreviewProvider {
    static var previews: some View {
        SettingsWindow()
            .environment(\.appEnvironment, AppContainer.live.environment)
    }
}
