import SwiftUI

@main
struct GarimeApp: App {
    init() {
        #if DEBUG
        // Simulador: `-geoBridgeToken <token>` usa o token só nesta execução, para testes visuais.
        if let index = CommandLine.arguments.firstIndex(of: "-geoBridgeToken"),
           index + 1 < CommandLine.arguments.count {
            BridgeConfig.debugTokenOverride = CommandLine.arguments[index + 1]
        }
        if let index = CommandLine.arguments.firstIndex(of: "-geoBridgeTermToken"),
           index + 1 < CommandLine.arguments.count {
            BridgeConfig.debugTermTokenOverride = CommandLine.arguments[index + 1]
        }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}
