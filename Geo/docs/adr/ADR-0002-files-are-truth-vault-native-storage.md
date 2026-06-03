# ADR-0002: Files-Are-Truth — Vault-Native Storage, App-as-Deriver, Tool-Surface Collapse

- Date: 2026-06-03
- Status: Proposed (decision-grade; phased, do-not-ship-as-originally-specified — see §9 blockers)
- Supersedes (operationally): the split-store + 39-tool transaction model
- Owner: Geo core

---

## 1. Context

### 1.1 The problem: source of truth is split across five stores

A Geo block's truth is currently spread across five places:

| Store | Holds | File |
|---|---|---|
| `.md` body | canonical prose, `type`, `status`, body `#tags`, `[[wikilinks]]`, checkboxes | `Blocks/*.md` |
| Sidecar JSON | `layer`, `tagId`, `dayId`, `isFullWidth` | `.blocks-metadata.json` |
| SQLite | mirror of all of the above + FTS | `Index/blocks.sqlite` |
| Day map | day → blockIds, captureIds | `days.json` |
| Tag store | tag defs (color) + membership by UUID | `tags.json` |

The `.md` is an **incomplete write**: `layer`/`tag`/`day` live elsewhere. To set a layer or tag, a writer must touch multiple stores atomically. That multi-store transaction is the **entire reason** the HTTP/MCP surface grew to ~39 tools — `set_layer`, `set_block_tag`, `link_block_to_day`, destructive prepare/commit, `frontmatter_version` counters, the `FrontmatterMutatorActor`, the `PendingTransactionStore`. The API exists to do what the file alone cannot.

### 1.2 Why now / why this is right

- **Concurrency is NOT a justification.** Geo is single-user, serial-attention. `frontmatter_version` and `FrontmatterMutatorActor` exist only for multi-writer coordination — exactly what this removes. They are demoted, not load-bearing.
- **Existence proof.** Obsidian + the Genesis Kit at `/Users/biel/ai/Obsidian-Brain` run a full PKM system where the **file is the whole truth** and the app derives everything. We adopt the same contract.
- **CLAUDE.md is stale and misrepresents the architecture.** It still frames hermes↔Geo as MCP-mediated and treats the bridge as the data contract. The MCP path is retired in favor of HTTP/native FS (both processes live on the same Mac). The ADR records the corrected model; CLAUDE.md must be updated as part of this work (§8.4).

### 1.3 Governing rule (from the Genesis Kit)

> **Folder = where it lives + owner · Tag = what it is · Link = how it connects.**

The kit's literal rule (`/Users/biel/ai/Obsidian-Brain/README.md:55`) is a **domain** taxonomy (`00-system / 10-journal / 20-private / 30-knowledge/...`). Geo's top-level folder instead encodes a **writer-permission/layer** axis (`Voce/Agente/Revisao/Compartilhado`). These are **different axes** (see §9, MAJOR: kit-alignment). This ADR adopts the *spirit* (files-are-truth, derive everything) but is **not** drop-in kit-compatible, and we drop that compatibility claim. If kit-compatibility ever becomes a goal, the permission axis must move off the folder (`owner:` frontmatter) and folders go domain-based.

---

## 2. Decision

1. **The `.md` file is the whole truth.** Every block attribute is either in the file body, in its frontmatter, or **derived from its path**.
2. **Folder = layer + owner.** Top-level folder under `Blocks/` selects the layer. (Refined by §9 BLOCKER-1: layer is the **first** path segment; arbitrary topic sub-nesting is preserved.)
3. **Tags and day-links are inline** (frontmatter `tags:` + body `#hashtag`; body `[[YYYY-MM-DD]]`). Tag identity becomes the **name string**, not a UUID.
4. **SQLite is demoted to a pure, rebuildable cache.** It is never authoritative. FTS/graph/tag-map/day-map all rebuild from files on FileWatcher events.
5. **The three central write stores die**: `.blocks-metadata.json`, `days.json`, and the membership half of `tags.json` (colors survive, §3.6).
6. **The write API collapses** into native filesystem ops (`Write`/`Edit`/`mv`/`rm`/`mkdir`). Only genuine compute (tasks recurrence/streaks/habits, AI parse, dedup, bm25 search, graph build) stays app-side.
7. **`frontmatter_version` + `FrontmatterMutatorActor` + destructive prepare/commit are demoted/dropped** — no concurrency need.

### 2.1 Hard constraint discovered in review — block identity must decouple from path

`relativeId` == relative path (`BlockFileService.swift:76-80`). Making layer == folder means **every layer change re-keys the block id**, orphaning task `linkedBlockId`, `days.json` `blockIds`, and capture links. `moveBlock` does **not** re-point those cross-subsystem refs today.

**Decision (revised from the original plan):** evaluate and prefer a **stable path-independent UUID id** stored in frontmatter (`id:`), so layer-as-folder never re-keys. This is the clean fix and removes the entire re-key cascade (§9 BLOCKER-4). If the UUID route is rejected, a **transactional, journaled re-key routine** (§7 Phase 1) that rewrites tasks/days/captures is mandatory and must be built **first**. Do not ship layer-as-folder without one of these two.

---

## 3. Target Architecture

### 3.1 Folder tree (folders = layers + owner; arbitrary nesting under each)

```
~/Library/Application Support/Geo/
  Blocks/
    Voce/            layer=.user      — agent CANNOT write (the one safety boundary)
      MOC/ Dias/ Semanas/ ...         — user topic sub-structure PRESERVED (BLOCKER-1)
    Agente/          layer=.agent     — agent free-write
    Revisao/         layer=.review    — agent free-write; agent-created default lands here
    Compartilhado/   layer=.shared    — agent free-write
    Daily/           Daily/YYYY-MM-DD.md daily-note link targets (backlinks → day membership)
    Attachments/     (existing; skipped by enumerator — BlockFileService.swift:52,101)
  Tasks/             <UUID>.md|json — NOT layered, own tree (§5)
  Captures/          *.png (unchanged)
  capture-history.json   (unchanged in Phase 1 — captures are not blocks)
  tags.json          SHRUNK to definitions-only: canonical-name → {color, icon?, order?}
```

