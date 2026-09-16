import AppKit
import Foundation

// Independent review harness for the Mac Duo menu surface.
// Rules honoured here: nothing in this file starts the lid sensor, opens a window,
// calls ScreenCaptureKit, or preflights/asks for the Screen Recording permission.
// Everything runs against the pure plan, the pure policy, plain NSMenu objects and
// the source text of Sources/MacDuo.

var passes = 0
var failures = 0
var notes: [String] = []

func check(_ condition: Bool, _ label: String) {
    if condition { passes += 1; print("  ok   \(label)") }
    else { failures += 1; print("  FAIL \(label)") }
}

func equal<T: Equatable>(_ lhs: T, _ rhs: T, _ label: String) {
    check(lhs == rhs, "\(label) [got: \(lhs)]")
}

func note(_ text: String) {
    notes.append(text)
    print("  note \(text)")
}

func plan(_ state: MacDuoMenuState) -> [MacDuoMenuItem] { MacDuoMenuPlan.items(for: state) }

func item(_ items: [MacDuoMenuItem], _ action: MacDuoMenuAction) -> MacDuoMenuItem? {
    items.first { $0.action == action }
}

let sourceRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Sources")

func source(_ relative: String) -> String {
    (try? String(contentsOf: sourceRoot.appendingPathComponent(relative), encoding: .utf8)) ?? ""
}

let menuSource = source("MacDuo/MacDuoMenu.swift")
let controllerSource = source("MacDuo/MacDuoController.swift")
let modelSource = source("MacDuo/MacDuoModel.swift")
let appSource = source("App/AppDelegate.swift")

print("== A. menu is enough on its own (no obligatory settings, no preview) ==")
do {
    let items = plan(.idle)
    check(item(items, .toggleEffect) != nil, "the essential switch lives in the menu")
    check(item(items, .pause) != nil, "pause lives in the menu")
    check(items.contains { if case .selectEffect = $0.action { return true } else { return false } },
          "the effect choice lives in the menu")
    check(items.contains { if case .selectDwell = $0.action { return true } else { return false } },
          "the dwell choice lives in the menu")
    check(!MacDuoMenuPolicy.opensSettingsOnEnable, "enabling never routes through the settings window")
    check(!MacDuoMenuPolicy.opensWindow(action: .toggleEffect), "the switch opens no window")
    check(items.allSatisfy { $0.action != .openSettings || $0.kind == .command },
          "settings is one plain optional command, never a gate")
    // The preview and the desktop test exist on the controller but must not be menu actions:
    // a menu-driven flow must not depend on them.
    check(!controllerSource.contains("case .playPreview") && !controllerSource.contains("case .testDesktop"),
          "no menu action maps to the preview or the desktop test")
    check(!menuSource.contains("playPreview") && !menuSource.contains("testDesktop"),
          "the menu plan never references the preview surface")
}

print("== B. enable -> TCC -> sensor -> render path, as bound by the menu ==")
do {
    // 1. menu action -> controller
    check(controllerSource.contains("case .toggleEffect: toggleEffect()"), "the switch reaches toggleEffect()")
    check(controllerSource.contains("if model.enabled { model.pause() } else { model.enable() }"),
          "toggleEffect drives the real model, not a private copy")
    // 2. model -> sensor gate before any TCC work
    let sensorGate = modelSource.range(of: "guard sensorAvailable else \\{[\\s\\S]*?\\n        \\}", options: .regularExpression)
        .map { String(modelSource[$0]) } ?? ""
    check(sensorGate.contains("sensorWaitSince = ProcessInfo.processInfo.systemUptime") && sensorGate.contains("return")
            && !sensorGate.contains("beginPermissionCheck"),
          "enable() returns into a sensor wait instead of reaching the permission check")
    check(modelSource.range(of: "sensorWaitSince = nil\\n        beginPermissionCheck", options: .regularExpression) != nil,
          "the permission check only runs once the sensor answered")
    check(modelSource.contains("beginPermissionCheck(startDesktopTest:"), "the permission check is a distinct step")
    check(modelSource.contains("try await capture.verifyAccess()"), "TCC is exercised by ScreenCaptureKit access, not by a prompt call")
    check(!modelSource.contains("CGRequestScreenCaptureAccess"), "the module never calls the blunt TCC request API")
    // 3. success -> render path
    check(modelSource.contains("self.enabled = true"), "a verified access is what flips enabled")
    check(modelSource.contains("try prepareOverlay(on: screen)"), "the overlay is prepared inside the update loop")
    check(modelSource.contains("overlayVisible = true"), "rendering is gated on a real captured frame")
    check(modelSource.contains("capture.frames.get().0 != nil"), "the overlay only shows with a frame in hand")
    // 4. the only menu action allowed near TCC
    for effect in MacDuoEffect.allCases {
        check(!MacDuoMenuPolicy.touchesScreenCapture(action: .selectEffect(effect), state: .idle),
              "selecting \(effect.rawValue) never touches screen capture")
    }
    for seconds in MacDuoMenuStatus.dwellChoices {
        check(!MacDuoMenuPolicy.touchesScreenCapture(action: .selectDwell(seconds), state: .idle),
              "selecting \(seconds)s never touches screen capture")
    }
    var live = MacDuoMenuState.idle
    live.enabled = true
    check(!MacDuoMenuPolicy.touchesScreenCapture(action: .toggleEffect, state: live), "turning off never touches screen capture")
    check(MacDuoMenuPolicy.touchesScreenCapture(action: .toggleEffect, state: .idle), "turning on is the single TCC entry")
}

