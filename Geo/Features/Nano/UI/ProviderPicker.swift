import SwiftUI

struct ProviderPicker: View {
    @ObservedObject var store: NanoProviderStore

    var body: some View {
        Picker("", selection: Binding(
            get: { store.current },
            set: { store.setProvider($0) }
        )) {
            ForEach(NanoProvider.allCases) { provider in
                Text(provider.label).tag(provider)
            }
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: 200)
        .labelsHidden()
    }
}
