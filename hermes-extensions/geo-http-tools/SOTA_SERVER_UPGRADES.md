# SOTA Server Upgrades — Geo HTTP API (next Geo.app build)

Reviewed design + patch spec for the **server side** (Swift) of the Geo HTTP API.
Authored by Lane S. **No `.swift` file is edited here** — this is a plan with exact
`file:line` anchors and diff sketches for the next build. Lane P aligns the Python
client (`hermes-extensions/geo-http-tools/`) to the contract below.

All line numbers are as of the commit this was authored against. Anchor by symbol
name if they have drifted.

Source map (what was read):

| File | Role |
|---|---|
| `Geo/Shared/Infrastructure/HTTP/GeoAPIRouter.swift` | route → MCP tool dispatch |
| `Geo/Shared/Infrastructure/MCP/Tools/{Block,Task,Tag,Day,AI}Tools.swift` | the tools |
| `Geo/Features/Blocks/Domain/BlocksRepository.swift` | repo protocol (only `list()`, no `get(id:)`) |
| `Geo/Features/Blocks/Data/BlocksStoreRepositoryAdapter.swift` | concrete repo + `BlocksStoreAccess` |
| `Geo/Features/Blocks/Data/BlocksStore.swift` | has a private `blocksById: [String:Int]` index already |
| `Geo/Features/Tasks/Domain/TasksRepository.swift` | repo protocol (only `list()`, no `get(id:)`) |
| `Geo/Features/Tasks/{Domain/QuickAddParser,Data/AITaskParser}.swift` | the parsers |
| `Geo/Tests/HTTP/GeoHTTPServerTests.swift` | test harness style |

---

## Ranked summary

| # | Upgrade | Value | Breaking? |
|---|---|---|---|
| 2 | Fix dead `/v1/tasks/parse` route (calls unregistered tool) | **Highest — live 500** | non-breaking (server bugfix) |
| 1 | Keyed block lookup in destructive prepare/commit (kill O(B)×2 scan) | High | non-breaking |
| 3 | Honor `limit`/`offset`/`depth` params the client sends | High | non-breaking (additive) |
| 4 | Server-side `GET /v1/tasks/search` fuzzy ranker | Medium-High | non-breaking (additive) |
| 5 | `update_block` metadata fields (title/type/status/layer) | Medium | non-breaking (additive) — **recommend (a)** |
| 6 | Pure-REST plural renames + create niceties | Low | **breaking — deferred, do not push** |
| — | Appendix: route→tool→args contract table | reference | — |

---

## 1. [PERF, non-breaking] Keyed block lookup in destructive prepare/commit

**Problem.** `prepareDestructive` and `commitDestructive` each do a full-vault scan to
find one block by id:

- `GeoAPIRouter.swift:322-323` (prepare):
  ```swift
  let all = try await blocks.list()
  guard let block = all.first(where: { $0.id == targetId }) else { ... }
  ```
- `GeoAPIRouter.swift:382-383` (commit re-check):
  ```swift
  let all = try await blocks.list()
  guard let current = all.first(where: { $0.id == op.targetId }) else { ... }
  ```

A single block delete pays this **twice** (prepare + commit). `blocks.list()` snapshots
the entire `BlocksStore.blocks` array on the MainActor and maps every entity
(`BlocksStoreRepositoryAdapter.list()`, line 240-242) — O(B) work + O(B) `.first(where:)`
linear search, to fetch **one** row by its primary key.

**Triad lens.** lens-data (array `.find` where the op is a primary-key lookup → should be
a hash map) + lens-io (two redundant full-snapshot round-trips for one delete). `BlockTools`
has the identical anti-pattern in its `loadBlock` helper (`BlockTools.swift:28-31`) and in
`getBlock` (line 123-124), so the fix is reusable.

**What exists today.** No `get(id:)` on `BlocksRepository` (protocol is `list()`-only,
`BlocksRepository.swift:3-23`) and none on `BlocksStoreAccess`
(`BlocksStoreRepositoryAdapter.swift:4-24`). **But** `BlocksStore` already maintains a keyed
index: `private var blocksById: [String:Int]` rebuilt on every `blocks` set
(`BlocksStore.swift:15-22`) with a private `block(withId:)` (line 29-32). So the keyed read
is O(1) and already computed — it just isn't surfaced through the protocol chain.

