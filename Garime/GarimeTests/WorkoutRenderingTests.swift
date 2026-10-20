import SwiftUI
import XCTest
@testable import Garime

/// Isolated visual smoke tests: no repository, no network and no real workout log
/// is written. Screenshots are attached to the result bundle and also dropped in
/// /tmp/garime-workout-ui for a quick human look.
@MainActor
final class WorkoutRenderingTests: XCTestCase {
    private static let dumpDirectory = URL(fileURLWithPath: "/tmp/garime-workout-ui", isDirectory: true)

    func testExerciseEntryAndRestRendering() async throws {
        let suite = "workout-render-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let session = WorkoutSessionModel(defaults: defaults)
        session.adopt(day: "2026-09-14")
        session.startRest(exerciseId: "render.remada", setIndex: 0, restSec: 90)
        let exercise = VitalsExercise(
            id: "render.remada",
            name: "Remada com apoio no peito",
            sets: [[10, 15], [10, 15], [10, 15]],
            muscles: ["upper-back"],
            restSec: 90
        )
        let view = ExerciseLogSheet(
            exercise: exercise,
            logged: VitalsLogExercise(id: exercise.id, sets: [VitalsLogSet(reps: 12, kg: 32.5)]),
            lastWeight: 32.5,
            session: session,
            onSave: { _ in XCTFail("Rendering must not save a workout") }
        )
        _ = try await render(view, name: "workout-series-rest")
        session.skipRest()
    }

    // MARK: - Home: mapa muscular protagonista + CTA

    func testHomeHeroCardRendersBodyMapAndColoredCTA() async throws {
        let progress = SessionProgress(setsDone: 4, setsTarget: 12, exercisesDone: 1, exercisesTarget: 4)
        let card = ScrollView {
            WorkoutHeroCard(
                sessionName: "a · pernas",
                highlighted: ["quadriceps", "gluteal", "hamstring"],
                isRest: false,
                progress: progress,
                currentName: "agachamento livre",
                restLabel: nil,
                action: {}
            )
            .padding(16)
        }
        .background(Color.slateCanvas)

        let image = try await render(card, name: "home-hero-card")
        // O mapa ocupa a maior parte da tela: a metade superior precisa ter
        // desenho (não pode ser um título gigante em cima de espaço vazio).
        let pixels = try Self.pixels(of: image)
        let topInset = pixels.height / 12
        let topHalfInk = pixels.count(in: CGRect(x: 0, y: topInset, width: pixels.width, height: pixels.height / 2 - topInset)) { rgb in
            rgb.isDistinctFromCanvas
        }
        XCTAssertGreaterThan(topHalfInk, 5_000, "o modelo muscular deve dominar o topo da Home")

        // CTA colorido presente na metade de baixo.
        let ctaPixels = pixels.count(in: CGRect(x: 0, y: pixels.height / 2, width: pixels.width, height: pixels.height / 2)) { rgb in
            rgb.isTeal || rgb.isGreenish
        }
        XCTAssertGreaterThan(ctaPixels, 800, "o CTA colorido deve aparecer abaixo do mapa")
    }

    func testHeroCTATitleFollowsProgress() {
        let fresh = SessionProgress(setsDone: 0, setsTarget: 12, exercisesDone: 0, exercisesTarget: 4)
        let started = SessionProgress(setsDone: 3, setsTarget: 12, exercisesDone: 1, exercisesTarget: 4)
        let complete = SessionProgress(setsDone: 12, setsTarget: 12, exercisesDone: 4, exercisesTarget: 4)
        XCTAssertEqual(WorkoutCTA.title(isRest: false, progress: fresh), "abrir treino")
        XCTAssertEqual(WorkoutCTA.title(isRest: false, progress: started), "continuar treino")
        XCTAssertEqual(WorkoutCTA.title(isRest: false, progress: complete), "revisar treino")
        XCTAssertEqual(WorkoutCTA.title(isRest: true, progress: fresh), "abrir descanso")
    }

    // MARK: - Tela dedicada do treino

    func testWorkoutDetailRendersInsideNavigationStack() async throws {
        let suite = "workout-detail-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let workout = WorkoutSessionModel(defaults: defaults)
        workout.adopt(day: "2026-09-14")
        let viewModel = HealthViewModel()
        let session = Self.sampleSession()

        let view = NavigationStack {
            Color.slateCanvas
                .navigationDestination(isPresented: .constant(true)) {
                    WorkoutDetailView(
                        viewModel: viewModel,
                        workout: workout,
                        session: session,
                        note: .constant(""),
                        onLog: { _ in XCTFail("Rendering must not open the log sheet") },
                        onPhoto: { _ in XCTFail("Rendering must not open the camera") }
                    )
                }
        }
        .tint(Color.slateText)

        let image = try await render(view, name: "workout-detail-nav")
        let pixels = try Self.pixels(of: image)
        let chromeHeight = pixels.height / 6
        // Barra de navegação discreta no topo (botão voltar) e conteúdo abaixo.
        XCTAssertGreaterThan(
            pixels.count(in: CGRect(x: 0, y: 0, width: pixels.width, height: chromeHeight)) { $0.isDistinctFromCanvas },
            200,
            "a tela dedicada precisa de barra com voltar/título inline"
        )
        XCTAssertGreaterThan(
            pixels.count(in: CGRect(x: 0, y: chromeHeight, width: pixels.width, height: pixels.height - chromeHeight)) { $0.isTeal },
            500,
            "o exercício atual deve estar destacado com a cor de ação"
        )
    }

    // MARK: - Seleção arredondada

