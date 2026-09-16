import AppKit
import Foundation

// Menu contract for Mac Duo. Nothing here starts the sensor, the capture or a window:
// every check runs against the pure plan, the pure policy or plain NSMenuItem objects.

var passes = 0
var failures = 0

func check(_ condition: Bool, _ label: String) {
    if condition {
        passes += 1
        print("  ok   \(label)")
    } else {
        failures += 1
        print("  FAIL \(label)")
    }
}

func equal<T: Equatable>(_ lhs: T, _ rhs: T, _ label: String) {
    check(lhs == rhs, "\(label) [got: \(lhs)]")
}

func actions(_ items: [MacDuoMenuItem]) -> [MacDuoMenuAction] { items.compactMap(\.action) }

func item(_ items: [MacDuoMenuItem], action: MacDuoMenuAction) -> MacDuoMenuItem? {
    items.first { $0.action == action }
}

print("== 1. plan shape ==")
do {
    let items = MacDuoMenuPlan.items(for: .idle)
    check(item(items, action: .toggleEffect) != nil, "the menu carries the enable toggle")
    check(item(items, action: .pause) != nil, "the menu carries pause")
    equal(items.filter { if case .selectEffect = $0.action { return true } else { return false } }.count, 5,
          "all five effects are selectable from the menu")
    equal(MacDuoEffect.allCases.map { MacDuoMenuAction.selectEffect($0) }
            .allSatisfy { action in actions(items).contains(action) }, true,
          "every effect of the catalog has its own item")
    equal(items.filter { if case .selectDwell = $0.action { return true } else { return false } }.count, 5,
          "the dwell offers one through five seconds")
    equal(MacDuoMenuStatus.dwellChoices, [1, 2, 3, 4, 5], "the dwell choices are the clamped range of the model")
    check(item(items, action: .toggleDwell) != nil, "the dwell itself can be turned off")
    check(item(items, action: .openSettings) != nil, "settings stay available, as a secondary item")
    check(items.contains { $0.kind == .separator }, "the plan is grouped with separators")
    check(items.allSatisfy { $0.kind == .separator || !$0.title.isEmpty }, "no item ships without a title")
    check(items.filter { $0.kind == .info }.allSatisfy { $0.action == nil && !$0.isEnabled },
          "status lines are inert")
}

print("== 2. enable and pause ==")
do {
    let off = MacDuoMenuPlan.items(for: .idle)
    let toggle = item(off, action: .toggleEffect)!
    check(!toggle.checked, "an off module shows an unchecked toggle")
    check(toggle.isEnabled, "the toggle is usable while the module is off")
    equal(toggle.title, "Ativar efeito da tampa", "the off title invites turning the effect on")
    check(!(item(off, action: .pause)?.isEnabled ?? true), "pause is dimmed when there is nothing to pause")

    var on = MacDuoMenuState.idle
    on.started = true
    on.enabled = true
    on.sensorAvailable = true
    on.hasPermission = true
    let running = MacDuoMenuPlan.items(for: on)
    check(item(running, action: .toggleEffect)!.checked, "the running effect is checked in the menu")
    check(item(running, action: .pause)!.isEnabled, "pause is live while the effect runs")

    var checking = MacDuoMenuState.idle
    checking.checkingPermission = true
    let busy = MacDuoMenuPlan.items(for: checking)
    check(!item(busy, action: .toggleEffect)!.isEnabled, "the toggle is dimmed while the permission check runs")
    equal(item(busy, action: .toggleEffect)!.title, "Ativando efeito da tampa…", "the toggle reports the pending check")
    check(item(busy, action: .pause)!.isEnabled, "a pending check can always be cancelled with pause")
}

print("== 3. effect and dwell selection ==")
do {
    var state = MacDuoMenuState.idle
    state.effect = .iris
    let items = MacDuoMenuPlan.items(for: state)
    let checkedEffects = items.filter { if case .selectEffect = $0.action { return $0.checked } else { return false } }
    equal(checkedEffects.count, 1, "exactly one effect is checked")
    equal(checkedEffects.first?.title, MacDuoEffect.iris.title, "the checked effect is the selected one")

    state.dwellSeconds = 3
    let dwell = MacDuoMenuPlan.items(for: state)
        .filter { if case .selectDwell = $0.action { return true } else { return false } }
    equal(dwell.filter(\.checked).count, 1, "exactly one dwell is checked")
    equal(dwell.first(where: \.checked)?.action, .selectDwell(3), "the checked dwell matches the model value")
    check(dwell.allSatisfy(\.isEnabled), "dwell steps are usable while the dwell is on")

    state.dwellEnabled = false
    let offDwell = MacDuoMenuPlan.items(for: state)
        .filter { if case .selectDwell = $0.action { return true } else { return false } }
    check(offDwell.allSatisfy { !$0.isEnabled && !$0.checked }, "turning the dwell off dims its steps")

    equal(MacDuoMenuStatus.dwellSelection(2.4), 2, "a fractional dwell rounds to a menu step")
    equal(MacDuoMenuStatus.dwellSelection(0), 1, "the dwell selection is clamped low, like the model")
    equal(MacDuoMenuStatus.dwellSelection(99), 5, "the dwell selection is clamped high, like the model")
    equal(MacDuoMenuStatus.dwellSelection(.nan), 2, "a broken dwell falls back to the default")
}

