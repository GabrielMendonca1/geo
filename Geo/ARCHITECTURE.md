# Geo Storage Architecture

## Source of truth

- `Application Support/Geo/Blocks/*.md` — one Markdown file per block. The filename (e.g. `My-Note.md`) is the block ID.
- `Application Support/Geo/Blocks/.blocks-metadata.json` — sidecar JSON mapping `blockId -> BlockMetadata` (`dayId`, `tagId`, `isFullWidth`, `status`, `type`, `layer`).

Together, the `.md` files and the metadata sidecar are jointly authoritative. Either can be edited externally; the app must reconcile.

Metadata: SQLite is the single source of truth. The legacy `blocks.metadata.json` sidecar is renamed to `.bak` on first launch of this build for rollback safety; not written to anymore. State source count: 5 (`.md` content, SQLite index+metadata, in-memory BlocksStore.blocks, in-memory metadata cache, NSTextStorage). Next: collapse the in-memory caches into SQLite-backed observers.

## Caches (rebuildable, never authoritative)

- `Application Support/Geo/Index/blocks.sqlite` — GRDB-backed denormalized projection: `blocks`, `block_tags`, `blocks_fts` (FTS5). Powers queries by tag, type, status, day range, FTS search, backlinks. Schema is managed via `DatabaseService` migrator.
- `BlocksStore.blocks` (`@MainActor`, in-memory) — observable array bound to UI. Hydrated from SQLite on launch, falling back to a full disk scan when the index is empty.
- `BlockMetadataService.blocksMetadata` (`@MainActor`, in-memory) — hot copy of `.blocks-metadata.json`.

The SQLite file MAY be deleted at any time. After deletion, the app reconstructs it from `Blocks/*.md` + the metadata sidecar.

## Rebuild contract

Two paths populate the index from the source of truth:

1. `BlocksStore.loadBlocksFromFiles()` — full disk scan, then `IndexCoordinator.rebuildIndex(blocks:)` wipes and re-inserts. Used when SQLite returns zero entries.
2. `IndexCoordinator.repairIntegrity(fileService:metadata:)` — incremental: diffs disk against index, upserts missing rows, deletes orphan rows. Invoked once on launch from `AppDelegate.applicationDidFinishLaunching` as a non-blocking background `Task`.

`verifyIntegrity(fileService:metadataIds:)` is pure observation — it returns an `IntegrityReport { missingFromIndex, orphanedInIndex, metadataDrift }` and never mutates.

## Invariants (post-`repairIntegrity`)

- Every `Blocks/*.md` file has exactly one row in `blocks` (and corresponding `block_tags` / `blocks_fts` entries).
- Every row in `blocks` corresponds to a file currently present on disk.
- `metadataDrift` (sidecar entries for missing files) is reported but NOT auto-purged — the user may have moved/renamed a file out-of-band and the metadata is recoverable.

## Drift detection at startup

On cold launch, after migrations and `BlocksStore.reload()`, repair runs in the background. Users may see a stale view for roughly one second if drift exists. UI launch is never blocked on the repair.

## Write chokepoint: `BlocksRepository`

All block writes (create / update / delete / metadata / tag / status / checkbox toggle / sync editor flush) flow through the `BlocksRepository` protocol, implemented by `BlocksStoreRepositoryAdapter` on top of `BlocksStore`. Today the adapter is pure routing — semantics are identical to calling `BlocksStore` directly. This is the seam through which the next-round migration to SQLite-as-authoritative will flow: once the implementation switches, the dozens of callers (UI, MCP tools, Agent dispatch, migrations, editor sync flush) stay unchanged. The protocol is also where validation, ordering invariants, audit, and metrics will land.

## Out of scope

- Frontmatter is NOT used to store sidecar metadata. The `.md` file body is the content; the sidecar JSON holds metadata.
- The storage format is fixed: one `.md` per block + one shared sidecar JSON. No alternate storage modes.
