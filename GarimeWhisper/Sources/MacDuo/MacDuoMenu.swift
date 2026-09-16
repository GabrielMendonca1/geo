import AppKit
import Foundation


enum MacDuoMenuAction: Equatable {
    case toggleEffect
    case pause
    case selectEffect(MacDuoEffect)
    case toggleDwell
    case selectDwell(Int)
    case retrySensor
    case openPrivacy
    case openSettings
}

struct MacDuoMenuState: Equatable {
    var started = false
    var enabled = false
    var checkingPermission = false
    var waitingForSensor = false
    var sensorAvailable = false
    var hasPermission = false
    var lidAngle: Double?
    var effect = MacDuoEffect.fallback
    var dwellEnabled = true
    var dwellSeconds: Double = 2
    var overlayVisible = false
    var status = "Mac Duo está desligado."
    var fps = 60
    var lowPower = false
    var thermalPressure = false

    static let idle = MacDuoMenuState()
}

struct MacDuoMenuItem: Equatable {
    enum Kind: Equatable { case separator, info, command, toggle, radio }

    var kind: Kind = .command
    var title: String = ""
    var action: MacDuoMenuAction?
    var checked = false
    var isEnabled = true
    var indent = 0

    static let separator = MacDuoMenuItem(kind: .separator, title: "", action: nil, isEnabled: false)
}

enum MacDuoMenuStatus {
    static let dwellChoices = [1, 2, 3, 4, 5]

    static func dwellSelection(_ seconds: Double) -> Int {
        guard seconds.isFinite else { return 2 }
        return min(5, max(1, Int(seconds.rounded())))
    }

    static func toggleTitle(enabled: Bool, checking: Bool, waitingForSensor: Bool = false) -> String {
        if checking { return "Ativando efeito da tampa…" }
        if waitingForSensor { return "Procurando o sensor da tampa…" }
        return enabled ? "Efeito da tampa ativo" : "Ativar efeito da tampa"
    }

    static func cancelTitle(waitingForSensor: Bool) -> String {
        waitingForSensor ? "Cancelar a procura" : "Pausar"
    }

    static func angleLine(_ angle: Double?) -> String {
        guard let angle, angle.isFinite else { return "Ângulo: —" }
        return "Ângulo: \(Int(angle.rounded()))°"
    }

    static func sensorLine(available: Bool, angle: Double?) -> String {
        guard available else { return "Sensor da tampa: indisponível" }
        return "Sensor da tampa: ok · \(angleLine(angle))"
    }

    static func permissionLine(hasPermission: Bool, checking: Bool) -> String {
        if checking { return "Gravação de tela: verificando…" }
        return hasPermission ? "Gravação de tela: concedida" : "Gravação de tela: pendente"
    }

    static func energyLine(fps: Int, lowPower: Bool, thermalPressure: Bool) -> String {
        var notes: [String] = ["\(max(1, fps)) Hz"]
        if lowPower { notes.append("baixo consumo") }
        if thermalPressure { notes.append("pressão térmica") }
        return "Energia: " + notes.joined(separator: " · ")
    }
}

enum MacDuoMenuPolicy {
    static let opensSettingsOnEnable = false

    static func touchesScreenCapture(action: MacDuoMenuAction, state: MacDuoMenuState) -> Bool {
        switch action {
        case .toggleEffect: return !state.enabled
        case .pause, .selectEffect, .toggleDwell, .selectDwell, .retrySensor, .openPrivacy, .openSettings:
            return false
        }
    }

    static func opensWindow(action: MacDuoMenuAction) -> Bool {
        switch action {
        case .openSettings, .openPrivacy: return true
        default: return false
        }
    }
}