print("== 4. status, sensor, permission and energy ==")
do {
    var state = MacDuoMenuState.idle
    state.status = "Seguindo a tampa."
    let items = MacDuoMenuPlan.items(for: state)
    check(items.contains { $0.kind == .info && $0.title == "Seguindo a tampa." }, "the model status is shown verbatim")
    check(item(items, action: .retrySensor) != nil, "a missing sensor offers a retry")
    check(item(items, action: .openPrivacy) != nil, "a missing permission offers the privacy pane")

    var healthy = MacDuoMenuState.idle
    healthy.sensorAvailable = true
    healthy.hasPermission = true
    healthy.lidAngle = 96.4
    let clean = MacDuoMenuPlan.items(for: healthy)
    check(item(clean, action: .retrySensor) == nil, "a working sensor hides the retry")
    check(item(clean, action: .openPrivacy) == nil, "a granted permission hides the privacy shortcut")

    equal(MacDuoMenuStatus.sensorLine(available: false, angle: nil), "Sensor da tampa: indisponível", "the sensor line reports absence")
    check(MacDuoMenuStatus.sensorLine(available: true, angle: 96.4).contains("96°"), "the sensor line shows the rounded angle")
    equal(MacDuoMenuStatus.angleLine(nil), "Ângulo: —", "a missing angle is a dash")
    equal(MacDuoMenuStatus.angleLine(.nan), "Ângulo: —", "a broken angle is a dash")
    equal(MacDuoMenuStatus.permissionLine(hasPermission: true, checking: false), "Gravação de tela: concedida", "granted access is stated")
    equal(MacDuoMenuStatus.permissionLine(hasPermission: false, checking: false), "Gravação de tela: pendente", "pending access is stated")
    equal(MacDuoMenuStatus.permissionLine(hasPermission: false, checking: true), "Gravação de tela: verificando…", "a running check is stated")
    equal(MacDuoMenuStatus.energyLine(fps: 120, lowPower: false, thermalPressure: false), "Energia: 120 Hz", "energy reports the frame cap")
    check(MacDuoMenuStatus.energyLine(fps: 60, lowPower: true, thermalPressure: false).contains("baixo consumo"), "low power mode is surfaced")
    check(MacDuoMenuStatus.energyLine(fps: 30, lowPower: false, thermalPressure: true).contains("pressão térmica"), "thermal pressure is surfaced")
    equal(MacDuoMenuStatus.energyLine(fps: 0, lowPower: false, thermalPressure: false), "Energia: 1 Hz", "the frame cap never reads as zero")
}

print("== 5. policy: no window, no surprise TCC ==")
do {
    check(!MacDuoMenuPolicy.opensSettingsOnEnable, "enabling the effect never opens the settings window")
    var off = MacDuoMenuState.idle
    check(MacDuoMenuPolicy.touchesScreenCapture(action: .toggleEffect, state: off),
          "only an explicit enable may ask for screen recording")
    off.enabled = true
    check(!MacDuoMenuPolicy.touchesScreenCapture(action: .toggleEffect, state: off),
          "turning the effect off never touches TCC")
    for action: MacDuoMenuAction in [.pause, .selectEffect(.roll), .toggleDwell, .selectDwell(4), .retrySensor, .openPrivacy, .openSettings] {
        check(!MacDuoMenuPolicy.touchesScreenCapture(action: action, state: .idle), "\(action) never triggers a capture prompt")
    }
    check(!MacDuoMenuPolicy.opensWindow(action: .toggleEffect), "the enable action opens no window")
    check(!MacDuoMenuPolicy.opensWindow(action: .selectEffect(.flex)), "choosing an effect opens no window")
    check(!MacDuoMenuPolicy.opensWindow(action: .selectDwell(2)), "choosing a dwell opens no window")
    check(MacDuoMenuPolicy.opensWindow(action: .openSettings), "settings is the only in-app window entry")
    check(MacDuoMenuPolicy.opensWindow(action: .openPrivacy), "the privacy pane is an explicit, user-asked window")
}

