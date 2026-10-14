import AppKit
import Foundation

public enum FilesWheelMode: String, Equatable {
    case convert
    case tools
}

extension FilesWheelMode {
    init(_ mode: FilesMode) {
        self = mode == .tools ? .tools : .convert
    }

    var mode: FilesMode { self == .tools ? .tools : .convert }
}

enum FilesContextualDismissReason: String, Equatable {
    case escape
    case commit
    case gap
    case reinvoked
    case sourceChanged
    case selectionChanged
    case stopped
}

enum FilesContextualArrow: Int, Equatable {
    case previous = -1
    case next = 1
}

enum FilesContextualKey: Equatable {
    case escape
    case enter
    case arrow(FilesContextualArrow)
}

struct FilesContextualPolicy: Equatable {
    struct Session: Equatable {
        let id: UUID
        let sourcePID: pid_t
        let fileKeys: [String]
        let optionCount: Int

        init(id: UUID = UUID(), sourcePID: pid_t, fileKeys: [String], optionCount: Int) {
            self.id = id
            self.sourcePID = sourcePID
            self.fileKeys = fileKeys
            self.optionCount = optionCount
        }
    }

    enum Input: Equatable {
        case present(Session)
        case hover(Int?)
        case arrow(FilesContextualArrow)
        case enter
        case click(Int?)
        case escape
        case invalidate(FilesContextualDismissReason)
    }

    enum Effect: Equatable {
        case select(Int?)
        case commit(sessionID: UUID, index: Int)
        case dismiss(FilesContextualDismissReason)
    }

    private(set) var session: Session?
    private(set) var selection: Int?

    var isPresenting: Bool { session != nil }

    var activeSessionID: UUID? { session?.id }

    mutating func apply(_ input: Input) -> [Effect] {
        switch input {
        case let .present(next):
            guard next.optionCount > 0, !next.fileKeys.isEmpty else {
                let wasPresenting = isPresenting
                clear()
                return wasPresenting ? [.dismiss(.reinvoked), .select(nil)] : [.select(nil)]
            }
            session = next
            selection = nil
            return [.select(nil)]
        case let .hover(index):
            guard let session else { return [] }
            let normalized = normalize(index, in: session)
            guard normalized != selection else { return [] }
            selection = normalized
            return [.select(normalized)]
        case let .arrow(direction):
            guard let session, session.optionCount > 0 else { return [] }
            let count = session.optionCount
            let next: Int
            if let current = selection {
                next = ((current + direction.rawValue) % count + count) % count
            } else {
                next = direction == .next ? 0 : count - 1
            }
            guard next != selection else { return [] }
            selection = next
            return [.select(next)]
        case .enter:
            guard let session, let index = selection else { return [] }
            let id = session.id
            clear()
            return [.commit(sessionID: id, index: index)]
        case let .click(index):
            guard let session else { return [] }
            guard let normalized = normalize(index, in: session) else {
                clear()
                return [.dismiss(.gap)]
            }
            let id = session.id
            let changed = normalized != selection
            clear()
            var effects: [Effect] = []
            if changed { effects.append(.select(normalized)) }
            effects.append(.commit(sessionID: id, index: normalized))
            return effects
        case .escape:
            guard isPresenting else { return [] }
            clear()
            return [.dismiss(.escape)]
        case let .invalidate(reason):
            guard isPresenting else { return [] }
            clear()
            return [.dismiss(reason)]
        }
    }

    private func normalize(_ index: Int?, in session: Session) -> Int? {
        guard let index, index >= 0, index < session.optionCount else { return nil }
        return index
    }

    private mutating func clear() {
        session = nil
        selection = nil
    }
}

enum FilesContextualFocus {
    static func shouldRestore(
        sourcePID: pid_t,
        frontmostPID: pid_t?,
        ownPID: pid_t,
        sourceRunning: Bool
    ) -> Bool {
        guard sourceRunning, sourcePID != ownPID else { return false }
        guard let frontmostPID else { return false }
        return frontmostPID == ownPID
    }

    static func shouldInvalidate(
        activatedPID: pid_t,
        sourcePID: pid_t,
        ownPID: pid_t
    ) -> Bool {
        activatedPID != sourcePID && activatedPID != ownPID
    }
}

enum FilesContextualFileKeys {
    static func keys(_ urls: [URL]) -> [String] {
        urls.map { $0.standardizedFileURL.path }
    }

    static func matches(_ lhs: [URL], _ rhs: [URL]) -> Bool {
        keys(lhs) == keys(rhs)
    }
}

struct FilesContextualNotice: Equatable {
    enum Remedy: Equatable {
        case none
        case automation(String)
        case accessibility
    }

    let title: String
    let message: String
    let remedy: Remedy

    var actionTitle: String? {
        switch remedy {
        case .none: return nil
        case .automation: return "Permitir Automação…"
        case .accessibility: return "Abrir pedido de Acessibilidade…"
        }
    }
}