print("== C. action bindings and object lifetime ==")
MainActor.assumeIsolated {
    // C1. Two surfaces from one MacDuoMenu alias the same action table.
    var fired: [MacDuoMenuAction] = []
    let menu = MacDuoMenu { fired.append($0) }
    var first = MacDuoMenuState.idle
    first.effect = .duo
    let flat = menu.items(for: first)
    let flatIris = flat.first { $0.title == MacDuoEffect.iris.title }!

    var second = MacDuoMenuState.idle
    second.sensorAvailable = true       // drops "Procurar o sensor de novo"
    second.hasPermission = true         // drops "Abrir Gravação de Tela…"
    second.enabled = true               // different plan shape
    _ = menu.submenuItem(for: second)   // rebuilds the shared action table

    _ = flatIris.target?.perform(flatIris.action!, with: flatIris)
    if fired == [.selectEffect(.iris)] {
        check(true, "items from an earlier build still fire their own action after a rebuild")
    } else {
        check(false, "items from an earlier build still fire their own action after a rebuild")
        note("ALIASING: MacDuoMenu keeps one `actions` array indexed by NSMenuItem.tag and clears it on every items(for:) call. Menu items produced by an earlier build now fire \(fired) instead of [.selectEffect(.iris)]. Safe only if exactly one surface exists and it is rebuilt right before each use.")
    }

    // C2. The item target is weak: the hub must retain the controller/menu.
    var box: MacDuoMenu? = MacDuoMenu { _ in }
    let orphan = box!.items(for: .idle).first { $0.action != nil }!
    box = nil
    check(orphan.target == nil,
          "NSMenuItem.target is weak, so a released MacDuoMenu leaves dead items (hub must retain the controller)")

    // C3. Tag/action table integrity inside one build.
    var busy = MacDuoMenuState.idle
    busy.checkingPermission = true
    let items = menu.items(for: busy)
    let live = items.filter { $0.action != nil }
    let tags = live.map(\.tag)
    equal(tags, Array(0..<live.count), "live items carry dense, ordered tags")
    check(live.allSatisfy { $0.isEnabled }, "every live item is enabled")
    check(items.filter { !$0.isSeparatorItem && $0.action == nil }.allSatisfy { !$0.isEnabled },
          "every dimmed item is inert (no target, no action)")

    // C4. Flat items dropped in a default NSMenu (the hub menu is a plain NSMenu()).
    let host = NSMenu()
    check(host.autoenablesItems, "a plain NSMenu auto-enables items (this is what the hub uses)")
    for entry in menu.items(for: busy) { host.addItem(entry) }
    check(host.items.count == plan(busy).count, "the flat plan can be appended to the hub menu as-is")
    check(!menuSource.contains("validateMenuItem"),
          "MacDuoMenu implements no validateMenuItem, so dimming relies on the action being nil, not on AppKit validation")
}

