import Foundation

enum BrainTools {
    static func register(registry: BrainRegistry = .shared) -> [MCPRegisteredTool] {
        [listBrains(registry), getBrainManifest(registry)]
    }

    private static func listBrains(_ registry: BrainRegistry) -> MCPRegisteredTool {
        MCPToolBuilder(
            name: "list_brains",
            description: "List all knowledge brains — the personal 'essence' brain plus any read-only domain brains. Returns id, title, gist, kind, ingest state, and node count so you can decide which brain to search.",
            schema: JSONSchemaObject(properties: [:]),
            handler: { _ in
                let items = registry.list().map { manifest -> [String: AnyCodableValue] in
                    [
                        "id": .string(manifest.id),
                        "title": .string(manifest.title),
                        "gist": .string(manifest.gist),
                        "kind": .string(manifest.kind.rawValue),
                        "state": .string(manifest.ingestState.rawValue),
                        "node_count": .int(manifest.nodeCount),
                    ]
                }
                return .json(items)
            }
        ).registered
    }

    private static func getBrainManifest(_ registry: BrainRegistry) -> MCPRegisteredTool {
        MCPToolBuilder(
            name: "get_brain_manifest",
            description: "Get a brain's full self-description (title, gist, kind, counts, ingest state, embedding model). Use to decide whether a brain is suitable before searching it.",
            schema: JSONSchemaObject(properties: [
                "brain": .string("Brain id (default: essence)"),
            ]),
            handler: { args in
                let id = args["brain"]?.stringValue ?? BrainRegistry.personalId
                guard let manifest = registry.manifest(id) else {
                    return .error("Unknown brain: \(id)")
                }
                let payload: [String: AnyCodableValue] = [
                    "id": .string(manifest.id),
                    "title": .string(manifest.title),
                    "gist": .string(manifest.gist),
                    "kind": .string(manifest.kind.rawValue),
                    "state": .string(manifest.ingestState.rawValue),
                    "source_count": .int(manifest.sourceCount),
                    "node_count": .int(manifest.nodeCount),
                    "embedding_model": manifest.embeddingModel.map { AnyCodableValue.string($0) } ?? .null,
                ]
                return .json(payload)
            }
        ).registered
    }
}