- **Layer is derived from the FIRST path segment only.** `Voce/MOC/MOC-Pessoal.md` → `.user`, sub-structure intact. This is the BLOCKER-1 correction to the original "flat `Blocks/`" assumption — the live vault already has `MOC/`, `Dias/`, `Semanas/` user folders that must NOT be flattened.

Folder → layer map (ASCII slugs):

```
"Voce" → .user · "Agente" → .agent · "Revisao" → .review · "Compartilhado" → .shared
root / unknown / "Daily" → .user   (safe default; never agent-writable)
```

**ASCII folder slugs, accented display names only.** Filenames NFC-precompose (`BlockFileService.swift:80`) and there is an explicit `collapseBlockIdNFCDuplicates` migration (`DatabaseService.swift:218-243`) proving accented path segments cause NFC/NFD duplicate-id bugs. On disk: `Voce/Agente/Revisao/Compartilhado`. Display stays `Você/Agente/Revisão/Compartilhado` via the already-decoupled `BlockLayer.displayName` (`BlockType.swift:45-52`). NOTE (§9 MINOR): `precomposedStringWithCanonicalMapping` is NFC normalization, not ASCII transliteration — the NFC guard must extend to the **new layer folder segments** too.

### 3.2 Inline frontmatter schema

```yaml
---
id: 0d6c1e7a-...        # NEW: stable path-independent id (preferred fix, §2.1)
type: permanent          # already present (fleeting|literature|permanent|moc|project)
status: evergreen        # already present
tags: [arc, engenharia-de-software]   # NEW write home (was sidecar tagId UUID)
full_width: true         # NEW (was sidecar isFullWidth); omit when false
---
```

- **Layer is NOT in frontmatter** — it's the first folder segment. A layer change is a `mv`. (Storing it in frontmatter too would re-create the dual-write we are killing.) Caveat: review's BLOCKER-1 mitigation (a) considers keeping layer in frontmatter as the honest orthogonal-axis representation; we reject (a) in favor of first-segment derivation + preserved sub-nesting (mitigation b).
- `frontmatter_version` dropped from new writes; reader tolerates absence (`MarkdownConverter.frontmatterVersion` → `0`).

### 3.3 Inline tags (two surfaces, both derived)

- Body `#hashtag` — already parsed (`MarkdownIndexingService.extractTags`, regex `(?<!\w)#([A-Za-z0-9_-]+)`).
- Frontmatter `tags: [a, b]` — **net-new support**, mandatory for multi-word/accented names the hashtag regex rejects (`Introdução à Engenharia de Software`, `Segurança e Auditoria`). Tag identity = **canonical name** (lowercase + NFC), eliminating UUID indirection.

### 3.4 Day-links inline + daily-note convention

- A block belongs to a day iff its body contains `[[YYYY-MM-DD]]`. Day id == `DateFormatters.dayId` (`yyyy-MM-dd`, `DateFormatters.swift:26-30`) — exact `[[date]]` shape.
- `Daily/YYYY-MM-DD.md` is a real link target so backlinks resolve.
- **Day membership is NOT a leading-wildcard LIKE scan.** (Original plan said use `searchBlocksContaining(wikiLink:)`; that is an un-indexable full-table content scan, §9 PERF-1.) Instead extract `[[YYYY-MM-DD]]` tokens in the **same single-pass body parse** that already finds `#tags`/checkboxes, and persist an indexed `block_days(blockId, dayId)` join table (mirroring `block_tags`). `get_today`/`get_day` answer with `SELECT blockId FROM block_days WHERE dayId = ?`. `searchBlocksContaining` LIKE is reserved for ad-hoc `find_backlinks` only.
- **`Dias/` vs `Daily/` collision** (§9 MINOR): the live vault already has a free-form `Dias/` (d1..d6, not date-named). Reconcile explicitly: keep `Dias/` as user topic notes (under `Voce/`), introduce `Daily/` only for date-named day notes; decide whether `Dias/` notes participate in backlink day-membership (default: no).

### 3.5 `full_width` — the one honest edge case

`isFullWidth` is a UI preference, not knowledge — no inline/folder home in the PKM model. Decision: inline as frontmatter `full_width: true` (omit when false). Rejected alternative: a tiny UI-prefs sidecar (re-introduces a per-block central store, defeats the point).

### 3.6 MOC / index convention

A MOC is a normal `type: moc` block (`BlockType.swift:7`) in its owner folder whose body is `[[wikilinks]]` to members; the graph deriver (`BlockGraphService`) resolves them. `Daily/YYYY-MM-DD.md` notes are per-day MOCs whose membership is derived via backlinks. No index file is authoritative.

### 3.7 Tag colors — the one legitimate central file

`tags.json` shrinks to canonical-name → `{color, icon?, order?}` (drop UUIDs/membership). Colors feed `BlockGraphService.buildGraph(tagColors:)`. `TagStore`'s watcher (`TagStore.swift:31`) keeps owning colors only. Auto-provision a default color when a new inline tag first appears.

### 3.8 Concrete example block

`Blocks/Compartilhado/Zettelkasten Method.md`:

```markdown
---
id: 7f3a9c20-1b44-4e9d-8a2e-2c1d5e0f9abc
type: permanent
status: evergreen
tags: [zettelkasten, pkm, engenharia-de-software]
full_width: false
---
# Zettelkasten Method

Atomic notes linked by meaning, not folders. See [[Atomic Notes]] and
[[Maps of Content]]. Captured #pkm thinking on [[2026-06-03]].

- [ ] Re-read Ahrens ch. 3
- [x] Migrate old highlights
```

Derivations from this one file: layer=`.shared` (folder `Compartilhado/`), tags=`{zettelkasten, pkm, engenharia-de-software}` (frontmatter + body `#pkm`, deduped), day-membership=`2026-06-03` (backlink to `Daily/2026-06-03.md`), graph edges → `Atomic Notes` / `Maps of Content` / `2026-06-03`, openTaskCount=1, completedTaskCount=1, type=permanent, status=evergreen, id=stable. **Zero central stores consulted.**