enum MacDuoMenuPlan {
    static func items(for state: MacDuoMenuState) -> [MacDuoMenuItem] {
        var items: [MacDuoMenuItem] = []
        let busy = state.checkingPermission
        let waiting = state.waitingForSensor && !busy

        items.append(MacDuoMenuItem(kind: .toggle,
                                    title: MacDuoMenuStatus.toggleTitle(enabled: state.enabled, checking: busy,
                                                                        waitingForSensor: waiting),
                                    action: waiting ? .pause : .toggleEffect,
                                    checked: state.enabled,
                                    isEnabled: !busy))
        items.append(MacDuoMenuItem(kind: .command,
                                    title: MacDuoMenuStatus.cancelTitle(waitingForSensor: waiting),
                                    action: .pause,
                                    isEnabled: state.enabled || busy || waiting || state.overlayVisible))

        items.append(.separator)
        items.append(MacDuoMenuItem(kind: .info, title: "Efeito", isEnabled: false))
        for effect in MacDuoEffect.allCases {
            items.append(MacDuoMenuItem(kind: .radio, title: effect.title,
                                        action: .selectEffect(effect),
                                        checked: effect == state.effect,
                                        indent: 1))
        }

        items.append(.separator)
        items.append(MacDuoMenuItem(kind: .toggle, title: "Limpar a tela em repouso",
                                    action: .toggleDwell,
                                    checked: state.dwellEnabled))
        let selected = MacDuoMenuStatus.dwellSelection(state.dwellSeconds)
        for seconds in MacDuoMenuStatus.dwellChoices {
            items.append(MacDuoMenuItem(kind: .radio, title: "\(seconds) s",
                                        action: .selectDwell(seconds),
                                        checked: state.dwellEnabled && seconds == selected,
                                        isEnabled: state.dwellEnabled,
                                        indent: 1))
        }

        items.append(.separator)
        items.append(MacDuoMenuItem(kind: .info, title: state.status, isEnabled: false))
        items.append(MacDuoMenuItem(kind: .info,
                                    title: MacDuoMenuStatus.sensorLine(available: state.sensorAvailable, angle: state.lidAngle),
                                    isEnabled: false))
        if !state.sensorAvailable {
            items.append(MacDuoMenuItem(kind: .command, title: "Procurar o sensor de novo",
                                        action: .retrySensor, indent: 1))
        }
        items.append(MacDuoMenuItem(kind: .info,
                                    title: MacDuoMenuStatus.permissionLine(hasPermission: state.hasPermission,
                                                                           checking: state.checkingPermission),
                                    isEnabled: false))
        if !state.hasPermission {
            items.append(MacDuoMenuItem(kind: .command, title: "Abrir Gravação de Tela…",
                                        action: .openPrivacy, indent: 1))
        }
        items.append(MacDuoMenuItem(kind: .info,
                                    title: MacDuoMenuStatus.energyLine(fps: state.fps, lowPower: state.lowPower,
                                                                       thermalPressure: state.thermalPressure),
                                    isEnabled: false))

        items.append(.separator)
        items.append(MacDuoMenuItem(kind: .command, title: "Ajustes do Mac Duo…", action: .openSettings))
        return items
    }
}

final class MacDuoMenuActionBox: NSObject {
    let action: MacDuoMenuAction

    init(_ action: MacDuoMenuAction) {
        self.action = action
        super.init()
    }
}

@MainActor final class MacDuoMenu: NSObject {
    private let perform: (MacDuoMenuAction) -> Void

    init(perform: @escaping (MacDuoMenuAction) -> Void) {
        self.perform = perform
        super.init()
    }

    func items(for state: MacDuoMenuState) -> [NSMenuItem] {
        var index = 0
        return MacDuoMenuPlan.items(for: state).map { descriptor in
            let item = make(descriptor, tag: index)
            if item.action != nil { index += 1 }
            return item
        }
    }

    func submenuItem(for state: MacDuoMenuState, title: String = "Mac Duo") -> NSMenuItem {
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        menu.autoenablesItems = false
        for item in items(for: state) { menu.addItem(item) }
        parent.submenu = menu
        return parent
    }

    private func make(_ descriptor: MacDuoMenuItem, tag: Int) -> NSMenuItem {
        if descriptor.kind == .separator { return NSMenuItem.separator() }
        let item = NSMenuItem(title: descriptor.title, action: nil, keyEquivalent: "")
        item.indentationLevel = descriptor.indent
        item.state = descriptor.checked ? .on : .off
        item.isEnabled = descriptor.isEnabled && descriptor.action != nil
        if let action = descriptor.action, descriptor.isEnabled {
            item.target = self
            item.action = #selector(fire(_:))
            item.tag = tag
            item.representedObject = MacDuoMenuActionBox(action)
        }
        return item
    }

    @objc private func fire(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? MacDuoMenuActionBox else { return }
        perform(box.action)
    }
}
