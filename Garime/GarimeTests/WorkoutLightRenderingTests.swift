import SwiftUI
import XCTest
@testable import Garime

@MainActor
final class WorkoutLightRenderingTests: XCTestCase {
    func testLightHeroAndRecoveryKeepVisibleSilhouette() async throws {
        let cases: [(Bool, ColorScheme)] = [(false, .light), (true, .light), (false, .dark), (true, .dark)]
        for (isRest, scheme) in cases {
            let view = ScrollView {
                WorkoutHeroCard(
                    sessionName: isRest ? "Recuperação" : "A · Pernas",
                    highlighted: isRest ? [] : ["quadriceps", "hamstring", "gluteal", "calves", "abs", "adductors"],
                    isRest: isRest,
                    progress: SessionProgress(setsDone: 0, setsTarget: isRest ? 0 : 16, exercisesDone: 0, exercisesTarget: isRest ? 0 : 7),
                    currentName: isRest ? nil : "Agachamento livre",
                    restLabel: nil,
                    action: {}
                )
                .padding(16)
            }
            .background(Color.slateCanvas)
            let name = "\(isRest ? "recovery" : "legs")-hero-\(scheme == .dark ? "dark" : "light")"
            try await snapshot(view, name: name, scheme: scheme)
        }
    }

    func testRecoveryNoteAndBackNavigationFromHiddenHomeBar() async throws {
        let suite = "workout-light-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let workout = WorkoutSessionModel(defaults: defaults)
        workout.adopt(day: "2026-09-14")
        let session = VitalsSession(index: 6, name: "Recuperação", short: "Descanso", rest: true, muscles: [], exercises: [])
        let view = NavigationStack {
            Color.slateCanvas
                .navigationBarHidden(true)
                .navigationDestination(isPresented: .constant(true)) {
                    WorkoutDetailView(
                        viewModel: HealthViewModel(), workout: workout, session: session,
                        note: .constant(""),
                        onLog: { _ in XCTFail("No logging in a rendering test") },
                        onPhoto: { _ in XCTFail("No camera in a rendering test") }
                    )
                }
        }
        try await snapshot(view, name: "recovery-detail-light") { controller in
            let nav = self.navigationController(in: controller)
            XCTAssertNotNil(nav, "A dedicated screen must have a navigation controller")
            XCTAssertFalse(nav?.isNavigationBarHidden ?? true, "The hidden Home bar must not hide Back in the workout")
            XCTAssertTrue(self.hasTextField(in: controller.view), "Recovery must offer the note promised by its text")
        }
    }

    private func navigationController(in controller: UIViewController) -> UINavigationController? {
        if let nav = controller as? UINavigationController { return nav }
        return controller.children.compactMap { navigationController(in: $0) }.first
    }

    private func hasTextField(in view: UIView) -> Bool {
        view is UITextField || view.subviews.contains { hasTextField(in: $0) }
    }

    private func snapshot<V: View>(_ view: V, name: String, scheme: ColorScheme = .light, verify: ((UIViewController) -> Void)? = nil) async throws {
        let controller = UIHostingController(rootView: view.environment(\.colorScheme, scheme))
        controller.overrideUserInterfaceStyle = scheme == .dark ? .dark : .light
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 375, height: 812)
        window.overrideUserInterfaceStyle = scheme == .dark ? .dark : .light
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(500))
        controller.view.layoutIfNeeded()
        verify?(controller)
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
        let image = renderer.image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertNotNil(image.cgImage)
    }
}