print("== D. state refresh: what the menu can and cannot see ==")
do {
    // D1. The pending-sensor window has no representation in the snapshot.
    // Fixed: the snapshot now carries the wait, and MacDuoController.menuState fills it from
    // MacDuoModel.awaitingSensor (sensorWaitSince != nil).
    check(menuSource.contains("waitingForSensor"), "MacDuoMenuState carries a lid-sensor-wait flag")
    check(controllerSource.contains("waitingForSensor: model?.awaitingSensor == true")
            && modelSource.contains("var awaitingSensor: Bool { sensorWaitSince != nil }"),
          "the snapshot wait flag is the model's armed sensor wait")
    var waiting = MacDuoMenuState.idle       // model: sensorWaitSince != nil, enabled false, checking false
    waiting.waitingForSensor = true
    waiting.status = "Waiting for the lid sensor…"
    let items = plan(waiting)
    equal(item(items, .toggleEffect)?.title, nil,
          "during the (up to 2 s) sensor wait the switch no longer lies about being off")
    check(plan(waiting).first?.title == "Procurando o sensor da tampa…"
            && plan(waiting).first?.action == .pause,
          "the first row tells the truth about the wait and cancels it")
    equal(item(plan(.idle), .toggleEffect)?.title, "Ativar efeito da tampa",
          "outside the wait the switch still reads as off")
    let pauseEnabled = item(items, .pause)?.isEnabled ?? false
    if pauseEnabled {
        check(true, "a pending enable can be cancelled from the menu")
    } else {
        check(false, "a pending enable can be cancelled from the menu")
        note("DEAD WINDOW: while MacDuoModel.sensorWaitSince is armed, `Pausar` is dimmed (enabled/overlay/checking are all false) and a second click on the switch calls enable(), which returns early because sensorWaitSince != nil. For up to MacDuoSensorWait.timeout (\(MacDuoSensorWait.timeout)s) the menu offers no way out and no feedback beyond the status line.")
    }
    check(modelSource.contains("if sensorWaitSince == nil {"), "enable() only arms the wait once (second click is a no-op)")

    // D2. The async part of enable never pushes a refresh back to the menu.
    check(controllerSource.contains("var onStateChange: (() -> Void)?"), "the controller exposes a refresh hook")
    let pushesFromModel = modelSource.contains("onStateChange") || controllerSource.contains("objectWillChange")
        || controllerSource.contains("$enabled") || controllerSource.contains("sink")
    if pushesFromModel {
        check(true, "the async enable result reaches onStateChange")
    } else {
        check(false, "the async enable result reaches onStateChange")
        note("PULL-ONLY STATE: onStateChange fires only inside synchronous controller methods. beginPermissionCheck finishes in a Task (enabled/hasPermission/status change there), and the model only bridges overlayVisibilityChanged. Any hub UI must rebuild the plan in menuWillOpen; a menu left open or a status icon will show stale state.")
    }
    check(controllerSource.contains("model.overlayVisibilityChanged = { [weak self]"),
          "the only model->controller push is overlay visibility")

    // D3. Reading the snapshot must not start anything.
    check(controllerSource.contains("var menuState: MacDuoMenuState") && controllerSource.contains("CGPreflightScreenCaptureAccess()"),
          "menuState only preflights (never requests) the permission")
    check(controllerSource.range(of: "var menuState[\\s\\S]{0,900}?start\\(\\)", options: .regularExpression) == nil,
          "reading menuState never calls start()")

    // D4. Every action that mutates state does announce it synchronously.
    for hook in ["func toggleEffect()", "func pause()", "func selectEffect", "func setDwellEnabled", "func setDwellSeconds", "func retrySensor"] {
        let body = controllerSource.range(of: "\(hook)[\\s\\S]{0,320}?\\n    }", options: .regularExpression)
            .map { String(controllerSource[$0]) } ?? ""
        check(body.contains("onStateChange?()"), "\(hook) announces the new state")
    }
    let privacy = controllerSource.range(of: "func openPrivacySettings\\(\\)[\\s\\S]{0,200}?\\n    }", options: .regularExpression)
        .map { String(controllerSource[$0]) } ?? ""
    check(!privacy.contains("onStateChange?()"), "opening the privacy pane changes no state (no refresh emitted)")
}

