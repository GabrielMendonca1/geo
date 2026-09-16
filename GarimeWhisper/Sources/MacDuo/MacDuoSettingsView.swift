import AppKit
import SwiftUI
import MetalKit

enum MacDuoType {
    static func plain(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> Font {
        Font(NSFont.systemFont(ofSize: size, weight: weight) as CTFont)
    }

    static func mono(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> Font {
        Font(NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight) as CTFont)
    }

    static func rounded(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> Font {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        if let descriptor = base.fontDescriptor.withDesign(.rounded), let font = NSFont(descriptor: descriptor, size: size) {
            return Font(font as CTFont)
        }
        return Font(base as CTFont)
    }
}

struct MacDuoPreview: NSViewRepresentable {
    @ObservedObject var model: MacDuoModel

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView()
        guard let device = model.device else { return view }
        do {
            let renderer = try MacDuoRenderer(device: device)
            renderer.fallback = try renderer.makePreviewTexture()
            renderer.parameters = { [weak model] in model?.uniforms(preview: true) ?? MacDuoUniforms() }
            renderer.animatedProgress = { [weak model] in model?.animatedProgress(preview: true) }
            renderer.pausesWhenSettled = true
            renderer.keepsAnimating = { [weak model] in
                guard let model else { return false }
                return model.previewPlaying || (model.followLid && model.demoRunning)
            }
            renderer.onFailure = { [weak model] message in model?.status = message }
            renderer.configure(view)
            context.coordinator.renderer = renderer
            context.coordinator.model = model
            model.previewRenderer = renderer
            model.previewView = view
        } catch { model.status = error.localizedDescription }
        return view
    }

    func updateNSView(_ view: MTKView, context: Context) {
        view.preferredFramesPerSecond = min(60, model.fps)
        context.coordinator.renderer?.wake(view)
    }

    static func dismantleNSView(_ view: MTKView, coordinator: Coordinator) {
        view.isPaused = true
        view.delegate = nil
        MainActor.assumeIsolated {
            if let model = coordinator.model {
                if model.previewView === view { model.previewView = nil }
                if model.previewRenderer === coordinator.renderer { model.previewRenderer = nil }
            }
        }
        coordinator.renderer = nil
        coordinator.model = nil
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var renderer: MacDuoRenderer?
        weak var model: MacDuoModel?
    }
}

struct MacDuoSettingsView: View {
    @ObservedObject var model: MacDuoModel
    @Environment(\.colorScheme) private var colorScheme

    private var accent: Color {
        colorScheme == .dark ? Color(red: 1.0, green: 0.56, blue: 0.18) : Color(red: 0.76, green: 0.30, blue: 0.04)
    }

    private var background: Color {
        colorScheme == .dark ? Color(red: 0.075, green: 0.085, blue: 0.095) : Color(red: 0.97, green: 0.965, blue: 0.95)
    }

    var body: some View {
        GeometryReader { geometry in
            let scale = min(1, geometry.size.width / 900, geometry.size.height / 508)
            let width = geometry.size.width / max(scale, 0.1)
            let height = geometry.size.height / max(scale, 0.1)
            let previewWidth = max(240, min(480, width - 424, (height - 205) * 1.54 + 14))
            let panelHeight = (previewWidth - 14) / 1.54 + 21
            VStack(alignment: .leading, spacing: 14) {
                header
                HStack(alignment: .top, spacing: 24) {
                    preview(width: previewWidth).frame(maxWidth: .infinity)
                    settings.frame(width: 350, height: panelHeight)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                footer
            }
            .padding(20)
            .frame(width: width, height: height, alignment: .top)
            .scaleEffect(scale, anchor: .topLeading)
        }
        .background(background)
        .tint(accent)
    }

    private var header: some View {
        HStack(alignment: .top) {
            Image(systemName: "macbook").resizable().scaledToFit().frame(width: 34, height: 34)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text("Mac Duo").font(MacDuoType.rounded(27, .semibold))
                Text("Let your desktop follow the fold.").font(MacDuoType.plain(12)).foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 6) {
                Circle().fill(model.sensorAvailable ? accent : .orange).frame(width: 6, height: 6)
                Text(model.lidAngle.map { String(format: "Lid %.0f°", $0) } ?? "Looking for sensor")
                    .font(MacDuoType.mono(12, .medium))
            }
            .padding(.horizontal, 12).padding(.vertical, 8).background(.primary.opacity(0.055), in: Capsule())
        }
    }

    private func preview(width: CGFloat) -> some View {
        VStack(spacing: 0) {
            MacDuoPreview(model: model)
                .frame(width: width - 14, height: (width - 14) / 1.54)
                .overlay(alignment: .top) {
                    UnevenRoundedRectangle(bottomLeadingRadius: 5, bottomTrailingRadius: 5)
                        .fill(.black).frame(width: width * 0.16, height: 9)
                }
                .clipShape(UnevenRoundedRectangle(topLeadingRadius: 12, bottomLeadingRadius: 2, bottomTrailingRadius: 2, topTrailingRadius: 12))
                .padding(7).background(.black, in: UnevenRoundedRectangle(topLeadingRadius: 18, topTrailingRadius: 18))
            RoundedRectangle(cornerRadius: 3).fill(Color(white: 0.34)).frame(height: 7).padding(.horizontal, -5)
        }
        .frame(width: width)
    }