**Proposed change.** Surface a keyed accessor end-to-end, then use it in the router.

1. `BlocksStore.swift` — make the existing helper reachable (drop `private`, or add a thin
   public wrapper):
   ```swift
   // was: private func block(withId id: String) -> Block?
   func block(withId id: String) -> Block? { ... }   // unchanged body, O(1) via blocksById
   ```
2. `BlocksStoreRepositoryAdapter.swift` — add to the `BlocksStoreAccess` protocol (line 4)
   and `LiveBlocksStoreAccess` (line 46):
   ```swift
   func block(id: String) async -> BlocksStore.Block? {
       await MainActor.run { blocksStore.block(withId: id) }
   }
   ```
3. `BlocksRepository.swift` — add to the protocol with a default that falls back to `list()`
   so test fakes need no change:
   ```swift
   func block(id: String) async throws -> BlockEntity?
   // in extension:
   func block(id: String) async throws -> BlockEntity? {
       try await list().first(where: { $0.id == id })   // default; adapter overrides O(1)
   }
   ```
   Adapter override:
   ```swift
   func block(id: String) async throws -> BlockEntity? {
       await storeAccess.block(id: id).map(BlockEntity.init(from:))
   }
   ```
4. `GeoAPIRouter.swift` — replace both scans:
   ```swift
   // prepare, line 322-323:
   - let all = try await blocks.list()
   - guard let block = all.first(where: { $0.id == targetId }) else {
   + guard let block = try await blocks.block(id: targetId) else {

   // commit, line 382-383:
   - let all = try await blocks.list()
   - guard let current = all.first(where: { $0.id == op.targetId }) else {
   + guard let current = try await blocks.block(id: op.targetId) else {
   ```

**Optional follow-up (same axis).** Refactor `BlockTools.loadBlock` (line 28-31) and
`getBlock` (123-124) to call `blocks.block(id:)`; pure win, no contract change.

**Test note.** Add `testDestructivePrepareUsesKeyedLookup` to `GeoHTTPServerTests`: give
`FakeBlocksRepository` a counting `block(id:)` and assert prepare+commit of one delete calls
it (or `list()`) the minimum number of times — currently `list()` is hit twice, target is a
keyed hit per phase. Cheaper version: just assert the two-phase delete still returns 200 with
the new path (regression guard).

**Verdict.** Worth it. Hot path (every delete), and the O(1) index already exists — this is
plumbing, not new data structure work.

---

## 2. [CORRECTNESS, server bug — HIGHEST] `/v1/tasks/parse` calls an unregistered tool

**Problem.** `GeoAPIRouter.swift:169-170`:
```swift
case "/v1/tasks/parse":
    return await call("ai_quick_add_parse", args: body)
```
No tool named `ai_quick_add_parse` is registered anywhere (grep confirms zero hits outside
this one line). `registry.call(name:)` throws → `call()`'s catch returns **500 "tool failed"**
(`GeoAPIRouter.swift:283-290`). The route is dead.

**What actually exists.** A correct, registered tool: `ai_parse_task` in
`AITools.swift:8-33`, wired in at `GeoApp.swift:131` (`+ AITools.register()`). It wraps
`AITaskParser.parse` (`AITaskParser.swift:17`), which itself runs `QuickAddParser` locally
first and falls back to Claude Haiku for low-confidence input — exactly the hybrid we want.
**Pick `ai_parse_task` / `AITaskParser`** (it subsumes `QuickAddParser`; do not wire the raw
`QuickAddParser`).

**Contract (read off the tool, for Lane P).**
- Tool input key: **`input`** (string, required) — `AITools.swift:14,19`.
- Tool output (`AITools.serialize`, lines 35-66): `{ title, kind, priority, notes, source,
  + (due | start,end | recurrence,time_of_day | target) [, estimated_minutes] [, tag_ids] }`.
  `source` is `"local"` or `"ai"`.

**Current client mismatch (3 ways off — Lane P fixes).** `tools_write.py:126-127`:
```python
async def _ai_parse_task(c, a):
    return await c.post("/tasks/ai-parse", json={"text": a["text"]})
```
posts to `/tasks/ai-parse` with key `text`. Server route is `/v1/tasks/parse` and the tool
wants `input`. Two ends, two names. **Decision: make the server the source of truth** and have
Lane P match it (path `/v1/tasks/parse`, body key `input`).

