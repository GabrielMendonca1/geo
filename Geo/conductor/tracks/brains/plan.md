# Track: Brains — Local NotebookLM-style Domain Knowledge Graphs

**Status:** Planning (v1.1 — hardened by a codebase-verification swarm)
**Created:** 2026-06-02
**Goal:** Let the user spin up many isolated, read-only **domain brains** — each a NotebookLM-style knowledge graph batch-built from attached sources — that the agent can search, navigate, and delegate into. The personal **essence brain** stays the only writable, growing graph.

---

## ⚠ Verification pass (v1.1) — corrections from a codebase-audit swarm

A 4-agent swarm audited every `file:line` claim against live code. Citations were ~95% accurate; **two architectural assumptions were wrong** and must be resolved in Phase 0.

**BLOCKER 1 — sqlite-vec cannot be loaded (Decision #5 changed).** GRDB links macOS system `libsqlite3`, compiled with `OMIT_LOAD_EXTENSION` (`load_extension` → "no such function"); GRDB exposes no extension-load API. **v1 fix:** store contiguous `float[D]` blobs in a plain `node_vec(blockId PK, embedding BLOB)` table and brute-force cosine in Swift with **Accelerate** (`vDSP`/`cblas_sgemv`) — the triad's own ~50M-flop budget at N≤100k already justifies it, no sqlite-vec needed. `vec_map` collapses into the `node_vec` row. sqlite-vec/ANN returns only as the **>250k-node upgrade**, contingent on statically linking a custom SQLite (project-config change, not app code).

**BLOCKER 2 — the Anthropic Batch API does not exist (Decision #3 caveat).** `AnthropicClient` does only synchronous single calls to a hardcoded `/v1/messages`; no `message_batches`/`custom_id`/poller, `sendWithRetry` is `private`, and the only public method (`parseTask`) hardcodes the task-JSON schema. The cost model, the "bounded round-trips" triad claim, and the non-recursive "advance-one-step" state machine **all assume batch = NET-NEW work.** Two ways forward: **(a)** build a batch client (submit→poll→retrieve-by-`custom_id`) — but a batch can take minutes–24h, stretching "next interaction window"; or **(b)** v1 on bounded *concurrent synchronous* Haiku calls (cap fan-out ~8). Either way Pass-1 needs a new **generic** message method first.

**FIX 3 — HTTP needs explicit `brain` wiring (§3).** "One optional param rides the shared args dict" is TRUE for MCP (single shared `registry`, untyped `[String:AnyCodableValue]`) but **not free on HTTP**: `GeoAPIRouter.dispatch` rebuilds args per route, so each brain-scoped read route needs `if let b = request.query["brain"] { args["brain"] = .string(b) }` (~10 one-line edits). The `brainScopedReadTools` guard runs in `dispatch`/`call`, **not** `requiredScope` (which only sees method/path). Default path stays identical.

**FIX 4 — `BlocksPane` does NOT page (§4).** Its list is `ForEach(filteredBlocks)` over a fully-materialized array; `LazyVStack` defers view construction, not data loading. Reusing it verbatim loads 100k nodes into RAM. `BrainsViewModel` must add **real `limit/offset` paging over `BrainIndex`** (BlocksPane is a *styling* precedent only). The per-brain GraphView decouple has **3** edit sites, not 2: the missed one is `GraphView.swift:530` `@Environment(\.tabRouter)` feeding the `:753/:825` gates — without cutting it a brain graph renders but is frozen (`selectedTab != .nodes`).

Minor citation fixes folded into the sections below: `MarkdownConverter.parse` is an **instance** method at `:49` (not static `:186`; file is 89 lines); `performWrite` is defined at `:572` (`:235` is a call site); per-brain neighbor rebuild is `findNeighbors :402-434 → buildGraph :247-328`; `JobRuntime` (`JobStore.swift:21`) is a read-only hermes status **DTO**, not a reusable state engine; `link_block_to_day` is in `DayTools.swift:82`; `MyCommands.swift:38` is the tab-shortcut generator (auto-wires `⌘<n>` for a new tab), not `⌘N`.

---

## Concept

Two kinds of brain, **one node format, two factories with opposite write-postures:**

- **Essence brain (exists, unchanged):** high-frequency, small, lossless, irreplaceable. The agent reads *and* writes it daily (the hermes capture loop). The seat of understanding and routing.
- **Domain brains (new):** large, regenerable (sources are the backup), **read-only to the agent**. Built solely by a batch pipeline from user-attached sources. Consultable libraries, not part of "you."

Knowledge flows one way: the agent **reads** a domain brain → distills → **writes the insight into the essence brain** (`layer=agent`/`review`), never back into the domain brain. The agent holds standing awareness (per-brain self-description) and **decides which brain is suitable, then acts** — *not* a federated similarity fan-out.

The verbs map onto tools that already exist, brain-scoped by one parameter:
**search** = `search_blocks(brain:)` · **navigate** = `list_neighbors`/`find_backlinks`/`get_graph_snapshot(brain:)` · **delegate** = `claude_code_run(directory: <brain folder>)`.

---

## Locked Decisions

1. **Option A storage** — each brain = its own folder + its own `index.sqlite` under `Geo/Brains/<brain-id>/`. Physically isolated, portable, regenerable.
2. **Node format reuses the block schema** — inside a domain brain: source chunks → `type=literature` (leaves); Pass-2 reconciled concepts → `type=permanent`/`moc` (hubs). Same Index→MOC→file shape as the personal Zettelkasten. `layer` is moot inside a domain brain (one fixed value, `shared`).
3. **Two-pass Haiku 4.5 ingest** — Pass 1: per-chunk → rich md node (extract `[[concept]]` links). Pass 2: cross-corpus concept reconcile (merge mentions into canonical hubs so links converge). Idempotent + resumable (content-hash chunks, NFC-normalize titles). **Net-new:** the Batch API doesn't exist (`AnthropicClient` is sync-only) — v1 may use bounded *concurrent synchronous* Haiku calls behind a new generic call path; see Verification BLOCKER 2.
4. **Non-recursive job** — no daemon. The user attaches sources; the job advances exactly one state transition on the user's **next interaction window**.
5. **Semantic search via Swift/Accelerate brute-force** over `float[D]` embedding blobs in a plain `node_vec` table (NOT sqlite-vec — unloadable against GRDB's system SQLite; Verification BLOCKER 1). Embeddings via Apple on-device `NLEmbedding`, scanned with `vDSP`/`cblas`. Embeddings = the doorway; graph traversal = the journey. ANN/sqlite-vec is a documented >250k-node escape hatch, not v1.
6. **Same read-tools + optional `brain` param**, default = personal brain (backwards-compatible). Write tools and all life tools (tasks/days/tags/reminders/habits) stay **personal-only**. The agent is **read-only on domain brains**; the batch is the sole writer via an app-internal path.

---

## Cross-cutting spine (resolved seams)

`BrainRegistry` (new, `Geo/Shared/Infrastructure/Brains/`) is the contract all four slices share:

- maps `brainId → (folder, index.sqlite, Blocks/, sources/)`, holds decoded `brain.json` manifests in an in-memory `[brainId: BrainManifest]` map, opens each `BrainIndex` once at init.
- the personal brain is registered as the default id `"essence"`, but its paths point at the existing `Geo/Blocks` + `Geo/Index/blocks.sqlite` and its `BrainIndex` wraps today's `DatabaseService`/`BlockGraphService` — so the default path is behavior-identical and every current call (no `brain` key) is untouched.
- **Storage** defines `BrainRegistry` + the `BrainIndex` read protocol; **API** calls `resolve`; **UI** calls `list`/`graphSnapshot`; **Ingest** writes through a per-brain `DatabaseService` funneled by the existing serial `performWrite` (single-writer preserved).

---

## 1. Storage & Data Layer

Geo's personal brain today stores markdown under `Geo/Blocks/*.md` (`BlockFileService.swift:24`) and indexes into a single `Geo/Index/blocks.sqlite` (`DatabaseService.swift:69`) with a `blocks` table, `block_tags`, and an FTS5 `blocks_fts` virtual table (`DatabaseService.swift:114-138`). Edges are not persisted — they are derived at query time from `[[wiki-links]]` in `content` by `BlockGraphService.buildGraph` (`BlockGraphService.swift:247-328`). Brains extend this verbatim, per-brain, and add a persisted edge table + a `float[D]` BLOB vector table.

### On-disk per-brain layout
```
Geo/Brains/<brain-id>/
  brain.json          # manifest
  sources/            # original attached files (the backup-of-record)
  Blocks/*.md         # nodes — same format & subfolder layout as Geo/Blocks
  index.sqlite        # per-brain DB (clone of blocks.sqlite + edges + vec)
```
`brain.json` fields: `id`, `title`, `gist` (1–2 sentence self-description for routing, decision #6 awareness), `kind` ("domain"|"essence"), `sourceCount`, `nodeCount`, `ingestState` ("empty"|"ingesting"|"ready"|"failed"), `embeddingModel`, `embeddingDims`, `schemaVersion`, `createdAt`, `updatedAt`.

### BrainRegistry
A new `Geo/Shared/Infrastructure/Brains/BrainRegistry.swift` (sibling to `DatabaseService.swift`). Resolves `brain-id → (folderURL, indexURL, blocksDir, sourcesDir)`; `list()` enumerates `Geo/Brains/*/brain.json` and decodes manifests into an in-memory `[brainId: BrainManifest]` map (O(1) routing lookups, ~tens of brains). Domain brains wrap a per-brain `DatabaseService(databaseURL: index.sqlite)` — that init already accepts an injected URL (`DatabaseService.swift:65`).

### Per-brain SQLite schema (reuses existing, adds two tables)
Reuse `buildMigrator`'s `blocks`, `block_tags`, `blocks_fts` exactly (`DatabaseService.swift:114-204`) so `BlockIndexEntry` and all fetch/upsert paths work unchanged. Add:
- `edges(sourceId TEXT, targetTitle TEXT, targetId TEXT NULL)` + index on `sourceId` and `targetId` — **persists** what `buildGraph` recomputes, since domain brains are batch-built and read-only. `targetId` resolved once at build.
- `node_vec(blockId TEXT PRIMARY KEY, embedding BLOB)` — contiguous `float[D]` blob per block, scanned with Accelerate brute-force cosine (NOT sqlite-vec — unloadable; BLOCKER 1). No `vec_map`; blockId is the PK.

### Node frontmatter spec (domain-brain nodes)
Parser is flat `key: value` only (`MarkdownConverter.swift:75-82`), so all fields are scalars. Reuse `type` (`literature` leaves; `permanent`/`moc` hubs), `status`, `[[links]]` in body, `layer` (single fixed value). Add brain-specific scalar keys: `source_ref` (relative path into `sources/`), `chunk_hash` (content-hash for dedup/idempotent rebuild), `vec_rowid`.

### BrainIndex read interface
```
protocol BrainIndex {
  func get(id) -> BlockIndexEntry?                          // O(1) PK
  func semanticSearch(queryEmbedding:[Float], k:Int) -> [(id,score)]
  func lexicalSearch(_ q:String, limit:Int) -> [String]    // wraps searchBlockIds
  func listNeighbors(of id) -> (incoming:[id], outgoing:[id])
  func getGraphSnapshot() -> BlockGraph
  func listByType(_ t:BlockType) -> [BlockIndexEntry]       // wraps fetchBlocks(byType:)
}
```
`lexicalSearch`/`listByType`/`get` map directly to existing `DatabaseService` methods (`:295`, `:326`, `:435`). `listNeighbors`/`getGraphSnapshot` read the persisted `edges` table instead of recomputing.

### Embedding storage/query
Apple `NLEmbedding.sentenceEmbedding` → fixed dim D (pin D in `brain.json`). Store contiguous `float[D]` blobs in `node_vec(blockId PK, embedding BLOB)`. Query: embed text → load blobs → **Accelerate brute-force cosine** (`vDSP`/`cblas_sgemv`), top-k. NOT sqlite-vec — it can't load against GRDB's system SQLite (`OMIT_LOAD_EXTENSION`; Verification BLOCKER 1). No `vec_map` (blockId is the PK). ANN only at >250k nodes, contingent on a custom static SQLite link. (Adopting a custom SQLite later means threading a GRDB `Configuration` through `openOrRecreate`/`forceRecreate`, which today use a bare `DatabaseQueue(path:)`.)

```triad
DESIGN — N = chunks/nodes per brain, bounded 100k–1M
(a) semantic top-k:  embed query (O(1) NLEmbedding) → Accelerate cosine.
    brute-force scans all N vectors = O(N·D). At N≤~100k,D~512 ~50M flops
    (<50ms) — fine. At N→1M ~500M/query borderline. Decision: ship
    Swift/Accelerate brute-force over float[D] BLOBs (vDSP/cblas_sgemv);
    gate ANN behind nodeCount>250k (needs custom static SQLite, not v1).
    Shape: contiguous float[D] blob, no per-row Swift object, no sqlite-vec.
(b) get(id):  blocks.id TEXT PRIMARY KEY → O(1) B-tree. No change.
(c) neighbors: persisted edges(sourceId idx, targetId idx) → O(deg) both
    directions. Replaces the O(N) rebuild-per-call
    (findNeighbors :402-434 → buildGraph :247-328) — critical at N=1M.
(d) vector storage: node_vec(blockId PK, embedding BLOB) — no vec_map, no
    vec0; vectors live in their own table, touched only on the semantic path.
Honest note: most domain brains N≈10k–100k → brute-force vec + indexed edges
is correct and simple; ANN is a documented escape hatch, not v1.
```

**Critical files:** `DatabaseService.swift` · `BlockGraphService.swift` · `BlockFileService.swift` · `MarkdownConverter.swift` · `IndexCoordinator.swift`.

---

## 2. Ingest Pipeline

Pipeline: `source → extract → chunk → Pass-1 batch → Pass-2 reconcile → embed → index → ready`. A per-brain `DatabaseService` reuses the same migrator, `upsertBlock`/`BlockIndexEntry` (`:234`, `:442`) and FTS5 (`:133`) verbatim — plus the `vec0`/`edges` tables owned by the schema layer.

### 2.1 Source intake + extraction (exists vs new)
- **PDF** — NEW. `PDFKit.PDFDocument` per-page `.string`; page index = chunk boundary.
- **Image / scanned** — REUSE. `OCRService.shared.process(_:completion:)` (`OCRService.swift:21`), Vision `.accurate`, 3000px cap (`:90`). Wrap callback in `withCheckedContinuation`.
- **URL** — NEW. `URLSession` fetch + readability → markdown. (Reuse `AnthropicClient.sendWithRetry` backoff, `:157`.)
- **Audio** — NO existing transcription. NEW: `SFSpeechRecognizer` on-device, or defer the type.

All extraction is internal/offline — never an agent tool (decision #6).

### 2.2 Chunking + idempotency
Structural-first: split on PDF pages / markdown headings / `\n\n`, pack to **~800 tokens, 80-token (~10%) overlap**. Content hash = SHA256 of NFC-normalized chunk text (reuse `precomposedStringWithCanonicalMapping`, `BlockFileService.swift:80`). Hash = stable chunk id + dedup key; `chunks(hash PRIMARY KEY, status)` lets a crashed run skip `done` rows. Titles NFC-normalized on write so no duplicate index rows.

### 2.3 Pass 1 (per-chunk → literature node)
One request per chunk, `custom_id = chunk hash`. **Net-new path:** Batch API doesn't exist — `AnthropicClient` is sync-only, `sendWithRetry` is `private`, and `parseTask` is task-JSON-specific, so add a generic message method, then batch-submit or bounded-concurrent-sync (BLOCKER 2). Reuse the model **constant** (`claude-haiku-4-5-20251001`, `:38`) + cached `system` block (`:96`). Parse output via `MarkdownConverter().parse` (instance, `:49`). System: *"Summarize this source chunk into a markdown note. Emit `[[Concept]]` links for every salient entity/idea. Frontmatter (`type: literature`, `source`, `moc_parent`, `concepts: [..]`) then body."* Output parsed by `MarkdownConverter` (`:186`); links via `extractWikiLinks` (`BlockGraphService.swift:440`).

### 2.4 Pass 2 (cross-corpus reconcile) + triad sketch
Collect every `[[concept]]` mention across all Pass-1 notes, merge into canonical `permanent/moc` hubs, rewrite leaf links to the canonical title.

```
TRIAD DESIGN — (a) chunking + (b) Pass-2 reconcile
CP1 Logic/BigO:
  Chunking: single linear scan O(chars).
  Pass-2: N = total mentions (~chunks*15 → ~6k for 400 chunks, 100k worst).
    NAIVE all-pairs O(N²) ≈ 10^10. REJECT.
    (1) canonical-key bucket: key = normalize(title) (diacritic+case fold,
        NFC) → exact/alias merge O(N) hash map.
    (2) only UNIQUE keys (U ≪ N, ~hundreds) get an NLEmbedding vector.
    (3) near-dup merge among U: Accelerate cosine, each key top-k (k≈10),
        union-find merge if cos>thr. No ANN → O(U²), but U~hundreds so
        ~10^4-10^5 ops, fine; NEVER O(N²). thr (~0.86) is NLEmbedding-
        specific — tune; false-merge (two distinct concepts) is the danger.
CP2 Data structures:
  mentionsByKey: [CanonicalKey: [MentionRef]]   // O(1) group
  canonicalTitle: [CanonicalKey: String]        // deterministic: longest, then lexicographically smallest (resumable)
  DSU parent[]                                   // union-find near-dup clusters
  vec0 keyed by canonical key (ANN)
CP3 Architecture/I/O:
  Round-trips BOUNDED: Pass-1 = ceil(chunks/maxPerBatch) submissions
    (1 batch ≈ 1–10 calls, NOT 1/chunk). Pass-2 = 0 or 1 batch.
  Embeddings on-device NLEmbedding, 0 network. Single DB writer (performWrite).
CP4 Failure/idempotency:
  custom_id = chunk hash → re-collect is set-difference, never re-pay.
  DSU + canonical map rebuildable from notes → Pass-2 fully resumable.
```

### 2.5 State machine (non-recursive, advance-one-step)
`pending → submitted → collecting → embedding → indexing → ready`, persisted in `brain.json` (shape mirrors `JobRuntime`, `JobStore.swift:21` — but that is a read-only hermes status DTO, so the transition engine is net-new). NO daemon (decision #4): on the user's **next interaction window**, advance exactly one transition. Each step idempotent (hash skip) so a crash mid-step re-enters the same state harmlessly. `failed` state on unrecoverable extraction/batch error.

### 2.6 App-internal write path (single-writer, bypasses agent)
Build `BlockIndexEntry` (`DatabaseService.swift:7`) per note; write `.md` via `BlockFileService.writeMarkdownToDisk` (`:144`); upsert through the brain `DatabaseService.upsertBlock` (`:234`) — all writes funnel the existing serial `performWrite` (`:235`). Edges resolved with `extractWikiLinks` + `normalize` (`BlockGraphService.440/484`). Invoked only by the ingest job, never an MCP tool → agent stays read-only (decision #6).

**Critical files:** `DatabaseService.swift` · `BlockFileService.swift` · `AnthropicClient.swift` · `BlockGraphService.swift` · `OCRService.swift`.

---

## 3. Tool & API Surface

The `brain` param is a plain optional string riding the existing `[String: AnyCodableValue]` args dict through the one chokepoint both transports share: `MCPToolRegistry.call(name:arguments:)` (`MCPToolRegistry.swift:25`) — one shared `registry` instance (`GeoApp.swift:133`) injected into both transports, reached from MCP via `MCPRouter.swift:80` and HTTP via `GeoAPIRouter.call` (`GeoAPIRouter.swift:283-291`). No new dispatch layer. **Caveat (verified):** free on MCP (raw args dict) but NOT on HTTP — `GeoAPIRouter.dispatch` rebuilds args per route, so each brain-scoped read route needs `if let b = request.query["brain"] { args["brain"] = .string(b) }` (~10 one-line edits).

**Resolution (no triad-critical path; O(1)).** Each brain-scoped handler reads `args["brain"]?.stringValue ?? BrainRegistry.personalId`, then `BrainRegistry.resolve(brain) -> BrainIndex?` — a single dictionary lookup over an already-open `[brainId: BrainIndex]` map (DBs opened once at init). Unknown id → `.error("unknown brain")`. The handler queries the resolved `BrainIndex` instead of the captured `BlocksRepository`. Today `searchBlocks` calls `blocks.search(matching:)` (`BlockTools.swift:225`); the brain-aware form routes to `index.search(...)`. The personal `BrainIndex` wraps the existing repository so the default path is behavior-identical.

**Tool boundary table.**

| Tool | Class | `brain` param | Non-personal `brain` |
|---|---|---|---|
| search_blocks, get_block, get_block_by_title, list_blocks, list_neighbors, find_backlinks, find_orphans, find_unresolved_links, get_graph_snapshot, list_by_type, list_by_status | brain-scoped read | optional, default personal | allowed |
| list_brains, get_brain_manifest (new) | registry read | n/a | n/a |
| create_block, update_block, delete_block, set_layer, set_block_tag, promote_to_permanent, extract_permanent_from, link_block_to_day | personal-only write | rejected if ≠ personal | 400 |
| create_task, update_task, delete_task, complete_task, add_reminder, record_habit_occurrence, ai_parse_task | personal-only life | rejected if ≠ personal | 400 |
| list_tasks, get_task, list_tasks_for_day, list_upcoming, get_today, get_day, list_tags, create_tag | personal-only life | rejected if ≠ personal | 400 |

Write tools in `BlockTools.swift`/`TagTools.swift` (note `link_block_to_day` is in `DayTools.swift:82`); life tools in `TaskTools.swift`/`DayTools.swift`/`AITools.swift`. None gain a `brain` param.

**Read-only enforcement.** Structural: write/life handlers never call `BrainRegistry.resolve`. Explicit guard is one line at the chokepoint: in `GeoAPIRouter.dispatch` (`GeoAPIRouter.swift:71`) and `MCPRouter` (`MCPRouter.swift:80`), before `registry.call`, if the tool is not in the brain-scoped read allowlist and `args["brain"]` is present and ≠ personal → `.error(400)`. Home the `static let brainScopedReadTools: Set<String>` near `requiredScope` (`GeoAPIRouter.swift:62`), but run the actual check in `dispatch`/`call` where the tool name + `args["brain"]` exist (`requiredScope` only sees method/path). This is a distinct seam from `AgentAuthorization` (`:25`) — that is a per-block-*layer* gate inside handlers, not a tool-name gate.

**Routing awareness — `list_brains` / `get_brain_manifest`.** New `BrainTools.register(registry:)` added at `GeoApp.swift:130`. `list_brains` → `[{id, title, gist, state, default}]`. `get_brain_manifest(brain)` → full self-description. This is the comprehend→route→act surface: agent reads manifests, picks the brain, re-issues a scoped read.

**Delegate contract.** Agent resolves the brain's absolute folder via `get_brain_manifest(brain).folder`, then `claude_code_run(directory: <brain folder>, prompt, ...)` (`hermes-extensions/claude-code-lane/README.md:11`). The subagent is read-only (only the brain's files, no write tools); it returns a synthesis the parent writes into the personal brain.

**search_blocks semantic mode.** Gains `mode: lexical | semantic` (default `lexical`, backwards-compatible) + `brain`. `semantic` calls `index.semanticSearch(query, topK)` (sqlite-vec). Validated at `BlockTools.swift:210`.

**Critical files:** `BlockTools.swift` · `GeoAPIRouter.swift` · `MCPToolRegistry.swift` · `GeoApp.swift` · `AgentAuthorization.swift`.

---

## 4. UI Surfaces

Geo's shell is a tab `ZStack` (`UnifiedNavigationContainer.swift:21`) driven by `TabRouter.selectedTab` (`NavigationStore.swift:5`); tabs are enum `AppTab` over `AppTab.defaultNavigationOrder` (`AppTab.swift:10`), with `⌘N` shortcuts (`MyCommands.swift:38`), each mapping to a `destinationView` (`AppTab.swift:62`).

### Where Brains lives — new top-level tab
Add `case brains` to `AppTab` (`AppTab.swift:3`), insert into `defaultNavigationOrder` before `.nodes`, add `displayTitle`/`icon` (`brain.head.profile`), add a `BrainsPane()` arm in `destinationView` (`:62`). Brains is a primary browsable workspace (list/graph/detail), not a config screen — Settings is the wrong home. Tabs lazy-mount via LRU (`UnifiedNavigationContainer.swift:8`), so the heavy graph tab costs nothing until selected.

### Brains list (manage many brains)
`BrainsPane` follows `BlocksPane`'s `Pane { ScrollView { LazyVStack } }` (`BlocksPane.swift:51,227,376`). A `BrainsViewModel` reads `BrainRegistry.list()` — registry rows only (title, gist, nodeCount, sourceCount, state), never node bodies. Per-brain `BrainCard` reuses `BlockListRow`/`BlockGroupHeader` styling (`:1214,1058`). `+ New Brain` chip reuses `BlocksControlBar.newMenu` (`:690`).
```
┌ Brains ───────────────[+ New Brain]┐
│ ◳ Immunology      ● ready           │
│   "T-cell signaling…"  12.4k · 38   │
│ ◳ Tax Law 2025    ◐ embedding 62%   │
│   "US federal…"        —     · 9    │
└─────────────────────────────────────┘
```

### Create-brain + attach-sources
`CreateBrainSheet` reuses the `.sheet` + `TagCreationSheet` form (`BlocksPane.swift:71,1178`): name + `AttachSourcesView`. `AttachSourcesView` (also per-brain) is a drop target via `.onDrop(of: [.fileURL])` + a URL text field (NEW; `AttachmentHandler.swift` is block-scoped). On confirm it calls the registry enqueue (the only human write) → brain `pending`.

### Ingest status surface (honest, multi-window)
Card badge renders the state-machine value: `pending` (clock), in-flight states (animated `ProgressView`, like `:274`), `ready` (filled dot). Tapping a non-ready brain opens `IngestDetailView`: current state label, per-stage counts (sources collected / chunks embedded / nodes indexed), and copy stating work resumes on the next interaction window — never a fake spinner-to-done. Re-reads registry state on appear; no client timer implies completion.

### Per-brain graph — reuse GraphView
`GraphView` takes a `BlockGraph` value + `onNodeTap`, not a singleton (`GraphView.swift:520,527`) — source-agnostic (verified). Coupling is (a) `NodesPane.swift:9` hard-binding `GraphStore.shared` (the `@ObservedObject`), and (b) **three** active-tab couplings: `@Environment(\.tabRouter)` (`GraphView.swift:530`) feeding two `selectedTab == .nodes` gates (`:753,:825`) — miss the `:530` env read and a brain graph renders but is frozen (mouse/scroll dead). Fix: add `BrainGraphStore` (mirroring `GraphStore.swift:11`) whose `@Published graph` is built from `BrainIndex.getGraphSnapshot()`; replace the env+gates with an injected `isActive: () -> Bool`. `BlockGraph`/`GraphNode`/`GraphEdge` reused as-is.

### Browse/detail + read-only affordance
Node list reuses `LazyVStack`/`BlockListRow`. Tapping opens `BrainNodeView` — a NEW read-only viewer, NOT `BlockEditorView` (built around `BlockEditorActions` + autosave, `BlockEditor.swift:12,55`). Renders title + markdown with no `TextEditor`, no layer/tag chips, a "Read-only · domain brain" pill. Absence of `actions` structurally prevents edits.

### Triad-critical constraint
ONE: a brain can hold 100k+ nodes — the node list MUST page through `BrainIndex` `limit/offset` into a `LazyVStack`. **Correction (verified):** `BlocksPane.swift:376` does NOT page — it's `ForEach` over a fully-materialized array (`LazyVStack` defers view construction, not data loading), so it's a *styling* precedent only; `BrainsViewModel` must add real `limit/offset` windowing BlocksPane lacks, or 100k nodes load into RAM. Graph snapshot is bounded server-side (top-N by degree). No further triad-critical path.

**Critical files:** `AppTab.swift` · `GraphStore.swift` · `NodesPane.swift` · `BlocksPane.swift` · `GraphView.swift`.

---

## Triad-critical hot paths (consolidated)

| Path | Trap | Fix |
|---|---|---|
| Pass-2 concept reconcile | O(N²) all-pairs over 100k+ mentions | canonical-key hash bucket (O(N)) → embed only unique keys U → ANN+union-find among U (O(U·log U)) |
| Per-brain neighbor/graph queries | `buildGraph` O(N) rebuild per call | persist `edges` table, indexed → O(deg) |
| Semantic top-k | brute-force O(N·D) at N→1M | Accelerate brute-force over float[D] BLOBs for v1 (NOT sqlite-vec — unloadable); ANN gate at >250k |
| Brain node-list UI | loading 100k nodes to render a list | real `limit/offset` paging in BrainsViewModel (BlocksPane does NOT page) |
| Batch round-trips | 1 API call per chunk | `ceil(chunks/maxPerBatch)` submissions; Pass-2 ≤1 batch |

---

## Phasing & sequencing

- **Phase 0 — Prereqs.** (1) Vectors: implement **Accelerate brute-force cosine** over `float[D]` BLOBs (sqlite-vec dropped — unloadable, BLOCKER 1). (2) Decide **batch vs bounded concurrent-sync** for Haiku and extract a generic `AnthropicClient` call path (BLOCKER 2). (3) Spike `NLEmbedding` dims + retrieval quality on a sample corpus. (4) Decide the concrete **"next interaction window"** trigger. Tests: Accelerate KNN round-trip; embedding determinism.
- **Phase 1 — Spine (unblocks all).** `BrainRegistry` + `BrainManifest`/`brain.json`; `BrainIndex` protocol; per-brain `DatabaseService` clone + `edges` + `node_vec`/`vec_map`; personal brain registered as default `"essence"`. Tests: registry resolve/list, edges persistence, get/neighbors parity vs `buildGraph`.
- **Phase 2 (parallel after Phase 1):**
  - **2a API** — `brain` param threading + boundary guard + `list_brains`/`get_brain_manifest` + `search_blocks` semantic mode. Tests: default-path regression (no `brain` = identical), write-with-brain → 400, semantic mode.
  - **2b Ingest** — extraction, chunking, two-pass batch, state machine, app-internal write path, embeddings. Tests: idempotent resume (hash skip), Pass-2 convergence (no near-dups), state-machine single-step advance.
  - **2c Graph decouple** — `BrainGraphStore` + parameterized active-tab gate (can start as soon as `getGraphSnapshot` exists). Tests: GraphView renders from injected snapshot.
- **Phase 3 — UI.** `AppTab.brains` + `BrainsPane`/`BrainCard`, `CreateBrainSheet`/`AttachSourcesView`, `IngestDetailView`, per-brain GraphView wiring, `BrainNodeView`. Tests: list paging, read-only viewer has no edit affordance, status badge reflects state.
- **Phase 4 — Hardening.** ANN escape hatch; `failed`-ingest UX + retry; large-N virtualization verification; brain delete/export (folder = portable unit); offline/disk-full handling.

---

## Open questions

1. **"Next window" trigger** — what concretely advances the non-recursive job? App foreground, a Brains-tab visit, or any user write? (Affects perceived latency.)
2. **Vector store** — RESOLVED for v1: sqlite-vec is unloadable (GRDB system-SQLite `OMIT_LOAD_EXTENSION`), so v1 brute-forces `float[D]` BLOBs with Accelerate. Open: at what N to invest in a custom static SQLite + sqlite-vec/ANN (guess >250k).
3. **Embedding quality** — is `NLEmbedding` (~512d) good enough for domain retrieval, or do we need a local model (MLX/Ollama) sooner than "later"? Spike in Phase 0.
4. **Audio sources** — ship `SFSpeechRecognizer` in v1 or defer the type?
5. **Concept-merge threshold** — `cos>0.86` is a guess; tune on a real corpus. False-merge (two distinct concepts collapsed) is the dangerous direction.
6. **Cross-brain query** — v1 is single-brain-per-call by design (agent loops if it wants several). Confirm no federated rerank is wanted.
7. **Delete/regenerate** — domain brains are regenerable; expose a "rebuild from sources" action and a clean delete.
8. **Batch vs concurrent-sync (Phase 0 decision)** — build the Anthropic Batch API client (cheaper, but minutes–24h latency vs the "next window" model) or ship v1 on bounded concurrent synchronous Haiku calls? Either needs a new generic `AnthropicClient` method first.