    private var effectPicker: some View {
        Picker("Effect", selection: $model.effect) {
            ForEach(MacDuoEffect.allCases) { effect in Text(effect.title).tag(effect) }
        }
        .pickerStyle(.segmented).labelsHidden().controlSize(.small)
        .font(MacDuoType.plain(11, .medium))
        .frame(height: 19)
        .accessibilityLabel("Effect")
        .help("Effect: \(model.effect.title) — \(model.effect.summary)")
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 10) {
            effectPicker
            Toggle("Follow my lid", isOn: $model.followLid)
                .toggleStyle(.switch).controlSize(.small).font(MacDuoType.plain(11.5, .medium))
            slider("Preview angle",
                   value: Binding(get: { model.followLid ? model.lidAngle ?? model.clearAngle : model.previewAngle },
                                  set: { model.previewAngle = $0 }),
                   range: 5...140,
                   text: String(format: "%.0f°", model.followLid ? model.lidAngle ?? model.clearAngle : model.previewAngle))
                .disabled(model.followLid || model.previewPlaying)
            Divider()
            slider("Clears at", value: $model.clearAngle, range: 60...140, text: String(format: "%.0f°", model.clearAngle))
            VStack(alignment: .leading, spacing: 6) {
                Toggle("Clear when the lid is still", isOn: $model.clearWhenStill)
                    .toggleStyle(.switch).controlSize(.small).font(MacDuoType.plain(11.5, .medium))
                slider("Clear after", value: $model.stillnessDelay, range: 1...5,
                       text: String(format: "%.0f s", model.stillnessDelay), step: 1)
                    .disabled(!model.clearWhenStill)
                Text("Move the lid to bring back the effect.")
                    .font(MacDuoType.plain(11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            slider("Perspective", value: $model.perspective, range: 0...1, text: percent(model.perspective))
            slider("Softness", value: $model.blur, range: 0...1, text: percent(model.blur))
            slider("Shadow", value: $model.shadow, range: 0...1, text: percent(model.shadow))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(16).background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 16))
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            HStack(spacing: 8) {
                Button(model.checkingPermission ? "Checking…" : (model.enabled ? "Pause Mac Duo" : "Enable Mac Duo")) {
                    if model.enabled { model.pause() } else { model.enable() }
                }
                .disabled(model.checkingPermission).buttonStyle(.borderedProminent).tint(accent)
                Button(model.demoRunning ? "Testing…" : "Test desktop · 8 sec") { model.testDesktop() }
                    .disabled(model.demoRunning || model.checkingPermission)
                Button {
                    model.playPreview()
                } label: {
                    Image(systemName: "play.fill")
                    Text("Replay")
                }
                .disabled(model.previewPlaying)
                Text(model.status).font(MacDuoType.plain(11)).foregroundStyle(.secondary)
                    .lineLimit(2).help(model.status).frame(maxWidth: .infinity, alignment: .trailing)
                if !model.hasPermission {
                    Button { model.openPrivacy() } label: { Image(systemName: "gearshape") }
                        .help("Open Screen Recording settings")
                }
            }
            HStack(spacing: 5) {
                Text(model.previewPlaying ? "Replaying" : (model.followLid ? "Live preview" : "Manual preview"))
                Text("·")
                Image(systemName: "escape")
                Text("or a click on the effect to pause")
                Spacer()
                if model.reducedMotion {
                    Text("Reduce Motion on")
                    Text("·")
                }
                Text("On your Mac only").foregroundStyle(accent.opacity(0.85))
            }
            .font(MacDuoType.plain(10)).foregroundStyle(.secondary)
            Text(MacDuoAttribution.summary)
                .font(MacDuoType.plain(9)).foregroundStyle(.secondary.opacity(0.7))
                .help(MacDuoAttribution.copyright)
        }
    }

    private func percent(_ x: Double) -> String { String(format: "%.0f%%", x * 100) }

    private func slider(_ name: String, value: Binding<Double>, range: ClosedRange<Double>, text: String, step: Double? = nil) -> some View {
        HStack(spacing: 10) {
            Text(name).font(MacDuoType.plain(11.5, .medium)).frame(width: 84, alignment: .leading)
            Group {
                if let step { Slider(value: value, in: range, step: step) }
                else { Slider(value: value, in: range) }
            }
            .accessibilityLabel(name)
            Text(text).font(MacDuoType.mono(11.5)).foregroundStyle(.secondary).frame(width: 36, alignment: .trailing)
        }
    }
}