**Proposed change.** One line in the router — point the route at the real tool and normalize
the body key so the client may send either `input` or `text`:
```swift
// GeoAPIRouter.swift:169-170
case "/v1/tasks/parse":
-   return await call("ai_quick_add_parse", args: body)
+   var args = body
+   if args["input"] == nil, let t = body["text"]?.stringValue { args["input"] = .string(t) }
+   return await call("ai_parse_task", args: args)
```
(The `text`→`input` shim is optional belt-and-suspenders; if Lane P sends `input`, drop it
and just `return await call("ai_parse_task", args: body)`.)

**Test note.** `testTasksParseRoutesToAIParser`: register a stub `ai_parse_task` in the test
registry (the harness already builds `MCPToolRegistry(tools:[])`, `GeoHTTPServerTests.swift:24`),
POST `/v1/tasks/parse` with `{"input":"gym tomorrow 7am"}`, assert 200 and that the stub saw
`input`. Add a guard test asserting the route is **not** 500 (the current symptom).

**Verdict.** Ship first. This is a live 500 on a documented route; the fix is one line + a
known-good tool.

---

## 3. [SOTA, non-breaking] Honor pagination / shaping params the client sends

All additive: new optional schema keys + a `prefix`/passthrough in the handler, plus the
router reading the query param. None change existing behavior when the param is absent.

### 3a. `limit` + `offset` on `list_tasks` and `list_blocks`

- **`list_blocks`** already accepts `limit` (schema `BlockTools.swift:67`, applied 83-85) and
  the router already forwards it (`GeoAPIRouter.swift:87`). **Add `offset` only.**
  ```swift
  // schema, after line 67:
  "offset": .integer("Skip N results before limit"),
  // handler, replace the limit block 83-85:
  let offset = args["offset"]?.intValue ?? 0
  if offset > 0 { filtered = Array(filtered.dropFirst(offset)) }
  if let limit = args["limit"]?.intValue { filtered = Array(filtered.prefix(limit)) }
  // router, after GeoAPIRouter.swift:87:
  if let o = request.query["offset"].flatMap(Int.init) { args["offset"] = .int(o) }
  ```
- **`list_tasks`** accepts neither today (schema `TaskTools.swift:226-231`, no slicing).
  ```swift
  // schema, add:
  "limit": .integer("Max results"),
  "offset": .integer("Skip N before limit"),
  // handler, before `return .json(items.map(taskSummary))` (TaskTools.swift:246):
  if let off = args["offset"]?.intValue, off > 0 { items = Array(items.dropFirst(off)) }
  if let lim = args["limit"]?.intValue { items = Array(items.prefix(lim)) }
  // router /v1/tasks block (GeoAPIRouter.swift:105-111), add:
  if let l = request.query["limit"].flatMap(Int.init) { args["limit"] = .int(l) }
  if let o = request.query["offset"].flatMap(Int.init) { args["offset"] = .int(o) }
  ```

### 3b. `limit` on `list_by_status`, `list_by_type`, `search_blocks`, `find_orphans`, `find_unresolved_links`, `list_tags`

Same shape each: add `"limit": .integer("Max results")` to the schema, and
`.prefix(limit)` the `items`/`entries` array just before `return .json(...)`. Anchors:

| Tool | schema line | apply `.prefix` before |
|---|---|---|
| `search_blocks` | `BlockTools.swift:181-183` | line 201 (`return .json(items)`) |
| `list_by_type` | `BlockTools.swift:540-542` | line 567 |
| `list_by_status` | `BlockTools.swift:576-578` | line 596 |
| `find_orphans` | `BlockTools.swift:452` (`[:]`) | line 466 |
| `find_unresolved_links` | `BlockTools.swift:478` (`[:]`) | line 493 |
| `list_tags` | `TagTools.swift:22` (`JSONSchemaObject()`) | line 35 |

Router passthrough — add `limit` reading to each route:
- `/v1/blocks/by-status` (`GeoAPIRouter.swift:93-95`), `/v1/blocks/by-type` (96-98),
  `/v1/blocks/search` (99-101): after building `args`, add
  `if let l = request.query["limit"].flatMap(Int.init) { args["limit"] = .int(l) }`.
