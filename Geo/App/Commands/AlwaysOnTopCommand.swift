import SwiftUI

struct AlwaysOnTopCommand: Commands {
    var body: some Commands {
        CommandGroup(after: .windowArrangement) {
            AlwaysOnTopCheckbox("Toggle Always on Top")
        }
    }
}

struct AlwaysOnTopCheckbox: View {
    let title: LocalizedStringKey
    @AppStorage(AlwaysOnTop.settingsKey) var isAlwaysOnTop: Bool = false

    init(_ title: LocalizedStringKey = "Always on top") {
        self.title = title
    }

    var body: some View {
        Toggle(title, isOn: $isAlwaysOnTop)
    }
}