enum FilesContextualNoticeFactory {
    static let finderBundleIdentifier = "com.apple.finder"

    static func isFinder(_ source: FileSelectionSource?) -> Bool {
        source?.bundleIdentifier == finderBundleIdentifier
    }

    static func permissionNotice(source: FileSelectionSource?) -> FilesContextualNotice {
        if isFinder(source) {
            return FilesContextualNotice(
                title: "Falta permissão de Automação",
                message: "O Whisper precisa da permissão de Automação para perguntar a seleção ao Finder. Conceda em Privacidade e Segurança › Automação › Whisper › Finder.",
                remedy: .automation(finderBundleIdentifier)
            )
        }
        let app = source?.bundleIdentifier ?? "o app em primeiro plano"
        return FilesContextualNotice(
            title: "Falta permissão de Acessibilidade",
            message: "Para ler a seleção de \(app) o Whisper precisa de Acessibilidade. Conceda em Privacidade e Segurança › Acessibilidade.",
            remedy: .accessibility
        )
    }

    static func notice(
        for failure: FileSelectionFailure,
        source: FileSelectionSource?
    ) -> FilesContextualNotice {
        switch failure {
        case .permissionDenied:
            return permissionNotice(source: source)
        case .noFrontmostApplication:
            return FilesContextualNotice(
                title: "Nenhum app em primeiro plano",
                message: "Não há app de origem para consultar a seleção.",
                remedy: .none
            )
        case .noSelection:
            return FilesContextualNotice(
                title: "Nada selecionado",
                message: isFinder(source)
                    ? "Selecione arquivos no Finder ou na Mesa e chame de novo."
                    : "Selecione arquivos no app de origem e chame de novo.",
                remedy: .none
            )
        case .unsupported:
            return FilesContextualNotice(
                title: "Seleção não suportada",
                message: "\(source?.bundleIdentifier ?? "O app de origem") não expõe arquivos selecionados de forma legível.",
                remedy: .none
            )
        case .timeout:
            return FilesContextualNotice(
                title: "A origem não respondeu",
                message: "A consulta de seleção expirou. Tente de novo com a janela de origem ativa.",
                remedy: .none
            )
        case .sourceChanged:
            return FilesContextualNotice(
                title: "A origem mudou",
                message: "Outro app ficou em primeiro plano durante a consulta; nada foi executado.",
                remedy: .none
            )
        case .tooManyItems:
            return FilesContextualNotice(
                title: "Seleção grande demais",
                message: "Reduza a quantidade de arquivos selecionados.",
                remedy: .none
            )
        case .symbolicLink:
            return FilesContextualNotice(
                title: "Atalho não aceito",
                message: "A seleção inclui link simbólico; use o arquivo original.",
                remedy: .none
            )
        case .invalidURL, .providerError:
            return FilesContextualNotice(
                title: "Não deu para ler a seleção",
                message: "A origem devolveu uma resposta inválida; nada foi executado.",
                remedy: .none
            )
        case .busy:
            return FilesContextualNotice(
                title: "Consulta em andamento",
                message: "Já existe uma leitura de seleção em curso.",
                remedy: .none
            )
        }
    }

    static func documentOnlyNotice(source: FileSelectionSource?) -> FilesContextualNotice {
        FilesContextualNotice(
            title: "Sem arquivos selecionados",
            message: "\(source?.bundleIdentifier ?? "O app de origem") só expôs o documento aberto. Selecione arquivos no Finder ou na Mesa para usar a roda.",
            remedy: .none
        )
    }

    static func noActionsNotice(urls: [URL]) -> FilesContextualNotice {
        FilesContextualNotice(
            title: "Nenhuma ação para esta seleção",
            message: urls.count == 1
                ? "Não há operação disponível para \(urls[0].lastPathComponent)."
                : "Não há operação comum aos \(urls.count) arquivos selecionados.",
            remedy: .none
        )
    }

    static let staleSelectionNotice = FilesContextualNotice(
        title: "A seleção mudou",
        message: "Os arquivos deixaram de ser os mesmos desde a abertura da roda; nada foi executado.",
        remedy: .none
    )

    static let ownApplicationNotice = FilesContextualNotice(
        title: "O Whisper está em primeiro plano",
        message: "A roda lê a seleção do app de origem. Volte para o Finder (ou para o app com os arquivos) e chame de novo.",
        remedy: .none
    )

    static func revalidationNotice(
        for failure: FileSelectionFailure,
        source: FileSelectionSource?
    ) -> FilesContextualNotice {
        let base = notice(for: failure, source: source)
        guard !base.message.contains("nada foi executado") else { return base }
        return FilesContextualNotice(
            title: base.title,
            message: base.message + " A ação escolhida não foi executada.",
            remedy: base.remedy
        )
    }
}