- `/v1/blocks/orphans` (line 78) and `/v1/blocks/unresolved-links` (line 80): currently
  `args:[:]`; switch to the same `var args` + limit-read pattern.
- `/v1/tags` (line 118): same.

Handler sketch (e.g. `search_blocks`, before line 201):
```swift
var items = results.map { ... }              // existing
if let lim = args["limit"]?.intValue { items = Array(items.prefix(lim)) }
return .json(items)
```

### 3c. `depth` on `list_neighbors`

`list_neighbors` (`BlockTools.swift:501-534`) returns only direct incoming/outgoing
(`graph.findNeighbors(of:)`, line 517) — no depth notion. **Two honest options:**

- **(i) Cheap, recommended now:** accept `depth` in the schema but document it as
  "reserved; only depth=1 supported", and 400 on `depth > 1` rather than silently lying.
  Add to schema: `"depth": .integer("Hops (1 supported today)")`; in handler:
  `if let d = args["depth"]?.intValue, d > 1 { return .error("depth>1 not yet supported") }`.
  Router already has the `/neighbors` route (`GeoAPIRouter.swift:125-127`); add the passthrough.
- **(ii) Real BFS:** implement multi-hop in `BlockGraphService.findNeighbors(of:depth:)`.
  This is genuine graph work, not a passthrough — **defer** unless a caller needs it. Don't
  cargo-cult a depth param onto a 1-hop function.

**Test note (all of #3).** One parametric test per family in `GeoHTTPServerTests`:
seed the fake repo with N items, `GET …?limit=2` → assert ≤2 returned; `?limit=2&offset=1`
on tasks/blocks → assert the windowed slice. For `depth`, assert `?depth=2` → 400.

**Verdict.** Do 3a + 3b (pure additive, the client already wants them). Do 3c option (i)
only — reject, don't fake. Skip 3c(ii).

---

## 4. [SOTA ARCH, non-breaking] `GET /v1/tasks/search?q=&limit=` — server-side fuzzy ranker

**Problem.** `geo_find_tasks` / `geo_resolve_task` / `geo_upsert_task` (Python) each pull the
**entire** task list over HTTP and rank client-side in `matching.py` (`rank`/`score`,
lines 29-66: accent-strip normalize → max(substring, `SequenceMatcher` ratio, token Jaccard)).
For a find-before-create dedup check that's a full-list transfer per call.

**Triad lens.** lens-io: computing in the client what the server already holds in memory.
The vault is small today, so this is **not** an O(scale) emergency — but a top-K endpoint is
strictly less data on the wire and lets the ranker live next to the data. Ship it as the
SOTA shape; it also un-blocks future server-side indexing.

**Proposed change.**

1. New tool in `TaskTools.swift` (register in the `register` array, line 5):
   ```swift
   private static func searchTasks(_ tasks: any TasksRepository) -> MCPRegisteredTool {
       MCPToolBuilder(
           name: "search_tasks",
           description: "Fuzzy-rank tasks by title against a query; returns top-K with score.",
           schema: JSONSchemaObject(properties: [
               "query": .string("Search query"),
               "limit": .integer("Max results (default 10)"),
               "status": .string("Filter before ranking", enum: ["pending","completed"]),
           ], required: ["query"]),
           handler: { args in
               guard let q = args["query"]?.stringValue else { return .error("Missing required parameter: query") }
               let limit = args["limit"]?.intValue ?? 10
               var items = try await tasks.list()
               if let s = args["status"]?.stringValue, let st = TaskStatus(rawValue: s) {
                   items = items.filter { $0.status == st }
               }
               let scored = items
                   .map { (task: $0, score: TaskMatch.score(query: q, title: $0.title)) }
                   .filter { $0.score > 0 }
                   .sorted { $0.score > $1.score }
                   .prefix(limit)
               return .json(scored.map { s -> [String: AnyCodableValue] in
                   var e = taskSummary(s.task); e["score"] = .double(s.score); return e
               })
           }
       ).registered
   }
   ```
2. `TaskMatch.score` — a small Swift mirror of `matching.py`'s `score` (normalize: lowercase
   + strip diacritics via `folding(options:.diacriticInsensitive)` + drop punctuation +
   collapse whitespace; then `max(substring, difflib-style ratio, token Jaccard)`). New file
   `Geo/Features/Tasks/Domain/TaskMatch.swift`. Swift has no `SequenceMatcher`; a Levenshtein-
   normalized ratio is an acceptable stand-in — note to Lane P that scores won't be
   bit-identical, only rank-compatible.