print("== 6. AppKit items ==")
MainActor.assumeIsolated {
    var fired: [MacDuoMenuAction] = []
    let menu = MacDuoMenu { fired.append($0) }
    var state = MacDuoMenuState.idle
    state.effect = .shutter
    state.sensorAvailable = true
    state.hasPermission = true
    let items = menu.items(for: state)
    let plan = MacDuoMenuPlan.items(for: state)
    equal(items.count, plan.count, "every planned entry becomes a real menu item")
    equal(items.filter { $0.isSeparatorItem }.count, plan.filter { $0.kind == .separator }.count, "separators survive the build")
    let actionable = items.filter { $0.action != nil }
    check(!actionable.isEmpty, "the menu has live commands")
    check(actionable.allSatisfy { $0.target === menu }, "the menu owns its own target, not the app delegate")
    check(items.filter { !$0.isSeparatorItem && $0.action == nil }.allSatisfy { !$0.isEnabled }, "inert lines stay dimmed")
    let checkedTitles = items.filter { $0.state == .on }.map(\.title)
    check(checkedTitles.contains(MacDuoEffect.shutter.title), "the selected effect is checked in AppKit too")

    guard let toggle = items.first(where: { $0.title == MacDuoMenuStatus.toggleTitle(enabled: false, checking: false) }) else {
        check(false, "the enable item exists in AppKit")
        exit(1)
    }
    _ = toggle.target?.perform(toggle.action!, with: toggle)
    equal(fired, [.toggleEffect], "clicking the toggle asks the controller to run the real flow")

    fired.removeAll()
    let irisItem = items.first { $0.title == MacDuoEffect.iris.title }!
    _ = irisItem.target?.perform(irisItem.action!, with: irisItem)
    equal(fired, [.selectEffect(.iris)], "clicking an effect selects it")

    fired.removeAll()
    let dwellItem = items.first { $0.title == "4 s" }!
    _ = dwellItem.target?.perform(dwellItem.action!, with: dwellItem)
    equal(fired, [.selectDwell(4)], "clicking a dwell step selects it")

    let parent = menu.submenuItem(for: state)
    equal(parent.title, "Mac Duo", "the submenu keeps the module name")
    equal(parent.submenu?.items.count, plan.count, "the submenu carries the same plan")
    equal(parent.submenu?.autoenablesItems, false, "the submenu respects our own enabled state")
    check(parent.target !== menu, "the parent item routes nothing to the menu handler")
    check(parent.submenu != nil, "the parent item is only a container")
}

print("== 7. source guards ==")
do {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let sources = root.appendingPathComponent("Sources/MacDuo")
    let menuText = (try? String(contentsOf: sources.appendingPathComponent("MacDuoMenu.swift"), encoding: .utf8)) ?? ""
    check(!menuText.isEmpty, "the menu source is readable")
    check(!menuText.contains("showSettings"), "the menu never opens the settings window on its own")
    check(!menuText.contains("NSWindow("), "the menu builds no window")
    check(!menuText.contains("SCStream") && !menuText.contains("CGRequestScreenCaptureAccess"), "the menu asks for no capture by itself")
    let keyEquivalents = menuText.components(separatedBy: "keyEquivalent: ").dropFirst().map { $0.prefix(2) }
    check(keyEquivalents.allSatisfy { $0 == "\"\"" }, "the menu binds no key equivalent")
    check(!menuText.contains("ModifierMask"), "the menu registers no new shortcut")
    check(!menuText.contains("RegisterEventHotKey") && !menuText.contains("import Carbon"), "the menu registers no hot key")

    let controller = (try? String(contentsOf: sources.appendingPathComponent("MacDuoController.swift"), encoding: .utf8)) ?? ""
    check(controller.contains("func menuItems()"), "the controller exposes menuItems()")
    check(controller.contains("func menuSubmenuItem"), "the controller exposes a submenu entry point")
    check(controller.contains("case .toggleEffect: toggleEffect()"), "enable routes to the existing real flow of the model")
    check(!controller.contains("case .toggleEffect: showSettings()"), "enable never falls back to the settings window")

    let app = root.appendingPathComponent("Sources/App/AppDelegate.swift")
    check(FileManager.default.fileExists(atPath: app.path), "the app delegate is untouched by this module and still integrates later")
}

print("")
print("passes: \(passes)  failures: \(failures)")
exit(failures == 0 ? 0 : 1)