---

## 4. App = Derivation Only

The app becomes a pure deriver; every read-model rebuilds from files on FileWatcher events. Infra is **repointed, not rewritten**.

| Derived artifact | Mechanism today | Repoint |
|---|---|---|
| **FTS** (`blocks_fts`) | `DatabaseService.upsertBlock` title+content from `.md` (`:596-600`) | None — already file-derived; just stops being authoritative for layer/tag/day. |
| **Wikilink graph** | `BlockGraphService.buildGraph/parseWikiLinks` (`:247-328,459-482`); node id = SHA256(blockId) | None — 100% file-derived. Day-links flow through for free. |
| **Tag map** (`block_tags`) | `MarkdownIndexingService.extract`→`block_tags` (`DatabaseService.swift:588-592`) | **Extend `extractTags`** to also read frontmatter `tags:` (today scans only `document.body`, `:44`). |
| **Day map** (`block_days`) | none (days.json is a write store) | **NEW**: extract `[[YYYY-MM-DD]]` in the same body pass; persist indexed `block_days` (§3.4). |
| **layer** | `block.metadata.layer.rawValue` in `IndexCoordinator.entry` (`:233,257`) | **Derive from `block.url` first path segment** at both `entry(for:)` sites. SQLite `layer` becomes a path-derived cache. |

### 4.1 FileWatcher / reconciler repoint (the core change)

- `FileWatcherService` already watches `Blocks/` **recursively** (`kFSEventStreamCreateFlagFileEvents`, `FileWatcherService.swift:26-30`) — subfolder/layer moves are already observed. No watcher change for the personal tree. **Caveat (§9 BLOCKER-2, Brains):** the watcher root is `fileService.blocksDirectory` (`BlockChangeReconciler.swift:40`) and does NOT cover `Brains/<id>/Blocks/`.
- `BlockChangeReconciler.handleExternalChanges` (`:57-186`) is today a **half-deriver** (re-reads status/type/version from file `:116-123` but pulls layer/tag/day from `metadata(for:)` `:115`). Make it a **full deriver**: layer ← first path segment; tags ← frontmatter + body; day ← `[[YYYY-MM-DD]]`; `full_width` ← frontmatter. Then feed `IndexCoordinator.index(block:)`.
- **Perf hardening (§9 PERF-3):** the reconciler does linear scans per changed url (`:119`, `:138`) → O(M×N) per batch; and `onBlocksChanged`→`GraphStore.refresh` does an O(N) fingerprint and a **full graph rebuild** when `totalChange > max(8, N/4)`. Since hermes writes now arrive as **external** FS events (no self-write suppression), index blocks by id in a `[String: Block]` dictionary (O(1) lookup → O(M+N) batch), keep the 16ms `$blocks` debounce, raise the delta/full-rebuild threshold or make `buildGraph` incremental, and cache parsed wikilinks per block keyed by content hash.
- App-driven moves are covered by `recordWrite`/`shouldIgnoreExternalChange` 1.0s grace (`:195-200`); `moveBlock` calls `recordWrite` for both ids (`BlocksStore.swift:483-484`). **The bulk migration is a separate path** and must pre-seed `recordWrite` for every new id (§9 PERF-2).

### 4.2 `MarkdownConverter.parse` is the one real parser change

Today `parse` is a flat first-colon `[String:String]` splitter (`:76-84`) — `tags: [a, b]` parses to the literal string `"[a, b]"`. The writer `FrontmatterMutator.serialize(.string)` emits values **raw, no quoting**. A tag with `:` `,` or `]` (e.g. `Direito: oportunidade`) corrupts on read-back. **Decision (§9 MAJOR, YAML round-trip):** replace the flat splitter with a real (mini-)YAML inline-list + scalar-quoting parser/serializer for **both** read and write. Add round-trip property tests for accents, commas, colons, brackets, quotes, empty lists. Normalize tag identity (lowercase + NFC) on **both** surfaces (`block_tags` lowercases at `DatabaseService.swift:306,591`; frontmatter must match to avoid `ARC`/`arc` splits).

---

## 5. Irreducible Compute That Stays (KEEP-COMPUTE)

Tasks stay structured files in their **own** tree (`Tasks/<UUID>.md|json`, `TasksStore.swift:341-360`) — app/system data, **not layered**, no layer-folder move. The existing reconcile (0.8s self-write grace, `:391`) is the files-are-truth ingest.

1. **Recurrence expansion** — `RecurrenceRule.nextDate` (`TaskItem.swift:215-286`), `occursOnDay`/`firstOccurrence` (`TaskTools.swift:186-218`). Exposed via `list_tasks_for_day`/`list_upcoming` over a derived day-index.
2. **Habit completion** — `completeHabitOccurrence` (`TasksStore+HabitCompletion.swift:36-75`): append occurrence, advance anchor, flip status at end-of-recurrence, re-arm reminders, reset linked-block checkboxes (`:57`). Destructive state, not a pure edit.
3. **Streaks** — `computeStreaks` (`TaskItem.swift:670-682`), derived, never stored.
4. **Reminder firing** — `NotificationManager` (`:140-253`); OS-bound, files can't fire.
5. **`ai_parse_task`** — NL→task (local + Haiku fallback).
6. **Semantic task dedup** — `geo_find_tasks`/`geo_resolve_task`/`geo_upsert_task` (`matching.py`).
7. **OCR/Vision capture** — `OCRService` + `LogStore.addCapture`. **OCR/screenshot NEVER creates blocks** (`ScreenshotWatcher.swift:403` only calls `addCapture`) — stated explicitly per §9 MINOR.
8. **The deriver engine** — FileWatcher→reconcile→FTS/graph/tag-map/day-map, deterministic SHA256 hashing, bm25, id management. This IS the architecture; it stays and grows the layer/day derivers.
9. **Tag color provisioning + rename** — auto default color on first sighting; rename = cross-file rewrite (name is identity).
10. **BackupService** — already files-are-truth (ditto-zip whole `Geo/`, `BackupService.swift:148`). **Must fix the non-recursive block count** (`inspect` uses non-recursive `contentsOfDirectory`, `:186`) → recursive enumerator, or nested layer folders report blockCount=0 (§9 MAJOR). Also reconcile the index-DB story (root `geo-index.db` vs `Index/blocks.sqlite`, §6.1).

