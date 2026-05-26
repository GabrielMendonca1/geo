import Foundation

enum NoteTemplate: String, CaseIterable, Identifiable {
    case permanent
    case literature
    case project
    case moc

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .permanent: return "Permanente"
        case .project: return "Projeto"
        case .moc: return "MOC"
        case .literature: return "Literatura"
        }
    }

    var icon: String {
        switch self {
        case .permanent: return "lightbulb.fill"
        case .project: return "folder.fill"
        case .moc: return "map.fill"
        case .literature: return "quote.bubble.fill"
        }
    }

    var content: String {
        switch self {
        case .permanent:
            return """
            # {título — uma afirmação completa}

            Justificativa, exemplos, qualificações. Mantém-se em uma só ideia.

            ## Conecta-se com
            - [[]]
            - [[]]

            #permanent
            """
        case .literature:
            return """
            # {título — referência da fonte}

            **Fonte:**
            **Autor:**

            ## Resumo
            Em palavras suas, o que a fonte argumenta.

            ## Trechos chave
            > "..."

            ## Conecta-se com
            - [[]]

            #literature
            """
        case .project:
            return """
            # {nome do projeto}

            **Deadline:**

            ## Objetivo

            ## Próximos passos
            - [ ]

            ## Insights extraídos
            > Antes de arquivar, promova qualquer aprendizado para uma permanent note.
            - [[]]

            #project
            """
        case .moc:
            return """
            # MOC — {tema}

            ## Núcleo
            - [[]]

            ## Sub-temas
            ###
            - [[]]

            ## Pontes
            - [[MOC — outro tema]]

            #moc
            """
        }
    }

    var initialMetadata: BlockEntity.Metadata {
        switch self {
        case .permanent:
            return BlockEntity.Metadata(status: "evergreen", type: .permanent)
        case .literature:
            return BlockEntity.Metadata(status: "active", type: .literature)
        case .project:
            return BlockEntity.Metadata(status: "active", type: .project)
        case .moc:
            return BlockEntity.Metadata(status: nil, type: .moc)
        }
    }
}
