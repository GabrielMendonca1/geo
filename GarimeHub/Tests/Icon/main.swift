import AppKit

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

let application = NSApplication.shared
application.setActivationPolicy(.accessory)

let icon = StatusIcon()

let states: [(IconState, String)] = [
    (.idle, "idle"),
    (.starting, "starting"),
    (.listening, "listening"),
    (.recording, "recording"),
    (.transcribing, "transcribing"),
    (.flushing, "flushing"),
    (.meeting, "meeting"),
    (.success, "success"),
    (.error, "error"),
    (.cancelled, "cancelled"),
]

print("== status icon: every state renders ==")
for (state, name) in states {
    icon.apply(state)
    let image = icon.renderedImage
    check(image != nil, "\(name) produces an image")
    if let image {
        let tint = IconAnimation.plan(for: state, reduceMotion: icon.reduceMotion).tint
        if tint == .neutral {
            check(image.isTemplate, "\(name) stays a template (auto-tints with the bar)")
        } else {
            check(!image.isTemplate, "\(name) carries its own colour")
        }
        check(image.size.width > 0 && image.size.height > 0, "\(name) image has a real size")
    }
}

print("== status icon: level driven frames ==")
icon.apply(.recording)
let quiet = icon.renderedImage
var changed = false
for step in 0..<12 {
    let level = Float(step) / 11.0
    icon.updateLevel(level, peak: min(1, level + 0.1))
    RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.08))
    if let current = icon.renderedImage, current !== quiet { changed = true }
}
check(changed, "the recording icon redraws as the level moves")
check(icon.renderedImage != nil, "the meter keeps producing frames")

icon.apply(.idle)
icon.updateLevel(0.9, peak: 1.0)
check(!icon.isAnimating, "levels are ignored while idle")

print("== status icon: timer lifecycle ==")
icon.apply(.transcribing)
check(icon.isAnimating, "the spinner installs a timer")
icon.apply(.idle)
check(!icon.isAnimating, "idle tears the timer down (zero idle cpu)")
icon.apply(.success)
check(!icon.isAnimating, "a static state runs no timer")
icon.apply(.recording)
check(icon.isAnimating, "the dictation ripple runs a ticker")

print("== status icon: one-shot pulse stops itself ==")
icon.apply(.starting)
let animatesAtStart = icon.isAnimating
let deadline = Date().addingTimeInterval(2.0)
while icon.isAnimating, Date() < deadline {
    RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
}
check(animatesAtStart, "the starting pulse animates")
check(!icon.isAnimating, "the starting pulse stops on its own instead of looping")

print("== status icon: cancelled returns to idle ==")
icon.apply(.cancelled)
let cancelledImage = icon.renderedImage
check(cancelledImage != nil, "the cancelled frame renders")
let idleDeadline = Date().addingTimeInterval(2.0)
var returned = false
while Date() < idleDeadline {
    RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
    if let current = icon.renderedImage, current !== cancelledImage {
        returned = true
        break
    }
}
check(returned, "the cancelled frame gives way to idle by itself")

print("== status icon: rapid interruptible transitions ==")
for _ in 0..<40 {
    for (state, _) in states {
        icon.apply(state)
        icon.updateLevel(0.5, peak: 0.7)
    }
}
check(icon.renderedImage != nil, "interrupting every transition never wedges the icon")
icon.apply(.idle)
check(!icon.isAnimating, "after a storm of transitions idle still has no timer")

print("== status icon: overlays compose over the base state ==")
icon.apply(.idle)
let bare = icon.renderedImage
icon.setOverlay(.alert, enabled: true)
let badged = icon.renderedImage
check(badged != nil, "alert overlay renders")
check(badged !== bare, "alert overlay changes the rendered image")
check(badged?.isTemplate == true, "overlaid image stays a template")
icon.setOverlay(.awake, enabled: true)
let mooned = icon.renderedImage
check(mooned != nil, "moon overlay renders")
check(mooned !== badged, "moon overlay changes the rendered image")
check(icon.activeOverlays == [.alert, .awake], "both overlays are tracked")
icon.apply(.transcribing)
check(icon.activeOverlays == [.alert, .awake], "overlays survive a state change")
icon.apply(.idle)
icon.setOverlay(.alert, enabled: false)
icon.setOverlay(.awake, enabled: false)
check(icon.activeOverlays.isEmpty, "overlays clear")
check(icon.renderedImage === bare, "without overlays the cached base image returns")

print("== status icon: flash is transient ==")
icon.apply(.idle)
let preFlash = icon.renderedImage
icon.flash("camera.fill")
check(icon.isFlashing, "flash engages")
check(icon.renderedImage !== preFlash, "flash swaps the rendered image")
let flashDeadline = Date().addingTimeInterval(Config.iconFlashSeconds + 1.0)
while icon.isFlashing, Date() < flashDeadline {
    RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
}
check(!icon.isFlashing, "flash expires on its own")
check(icon.renderedImage === preFlash, "the base image returns after the flash")

print("== menu controller: sections keep order and separators ==")
let controller = MenuController(menu: icon.menu)
let first = NSMenuItem(title: "Pronto", action: nil, keyEquivalent: "")
let second = NSMenuItem(title: "Ditar", action: nil, keyEquivalent: "")
let last = NSMenuItem(title: "Sair", action: nil, keyEquivalent: "")
controller.set(.status, items: [first])
controller.set(.app, items: [last])
check(icon.menu.items.map(\.title) == ["Pronto", "", "Sair"], "two sections render with one separator")
controller.set(.dictation, items: [second])
check(
    icon.menu.items.map(\.title) == ["Pronto", "", "Ditar", "", "Sair"],
    "a section added later lands in declaration order"
)
controller.set(.dictation, items: [])
check(icon.menu.items.map(\.title) == ["Pronto", "", "Sair"], "an emptied section disappears with its separator")
let replacement = NSMenuItem(title: "Gravar", action: nil, keyEquivalent: "")
controller.set(.meeting, items: [replacement])
check(
    icon.menu.items.map(\.title) == ["Pronto", "", "Gravar", "", "Sair"],
    "a later section slots between its neighbours"
)
check(controller.items(in: .meeting) == [replacement], "section contents are queryable")

print("")
print("icon passed: \(passes)   failed: \(failures)")
exit(failures == 0 ? 0 : 1)
