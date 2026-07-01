# Brains — End-to-End Build Blueprint (workflow-generated, critique-hardened)

_Source: brains-e2e-blueprint workflow (8 agents). Critique fixes folded into implementation. Build order: 2b-storage → 2b-ingest → 2a → 2c → 3._

All key anchors verified. The specs are accurate: GraphView gates at :753 and :825 are byte-identical to what Spec 4 claims; `onNodeTap` is the trailing required member at :527 (Spec 4's "insert before onNodeTap" placement is correct); the 6 direct `blocks.*` calls at :103/155/165/209/322/381 confirm Spec 6's routing gap. `searchBlocks` takes `_ blocks` positionally. AppTab confirms the case names (`.nodes`, `.nano`) and ordering. I have everything needed to synthesize.

---

# BRAINS — UNIFIED ADDITIVE IMPLEMENTATION BLUEPRINT

Spine (Phase 1) is green (595/0). This blueprint covers Phases 2a → 2b-storage → 2b-ingest → 2c → 3. Every existing-file edit is tagged ADDITIVE or BEHAVIORAL; there are ZERO behavioral changes to working UI (one BEHAVIORAL tag remains on `NavigationSegmentedControl` — resolved to Option A/B in §4 and §UI-VERDICT). All paths absolute.

---

## 1. ORDERED PHASE CHECKLIST + DEPENDENCIES

```
P2b-storage  (schema + edge/vector DB methods + DatabaseBrainIndex.semanticSearch/listNeighbors)
     │  hard edge: ingest writes vectors/edges through these methods; semanticSearch needs the table
     ▼
P2b-ingest   (ChunkSummarizer/EmbeddingService protocols + fakes, SourceExtractor, Chunker,
     │        two-pass IngestPipeline state machine; AnthropicClient.complete extraction;
     │        BlockFileService blocksDirectoryOverride)
     │  depends on P2b-storage (upsertVector/setEdges); embeds via EmbeddingService
     ▼
P2a-routing  (BrainCallContext interceptor in MCPToolRegistry.call; GeoAPIRouter x-geo-brain;
     │        BrainTools list_brains/get_brain_manifest; search_blocks +mode/+brain)
     │  compiles against spine alone, but ship AFTER P2b so routed semantic/lexical reads return real data
     ▼
P2c-graph    (GraphView.isActive additive gate; BrainGraphStore; per-brain graph build via
     │        IndexCoordinator(database:) injection)
     │  depends on P2b-storage (a populated index.sqlite to graph); reuses BlockGraphService unchanged
     ▼
P3-UI        (Brains feature module: tab + panes + read-only viewer + paged node list)
              depends on spine BrainRegistry.list()/manifest() for the catalog; on P2b for ingest trigger;
              on P2c for the embedded per-brain graph; on P2a only if panes drive brain-scoped HTTP/MCP reads
```

> NOTE the locked-context labels (2a/2b/2c/3) and Spec 6's inferred labels disagree. This blueprint uses the **locked-context taxonomy**: 2a = tool/API surface + routing interceptor; 2b-storage = per-brain schema; 2b-ingest = pipeline; 2c = graph; 3 = UI. Build order above puts storage first (a hard dependency for everything) and routing after storage so routed reads aren't empty — this reorders the *label* sequence but respects every hard edge. Implement in the dependency order shown, not in label order.

Within each phase, `BrainsTests.swift` and the new test files are already / will be in GeoTests, so test edits never need a pbxproj change.

---

## 2. PER-PHASE SPEC

### PHASE 2b-storage — per-brain schema + edge/vector query methods

**NEW files:** none.

**EXISTING-file edits:**

`/Users/biel/ARCA/Forge/Geo/Geo/Shared/Infrastructure/Database/DatabaseService.swift`
- **ADDITIVE** — add file-level `enum DatabaseSchemaProfile: Sendable { case personal; case domain }`.
- **ADDITIVE** — `init` at **:65** gains trailing defaulted param: `init(databaseURL: URL? = nil, fileManager: FileManager = .default, schema: DatabaseSchemaProfile = .personal)`. Verified: every caller (`.shared` :60, `Brains.swift:216`, all tests) uses `databaseURL:`/`fileManager:` only → all compile unchanged, all resolve `.personal`.
- **ADDITIVE** — at **:72** change `Self.buildMigrator()` → `Self.buildMigrator(schema: schema)`. Lines :73–83 (migrate + destructive `forceRecreate` fallback) untouched.
- **ADDITIVE** — parameterize `buildMigrator` (**:112**): `private static func buildMigrator(schema: DatabaseSchemaProfile = .personal) -> DatabaseMigrator`. Move the current body (:114–230, the six `registerMigration` blocks, verbatim, same names/order/SQL) into a new `registerPersonalMigrations(_:)`. Then `if case .domain = schema { registerDomainMigrations(&migrator) }`. **Migration-identity proof:** `.personal` registers exactly today's six migrations in the same order → existing on-disk `blocks.sqlite` migrates as a no-op and passes GRDB's consistency check. Domain migrations only ever register on a fresh `index.sqlite` that has never seen `.personal` → no cross-profile conflict.
- **ADDITIVE** — `registerDomainMigrations`: `createBrainEdges` (`edges(sourceId TEXT NOT NULL, targetTitle TEXT NOT NULL, targetId TEXT)` + index `edges_source` on `["sourceId"]` + index `edges_target` on `["targetId"]` — two single-column indexes give O(deg) both directions, composite cannot serve the reverse lookup) and `createBrainNodeVec` (`node_vec(blockId TEXT PRIMARY KEY, dims INTEGER NOT NULL, embedding BLOB NOT NULL)`). Keep migrations pure-DDL — no throwing backfill (the `forceRecreate` fallback at :105 would nuke the brain index on a migration throw).
- **ADDITIVE** — new methods after `fetchBlocks(ids:)`: private statics `encodeVector([Float])->Data` (`v.withUnsafeBytes { Data($0) }`) and `decodeVector(Data)->[Float]` (derive count from byte length, bind `Float.self`); `struct BrainEdge { sourceId; targetTitle; targetId: String? }`; `setEdges(forSource:edges:)` (delete-all-for-source then insert), `outgoingEdges(from:)`, `incomingEdges(to:)`, `resolveEdgeTargets(title:toBlockId:)` (bulk `UPDATE … WHERE targetId IS NULL AND targetTitle = ?` matching **raw** title); `upsertVector(blockId:embedding:)` (`INSERT … ON CONFLICT(blockId) DO UPDATE`), `loadAllVectors() -> [(id:String, vector:[Float])]`. All via existing `performWrite`/`performRead` (:559–583).

> **RESOLVED CONFLICT (vector table name/columns):** Spec 2 names the table `node_vec(blockId, dims, embedding)` and methods `upsertVector`/`loadAllVectors`. Spec 3 names it `embeddings`/`node_vec(blockId, dims, vec)` with `upsertEmbedding`/`fetchAllEmbeddings`. Spec 6 says `embeddings`. **Use Spec 2's `node_vec(blockId, dims, embedding)` + `upsertVector`/`loadAllVectors`** — it is the most detailed and self-consistent, and the ingest spec (2b-ingest) below is wired to call exactly those names. Drop the `embeddings` name everywhere.

`/Users/biel/ARCA/Forge/Geo/Geo/Shared/Infrastructure/Brains/Brains.swift`
- **ADDITIVE (replace known stub, not a surface)** — implement `DatabaseBrainIndex.semanticSearch` (currently `[]` at **:124–126**): `guard k>0, !embedding.isEmpty else { [] }; let c = try await database.loadAllVectors(); guard !c.isEmpty else { [] }; return VectorMath.topK(query: embedding, candidates: c, k: k)`.
- **ADDITIVE (protocol requirement + default impl, atomic)** — add `func listNeighbors(of blockId: String) async throws -> (incoming: [BlockIndexEntry], outgoing: [BlockIndexEntry])` to `BrainIndex` (:94–100) **AND** a default impl in `extension BrainIndex` returning `([],[])` in the **same commit** (Spec 6 #2 violation fix — a bare requirement breaks `DatabaseBrainIndex` conformance; the default keeps the personal index, which has no `edges` table, conformant). Implement the real version on `DatabaseBrainIndex` via `incomingEdges`/`outgoingEdges` + `fetchBlocks(ids:)`.

> **OPEN DECISION (carry to P2c/P3):** Spec 6 #2 argues `listNeighbors` on the protocol may be **unnecessary** — the existing `list_neighbors` MCP tool, once brain-routed by 2a, covers neighbor reads, and the personal graph resolves neighbors via `BlockGraphService`, not the edges table. **Recommendation:** still ship `setEdges`/`incoming`/`outgoing` DB methods in 2b-storage (the ingest pipeline must persist edges), but make `listNeighbors` on the protocol **optional/deferred** — only add it if P2c's `BrainGraphStore` or a brain-scoped `list_neighbors` actually needs it. If added, the default-impl pattern above is mandatory. Lowest-risk path: defer the protocol requirement; keep only the DB methods + the additive default if/when needed.

**Unit tests** (append to `/Users/biel/ARCA/Forge/Geo/Geo/Tests/BrainsTests.swift`, temp `.domain` DB, `defer` cleanup, follows existing `testDatabaseBrainIndexLexicalGetAndType` at :104):
1. `testPersonalSchemaHasNoDomainTables` — default-`.personal` DB; upsert+fetch a block works (personal path untouched).
2. `testEdgeRoundTripBothDirections` — `setEdges` with one resolved + one `nil`-target edge; assert `listNeighbors` incoming/outgoing.
3. `testSetEdgesReplacesPriorEdges` — delete-all-for-source semantics.
4. `testVectorBlobRoundTrip` — `upsertVector([0.1,0.2,0.3])` → `loadAllVectors` equal within 1e-6, count 3.
5. `testSemanticSearchRanksByCosine` — three vectors, `semanticSearch(query:[1,0],k:2)` ranks aligned-then-diagonal (end-to-end through SQLite; mirrors `testTopKRanksByDescendingSimilarity` :27).
6. `testSemanticSearchEmptyWhenNoVectors` — `.domain` DB, zero rows → `[]`.
7. `testPersonalIndexListNeighborsDefaultsEmpty` — personal index → `([],[])` via default (negative proof; only if `listNeighbors` ships).

---

### PHASE 2b-ingest — extraction → chunk → two-pass summarize/reconcile → embed → index

**NEW files (all → Geo target):**
- `/Users/biel/ARCA/Forge/Geo/Geo/Shared/Infrastructure/Brains/ChunkSummarizer.swift` — `protocol ChunkSummarizer: Sendable { func summarize(_ chunk: String, context: SummarizeContext) async throws -> String }` + `struct SummarizeContext { brainTitle; brainGist; sourceLabel }` + `AnthropicHaikuSummarizer` (real, calls `AnthropicClient.complete`).
- `/Users/biel/ARCA/Forge/Geo/Geo/Shared/Infrastructure/Brains/EmbeddingService.swift` — `protocol EmbeddingService: Sendable { var dims: Int { get }; func embed(_ text: String) async -> [Float]? }` + `NLEmbeddingService` (`NLEmbedding.sentenceEmbedding(for: .english)`, 512-dim, nil-guarded, `[Double]→[Float]`). Model call AND embedding both sit behind protocols → pipeline tests use fakes, zero network/model.
- `/Users/biel/ARCA/Forge/Geo/Geo/Shared/Infrastructure/Brains/SourceExtractor.swift` — `protocol SourceExtractor` + `DefaultSourceExtractor` (PDFKit page loop; HTML→text pure helper; image via `OCRService.shared.process` wrapped in `withCheckedContinuation`; `case .audio: throw NotSupported`).
- `/Users/biel/ARCA/Forge/Geo/Geo/Shared/Infrastructure/Brains/Chunker.swift` — `struct Chunk { text; hash; order; sourceLabel }` + `enum Chunker { static func chunk(...) }`; `hash = SHA256(NFC(text))` via `.precomposedStringWithCanonicalMapping` (reuse `BlockGraphService.deterministicUUID` pattern :492); 800-word window / 80 overlap.
- `/Users/biel/ARCA/Forge/Geo/Geo/Shared/Infrastructure/Brains/IngestPipeline.swift` — `enum BrainIngestStep`, non-recursive `advance(brain:summarizer:embedder:...)` executing ONE step/window, persisting cursor to `brain.json`. Pass1 chunk→literature md (`# title`, prose, `[[concept]]` links) with frontmatter `type: literature`, `layer: shared` (`user` is forbidden for agent writes), `frontmatter_version: 1`, `chunk_hash: <sha>`. Bounded-concurrency TaskGroup **cap 8** owned here (not the protocol). Pass2 reconcile: bucket all `[[mentions]]` (via `BlockGraphService.extractWikiLinks` :440) by `WikiTitleNormalizer.normalize` key → O(N), deterministic canonical = **longest-then-lexicographically-smallest** (pin the comparator), rewrite links preserving `|alias`, skip write if bytes unchanged. SOLE writer; never an MCP tool.

**EXISTING-file edits:**

`/Users/biel/ARCA/Forge/Geo/Geo/Shared/Infrastructure/AI/AnthropicClient.swift`
- **ADDITIVE** — extract `static func complete(system:user:maxTokens:Int=4096) async throws -> String` from `parseTask` (:88–155), reusing private `sendWithRetry` (:157), status-check, text-extraction. `parseTask` then calls `complete` + its existing `stripCodeFences`/`decodeTaskJSON`. Byte-identical on the wire (same model `claude-haiku-4-5-20251001` :38, headers, cache beta). `sendWithRetry` stays private.

`/Users/biel/ARCA/Forge/Geo/Geo/Shared/Infrastructure/Brains/Brains.swift`
- **ADDITIVE** — add `enum BrainIngestStep: String, Codable, Sendable` (pending/extracting/summarizing/reconciling/embedding/indexing/ready/failed) and additive Codable manifest fields `var ingestStep: BrainIngestStep? = nil` + `var lastError: String? = nil` (default-nil → existing `brain.json` decodes unchanged). Keep the coarse `BrainIngestState` (:9) as the UI-facing field (map extracting…indexing → `.ingesting`). Persist `embeddingModel="NLEmbedding"` + `embeddingDims=512` on the manifest when embedding completes.

`/Users/biel/ARCA/Forge/Geo/Geo/Features/Blocks/Data/BlockFileService.swift`
- **ADDITIVE** — add `blocksDirectoryOverride: URL? = nil` to `init` (~:13–26). When nil, compute `Geo/Blocks` as today (byte-identical for all existing callers); when set, `blocksDirectory = override`. Lets the pipeline write into `Geo/Brains/<id>/Blocks` (`BrainPaths.blocksDir` :202). Sanctioned "optional param whose default == current behavior."

> **RESOLVED CONFLICT (where the ingest DB write lands):** Spec 3 §6 proposed adding the `node_vec` migration here; Spec 2 already owns it in 2b-storage. **2b-storage owns ALL schema + DB methods.** 2b-ingest only *calls* `upsertVector`/`setEdges`/`upsertBlock` against a `DatabaseService(databaseURL: paths.indexURL, schema: .domain)`. Domain DBs are constructed with `.domain` — see the wiring flip below.

> **RESOLVED — domain DB `.domain` profile activation:** `Brains.swift:216` currently builds `DatabaseService(databaseURL: paths.indexURL)` (defaults `.personal`). **Flip to `DatabaseService(databaseURL: paths.indexURL, schema: .domain)`** — **ADDITIVE/behavior-preserving** (personal branch at :215 still uses `.shared`/`.personal`; no UI touched). Place this flip in **2b-storage** (so its tests that construct `.domain` DBs match the production path) — Spec 2 §6 recommends including it there. Without it, domain DBs lack `edges`/`node_vec` and ingest throws "no such table."

**Unit tests** → NEW `/Users/biel/ARCA/Forge/Geo/Geo/Tests/IngestPipelineTests.swift` (GeoTests; FakeSummarizer + FakeEmbedder live here, test-only). Zero network/model:
- Chunking: fixed input → chunk count, 80-word overlap, `hash == SHA256(NFC(text))` precomputed hex; NFC vs NFD inputs → identical hash.
- Reconcile: diacritic/case/hyphen variants (`[[T-cell]]`/`[[T cells]]`/`[[t-cells]]`) → single bucket, canonical = longest-then-lex-smallest, links rewritten preserving `|alias`, re-run byte-identical.
- State machine: drive `advance` repeatedly over temp brain dir + FakeSummarizer → exact step order to `.ready`; re-running a done step is a no-op (file bytes + `node_vec` count unchanged); injected error → `.failed` + `lastError`, recoverable.
- Write+index: one `indexing` step → `.md` on disk with correct frontmatter; `DatabaseBrainIndex.get`/`lexicalSearch`/`listByType("literature")` all find it in the per-brain `.domain` sqlite.
- Embedding round-trip: synthetic `[Float]` via `upsertVector`→`loadAllVectors` within 1e-6; `semanticSearch` returns matching id first. Guard any live `NLEmbedding` path behind `XCTSkipUnless(NLEmbedding.sentenceEmbedding(for: .english) != nil)`.
- Extraction: PDF page loop on a tiny bundled fixture; HTML→text as a pure-function test on a fixed string.

---

### PHASE 2a — tool/API surface + resolve-once brain interceptor

**NEW files (→ Geo target):**
- `/Users/biel/ARCA/Forge/Geo/Geo/Shared/Infrastructure/MCP/Tools/BrainTools.swift` — `enum BrainTools { static func register(registry: BrainRegistry = .shared) -> [MCPRegisteredTool] }` exposing `list_brains` (empty schema) and `get_brain_manifest` (`brain` prop, default `essence`). Both read `BrainRegistry` directly (brain-agnostic at the data level).

> **RESOLVED CONFLICT (BrainCallContext file placement):** Spec 1 recommends **appending** `BrainCallContext` to `MCPToolRegistry.swift` to avoid a second pbxproj entry. Spec 6 lists an optional separate `BrainRouting.swift`. **Append to `MCPToolRegistry.swift`** — fewer pbxproj edits, the type is tightly coupled to `call`.

**EXISTING-file edits:**

`/Users/biel/ARCA/Forge/Geo/Geo/Shared/Infrastructure/MCP/MCPToolRegistry.swift`
- **ADDITIVE** — append `struct BrainCallContext: Sendable { let brainId: String; let index: BrainIndex; @TaskLocal static var current: BrainCallContext? = nil; static let brainScopedReadTools: Set<String> = [...] }`. Whitelist = pure readers only: `search_blocks, get_block, get_block_by_title, list_blocks, list_by_type, list_by_status, find_backlinks, find_orphans, find_unresolved_links, list_neighbors, get_graph_snapshot, list_brains, get_brain_manifest`. Excludes all write/destructive + Task/Day/Tag/AI tools.
- **ADDITIVE** — add `brains: BrainRegistry = .shared` to `init` (:13). Existing `MCPToolRegistry(tools: mcpTools)` (GeoApp.swift:133) compiles unchanged.
- **ADDITIVE (provably pass-through default branch — Spec 6 #5 obligation)** — rewrite `call` body (:25–30): resolve `brainId = arguments["brain"]?.stringValue ?? BrainRegistry.personalId`; if non-personal AND not in `brainScopedReadTools` → `.error("read-only-blocked …")`; `guard let index = brains.index(for: brainId) else { .error("unknown brain …") }`; then `try await BrainCallContext.$current.withValue(BrainCallContext(brainId:index:)) { try await tool.handler(arguments) }`. **When `brain` absent → brainId == "essence" → guard skipped → `index(for:"essence")` always resolves (seeded :155) → TaskLocal bound but unread by all 70+ handlers → byte-identical to today.** Covers BOTH callers: `MCPRouter.handleToolCall` (:80) and `GeoAPIRouter.call` (:285).

`/Users/biel/ARCA/Forge/Geo/Geo/Shared/Infrastructure/HTTP/GeoAPIRouter.swift`
- **ADDITIVE** — add `extension GeoAPIRouter { @TaskLocal static var requestBrain: String? = nil }`.
- **ADDITIVE** — at **:38**, wrap dispatch: `let brain = request.headers["x-geo-brain"]?.lowercased(); let response = await GeoAPIRouter.$requestBrain.withValue(brain) { await dispatch(request: request, token: token) }`. (Server lowercases header keys at parse time; value defensively lowercased.)
- **ADDITIVE** — at `call` (**:283**): `var args = args; if args["brain"] == nil, let b = GeoAPIRouter.requestBrain, !b.isEmpty { args["brain"] = .string(b) }` then existing `registry.call`. One edit reaches all ~40 routes; route table untouched. No header → no key → personal path identical.

`/Users/biel/ARCA/Forge/Geo/Geo/Shared/Infrastructure/MCP/Tools/BlockTools.swift`
- **ADDITIVE** — `searchBlocks` (:198–220): add schema props `mode` (enum `["lexical","semantic"]`) + `brain`, both optional, `query` stays sole required. Handler reads `BrainCallContext.current`: default (`ctx == nil || ctx.brainId == essence`, lexical) → **exact current `blocks.search` path**; else route to `ctx.index.lexicalSearch`. **Note:** `searchBlocks` takes `_ blocks` positionally (verified) — handler closure already captures it; no signature change.

> **RESOLVED CONFLICT (semantic mode):** there is NO embedding generator wired into `search_blocks` yet (the query arrives as a string; `semanticSearch` needs a `[Float]`). **DECISION:** since 2b-ingest now ships `EmbeddingService`, the cleanest path is: in 2a, add the `mode`/`brain` schema and route `mode:semantic` through `EmbeddingService.embed(query)` → `ctx.index.semanticSearch(embedding, k:)`. If you prefer to keep 2a model-call-free (Spec 1's stricter reading), ship only `brain` + lexical-over-index in 2a and add `mode:semantic` wiring as a one-line follow-up once `EmbeddingService` is injectable into `BlockTools.register`. **Recommendation:** wire semantic in 2a using the now-available `EmbeddingService` (pass it into `BlockTools.register` as an additive defaulted param), so the API surface ships complete. Either way the default lexical/personal branch is byte-identical.

`/Users/biel/ARCA/Forge/Geo/Geo/App/GeoApp.swift`
- **ADDITIVE** — at **:130–131**, append `+ BrainTools.register()` to the `mcpTools` chain. `tools/list` auto-includes the two new defs.

> **ROUTING GAP (flag, not a violation — Spec 6 §2/§8):** `GeoAPIRouter` calls `blocks.listFolders/move/createFolder/get` **directly** at :103/155/165/209/322/381 (verified), bypassing `registry.call` and therefore the interceptor — they are permanently `essence`-scoped. Acceptable under read-only-domain-brains (these are write/management ops). **Do NOT thread a brain into the `blocks` repo path** (would risk the working essence write path). If a domain brain ever needs `get`/folders, route them through `registry.call` instead.

**Unit tests** (append to `BrainsTests.swift`; construct `MCPToolRegistry(tools:, brains: tempRegistry)`):
1. `testInterceptorDefaultsToPersonalWhenNoBrainArg`, 2. `testInterceptorBindsRequestedDomainBrain`, 3. `testInterceptorBlocksWriteToolOnDomainBrain` (`update_block` + `brain:"x"` → "read-only-blocked"), 4. `testInterceptorAllowsReadToolOnPersonalBrain`, 5. `testInterceptorUnknownBrainErrors`, 6. `testSearchBlocksLexicalPersonalUnchanged`, 7. `testSearchBlocksLexicalDomainUsesIndex`, 8. `testListBrainsReturnsEssenceFirst` + `testGetBrainManifestUnknownErrors`, 9. `testHTTPHeaderInjectsBrain` (or focused `requestBrain` TaskLocal test if a valid `APITokenStore` token is heavy). **Byte-identical default-branch test is the load-bearing one** (Spec 6 #5).

---

### PHASE 2c — per-brain graph render without touching the working graph UI

**NEW files (→ Geo + GeoTests):**
- `/Users/biel/ARCA/Forge/Geo/Geo/Features/Brains/Data/BrainGraphStore.swift` (Geo) — `@MainActor final class BrainGraphStore: ObservableObject` (NOT a singleton; one per brain id). `@Published private(set) var graph: BlockGraph = .empty`, `idLookup: [UUID:String] = [:]`, `cachedPositions`, `simulationSettled`. `func load(registry: BrainRegistry = .shared) async`: resolve `paths`, `db = isPersonal ? .shared : DatabaseService(databaseURL: paths.indexURL, schema: .domain)`, `BlockGraphService(indexCoordinator: IndexCoordinator(database: db), tagStore: .shared).loadGraph()`. Read-only — NO `.blocksExternallyChanged` observer, no delta machinery. `updateLayoutCache(positions:settled:)` mirrors `GraphStore:99`.

**EXISTING-file edits:**

`/Users/biel/ARCA/Forge/Geo/Geo/Features/Graph/UI/GraphView.swift`
- **ADDITIVE** — insert `var isActive: (() -> Bool)? = nil` among the defaulted members **before** the required trailing `onNodeTap` at :527 (e.g. right after `onLayoutChange` at :526). **Placement is load-bearing:** `onNodeTap` is the positional trailing closure at both call sites (`NodesPane.swift:63`, `#Preview`); inserting after it would shift the trailing-closure slot (compile break). Before it = safe.
- **ADDITIVE** — at **:753**: `isActiveCheck: { [tabRouter] in isActive?() ?? (tabRouter.selectedTab == .nodes) }`.
- **ADDITIVE** — at **:825**: same swap. When `isActive == nil` (every existing call site), `nil ?? (tabRouter.selectedTab == .nodes)` is the verbatim original expression, same `[tabRouter]` capture. `tabRouter` (:530) stays live. **`NodesPane.swift`, `GraphStore.swift`, `BlockGraph.swift`, `BlockGraphService.swift` are NOT edited** — `BrainGraphStore` reuses `BlockGraphService` via `IndexCoordinator(database:)` injection (both already accept arbitrary instances).

> **RESOLVED CONFLICT (`BlockGraphService.buildGraph` visibility):** Spec 5 proposed widening `private func buildGraph` to internal. Spec 4 shows `BrainGraphStore` can instead call the existing `BlockGraphService(indexCoordinator:).loadGraph()` (which internally calls `buildGraph` over `fetchAllBlocks()`), requiring **zero** edit to `BlockGraphService`. **Use Spec 4's path — do NOT widen `buildGraph`.** `loadGraph()` already returns `(.empty,[:])` for an empty index.

> **tagColors note:** domain-brain `tagId`s won't exist in personal `TagStore.shared` → nodes render neutral grey (`GraphView:1201`), color-by-type/-layer still works. Safe v1 default, no new tag infra.

**Unit tests** → NEW `/Users/biel/ARCA/Forge/Geo/Geo/Tests/BrainGraphStoreTests.swift` (GeoTests):
1. **Gate behavior-preservation (load-bearing):** pure harness `gate(isActive:tabIsNodes:) = isActive?() ?? tabIsNodes` → `gate(nil,true)==true`, `gate(nil,false)==false`, `gate({true},false)==true`, `gate({false},true)==false`. Locks the `??` semantics without SwiftUI.
2. `load` builds graph from a seeded temp `.domain index.sqlite` → node/edge counts.
3. Empty brain → `graph == .empty`, `idLookup == [:]`.
4. Read-only API shape (no mutation method beyond `updateLayoutCache`).
5. `updateLayoutCache` round-trip.
6. Personal-brain parity: `BrainGraphStore("essence").load()` == `BlockGraphService().loadGraph()` over `.shared`.

---

### PHASE 3 — additive Brains feature module (tab + panes)

**NEW files (all → Geo target):**
- `/Users/biel/ARCA/Forge/Geo/Geo/Features/Brains/UI/BrainsPane.swift` — `.brains` destination; `Pane { ScrollView { LazyVStack { ForEach(brains) { BrainCard } } } }`; `@State brains = BrainRegistry.shared.list()` in `.task`; `+` "New Brain" chip → `CreateBrainSheet`; empty state cloned from `BlocksPane.emptyState`; inner `@State openBrain` drives a full-pane push (kept inside BrainsPane).
- `/Users/biel/ARCA/Forge/Geo/Geo/Features/Brains/UI/BrainCard.swift` — styled after `BlockListRow`; title/gist/`nodeCount` + ingest-state badge from `BrainIngestState`.
- `/Users/biel/ARCA/Forge/Geo/Geo/Features/Brains/UI/CreateBrainSheet.swift` — chrome cloned from `TagCreationSheet`; derive `id` via `WikiTitleNormalizer`; `BrainManifest(...).save(to: paths(id).manifestURL)`; advance to `AttachSourcesView`.
- `/Users/biel/ARCA/Forge/Geo/Geo/Features/Brains/UI/AttachSourcesView.swift` — NEW `.onDrop(of:[.fileURL])` drop zone (net-new; `AttachmentHandler` is pasteboard-only, not reused); copy URLs into `paths(id).sourcesDir`; bump `sourceCount`; flip `ingestState .empty→.ingesting`; save; kick the IngestPipeline by id (app-internal, never MCP).
- `/Users/biel/ARCA/Forge/Geo/Geo/Features/Brains/UI/IngestDetailView.swift` — honest state-machine status (indeterminate `ProgressView()` for `.ingesting`, "advances when the agent next runs"); reads live status via `BrainManifest.load(from: paths.manifestURL)` on `.task`/timer (registry caches manifests at init — read `brain.json` directly for live progress).
- `/Users/biel/ARCA/Forge/Geo/Geo/Features/Brains/UI/BrainNodeView.swift` — READ-ONLY viewer; renders markdown via `MarkdownStyler`/`MarkdownConverter` in a `ScrollView`, NOT `BlockEditor`/`BlockTextEditorView`; tappable `[[concept]]` links load sibling nodes; no save/delete/mutate menu.
- `/Users/biel/ARCA/Forge/Geo/Geo/Features/Brains/UI/BrainNodesView.swift` — paged node list (`pageSize 50`, `offset`, infinite-scroll via last-row `.onAppear`) + embedded per-brain `GraphView` fed by `@StateObject BrainGraphStore` (call shape from `NodesPane.swift:49–69`); node tap → `BrainNodeView`, never `openWindow`.

> **RESOLVED CONFLICT (BrainGraphStore location/init):** Spec 4 puts it at `Features/Brains/Data/BrainGraphStore.swift` with `init(brainId:)`; Spec 5 puts it in the same file but as `BrainGraphStore()` + `load(brainId:)`. **Single file `Features/Brains/Data/BrainGraphStore.swift` (owned by Phase 2c), `load(registry:)`-style API.** Phase 3 only *consumes* it. Do not duplicate.

> **RESOLVED CONFLICT (paging):** Spec 5 wants a new `BrainIndex.listAll(limit:offset:)` + `DatabaseService.fetchAllBlocks(limit:offset:)`. This is **only needed if `BrainNodesView` paginates the list.** **DECISION:** add it as part of Phase 3 (it's a P3-driven need), ADDITIVE:
> - `DatabaseService.swift` — **ADDITIVE** new overload `fetchAllBlocks(limit:offset:)` next to `fetchAllBlocks()` (`SELECT id … ORDER BY modifiedAt DESC LIMIT ? OFFSET ?` then `fetchBlocks(ids:)`); existing zero-arg version untouched.
> - `Brains.swift` — **ADDITIVE** `BrainIndex.listAll(limit:offset:)` requirement + `extension BrainIndex` default (fallback to `listByType`/empty) so personal index conforms; real impl on `DatabaseBrainIndex`. Same atomic protocol+default discipline as `listNeighbors`.
> If a simpler v1 ships the full node list unpaged (domain brains bounded to hundreds–low-thousands), this whole sub-edit is **deferrable** — flag as open.

**EXISTING-file edits:**

`/Users/biel/ARCA/Forge/Geo/Geo/Shared/Navigation/AppTab.swift`
- **ADDITIVE** — add `case brains = "Brains"` (:3–8).
- **ADDITIVE** — append `.brains` to **END** of `defaultNavigationOrder` (:10) → `[.home, .nano, .tasks, .nodes, .brains]`. ⌘1–⌘4 unchanged, new tab = ⌘5. (Option A; see UI-VERDICT.)
- **ADDITIVE** — new switch arms in `displayTitle` (:27), `icon` (:37), `destinationView` (:63): `case .brains: …` / `BrainsPane()`. Compile-forced exhaustiveness = sanctioned new-case pattern. `shortcutHint` (:46) auto-derives ⌘5 via `firstIndex`.

`/Users/biel/ARCA/Forge/Geo/Geo/Shared/Navigation/NavigationSegmentedControl.swift`
- **BEHAVIORAL (flagged — title bar is a working surface)** — `TabIconView` switch (:77–92) is exhaustive over `AppTab` → MUST add `case .brains: Image(systemName: tab.icon)` to compile. The arm is behavior-preserving for existing cases; the *visible* 5th segment comes from the `defaultNavigationOrder` append (Option A), not this arm. See UI-VERDICT for Option B (4 segments, ⌘5 via explicit button) which keeps the segment count unchanged but still requires this compile-forced (non-rendering) arm.

**NO EDIT (confirmed):** `UnifiedNavigationContainer.swift` (iterates `allCases`, auto-includes; `maxLiveTabs = allCases.count` auto-grows), `MenuActions.swift` (`showTab` generic), `MyCommands.swift` (Option A: `ForEach(defaultNavigationOrder.enumerated())` auto-assigns ⌘5).

**Unit tests:** Phase 3 is UI; no test files mandated by specs. Optional: a `BrainsPane`/`BrainCard` snapshot or a `CreateBrainSheet` id-derivation test → GeoTests.

---

## 3. CONSOLIDATED NEW-FILES → TARGET (xcodeproj-gem registration)

Classic pbxproj objectVersion 55, no synchronized groups. Each app file needs the 4-stanza pattern (PBXBuildFile, PBXFileReference, group child, Sources build phase) in the correct group; each test file the same into GeoTests sources. `BrainCallContext` is appended to `MCPToolRegistry.swift` (NO new file). FakeSummarizer/FakeEmbedder live inside `IngestPipelineTests.swift` (no shipped file).

**→ Geo (app) target:**
1. `/Users/biel/ARCA/Forge/Geo/Geo/Shared/Infrastructure/MCP/Tools/BrainTools.swift`
2. `/Users/biel/ARCA/Forge/Geo/Geo/Shared/Infrastructure/Brains/ChunkSummarizer.swift`
3. `/Users/biel/ARCA/Forge/Geo/Geo/Shared/Infrastructure/Brains/EmbeddingService.swift`
4. `/Users/biel/ARCA/Forge/Geo/Geo/Shared/Infrastructure/Brains/SourceExtractor.swift`
5. `/Users/biel/ARCA/Forge/Geo/Geo/Shared/Infrastructure/Brains/Chunker.swift`
6. `/Users/biel/ARCA/Forge/Geo/Geo/Shared/Infrastructure/Brains/IngestPipeline.swift`
7. `/Users/biel/ARCA/Forge/Geo/Geo/Features/Brains/Data/BrainGraphStore.swift`
8. `/Users/biel/ARCA/Forge/Geo/Geo/Features/Brains/UI/BrainsPane.swift`
9. `/Users/biel/ARCA/Forge/Geo/Geo/Features/Brains/UI/BrainCard.swift`
10. `/Users/biel/ARCA/Forge/Geo/Geo/Features/Brains/UI/CreateBrainSheet.swift`
11. `/Users/biel/ARCA/Forge/Geo/Geo/Features/Brains/UI/AttachSourcesView.swift`
12. `/Users/biel/ARCA/Forge/Geo/Geo/Features/Brains/UI/IngestDetailView.swift`
13. `/Users/biel/ARCA/Forge/Geo/Geo/Features/Brains/UI/BrainNodeView.swift`
14. `/Users/biel/ARCA/Forge/Geo/Geo/Features/Brains/UI/BrainNodesView.swift`

**→ GeoTests target:**
15. `/Users/biel/ARCA/Forge/Geo/Geo/Tests/IngestPipelineTests.swift`
16. `/Users/biel/ARCA/Forge/Geo/Geo/Tests/BrainGraphStoreTests.swift`

(`BrainsTests.swift` is appended to — already in GeoTests, no registration.)

EXISTING files edited (NO registration needed): `DatabaseService.swift`, `Brains.swift`, `AnthropicClient.swift`, `BlockFileService.swift`, `MCPToolRegistry.swift`, `GeoAPIRouter.swift`, `BlockTools.swift`, `GeoApp.swift`, `GraphView.swift`, `AppTab.swift`, `NavigationSegmentedControl.swift`, `BrainsTests.swift`.

---

## 4 & UI-SAFETY VERDICT

Every working UI surface is untouched or behavior-preserving, with **ONE** flagged item resolved below.

**Confirmed UNTOUCHED:** `NodesPane.swift`, `GraphStore.swift`, `BlockGraph.swift`, `BlockGraphService.swift`, `BlocksPane.swift`, `NanoPane.swift`, `HomePane.swift`, `TasksPane.swift`, `SettingsPane.swift`, `UnifiedNavigationContainer.swift`, `MenuActions.swift`, `MyCommands.swift` (Option A), `AttachmentHandler.swift`. Reused-not-edited: `BlockListRow`, `TagCreationSheet`, `Pane`, `GeoStyle`, `MarkdownStyler`/`MarkdownConverter`, `GraphView` call shape.

**Behavior-preserving additive edits to UI-adjacent files (verified byte-identical defaults):**
- `GraphView.swift` — `isActive: (() -> Bool)? = nil` inserted before `onNodeTap`; gates become `isActive?() ?? (tabRouter.selectedTab == .nodes)`. nil → verbatim original. No existing call site passes it. **SAFE.**
- `AppTab.swift` — new case + new switch arms + append to END of `defaultNavigationOrder`. ⌘1–⌘4 + ⌘, unchanged. **ADDITIVE.**

**THE ONE FLAGGED SURFACE — `NavigationSegmentedControl.swift` (title bar):**
- The exhaustive `TabIconView` switch (:77–92) MUST gain `case .brains` to compile — unavoidable regardless of option, behavior-preserving for existing arms.
- **Option A (recommended):** append `.brains` to `defaultNavigationOrder` → title bar shows a **5th segment**. This is an *additive* new control at the end; the existing 4 segments keep identical position/behavior/shortcuts. Matches the locked "append a tab so existing shortcuts don't shift" license. Tagged BEHAVIORAL only because the file renders a working surface, but the change is purely additive (new segment, no existing segment altered).
- **Option B (zero visible title-bar change, if a stricter reading is required):** do NOT append to `defaultNavigationOrder`; add the `case .brains` arm (non-rendering, since the control iterates `defaultNavigationOrder`); reach Brains via an explicit `Button(...).keyboardShortcut("5", .command)` in `MyCommands.swift` (one ADDITIVE button) + an in-pane entry point. Title bar stays at 4 segments.

**VERDICT:** No working surface's behavior/layout/styling is modified. The single title-bar segment addition (Option A) is additive-by-extension and license-covered; Option B is the zero-visible-change fallback. **No violations remain** — every mapper-proposed behavioral change (Spec 6 #2 protocol-without-default, #5 interceptor non-pass-through, #17/#18 graph-wiring-into-live-view, Spec 5's `buildGraph` widening) has been replaced with its additive alternative above.

---

## 5. OPEN RISKS + GENUINELY-OPEN DECISIONS

**Risks (mitigated, but watch):**
- **GRDB destructive fallback:** `DatabaseService.init` calls `forceRecreate` (:105) on migration throw → a malformed domain migration silently nukes a brain `index.sqlite`. Keep domain migrations pure-DDL, no throwing backfill.
- **Two HTTP chokepoints:** the interceptor covers `registry.call` but NOT the 6 direct `blocks.*` calls (:103/155/165/209/322/381) — those are permanently `essence`. Acceptable for read-only domain brains; never thread a brain through the `blocks` repo path.
- **NLEmbedding availability:** `sentenceEmbedding(for:.english)` is optional (nil if model unavailable) and fixed-dim (512). Guard nil (skip semantic, never crash); persist `embeddingDims`; cross-dim brains score 0 via `VectorMath.cosineSimilarity`'s `a.count==b.count` guard (:224) — safe but silent. CI: `XCTSkipUnless` the live model.
- **Live ingest progress in UI:** `BrainRegistry.manifestsById` is immutable post-init → `IngestDetailView` must read `brain.json` directly via `BrainManifest.load`, not the cached registry.
- **`brute-force loadAllVectors`:** fine for bounded domain brains (hundreds–low-thousands); flag a cap if any brain exceeds ~50k nodes.
- **Interceptor purity is a test obligation:** the byte-identical default-branch test (2a #1/#6) is the regression guard for every existing MCP/HTTP consumer — do not skip it.

**Genuinely-open decisions (pick before implementing the relevant phase):**
1. **`mode:semantic` in 2a** — wire it now via the newly-available `EmbeddingService` (recommended; ships complete surface) vs. ship `brain`+lexical-only and add semantic as a one-line follow-up. Affects whether `BlockTools.register` gains an `EmbeddingService` defaulted param.
2. **`listNeighbors` on `BrainIndex`** — ship it (with mandatory additive default) vs. defer entirely and rely on the brain-routed `list_neighbors` MCP tool. Recommendation: defer the protocol requirement; ship only the DB edge methods in 2b-storage.
3. **Paging (`listAll`/`fetchAllBlocks(limit:offset:)`)** — add in P3 vs. ship the node list unpaged for v1 (domain brains are bounded). Recommendation: unpaged v1, add paging only if a brain proves large.
4. **Title-bar Option A vs B** — 5th segment (one source of truth, recommended) vs. 4 segments + explicit ⌘5 button (zero visible title-bar change). User's call given the HARD UI constraint; A is license-covered, B is strictly conservative.
---
# ADVERSARIAL CRITIQUE (fixes folded in during implementation)

Confirmed key facts:
- `NLEmbedding` is NOT currently imported/used anywhere (only a string literal in a test). NaturalLanguage framework would be a NEW import — fine, it's a system framework, but no precedent in the codebase.
- PDFKit is NOT used anywhere — new dependency.
- `OCRService.process` signature is `func process(_ image: NSImage, completion: @escaping (String) -> Void)` — takes an `NSImage`, NOT a file URL, and the completion is on the main queue (line 37) returning `String` (never fails/errors — empty string on failure). The blueprint says "image via `OCRService.shared.process` wrapped in `withCheckedContinuation`". This is workable but the input is `NSImage` not a URL, and the completion fires on `DispatchQueue.main` — wrapping in `withCheckedContinuation` is fine. `OCRService` is not Sendable-annotated and not `@MainActor`; calling from a `Sendable` `SourceExtractor` across actors with `NSImage` (not Sendable) is a concurrency concern.

I have enough verified ground truth. Let me write the prioritized critique.

---

# ADVERSARIAL CRITIQUE — Brains Build Blueprint

Verdict: the blueprint is mostly sound on UI-safety and routing, but contains **two outright build/test breakers**, several **wrong-API / wrong-path facts**, and multiple **underspecified concurrency hazards**. Fix all P0/P1 items before any code is written.

---

## P0 — WILL BREAK THE BUILD OR AN EXISTING GREEN TEST

**1. Implementing `semanticSearch` breaks the existing green test `testDatabaseBrainIndexLexicalGetAndType`.**
`/Users/biel/ARCA/Forge/Geo/Geo/Tests/BrainsTests.swift:134-135` asserts `index.semanticSearch(query:[0.1,0.2], k:5)` returns `[]` against a **default (`.personal`) DB built at :107 with no `node_vec` table**. The blueprint's new `semanticSearch` (Brains.swift:124) calls `database.loadAllVectors()`, which runs `SELECT … FROM node_vec` — on a `.personal` DB that table does not exist, so it **throws "no such table: node_vec"**, not returns `[]`. Two compounding bugs:
   - (a) The blueprint's own guard ordering — `let c = try await database.loadAllVectors(); guard !c.isEmpty else {[]}` — throws before the empty-guard.
   - (b) Even if it didn't throw, the existing test now exercises a path the blueprint didn't account for.
   **Fix:** `loadAllVectors()` must be table-existence-tolerant (`SELECT … FROM node_vec` wrapped so a missing table returns `[]`, e.g. guard on `sqlite_master` or catch the GRDB error), AND update that existing test to either keep asserting `[]` on a vector-less DB or move it to a `.domain` DB with seeded vectors. Pick one and write it into the blueprint. As written, the suite goes red the moment Brains.swift is touched.

**2. `AnthropicClient.complete(... maxTokens: Int = 4096)` contradicts the verified source.**
The blueprint claims `complete(system:user:maxTokens:Int=4096)` and "byte-identical on the wire … same model." Verified: `AnthropicClient.maxTokens = 2048` (`AnthropicClient.swift:39`) and `parseTask` sends `max_tokens: maxTokens` (=2048) at :94. A default of 4096 is **not** byte-identical for the extracted `parseTask` path. Also `parseTask` passes **two** system blocks (static prompt + a `Current time` block, :96-107), the second non-cached; a naive `complete(system:user:)` with one system string changes the cache-control shape and the time injection. **Fix:** `complete` must accept an array of system blocks (or replicate the two-block shape), default `maxTokens` to `2048` (the real constant) for the parseTask call site, and `parseTask` must reconstruct its exact 2-block system array. Otherwise either the wire changes (cache-miss regressions) or `parseTask`'s behavior shifts.

**3. `.domain` schema flip + GRDB destructive fallback can silently nuke a brain index — and the migrator identity proof is incomplete.**
The blueprint flips `Brains.swift:216` to `DatabaseService(databaseURL: paths.indexURL, schema: .domain)`. But `DatabaseService.init` (:73-83) runs `buildMigrator().migrate()` and on **any** throw calls `backupDatabase` (hardcoded name `blocks.sqlite.backup-…`, :88) then `forceRecreate` (deletes the file, :105-106). Consequences not addressed:
   - The backup filename is hardcoded `blocks.sqlite.backup-*` even for a brain's `index.sqlite` — wrong/confusing artifact name; not fatal but sloppy.
   - More importantly, the `.personal`/`.domain` split must guarantee a `.domain` DB **only ever** registers domain migrations. But the blueprint's `registerPersonalMigrations` for `.personal` and "domain only on fresh index" reasoning ignores that **both profiles share one `DatabaseMigrator` instance built per `init`** and GRDB tracks applied migrations in `grdb_migrations`. If a `.domain` DB is ever opened later with `.personal` (e.g. a caller forgets the param, or `BrainGraphStore` for a domain brain constructs `DatabaseService(databaseURL: paths.indexURL)` without `.domain` — see P1#7), GRDB sees unknown applied migrations / missing expected ones → migrate throws → **forceRecreate deletes the brain's index**. **Fix:** make schema profile a property of the path, not the call site — resolve `.domain` vs `.personal` from the URL/registry inside a single helper so no caller can open a domain index with the wrong profile. At minimum, audit every `DatabaseService(databaseURL: paths.indexURL …)` construction (Brains.swift:216 AND the proposed `BrainGraphStore`) to pass `.domain` consistently.

---

## P1 — WRONG FACTS / UNDERSPEC THAT WILL MISLEAD THE IMPLEMENTER

**4. `BlockGraphService` path is wrong in the blueprint.**
Blueprint cites `BlockGraphService.deterministicUUID :492` and `extractWikiLinks :440` under `Geo/Features/Graph/Domain/`. Actual file: `/Users/biel/ARCA/Forge/Geo/Geo/Features/Graph/Data/BlockGraphService.swift` — `extractWikiLinks` at **:440**, `deterministicUUID` at **:488** (not 492). Both helpers are already `internal static` (:440, :488), so the Chunker/IngestPipeline can reuse them **without** any visibility edit. Also: the blueprint's Spec-5-vs-4 debate over widening `buildGraph` is moot — `buildGraph` is **already `internal`** (`:247`), not `private`. Fix the path and the "do not widen" rationale (it needs no widening regardless).

**5. `BrainGraphStore` has a MainActor-isolation trap when constructing `BlockGraphService`.**
`BlockGraphService.init(tagStore: nil)` calls `MainActor.assumeIsolated { TagStore.shared }` (`:17`). The blueprint says `BrainGraphStore` is `@MainActor` and passes `tagStore: .shared` explicitly — good, that sidesteps `assumeIsolated`. But:
   - `TagStore.shared` is `@MainActor`; reading it inside an `async` `load()` that may hop off the main actor needs care. Spell out that the `BlockGraphService(...)` construction happens **on the main actor** (the store is `@MainActor`), and `loadGraph()` is awaited.
   - For a **domain** brain, `resolveTagColors()` reads `TagStore.shared` (personal tags) — domain `tagId`s won't match → the blueprint's "neutral grey" claim. Verify against `buildGraph`'s color lookup; if a missing tagId yields `nil` color and the node falls back to type/layer color, fine. But the blueprint asserts grey at `GraphView:1201` without showing `buildGraph` actually passes an empty/missing color through — confirm the `tagColors[tagId]` miss path doesn't crash or mis-key. (I verified `tagStore: .shared` is accepted; I did NOT verify the grey fallback end-to-end — flag as must-verify, not proven.)

**6. `OCRService` API mismatch — it takes `NSImage` + a main-queue completion, not a URL, and is not Sendable.**
`OCRService.process(_ image: NSImage, completion: @escaping (String) -> Void)` (`OCRService.swift:21`), completion on `DispatchQueue.main` (:37), returns `String` (empty on failure — never throws). The blueprint says "image via `OCRService.shared.process` wrapped in `withCheckedContinuation`." Problems: (a) the `SourceExtractor` must first load the file into an `NSImage` (no URL overload exists); (b) `NSImage` is **not `Sendable`** — capturing it into a `Sendable` extractor / crossing the continuation boundary will draw concurrency warnings/errors under Swift 6 strict concurrency; (c) `OCRService` is a plain `class`, not `@MainActor`/`Sendable`. **Fix:** specify that extraction runs on the main actor (or wrap `OCRService` access there), and that "no text" is an empty string, not an error — Pass1 must skip empty OCR results, not treat them as failures.

**7. `BrainGraphStore` opening a domain index without `.domain` re-triggers P0#3.**
The blueprint's `BrainGraphStore.load` does `db = isPersonal ? .shared : DatabaseService(databaseURL: paths.indexURL, schema: .domain)`. Good — but this is the **second** construction site of a domain `DatabaseService` (the first is Brains.swift:216). Both must agree. If they ever diverge, GRDB destroys the index (P0#3). Make this a single shared factory.

**8. PDFKit and NaturalLanguage are brand-new framework dependencies — no precedent in the repo.**
Verified: zero `import PDFKit` and zero `import NaturalLanguage`/`NLEmbedding` usages exist today. Not a blocker, but: (a) both must be added to the link step / available on the macOS target; (b) `NLEmbedding.sentenceEmbedding(for:.english)` returns **`[Double]`** from `vector(for:)` and is **optional** (nil when the model is absent) and **fixed 512-dim for English only** — the blueprint's `[Double]→[Float]` cast and 512 dims are correct, but the `dims` must be read from the live model, not hardcoded, because non-English/word-embedding variants differ. Spell out: persist `embeddingDims` from `embedding.dimension`, and `VectorMath.cosineSimilarity`'s `a.count==b.count` guard (`Brains.swift:224`) means cross-dim brains silently score 0 — acceptable but must be a documented invariant.

**9. The interceptor's "byte-identical default branch" is only byte-identical if `arguments` is not re-encoded.**
`MCPToolRegistry.call` (`:25-30`) currently does `tools[name]` → `tool.handler(arguments)`. The blueprint wraps it in `BrainCallContext.$current.withValue(...) { tool.handler(arguments) }`. That is genuinely pass-through for the personal path **only if** the resolve step (`arguments["brain"]?.stringValue ?? personalId` → `brains.index(for: "essence")`) cannot fail or add latency that changes behavior. Two gaps:
   - `brains.index(for:"essence")` constructs/caches a `DatabaseBrainIndex(database:.shared)` (Brains.swift:214). On the **first** MCP call ever, this lazily builds that index under `cacheLock`. That's a new side effect on the hot path. It won't change results, but flag it: the interceptor now forces essence-index construction on every process's first tool call even for non-block tools (Task/Day/Tag/AI). Confirm that's acceptable, or skip resolution entirely when `brain` is absent (the cleaner pass-through: if no `brain` arg AND tool isn't brain-scoped → call handler directly, never touch `BrainRegistry`).
   - **Recommendation:** make the absent-brain path literally `return try await tool.handler(arguments)` with no registry touch — that is the only provably byte-identical default. Resolve a brain ONLY when `arguments["brain"]` is present.

**10. `GeoAPIRouter` wrap point is misdescribed.**
Blueprint: "at :38, wrap dispatch." Verified `:38` is `let response = await dispatch(request: request, token: token)` inside `handle`. That's correct, BUT the TaskLocal `requestBrain` must be set **before** `dispatch` and the header read must use the server's actual header casing. The blueprint asserts "server lowercases header keys at parse time" — I did **not** verify `GeoHTTPServer`'s header parsing lowercases keys. If it doesn't, `request.headers["x-geo-brain"]` misses a `X-Geo-Brain` header. **Must verify** `GeoHTTPServer` header normalization before relying on lowercase lookup; otherwise read case-insensitively.

---

## P2 — MISSING / UNDERSPECIFIED TESTS FOR DETERMINISTIC LOGIC

**11. No test for the Pass2 reconcile tie-break determinism beyond the happy path.** The blueprint specifies "longest-then-lexicographically-smallest" but the test only checks one variant cluster. Add: (a) two candidates of **equal length** → lexicographic tie-break is exercised; (b) a cluster where the canonical is NOT the first-seen mention (order-independence); (c) alias preservation when the alias itself differs in case from the canonical. Without (a)/(b) the comparator can be implemented wrong and still pass.

**12. No test that re-running Pass2 is a true no-op at the byte level.** The blueprint says "skip write if bytes unchanged" but the test list only says "re-run byte-identical." Make it explicit: assert file `Data` equality AND that `frontmatter_version` did NOT bump on the second pass (idempotency must not churn the version counter — relevant to the `FrontmatterMutator` coordination noted in CLAUDE.md).

**13. State machine: no test for crash-recovery mid-Pass1 (partial chunks indexed).** The blueprint claims "idempotent via SHA256(NFC) chunk hash" and "re-running a done step is a no-op." Add a test that seeds a brain where **half** the chunks are already written+indexed (their `chunk_hash` present) and asserts `advance` skips them and only processes the remainder — this is the actual resume path, distinct from "re-run a fully-done step."

**14. The interceptor default-path test must assert NO `BrainRegistry` interaction (tie to P1#9).** The blueprint calls test #1/#6 "load-bearing" but defines it as behavioral equivalence. Strengthen: inject a `BrainRegistry` spy and assert it is **never queried** when `brain` is absent. That is the only way to prove byte-identical pass-through rather than "same result, extra work."

**15. No round-trip test for `Float` BLOB endianness / corrupt-length handling.** `encodeVector`/`decodeVector` derive count from byte length. Add a test for a BLOB whose length is **not** a multiple of 4 (corruption) → must not crash (return `[]` or throw cleanly), and a test asserting little-endian round-trip is stable across the `withUnsafeBytes` reinterpret. `VectorMath` round-trip ≠ BLOB layout round-trip.

**16. No test for `resolveEdgeTargets` matching semantics.** The blueprint matches on **raw** title (`WHERE targetId IS NULL AND targetTitle = ?`) while the bucket reconcile uses `WikiTitleNormalizer.normalize`. That's an inconsistency: edges store raw titles, but concept identity is normalized. A `[[T-cell]]` edge won't resolve to a node titled `T cells` even though Pass2 merged them. **Either** store the normalized key on the edge **or** resolve via normalized comparison — and test it. As specified, edge resolution and concept reconcile use different keys → orphan edges. This is a P1-level design bug; flagged here because it surfaces as a missing test.

---

## P3 — ORDERING / SECONDARY

**17. Build-order vs. label-order is fine, but P2a "ship after P2b" has a test-time coupling.** The 2a interceptor tests (`testSearchBlocksLexicalDomainUsesIndex`) need a populated `.domain` index, which only exists after 2b-storage's DB methods AND 2b-ingest. If 2a is implemented/tested in isolation, that test must seed the index directly via `upsertBlock` on a `.domain` DB (not via the pipeline) — state that, or the test can't run until ingest lands.

**18. `AppTab` `.settings` is in `allCases` but not `defaultNavigationOrder` — the blueprint's auto-include claims are half-right.** `UnifiedNavigationContainer` iterates `AppTab.allCases` (`:21`) and `maxLiveTabs = allCases.count` (`:6`) — so adding `.brains` auto-grows the live-tab pool ✓. But `NavigationSegmentedControl` iterates `defaultNavigationOrder` (`:7`), NOT `allCases` — so the segment only appears if you append to `defaultNavigationOrder` (Option A) ✓. The blueprint states this correctly for the segmented control but says UnifiedNavigationContainer "iterates allCases, auto-includes" — that's true, yet it means a `.brains` destination is **instantiated/kept-alive** even under Option B (4 segments). Confirm `destinationView` for `.brains` is cheap to construct (it is — `BrainsPane()` with a `.task`-loaded list), since `allCases` iteration will build it regardless of nav order.

**19. `MyCommands.swift` ⌘5 auto-assignment unverified.** The blueprint asserts (Option A) `MyCommands` does `ForEach(defaultNavigationOrder.enumerated())` and auto-assigns ⌘5. I did not read `MyCommands.swift`. **Must verify** before relying on automatic ⌘5; if it hardcodes ⌘1–⌘4, appending the tab does nothing for the shortcut and you silently ship a tab with no key.

**20. `BlockFileService.blocksDirectoryOverride` — verify the init shape and that all writers honor the override.** I did not read `BlockFileService.swift`. The "byte-identical when nil" claim is plausible but unverified; confirm there isn't a second place that recomputes `Geo/Blocks` independently of the stored property.

---

## CONCRETE FIX LIST (fold into blueprint, in order)

1. **[P0]** `loadAllVectors()` must tolerate a missing `node_vec` table (return `[]`); update/relocate `testDatabaseBrainIndexLexicalGetAndType`'s semantic assertion accordingly.
2. **[P0]** `AnthropicClient.complete`: default `maxTokens = 2048`; accept the 2-block system array; `parseTask` reconstructs its exact static+time system blocks. No 4096.
3. **[P0]** Single domain-`DatabaseService` factory keyed off the brain path so `.domain` is impossible to omit (covers Brains.swift:216 AND BrainGraphStore). Fix the hardcoded `blocks.sqlite.backup-*` name or accept it knowingly.
4. **[P1]** Correct the `BlockGraphService` path to `Features/Graph/Data/`, `deterministicUUID` → :488; drop the `buildGraph`-widening discussion (already `internal`).
5. **[P1]** Specify `BrainGraphStore` constructs `BlockGraphService` on the main actor, passes `tagStore: .shared`; verify the domain-tag grey-fallback end-to-end (not yet proven).
6. **[P1]** `SourceExtractor`: load file → `NSImage` → `OCRService.process` continuation **on the main actor**; treat empty string as "skip", handle `NSImage` non-Sendable explicitly.
7. **[P1]** NaturalLanguage + PDFKit: add framework links; read `embeddingDims` from the live `NLEmbedding.dimension`, don't hardcode 512 in code (manifest value is fine).
8. **[P1]** Interceptor: when `arguments["brain"]` is absent, `return try await tool.handler(arguments)` with **zero** `BrainRegistry` touch — the only provably byte-identical default. Resolve only when `brain` present.
9. **[P1]** Verify `GeoHTTPServer` lowercases header keys before relying on `headers["x-geo-brain"]`; else case-insensitive lookup.
10. **[P1/P2]** Reconcile edge-resolution key: store/resolve edges by `WikiTitleNormalizer.normalize`d title, not raw, so reconciled concepts actually resolve; add the test.
11. **[P2]** Add tests: equal-length tie-break + order-independent canonical (#11); byte-level + frontmatter_version-stable re-run (#12); partial-resume Pass1 (#13); interceptor spy asserts no-registry-touch (#14); non-multiple-of-4 BLOB + endianness (#15).
12. **[P3]** Verify `MyCommands.swift` derives ⌘5 from `defaultNavigationOrder` (#19); verify `BlockFileService` override honored everywhere (#20); seed `.domain` index directly in 2a tests (#17).

Files read for ground truth (all absolute): `/Users/biel/ARCA/Forge/Geo/Geo/Shared/Infrastructure/Brains/Brains.swift`, `/Users/biel/ARCA/Forge/Geo/Geo/Shared/Infrastructure/Database/DatabaseService.swift`, `/Users/biel/ARCA/Forge/Geo/Geo/Shared/Infrastructure/MCP/MCPToolRegistry.swift`, `/Users/biel/ARCA/Forge/Geo/Geo/Shared/Infrastructure/AI/AnthropicClient.swift`, `/Users/biel/ARCA/Forge/Geo/Geo/Shared/Infrastructure/HTTP/GeoAPIRouter.swift`, `/Users/biel/ARCA/Forge/Geo/Geo/Features/Graph/UI/GraphView.swift`, `/Users/biel/ARCA/Forge/Geo/Geo/Shared/Navigation/AppTab.swift`, `/Users/biel/ARCA/Forge/Geo/Geo/Shared/Navigation/NavigationSegmentedControl.swift`, `/Users/biel/ARCA/Forge/Geo/Geo/Shared/Navigation/UnifiedNavigationContainer.swift`, `/Users/biel/ARCA/Forge/Geo/Geo/Shared/Infrastructure/MCP/Tools/BlockTools.swift`, `/Users/biel/ARCA/Forge/Geo/Geo/Shared/Utilities/WikiTitleNormalizer.swift`, `/Users/biel/ARCA/Forge/Geo/Geo/Features/Graph/Data/BlockGraphService.swift`, `/Users/biel/ARCA/Forge/Geo/Geo/Shared/Infrastructure/Database/IndexCoordinator.swift`, `/Users/biel/ARCA/Forge/Geo/Geo/Shared/Platform/OCRService.swift`, `/Users/biel/ARCA/Forge/Geo/Geo/App/GeoApp.swift`, `/Users/biel/ARCA/Forge/Geo/Geo/Tests/BrainsTests.swift`, `/Users/biel/ARCA/Forge/Geo/Geo/Features/Blocks/Domain/BlocksRepository.swift`.

Not verified (flagged must-verify): `MyCommands.swift` ⌘5 derivation, `GeoHTTPServer` header casing, `BlockFileService` override honored, domain-tag grey fallback in `buildGraph`.