print("== E. persistence of the essential adjustments ==")
do {
    // Effect and dwell persist through UserDefaults in the model; the switch does not.
    check(modelSource.contains("UserDefaults.standard.set(effect.persistedIdentifier, forKey: MacDuoDefaults.effect)"),
          "the chosen effect is written to UserDefaults")
    check(modelSource.contains("UserDefaults.standard.set(clearWhenStill, forKey: MacDuoDefaults.clearWhenStill)"),
          "the dwell switch is written to UserDefaults")
    check(modelSource.contains("UserDefaults.standard.set(clamped, forKey: MacDuoDefaults.stillnessDelay)"),
          "the dwell seconds are written to UserDefaults, already clamped")
    check(!modelSource.contains("macduo.enabled"), "the on/off state of the effect is deliberately not persisted")
    note("RELAUNCH: MacDuoDefaults has no key for `enabled`, and AppDelegate only calls macDuo.start(). The effect is off after every relaunch and must be switched on again from the menu — intentional for a TCC-touching feature, but it is a product decision worth stating.")

    // The menu's clamping must agree with the model's clamping, or the checkmark lies.
    equal(MacDuoMenuStatus.dwellSelection(1.0), 1, "menu clamp low matches the model clamp")
    equal(MacDuoMenuStatus.dwellSelection(5.0), 5, "menu clamp high matches the model clamp")
    equal(MacDuoMenuStatus.dwellSelection(-3), 1, "a negative dwell is clamped like the model")
    equal(MacDuoMenuStatus.dwellSelection(.infinity), 2, "a non-finite dwell falls back like the model")
    for seconds in MacDuoMenuStatus.dwellChoices {
        equal(MacDuoMenuStatus.dwellSelection(Double(seconds)), seconds, "\(seconds)s round-trips through the menu")
    }
    // Every effect the menu can select is a real, persistable case.
    for effect in MacDuoEffect.allCases {
        equal(MacDuoEffect.resolve(persisted: effect.persistedIdentifier), effect, "\(effect.rawValue) round-trips through UserDefaults")
        equal(MacDuoEffect.resolve(shaderIndex: effect.shaderIndex), effect, "\(effect.rawValue) maps to a unique shader index")
    }
    equal(MacDuoEffect.resolve(persisted: "zzz"), MacDuoEffect.fallback, "an unknown persisted effect falls back")
    equal(Set(MacDuoEffect.allCases.map(\.shaderIndex)).count, MacDuoEffect.allCases.count, "shader indexes are unique")
    // A dwell of 2.5 shows as 3 in the menu but the model keeps 2.5: the checkmark is a rounding, not a write-back.
    equal(MacDuoMenuStatus.dwellSelection(2.5), 3, "2.5 s is displayed as the 3 s step")
    note("ROUNDING: a dwell of 2.5 s (reachable from the settings slider) is drawn as the 3 s step in the menu while the model keeps 2.5 s. Harmless, but the menu is a lossy view of the slider.")
}

print("== F. lid sensor and permission: what cannot be verified here ==")
do {
    check(modelSource.contains("MacDuoMath.decodeReport") || source("MacDuo/MacDuoFoldCore.swift").contains("decodeReport"),
          "the raw HID report decoding is a pure function")
    equal(MacDuoMath.decodeReport([1, 90, 0]), 90, "a 90° report decodes")
    equal(MacDuoMath.decodeReport([1, 181, 0]), nil, "an out-of-range angle is rejected")
    equal(MacDuoMath.decodeReport([2, 90, 0]), nil, "a foreign report id is rejected")
    equal(MacDuoMath.decodeReport([]), nil, "an empty report is rejected")
    equal(MacDuoMenuStatus.sensorLine(available: false, angle: 90), "Sensor da tampa: indisponível",
          "an angle without an available sensor is not shown")
    note("UNTESTABLE HERE: opening the real IOHIDDevice (usage page 0x20 / usage 0x8A), the physical lid travel, and the ScreenCaptureKit access dialog all need a physical Mac with a hinge sensor and a TCC decision. This harness deliberately never starts MacDuoLidSensor, never instantiates MacDuoModel/MacDuoController, and never calls CGPreflight/CGRequestScreenCaptureAccess. Everything above the HID boundary is covered; the boundary itself is not.")
}

print("== G. integration state of the menu surface ==")
do {
    check(controllerSource.contains("func menuItems()") && controllerSource.contains("func menuSubmenuItem"),
          "both hub entry points exist")
    let wired = appSource.contains("menuItems()") || appSource.contains("menuSubmenuItem")
    if wired {
        check(true, "the hub menu shows the Mac Duo controls")
    } else {
        check(false, "the hub menu shows the Mac Duo controls")
        note("NOT WIRED: AppDelegate still builds only `Mac Duo…` -> showSettings(). menuItems()/menuSubmenuItem() have no caller, and onStateChange is never assigned outside MacDuo. Until that binding lands, the menu-only flow this review is about is unreachable by the user. (Flagged as pending by the task.)")
    }
    // Fixed: AppDelegate no longer owns a `Mac Duo…` item pointing at showSettings(); the window is
    // now one optional row inside the submenu, routed by the controller (.openSettings -> showSettings()).
    check(!appSource.contains("Mac Duo…"), "the settings window is no longer the primary hub entry")
    check(controllerSource.contains("case .openSettings: showSettings()")
            && plan(.idle).contains { $0.action == .openSettings },
          "the settings window stays reachable as an optional menu row")
    check(appSource.contains("macDuo.stop()"), "the controller is stopped on termination")
}

print("")
for text in notes { print("NOTE: \(text)") }
print("")
print("passes: \(passes)  failures: \(failures)")
exit(failures == 0 ? 0 : 1)