3. Router — add to the GET switch (alongside `/v1/tasks/upcoming`, `GeoAPIRouter.swift:112`):
   ```swift
   case "/v1/tasks/search":
       guard let q = request.query["q"] else { return .error(400, "q query required") }
       var args: [String: AnyCodableValue] = ["query": .string(q)]
       if let l = request.query["limit"].flatMap(Int.init) { args["limit"] = .int(l) }
       if let s = request.query["status"] { args["status"] = .string(s) }
       return await call("search_tasks", args: args)
   ```
   **Ordering caveat:** this `case` must sit in the literal-path `switch` (lines 76-120),
   which runs *before* the `/v1/tasks/{id}` `pathParam` fallback (line 134) — so `search`
   won't be swallowed as a task id. Good as written.

**Client change Lane P would make later (note only).** Add `_search_tasks(c,a) → GET
/v1/tasks/search?q=&limit=`; switch `geo_find_tasks`/`geo_resolve_task` to call it instead of
fetching all + `matching.rank`. Keep `matching.py` as the fallback if the route 404s on an old
build (forward-compatible degrade).

**Test note.** `testTasksSearchRanksByTitle`: stub `search_tasks` (or seed a fake with three
titles), `GET /v1/tasks/search?q=…&limit=2`, assert 200, ≤2 results, descending `score`, exact
title first.

**Verdict.** Worth shipping as additive — but be honest in the file that at current vault size
the win is wire-size + architecture, not a perf cliff.

---

## 5. [UX] `update_block` cannot change title/type/status/layer — extend it

**Problem.** `update_block` (`BlockTools.swift:276-332`) takes only `{id, content}` (schema
280-283) and replaces the full markdown (merging only frontmatter that round-trips through
the body). It cannot set type/status/layer/title directly — callers must chain
`set_layer` / `promote_to_permanent` / a frontmatter-encoded body. The capabilities exist as
separate repo calls (`setType`/`setStatus`/`setLayer`, used in `createBlock` lines 263-269).

**Options.**
- **(a) Extend `update_block`** with optional `title`/`type`/`status`/`layer`, applied after
  the content write via the same calls `createBlock` uses. `content` becomes optional too
  (so a pure metadata edit needs no full-body rewrite).
- **(b) Document the split as intentional** — `set_layer`, `set_block_tag`, dedicated
  promote/extract endpoints each own one mutation; `update_block` owns body only.