    func testSelectedRowBackgroundIsRoundedNotSquare() async throws {
        let probe = TrainingRowBackground(state: .current)
            .frame(width: 320, height: 64)
            .padding(20)
            .background(Color.black)

        let image = try await render(probe, name: "selected-row-rounded", size: CGSize(width: 402, height: 420))
        let pixels = try Self.pixels(of: image)
        guard let box = pixels.boundingBox(where: { $0.isTeal }) else {
            return XCTFail("o fundo selecionado precisa ser visível")
        }
        XCTAssertGreaterThan(box.width, 200)
        XCTAssertGreaterThan(box.height, 30)

        // Cantos do retângulo do fundo não podem estar pintados: é arredondado.
        for corner in [
            CGPoint(x: box.minX + 1, y: box.minY + 1),
            CGPoint(x: box.maxX - 1, y: box.minY + 1),
            CGPoint(x: box.minX + 1, y: box.maxY - 1),
            CGPoint(x: box.maxX - 1, y: box.maxY - 1),
        ] {
            XCTAssertFalse(
                pixels.rgb(x: Int(corner.x), y: Int(corner.y)).isTeal,
                "canto \(corner) pintado: o fundo de seleção está quadrado"
            )
        }

        // ...mas o meio está pintado (não é só um contorno fino).
        XCTAssertTrue(
            pixels.rgb(x: Int(box.midX), y: Int(box.midY)).isTeal,
            "o estado selecionado precisa de preenchimento, não só borda"
        )
    }

    func testCompletedRowUsesGreenAndCurrentUsesTeal() async throws {
        let probe = VStack(spacing: 12) {
            TrainingRowBackground(state: .current).frame(width: 320, height: 48)
            TrainingRowBackground(state: .done).frame(width: 320, height: 48)
        }
        .padding(16)
        .background(Color.black)

        let image = try await render(probe, name: "row-states", size: CGSize(width: 402, height: 420))
        let pixels = try Self.pixels(of: image)
        XCTAssertGreaterThan(pixels.count(in: nil) { $0.isTeal }, 500)
        XCTAssertGreaterThan(pixels.count(in: nil) { $0.isGreenish }, 500)
    }

    // MARK: - Infra

    private static func sampleSession() -> VitalsSession {
        VitalsSession(
            index: 0,
            name: "pernas · força",
            short: "a · pernas",
            rest: false,
            muscles: ["quadriceps", "gluteal"],
            exercises: [
                VitalsExercise(
                    id: "detail.agacho",
                    name: "Agachamento livre",
                    sets: [[6, 8], [6, 8], [6, 8]],
                    muscles: ["quadriceps"],
                    restSec: 120
                ),
                VitalsExercise(
                    id: "detail.leg",
                    name: "Leg press",
                    sets: [[10, 12], [10, 12]],
                    muscles: ["gluteal"],
                    restSec: 90
                ),
            ]
        )
    }

    @discardableResult
    private func render(
        _ view: some View,
        name: String,
        size: CGSize = CGSize(width: 402, height: 874)
    ) async throws -> UIImage {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        let controller = UIHostingController(rootView: AnyView(view))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await Task.sleep(nanoseconds: 1_000_000_000)
        controller.view.layoutIfNeeded()
        XCTAssertGreaterThan(controller.view.bounds.width, 0)
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        Self.dump(image, name: name)
        return image
    }

    private static func dump(_ image: UIImage, name: String) {
        guard let data = image.pngData() else { return }
        try? FileManager.default.createDirectory(at: dumpDirectory, withIntermediateDirectories: true)
        try? data.write(to: dumpDirectory.appendingPathComponent("\(name).png"))
    }

    private static func pixels(of image: UIImage) throws -> PixelGrid {
        let cgImage = try XCTUnwrap(image.cgImage)
        return try XCTUnwrap(PixelGrid(cgImage))
    }
}

struct RGB {
    let r: Int
    let g: Int
    let b: Int

    /// Ciano/teal: verde e azul claramente acima do vermelho.
    var isTeal: Bool { g > r + 12 && b > r + 12 && abs(g - b) < 60 }
    /// Verde de "concluído": verde acima dos outros dois.
    var isGreenish: Bool { g > r + 12 && g > b + 12 }
    /// Qualquer coisa que não seja o preto/branco puro do canvas.
    var isDistinctFromCanvas: Bool { max(r, max(g, b)) > 14 && min(r, min(g, b)) < 245 }
}

/// Leitura de pixels de um screenshot — só para asserções de teste.
struct PixelGrid {
    let width: Int
    let height: Int
    private let bytes: [UInt8]

    init?(_ image: CGImage) {
        width = image.width
        height = image.height
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &buffer,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        bytes = buffer
    }

    func rgb(x: Int, y: Int) -> RGB {
        guard x >= 0, y >= 0, x < width, y < height else { return RGB(r: 0, g: 0, b: 0) }
        let offset = (y * width + x) * 4
        return RGB(r: Int(bytes[offset]), g: Int(bytes[offset + 1]), b: Int(bytes[offset + 2]))
    }

    func count(in rect: CGRect?, where predicate: (RGB) -> Bool) -> Int {
        let box = clamped(rect)
        var total = 0
        for y in Int(box.minY)..<Int(box.maxY) {
            for x in Int(box.minX)..<Int(box.maxX) where predicate(rgb(x: x, y: y)) {
                total += 1
            }
        }
        return total
    }

    func boundingBox(where predicate: (RGB) -> Bool) -> CGRect? {
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width where predicate(rgb(x: x, y: y)) {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Recortes de teste chegam em pixels; aqui só garantimos que cabem na imagem.
    private func clamped(_ rect: CGRect?) -> CGRect {
        let full = CGRect(x: 0, y: 0, width: width, height: height)
        guard let rect else { return full }
        let clipped = rect.intersection(full)
        return clipped.isNull || clipped.isEmpty ? full : clipped.integral
    }
}