---

## 6. Tool-Surface Collapse (all ~39 `geo_*` tools)

Legend: **FILE-OP** = native Read/Write/Edit/mkdir/mv/rm · **DERIVED-QUERY** = thin read cache over FileWatcher-rebuilt index (or native grep/glob) · **KEEP-COMPUTE** = genuine logic · **DROP**.

> CRITICAL CAVEAT (§9 BLOCKER, agent integration): collapsing **writes** to raw FS removes server-side `AgentAuthorization`. See §8.2 — for layer-changing/creation ops we **keep the write path through Geo.app's authorized endpoint**; raw-FS writes only for layers the agent already owns, plus a FileWatcher quarantine guard on `Voce/`.

### 6.1 Block writes → FILE-OP (with auth caveat above)

| Tool | Today | Target |
|---|---|---|
| `create_block` | `BlockTools.swift:234-302`: `.md` + sidecar + days.json | Write `.md` **directly into the layer folder in one op** (no create-then-move; original create-then-`setLayer` returns a stale id once setLayer becomes a re-keying mv, §9 MINOR) + inline `tags:` + `[[date]]`. |
| `update_block` | `:304-358` | Edit/Write the `.md`. |
| `delete_block` | `:372-394` + sidecar | `rm` the `.md` (single store). |
| `set_layer` | `:396-426`→`setLayer` SIDECAR-ONLY (`BlocksStore.swift:554-558`) | `mv` between layer folders. With UUID ids (§2.1) no re-key; otherwise rides the journaled re-key routine. Rewrite `BlocksStore.setLayer`→`moveBlock(_:toFolder:)`. |
| `set_block_tag` | `TagTools.swift:68-101` SIDECAR-ONLY | Edit frontmatter `tags:` / body `#tag` with the **name**. |
| `link_block_to_day` | `DayTools.swift:72-100`→days.json | Edit to insert `[[YYYY-MM-DD]]`. Keep `.linkToDay` auth gate (folder-based). |
| `promote_to_permanent` | `:600-627` frontmatter+sidecar | Edit frontmatter `type: permanent`, `status: evergreen` (drop sidecar). |
| `extract_permanent_from` | `:629-664` | 2 ops: Write new `.md` in `Revisao/` with backlink stub + Edit source `status: archived`. Drop as dedicated tool. Same stale-id fix as `create_block`. |
| `create_tag` | `TagTools.swift:36-66`→tags.json | DROP as membership creator (tags created by mention); color auto-provisioned. |
| `move_block`/`create_folder`/`list_folders` | `GeoAPIRouter.swift:150-170,208-222` already real dir ops | Already native — canonical primitives `set_layer` rides. |

### 6.2 Reads → DERIVED-QUERY

`search_blocks`, `list_blocks`, `get_block`, `get_block_by_title`, `list_by_type`, `list_by_status`, `find_backlinks`, `find_orphans`, `find_unresolved_links`, `list_neighbors`, `get_graph_snapshot`, `list_brains`, `get_brain_manifest`, `get_today`, `get_day`, `list_tags`.