**Recommendation: (a).** Rationale: (b)'s split forces N round-trips and a read-modify-write
for what is conceptually one PATCH, and the client PATCH route (`GeoAPIRouter.swift:219-223`)
already funnels arbitrary body fields into `update_block` — so the *transport* already invites
a richer body; only the tool is narrow. (a) is additive (absent fields = today's behavior),
and reuses authorized setters that already gate on layer.

**Diff sketch (`BlockTools.swift`).**
```swift
// schema (lines 280-283): make content optional, add fields:
schema: JSONSchemaObject(properties: [
    "id": .string("Block ID (filename)"),
    "content": .string("New markdown content (optional if only changing metadata)"),
    "title": .string("New display title (optional)"),
    "type": .string("fleeting|literature|permanent|moc|project (optional)"),
    "status": .string("active|evergreen|archived|draft (optional)"),
    "layer": .string("agent|review|shared (optional)"),
], required: ["id"]),                       // was ["id","content"]

// handler: guard only id; run the existing content path only when content present;
// then, gated by the same authorize(.update…) already at line 295:
if let t = args["type"]?.stringValue, let bt = BlockType(rawValue: t.lowercased()) {
    try await blocks.setType(blockId: id, type: bt)
}
if let s = args["status"]?.stringValue { try await blocks.setStatus(blockId: id, status: s.lowercased()) }
if let l = args["layer"]?.stringValue, let bl = BlockLayer(rawValue: l.lowercased()) {
    try await blocks.setLayer(blockId: id, layer: bl)
}
```
**Caveat to flag:** keep the agent-layer guard — agents must not set `layer: user`
(`set_layer` already rejects it via `AgentAuthorization`; reuse the same path, don't bypass).
Title rename = filename change in this store; if there's no safe rename primitive, **omit
`title` from (a)** and leave renames to the app. Confirm before implementing.

**Test note.** `testUpdateBlockSetsTypeWithoutContent`: PATCH `/v1/blocks/{id}` with
`{"type":"permanent"}` only → 200, and `get_block` shows `type=permanent`, body unchanged.

**Verdict.** Do (a), minus `title` unless a rename primitive exists.

---

## 6. [OPTIONAL, breaking — flag only, DO NOT PUSH] Pure-REST renames & create niceties

These would make the surface tidier but **break the client atomically** and we own both
sides, so the value is ~zero. Listed for the record; defer indefinitely.

- `/blocks/{id}/tag` → `/blocks/{id}/tags` (plural). Router `GeoAPIRouter.swift:183-187`.
- `/tasks/{id}/reminder` → `/tasks/{id}/reminders` (plural). Router line 227-231. (Note: the
  Python client *already* posts to `/tasks/{id}/reminders` — `tools_write.py` `_add_reminder`
  — so today that call 404s; **either** rename server to plural **or** Lane P fixes the client
  to singular. Cheaper: Lane P matches the singular server. Flagging the mismatch here.)
- `record_habit_occurrence` route is `/v1/days/{date}/habit` (router line 237-240); the client
  posts `/habits/occurrences`. Pure-REST would be `/habits/{id}/occurrences`. Breaking; defer.
- `create_block` multi-tag: today one `tag_name` (BlockTools line 240-245). Plural `tag_names`
  is additive-ish but needs a repo multi-tag primitive — defer with the renames.
- `create_tag` hex-color input: today only `{red,green,blue}` floats (`TagTools.swift:46-65`).
  Accepting `"#0055FF"` is a nice convenience and **non-breaking** (additive optional key) —
  if anything pull this *out* of the breaking bucket and fold into a future additive pass.

**One-line caveat:** anything renaming a path is breaking and must land in the same release as
the client change; given single-owner deployment, prefer making the client match the existing
server path over renaming the server.

**Test note.** None until/unless adopted.

---

## 7. APPENDIX — Route → MCP tool → args contract (authoritative)

Compiled from the tool files. `*` = required. "router-injected" = the router supplies this
from the URL path/query, not the JSON body. Args list the tool's schema keys (body keys for
POST/PATCH unless noted). Current-build truth; items #2–#5 above change rows marked ⚠.

### GET

| Route | Tool | Args (router→tool) |
|---|---|---|
| `/v1/blocks` | `list_blocks` | `tag_name?`, `limit?` (query) — ⚠ +`offset?` (#3a) |
| `/v1/blocks/{id}` | `get_block` | `id*` (path) |
| `/v1/blocks/by-title?title=` | `get_block_by_title` | `title*` (query) |
| `/v1/blocks/by-status?status=` | `list_by_status` | `status*` (query) — ⚠ +`limit?` (#3b) |
| `/v1/blocks/by-type?type=` | `list_by_type` | `type*` (query) — ⚠ +`limit?` (#3b) |
| `/v1/blocks/search?q=` | `search_blocks` | `query*` (q→query) — ⚠ +`limit?` (#3b) |
| `/v1/blocks/{id}/neighbors` | `list_neighbors` | `id*` (path) — ⚠ +`depth?` reserved (#3c) |
| `/v1/blocks/{id}/backlinks` | `find_backlinks` | `block_id*` (path) |
| `/v1/blocks/orphans` | `find_orphans` | — ⚠ +`limit?` (#3b) |
| `/v1/blocks/unresolved-links` | `find_unresolved_links` | — ⚠ +`limit?` (#3b) |
| `/v1/graph/snapshot?limit=` | `get_graph_snapshot` | `limit?` (query) |
| `/v1/folders` | (direct `blocks.listFolders()`, no tool) | — |
| `/v1/tasks` | `list_tasks` | `status?`,`kind?`,`priority?`,`linked_block_id?` (query) — ⚠ +`limit?`,`offset?` (#3a) |
| `/v1/tasks/{id}` | `get_task` | `id*` (path) |
| `/v1/tasks/upcoming?window=&limit=` | `list_upcoming` | `window?`,`limit?` (query) |
| `/v1/tasks/for-day/{date}` | `list_tasks_for_day` | `date*` (path) |
| `/v1/tasks/search?q=&limit=` | `search_tasks` | ⚠ **new** (#4): `query*`,`limit?`,`status?` |
| `/v1/tags` | `list_tags` | — ⚠ +`limit?` (#3b) |
| `/v1/days/today` | `get_today` | — |
| `/v1/days/{date}` | `get_day` | `date*` (path) |

### POST / PATCH

| Route | Tool | Args |
|---|---|---|
| `POST /v1/blocks` | `create_block` (+`blocks.move` if `folder`) | `title*`,`content*`,`tag_name?`,`day_id?`,`type?`,`status?`,`layer?`,`folder?` |
| `POST /v1/folders` | (direct `blocks.createFolder`) | `folder*` (or `path`) |
| `POST /v1/tasks` | `create_task` | `title*`,`body*`(`kind*`+kind fields),`notes?`,`linked_block_id?`,`priority?`,`tag_ids?`,`reminders?` |
| `POST /v1/tasks/parse` | ⚠ `ai_parse_task` (#2; was bad `ai_quick_add_parse`) | `input*` (router shims `text`→`input`) |
| `POST /v1/tags` | `create_tag` | `name*`,`color?`{red,green,blue} |
| `POST /v1/destructive/prepare` | (router) → `delete_block`/`delete_task` at commit | `operation*`,`target_id*` |
| `POST /v1/destructive/commit/{txId}` | → `delete_block`/`delete_task` | `block_version?` (path `txId*`) |
| `POST /v1/blocks/{id}/tag` | `set_block_tag` | `block_id*`(path),`tag_name*` |
| `POST /v1/blocks/{id}/layer` | `set_layer` | `id*`(path),`layer*` |
| `POST /v1/blocks/{id}/extract-permanent` | `extract_permanent_from` | `id*`(path) |
| `POST /v1/blocks/{id}/promote-permanent` | `promote_to_permanent` | `id*`(path) |
| `POST /v1/blocks/{id}/link-day` | `link_block_to_day` | `block_id*`(path),`date*` |
| `POST /v1/blocks/{id}/move` | (direct `blocks.move`) | `id*`(path),`folder?` |
| `PATCH /v1/blocks/{id}` | `update_block` | `id*`(path),`content*` — ⚠ +`title?`,`type?`,`status?`,`layer?`, content→optional (#5) |
| `POST /v1/tasks/{id}/complete` | `complete_task` | `id*`(path) |
| `POST /v1/tasks/{id}/reminder` | `add_reminder` | `id*`(path),`trigger*`,`offset?`/`at?` |
| `PATCH /v1/tasks/{id}` | `update_task` | `id*`(path),`title?`,`notes?`,`status?`,`linked_block_id?`,`priority?`,`tag_ids?`,`body?` |
| `POST /v1/days/{date}/habit` | `record_habit_occurrence` | `date*`(path),`id*`,`date?` |

### DELETE (two-phase; require `transaction_id` from prepare)

| Route | Tool | Args |
|---|---|---|
| `DELETE /v1/blocks/{id}` | `delete_block` (after commit) | `id*`(path), `transaction_id*`,`block_version?`(body) |
| `DELETE /v1/tasks/{id}` | `delete_task` (after commit) | `id*`(path), `transaction_id*`(body) |

---

### Items deliberately NOT proposed (anti-cargo-cult)

- **`get_block`/`BlockTools.loadBlock` O(B) scans:** flagged as a *follow-up* under #1, not a
  separate work item — same fix, batch it.
- **Caching `blocks.list()` results:** the store is the in-memory source of truth already; a
  cache layer would add staleness risk for no measured win at this vault size. Skip.
- **Pagination on `get_graph_snapshot`:** already has `limit` by weight (BlockTools 672-730).
  Fine as-is.
- **`list_upcoming` limit:** already honored (TaskTools 519,523,539). Fine as-is.