- None write. `get_today`/`get_day` flip from days.json to indexed `block_days` (§3.4). `list_by_type`/`list_by_status` derive from frontmatter once sidecar drops. `list_tags` reads derived tag map + tags.json colors.
- Keep `search_blocks` + `get_graph_snapshot` as the explicitly-allowed perf cache (bm25/graph can't be done over flat files). The rest are optional (hermes can use native Read/Grep/Glob).
- **`get_block_by_title` ambiguity (§9 MAJOR):** once layer==folder, identical titles in different layers become legal, but `BlockGraphService.titleIndex` keeps first-id-per-title and `get_block_by_title` returns `.first`. Make `titleIndex` collision-detecting (log/flag), scan for collisions at migration, and pin identity-block fetches (profile/memory/protocol) to `Voce/` explicitly, not title-only (§8.2).

### 6.3 Tasks + AI → KEEP-COMPUTE (§5)

`create_task`, `update_task`, `delete_task`, `complete_task`, `get_task`, `list_tasks`, `add_reminder`, `record_habit_occurrence`, `list_tasks_for_day`, `list_upcoming`, `ai_parse_task`, `geo_find_tasks`/`geo_resolve_task`/`geo_upsert_task`.

### 6.4 Auth + destructive → DROP / replace

| Tool/mechanism | Target |
|---|---|
| `AgentAuthorization` (`:25-47`, metadata.layer lookup) | Input source moves from sidecar to first path segment; **policy matrix `allowsAgentWrites` (`BlockType.swift:63-70`) stays verbatim.** BUT enforcement must stay **server-side for writes** (§8.2) — folder perms alone do not enforce same-uid (§9 BLOCKER). |
| destructive prepare/commit (`GeoAPIRouter.swift:317-412`, `destructive.py`) | Loses its multi-store reason. Deletes = single `rm`. Drop `frontmatter_version`/`PendingTransactionStore`. Keep Telegram Y/N confirm as a UX gate if desired. |

**Net collapse:** ~24 write/auth/transaction tools → native FS ops + server-side folder-perm check; ~15 read tools → optional derived-query caches; ~12 task/AI/dedup tools → KEEP-COMPUTE.

---

## 7. Phased Migration Plan (shippable at every phase)

Each phase gated by a `UserDefaults` flag (mirroring `StorageMigrationService.migrateIfNeeded` `:15` / `FrontmatterStripMigrationService` `:9,18-26`). **Rollback unit = the ENTIRE `Geo/` dir** (Blocks + Tasks + days.json + tags.json + Index/), backed up atomically before each destructive phase via `BackupService`. Refuse to back up while a migration journal is open. Destructive ordering: read sidecar/days.json/tags.json/SQLite as truth **before** deleting them.

**Migration read-source hard-pin (§9 BLOCKER-2):** the live sidecar `.blocks-metadata.json` does NOT exist (only a partial May-29 `.bak` with type/status for 8 MOC blocks). Layer/tag/day live **exclusively** in `Index/blocks.sqlite`. Two dead DBs exist (`geo-index.db` = FTS-only stale; `Index/blocks.db` = 0 bytes). The migration MUST: pin reads to the app's `DatabaseService` path (`Index/blocks.sqlite`); assert `blocks` rowcount > 0 before ANY `mv`; WAL-checkpoint before reading; abort loudly otherwise. A "sidecar-first" read gets nothing and silently demotes all 25 agent + 5 review blocks to `.user`.

### Phase 0 — Derivers learn new inputs + re-inject frontmatter (NO data move, back-compat)

Pure additive; app still reads SQLite/sidecar as truth, ships immediately.

- `MarkdownConverter.parse`: real YAML inline-list + scalar quoting (read **and** write), §4.2.
- `MarkdownIndexingService.extractTags`: also read frontmatter `tags:`.
- Add `[[YYYY-MM-DD]]` extraction to the same body pass → indexed `block_days` (alongside days.json; UI still reads days.json).
- Add `BlockLayer(folderSegment:)` + `layer.folderName` + folder→layer map (ASCII slugs, first-segment). No call sites switched.
- **Re-inject ALL frontmatter (§9 MAJOR):** `FrontmatterStripMigrationService` already STRIPPED `type`/`status` into SQLite — 27/54 files have **no frontmatter at all**. Backfill `type`, `status`, `tags`, `full_width`, `id` from SQLite into every block. Round-trip-test that a stripped block recovers its SQLite type/status into frontmatter. Do the bulk write with FileWatcher paused (or `recordWrite` every touched id) + a single post-migration `rebuildIndex`, preserving byte-identical body (only frontmatter added).
- **Permanently retire `FrontmatterStripMigrationService`** from the launch sequence and guard so a restored backup can never re-trigger it (it is directly antagonistic — it would re-strip freshly inlined frontmatter).
- **Adopt stable UUID `id:` (§2.1):** generate/persist a UUID per block now, so later layer moves don't re-key. (If UUID route rejected, build the journaled re-key routine here instead.)
- **Ship.**

### Phase 1 — Layer = first folder segment (the hard, id-sensitive phase)

- Repoint `IndexCoordinator.entry(for:)` (both, `:233,257`) and `BlockChangeReconciler` (`:115`) to derive layer from `block.url` **first** segment. SQLite `layer` = path-derived cache.
- Rewrite `BlocksStore.setLayer` (`:554-558`) → `moveBlock(_:toFolder:)`. With UUID ids the move does not re-key; **stop carrying stale `metadata.layer`** across a move (or overwrite to destination) so cache and path-derived layer never disagree (§9 MAJOR).
- Rewrite `AgentAuthorization` to **destination-folder** based (deny any agent write resolving to `Voce/`/`Daily/`); keep agent default → `Revisao/`. Flip ALL layer read sites to folder-derived **in the same phase** (never half).
- **One-shot layer migration** (gated, after FrontmatterStrip retired): read each block's layer from `Index/blocks.sqlite` (hard-pinned), `mkdir` the layer folder, `mv` the `.md` in — **preserving any topic sub-path** (`MOC/Foo.md` → `Voce/MOC/Foo.md`), NOT flattening (BLOCKER-1).
  - **Re-key cascade (BLOCKER-4):** if ids are still path-based, build the complete old→new id map FIRST as a dry run, persist a **journal**, then perform `mv` + `linkedBlockId` rewrite (all `Tasks/*`) + `days.json` rewrite + capture-ref rewrite as **one resumable pass** keyed off the journal. On relaunch, detect a half-finished journal and resume/rollback. Keep `linkedBlockId` **id-based** (re-pointed via map); do NOT silently convert to title-wikilink (title resolution is non-unique, §6.2). With UUID ids, this whole step is unnecessary — the strong reason to prefer UUIDs.
- Pre-seed `recordWrite` for both old and new ids before any `mv`; run one batched `rebuildIndex` at the end, not per-file (§9 PERF-2).
- **In-app live-edit race (§9 MAJOR):** the open `BlockEditor` binds `liveBlock.id`; a layer change mid-edit re-keys it while a detached debounced save (`BlocksStore.swift:300-353`) targets the old url. Flush/await pending saves before a layer `mv`, rebind the editor to the new id atomically (or block layer change while a save is pending). Stress-test "change layer while typing".
- **Rollback:** flag off + restore the whole-`Geo/` backup; `rebuildIndex` recovers the cache. Benchmark `rebuildIndex`+`loadBlocksFromFiles` at 10×/100× corpus before relying on it (§9 PERF-6); add incremental `repairIndex` if it exceeds a few seconds.
- **Ship.**

### Phase 2 — Tags inline

- `BlocksStore.setTag` (`:542-546`) → frontmatter mutation via `mutateFrontmatter`/`FrontmatterEditor.upsert` (`:687,775`) writing the **name**. `set_block_tag` repointed.
- Drop tag→blocks reads off sidecar `tagId` (`BlockMetadataService.swift:64-66`, `BlocksStore.swift:504-505`); switch grouping/filtering (`BlocksViewModel.swift:395-397,483-485,595-596`; `DockView.swift:20,32`) to derived `block_tags` by name.
- **Commit to the 1→N multi-tag UI as a real deliverable (§9 MAJOR):** picker is single-select today (`BlockEditor.swift:507-508,913`); a block now carries N tags and appears in multiple groups. Build multi-tag picker/chips + group-by-tag with N membership (built once per blocks change, not per render).
- Shrink `tags.json` to name→color (drop UUIDs); auto-provision default color; address `TagStore` watcher lifecycle (still owns colors).
- **One-shot backfill (§9 MAJOR):** 0/54 files have frontmatter `tags:` today — this writes net-new inline data into all of them. Resolve each sidecar/SQLite `tagId` → name via tags.json, write inline `tags:` BEFORE dropping `tagId`. Case-fold canonical (lowercase + NFC) to avoid `ARC`/`arc` splits.
- **Ship.**

### Phase 3 — Day-links inline

- Build an explicit `lastPathComponent → fullRelativeId` map and assert 1:1 BEFORE use (§9 BLOCKER-3): `days.json` references blocks by **bare filename** while ids are **relative paths** — already misaligned for subfolder blocks; non-unique basenames must be hand-resolved or dropped with an audit log. Run day-link injection AFTER the layer move, keyed off post-move ids.
- `recordBlockCreation` (`DayManager.swift:27`) + `create_block` (`BlockTools.swift:283`) stop calling `addBlockToDay`; editor auto-inserts today's `[[YYYY-MM-DD]]` on create (preserve "new block joins today" UX).
- `link_block_to_day` → Edit inserting `[[date]]`. `linkBlockToDay` (`:536-540`) deleted.
- `DayStore` flips from JSON decode to FileWatcher-derive over `block_days`; keep `Day` struct + `@Published days` so Calendar/`DayRow` UI untouched. Delete `loadDays`/`persistInBackground` (`:115-139`).
- `get_today`/`get_day` → read-only derivers over `block_days`; create `Daily/YYYY-MM-DD.md` **lazily** only when queried (not on every block create, §9 PERF-5); exclude `Daily/` from the default graph/backlink surface so date-hub nodes don't swamp neighbor queries (§9 MINOR). Use `DateFormatters.dayId` for write+derive (tz/locale consistency).
- **Captures stay (§9 MINOR):** `CaptureItem.dayId` is self-contained per-record. But `days.json` also stores `captureIds` per day. When `days.json` retires, captures have no markdown body for a `[[date]]`. Decision: keep `CaptureItem.dayId` authoritative; `get_day`/`get_today` UNION block backlinks with captures-by-`dayId`. Do not let captures block the blocks migration.
- **One-shot migration** (new key, after FrontmatterStrip retired): inject `[[YYYY-MM-DD]]` into each days.json-listed block (resolved via the 1:1 map), create daily notes, back up + retire days.json.
- **Ship.**

### Phase 4 — Delete dead stores + demote coordination

- Drop `layer`/`tagId`/`dayId` from `BlockMetadata` (`BlocksStore.swift:56-117`) and as SQLite write targets; keep only path-derived `layer` + derived `block_tags`/`block_days` as cache.
- Delete sidecar read/write (`BlockMetadataService.loadMetadata/saveMetadata`, `GeoApp.swift:339-349` `.bak` dance); demote sidecar watch branch (`BlockChangeReconciler:62-95`).
- Demote `frontmatter_version` + `FrontmatterMutatorActor` (`:687-772`); reader tolerates absence.
- Inline `isFullWidth` → `full_width`; remove sidecar field.
- Delete dead DBs (`geo-index.db`, `Index/blocks.db`); document `Index/blocks.sqlite` as the sole rebuildable cache.
- **Tests (§9 MINOR — ~13 files, not ~5):** `BackupServiceTests` (recursive count + `hasTags`), `HermesMigrationFixesTests`, `BlocksStoreFrontmatterMutatorTests`, `BlockIndexSchemaTests`, `BlockGraphServiceTests`, `GeoHTTPServerTests` (the full 39-tool surface → file-ops), `BrainsTests`, `BrainGraphStoreTests`, `BlockEditOpsStressTests`, `BlocksStoreCheckboxTests`, plus new YAML round-trip + re-key journal + multi-tag UI tests.
- **Ship.** SQLite is a pure rebuildable cache; the `.md` is the whole truth.

---

## 8. How hermes Changes

### 8.1 What replaces the API

`hermes-extensions/geo-http-tools/{tools_write.py, destructive.py}` write helpers (`_create_block`/`_update_block`/`_set_layer`/`_set_block_tag`/`_link_block_to_day`/`_move_block`, lines 37-73) become native FS ops against `~/Library/Application Support/Geo/Blocks/<LayerFolder>/...` — **subject to §8.2**. The FileWatcher catches every native write and rebuilds indexes.

### 8.2 The safety boundary — KEEP WRITES SERVER-AUTHORIZED (revised from original §6)

Original plan claimed "OS perms make `Voce/` unwritable by hermes." **This is false (§9 BLOCKER):** hermes runs as a LaunchAgent under the same uid (`biel`) that owns `Blocks/`, so file-mode perms cannot distinguish Geo.app from hermes; prompt-injection or any other writer (Claude Code's `Write`/`Edit`, claude-code-lane workers) bypasses a self-policed path check.

**Decision:** layer-changing / block-creation writes go **through Geo.app's authorized HTTP endpoint** (`create_block`/`move_block`), which still runs `AgentAuthorization` server-side resolving the destination folder. The agent reads files freely (including `Voce/`) and may raw-FS-write **only** layers it already owns (`Agente/`/`Revisao/`/`Compartilhado/`). Defense-in-depth: the FileWatcher reconciler **quarantines** (moves back) any externally-created file landing under `Voce/`/`Daily/` lacking a Geo.app self-write grace marker. True raw-FS writes everywhere would require real privilege separation (separate user/role, sandbox profile) — out of scope and contradicting the current LaunchAgent model.

### 8.3 Fix the hermes tool vocabulary bug (§9 BLOCKER)

`geo_create_block`/`geo_set_layer` tell the agent `layer: 'fleeting'|'literature'|'permanent'` (`tools_write.py:340,403`) — those are **TYPE** values, not layers. Real layers are `agent|review|shared` (default `.review`, `BlockTools.swift:245,252`). Under FS ops, an agent obeying its own description and passing `layer='permanent'` would `mkdir Blocks/permanent/` junk. **Before any FS collapse:** fix descriptions to `agent|review|shared` (never `user`); validate the first path segment against `BlockLayer(folderSegment:)`, hard-reject unknown segments (no junk `mkdir`); test agent create defaults to `Revisao/`.

### 8.4 What stays / what else changes

- `geo-context` handler needs **no change** — reads bodies, strips frontmatter (`handler.py:86,278`), never touched the sidecar.
- **Read-after-write contract (§9 MAJOR):** day-membership now derives async (0.4s coalesce + reconcile). Keep `get_today` server-computed and **synchronous over the in-memory derived map**, OR have raw-FS write ops block until the FileWatcher reconcile for that path completes before returning. Pin boot-bundle profile/memory/protocol fetch to `Voce/Daily` explicitly, not title-only, so an `Agente/` block cannot shadow identity blocks.
- KEEP-COMPUTE tools stay as HTTP tools (tasks, `ai_parse_task`, dedup trio). Thin `search_blocks`/`get_graph_snapshot` cache stays. geo-mcp-subscriber push cache + RPC pooling stay (now warm file-derived state).
- **SOUL.md is now load-bearing (§9 MINOR):** encode the vault contract in SOUL.md (folder→layer map w/ ASCII slugs, write-forbidden folders, `[[YYYY-MM-DD]]` convention, frontmatter-`tags:` vs body-`#hashtag` duality) and in the FS-tool descriptions. Treat SOUL.md as a migration artifact.
- **Update CLAUDE.md (§1.2):** correct the MCP-stale framing — hermes reaches Geo via HTTP/native FS on the same Mac; the bridge is no longer the sole data contract; the 39-tool transaction model is retired.

### 8.5 `linkedBlockId` handling

Keep `linkedBlockId` **id-based**, re-pointed via the old→new map during the layer migration (or made moot by UUID ids). Do NOT silently convert to title-wikilinks — title resolution is ambiguous (§6.2).

---

## 9. Risks & Mitigations (folds in the confirmed review)

### Blockers (must resolve before any destructive step)

| # | Risk | Mitigation |
|---|---|---|
| B1 | **Layer-as-folder flattens hand-built user folders.** Live vault has `MOC/`(8), `Dias/`(6), `Semanas/`(~8) all layer=user; the original "root→.user" mass-`mv` would collapse them into `Voce/`, destroying topic structure. | Derive layer from the **FIRST** path segment only; preserve sub-nesting under each layer folder (`Voce/MOC/...`). Re-survey the real tree before writing the migration. (§3.1, Phase 1) |
| B2 | **Layer source-of-truth mis-stated.** Sidecar doesn't exist; layer lives only in `Index/blocks.sqlite`; two dead DBs on disk. "Sidecar-first" read → silently demotes all agent/review blocks to user. | Hard-pin reads to the app's `Index/blocks.sqlite`; assert rowcount>0; WAL-checkpoint first; abort loudly; delete dead DBs. (Phase 1 preamble) |
| B3 | **days.json bare filenames vs path ids** → day membership lost on migration for subfolder blocks. | Build a `lastPathComponent→fullRelativeId` 1:1 map, assert uniqueness, hand-resolve/drop ambiguous with audit log; inject day-links AFTER layer move keyed off post-move ids. (Phase 3) |
| B4 | **Re-key cascade orphans tasks/days/captures.** `moveBlock` only re-keys its own id, NOT task `linkedBlockId`/`days.blockIds`/captures; layer==folder re-keys every id. | **Prefer stable UUID `id:` in frontmatter** (eliminates the cascade). Else: dry-run old→new map → journal → resumable transactional pass rewriting tasks/days/captures; resume/rollback on crash. (§2.1, Phase 0/1) |
| B5 | **Layer enforcement becomes an honor system.** Raw-FS writes bypass server `AgentAuthorization`; same-uid perms can't gate hermes. | Keep layer-changing/creation writes through Geo.app's authorized endpoint; raw FS only for owned layers; FileWatcher quarantine on `Voce/`. (§8.2) |
| B6 | **hermes tool vocabulary bug** — `layer:'permanent'` etc. would `mkdir` junk folders under FS ops. | Fix descriptions to `agent\|review\|shared`; validate first segment, hard-reject unknown. (§8.3) |
| B7 | **Brains: an entire second vault is unaddressed.** `Brains/<id>/Blocks/` + own `index.sqlite` are outside the watched root; layer-from-path chokes on `Brains/<id>/Blocks/Foo.md`. | Scope Brains explicitly: declare brain blocks one implicit layer (deriver maps unknown roots → safe default), OR extend watcher + deriver + auth per brain vault; spell out watcher topology. (§4.1) |

### Majors

| Risk | Mitigation |
|---|---|
| **Half the vault has no frontmatter** (FrontmatterStrip already removed type/status; 27/54 files bare). Restoring a backup could re-trigger strip and destroy inlined frontmatter. | Phase 0 re-injects ALL frontmatter from SQLite; permanently retire/guard `FrontmatterStripMigrationService`; round-trip test. |
| **Title collisions** become legal once layer==folder; `titleIndex` is first-wins, `get_block_by_title` returns `.first`. | Collision-detecting `titleIndex` (log/flag); scan at migration (rename-on-migrate or keep id-based refs); pin identity-block fetch to `Voce/`. |
| **YAML round-trip lossy** — flat parser + raw serializer corrupt tags with `:`/`,`/`]`. | Real mini-YAML inline-list + scalar-quoting for read AND write; round-trip property tests; consistent lowercase+NFC on both surfaces. |
| **Reversibility weaker than claimed** — vault-only restore leaves SQLite/Tasks/UserDefaults inconsistent; mid-migration backup captures partial state. | Rollback unit = entire `Geo/` dir, atomic before each destructive phase; journaled+resumable phases; refuse backup while a journal is open. |
| **BackupService non-recursive block count** returns 0 once blocks nest in layer folders → backup looks corrupt. | Recursive enumerator in `inspect()`; document index-DB story; add nested-folder backup test. |
| **Tag colors / TagStore / multi-tag UI** under-scoped; 0/54 files have inline tags (large net-new mutation); single-select picker. | Define post-shrink tags.json schema keyed by canonical name; address TagStore lifecycle; commit multi-tag picker/chips/group-by-N as real deliverable; case-fold color keys. |
| **moveBlock carries stale `metadata.layer`** → cache vs path-derived disagree until reindex. | Stop persisting `metadata.layer` on move (derive) or overwrite to destination; reconciler asserts equality, reindex on mismatch; flip all read sites in one phase. |
| **In-app live-edit race** — layer change re-keys the OPEN block mid-edit; detached save targets old url. | Flush/await pending saves before `mv`; rebind editor to new id atomically (or block while save pending); "change layer while typing" stress test. |
| **get_today / boot staleness** — async derive vs immediate read; identity blocks shadowable by title. | Read-after-write contract (sync in-memory derive or write blocks on reconcile); pin profile/memory/protocol to `Voce/Daily`. |
| **Obsidian-Brain kit misalignment** — kit folders are domain-based, Geo's are permission-based. | Adopt files-are-truth spirit only; **drop** "drop-in kit-compatible" framing; if compatibility ever wanted, move permission to `owner:` frontmatter + domain folders. |
| **PERF-1: day-membership LIKE scan** is un-indexable full-table content scan. | Indexed `block_days(blockId, dayId)` join table from the single body pass; `SELECT ... WHERE dayId=?`. LIKE only for ad-hoc backlinks. |
| **PERF-2: bulk-mv FSEvent storm + grace miss** — mv changes id, new path has no recordWrite → whole vault treated external. | Pre-seed recordWrite for both ids of every block before mv; one batched `rebuildIndex` at end; raise watcher latency for the migration window. |
| **PERF-3: reconciler O(M×N) + full graph rebuild** on every >N/4 external batch (now common w/ hermes writes). | `[String:Block]` dict for O(1) lookup (→O(M+N)); keep 16ms debounce; raise delta/full threshold or incremental `buildGraph`; cache parsed wikilinks per content hash. |

### Minors

- **create_block stale id** after `setLayer`→re-keying mv → create directly into target folder / thread post-move id back; test id resolves immediately.
- **FrontmatterStrip body-whitespace drift** on re-inline → churns mtime, reindex storms. Migrate with watcher paused + single `rebuildIndex`; byte-identical-body round-trip test.
- **`Dias/` vs `Daily/` collision** + NFC-vs-ASCII conflation. Reconcile `Dias/` explicitly; keep NFC canonicalization on ALL path segments incl. new layer folders; extend `collapseBlockIdNFCDuplicates` to folder segments.
- **Captures day-membership** post-days.json → keep `CaptureItem.dayId` authoritative; UNION into `get_day`. State OCR never creates blocks.
- **Test blast radius ~13 files, not ~5** (incl. `GeoHTTPServerTests`, Brains tests). Budget accordingly; state default layer for in-app/template-created blocks (root → `Voce/`/`.user`).
- **Daily-note hub-node bloat / lazy creation** → create daily notes lazily on query; exclude `Daily/` from default graph/backlink surface; regression-check `get_graph_snapshot` node degree after Phase 3.
- **PERF-6: rebuildIndex rollback unmeasured at scale** → benchmark at 10×/100×; add incremental `repairIndex` if slow; run inside one transaction off the main actor.

---

## 10. Consequences

1. The `.md` file is the complete, portable, human- and agent-editable unit of truth; the vault is Obsidian-grade and survives the app.
2. SQLite, graph, FTS, tag map, day map are all rebuildable caches — corruption is recoverable by re-derivation.
3. The write API collapses from ~39 transaction tools to native FS ops + a small server-authorized boundary + KEEP-COMPUTE; the agent edits files like a human would.
4. The single residual safety boundary (agent ≠ `Voce/`) is enforced server-side (authorized endpoint + FileWatcher quarantine), not by same-uid file perms.
5. Concurrency machinery (`frontmatter_version`, `FrontmatterMutatorActor`, destructive prepare/commit) is removed as unjustified for a single-user serial app.
6. Block identity decouples from path (UUID `id:`), eliminating the re-key cascade — the most important structural decision in this ADR.

## 11. Load-Bearing Facts (verified against source)

- `relativeId` NFC-precomposes (`BlockFileService.swift:80`) → ASCII folder slugs; NFC guard must cover new layer segments.
- `loadBlocksFromFiles` re-derives only status/type/version from file (`:114-116`); layer/tag/day come from passed-in metadata → migration targets.
- `moveBlock(_:toFolder:)` re-keys own id + metadata + focusedBlockId + recordWrite both ids (`BlocksStore.swift:451-490`) — but NOT tasks/days/captures (B4).
- `MarkdownConverter.parse` flat first-colon `[String:String]` (`:76-84`) → `tags:[a,b]` is a literal string; real YAML needed (read+write).
- `MarkdownIndexingService.extractTags` scans only `document.body` (`:44`) → frontmatter `tags:` is net-new.
- `IndexCoordinator.entry(for:)` ×2 (`:233,257`) read `block.metadata.layer.rawValue` → exact repoint sites for layer-from-path.
- `AgentAuthorization.authorize` switches on `block.metadata.layer` (`:25-47,60`); `allowsAgentWrites` denies `.user` (`BlockType.swift:63-70`) → policy stays, input source moves to folder, enforcement stays server-side.
- `BlockLayer` rawValue `user/agent/review/shared` decoupled from `displayName` `Você/Agente/Revisão/Compartilhado` (`BlockType.swift:45-52`) → accented forms display-only.
- Live data: sidecar absent (only partial `.bak`); layer/tag/day in `Index/blocks.sqlite`; dead `geo-index.db` + 0-byte `Index/blocks.db`; days.json keys by bare filename; ids are relative paths; 27/54 files have no frontmatter; 0/54 have inline `tags:`; `Dias/` (d1..d6) coexists; Brains vaults outside the watched root.
