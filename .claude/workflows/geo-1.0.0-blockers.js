export const meta = {
  name: 'geo-1.0.0-blockers',
  description: 'Fix the mechanical 1.0.0 LTS blockers in Geo: green the test suite, kill 3 crash vectors, de-hardcode hermes model IDs, write INSTALL.md. Skips feature work (auto-update, backup) and human-gated signing.',
  phases: [
    { title: 'Fix' },
  ],
}

const version = (args && args.version) || null
const bundleId = (args && args.bundleId) || null
const doModelConfig = !args || args.includeModelConfig !== false
const doDocs = !args || args.includeDocs !== false

const RESULT_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['concern', 'status', 'filesChanged', 'verification', 'notes'],
  properties: {
    concern: { type: 'string' },
    status: { type: 'string', enum: ['fixed', 'partial', 'skipped', 'finding-invalid'] },
    filesChanged: { type: 'array', items: { type: 'string' } },
    verification: { type: 'string', description: 'exact build/test command run and its result (pass/fail, counts)' },
    notes: { type: 'string', description: 'anything the human must decide, confirm, or follow up on' },
  },
}

const versionInstr = version
  ? `Also set the marketing version to "${version}" (MARKETING_VERSION in project.pbxproj for all configs, and CFBundleShortVersionString in Geo/App/Info.plist).`
  : `Do NOT change the version (no version provided). Add a note that MARKETING_VERSION is still "2.0" and needs a human decision.`

const bundleInstr = bundleId
  ? `Also set PRODUCT_BUNDLE_IDENTIFIER to "${bundleId}" (replacing com.example.mac.Geo) across all build configs in project.pbxproj, and update any matching reference in Info.plist if present.`
  : `Do NOT change the bundle identifier (none provided). Add a note that it is still the placeholder com.example.mac.Geo and must be set before notarization.`

phase('Fix')

const xcodeSuite = () => agent(
  `You are fixing the Geo macOS app test suite so it compiles and runs. Repo root: /Users/biel/ARC/Forge/Geo. Project rule: NO comments in code; surgical changes only.

VERIFY each finding still holds (line numbers may have drifted) BEFORE editing, then fix:
1. In Geo.xcodeproj/project.pbxproj the "Tests" PBXGroup has \`path = Tests\` but the files live in Geo/Tests. Change that group's path to \`Geo/Tests\` (or reparent under the Geo group) so the 26 referenced test files resolve.
2. HabitCompletionTests.swift and TaskItemSchemaTests.swift reference a nonexistent \`HabitState(...)\` type (abandoned-proposal remnant). The real API is the enum case on TaskItem: \`.habit(rule:timeOfDay:occurrences:)\` with habitOccurrences/habitCurrentStreak/habitLongestStreak (see Geo/Features/Tasks/Domain/TaskItem.swift). Rewrite the affected tests against the real API; if a test cannot be meaningfully expressed, quarantine it with a clear skip and note it.
3. Wire the orphaned Geo/Tests/BlockIndexSchemaTests.swift into the GeoTests target.
${versionInstr}
${bundleInstr}

VERIFY: run \`xcodebuild test -scheme Geo -destination 'platform=macOS'\` from the repo root (timeout up to 10 min). Iterate on compile errors until it builds. Then report whether tests compiled and the actual pass/fail counts of the run.

OUTPUT: the StructuredOutput tool matching the schema. SCOPE: only project.pbxproj, Geo/Tests/*, and Geo/App/Info.plist. Do NOT touch app feature source except the minimum needed to wire tests, and do NOT fix crash vectors or model IDs — other agents own those. Do NOT commit or push.`,
  { label: 'xcode-suite', phase: 'Fix', schema: RESULT_SCHEMA }
)

const crashVectors = () => agent(
  `You are eliminating three crash vectors in the Geo macOS app with minimal edits, keeping the build green. Repo root: /Users/biel/ARC/Forge/Geo. Project rule: NO comments; surgical changes; match surrounding style.

VERIFY each line still matches (lines may have drifted; grep for the construct) BEFORE editing, then fix:
1. Geo/Shared/Infrastructure/Database/DatabaseService.swift ~line 565: a \`fatalError(...)\` in the in-memory database fallback path kills the whole app if DB init fails twice. Degrade gracefully instead (log and continue with a non-fatal empty/read-only path consistent with how the type already reports failures). Do not change behavior on the success path.
2. Geo/Features/Blocks/UI/BlockEditorActions.swift ~line 78: a \`fatalError\` when the view model is nil. Guard it and no-op / return early instead of crashing.
3. Geo/App/Notch/NSScreen+Notch.swift ~line 5: \`NSScreen.screens[0]\` force-index crashes if screens is empty. Use \`NSScreen.screens.first\` with a safe fallback.

VERIFY: run \`xcodebuild build -scheme Geo -destination 'platform=macOS'\` and confirm BUILD SUCCEEDED.

OUTPUT: the StructuredOutput tool matching the schema. SCOPE: only those three Swift files. Do NOT touch project.pbxproj, tests, or hermes. Do NOT commit or push.`,
  { label: 'crash-vectors', phase: 'Fix', schema: RESULT_SCHEMA }
)

const hermesModels = () => agent(
  `You are de-hardcoding model IDs in the hermes daemon so a model retirement does not break it. Repo root: /Users/biel/ARC/Forge/Geo. Keep it minimal; do NOT over-engineer.

VERIFY each location still holds, then make config.yaml the single source of truth for model IDs:
- hermes/config.yaml ~lines 78-79: \`full: claude-opus-4-7\`, \`nano: claude-haiku-4-5\` (leave these as the canonical declarations).
- hermes/hooks/geo-context/handler.py ~line 34: \`HAIKU_MODEL = "claude-haiku-4-5"\` hardcoded.
- hermes/scripts/whatsapp-extractor.py ~line 32: \`HAIKU_MODEL = "claude-haiku-4-5"\` hardcoded.

Approach: have the two python files read the model id from config.yaml (or an env var) with a sane fallback default, instead of a hardcoded literal. Match the existing config-reading style in those files if one exists.

VERIFY: confirm the python files still import/parse cleanly (e.g. \`python3 -c "import ast; ast.parse(open(path).read())"\` for each). Do NOT restart the daemon or touch launchctl.

OUTPUT: the StructuredOutput tool matching the schema; in notes, state the exact config key / env var you chose so the human can confirm. SCOPE: only those three files. Do NOT commit or push.`,
  { label: 'hermes-model-config', phase: 'Fix', schema: RESULT_SCHEMA }
)

const installDocs = () => agent(
  `You are writing a concise INSTALL.md for Geo's 1.0.0 release. Repo root: /Users/biel/ARC/Forge/Geo. Create /Users/biel/ARC/Forge/Geo/INSTALL.md.

Pull facts from CLAUDE.md, Geo/README.md, Geo/App/Geo.entitlements, and Geo/App/Info.plist. Cover, briefly: building from source (xcodebuild commands), installing the hermes daemon (\`bash hermes/install.sh\`), the macOS permissions the app needs and why (Accessibility for the global hotkey/CGEventTap, Screen Recording for OCR, Input Monitoring), the Gatekeeper "unidentified developer" workaround for the currently UNSIGNED/ad-hoc build (right-click → Open), where data lives (~/Library/Application Support/Geo/ — Blocks/*.md, Tasks/*.md, tags.json, days.json) and a manual-backup tip (copy that folder). Do NOT invent a signing/notarization or auto-update story that does not exist — state plainly that the build is unsigned and there is no auto-updater yet.

OUTPUT: the StructuredOutput tool matching the schema. SCOPE: create INSTALL.md only; read-only everywhere else. Do NOT commit or push.`,
  { label: 'install-docs', phase: 'Fix', schema: RESULT_SCHEMA }
)

const sideTasks = []
if (doModelConfig) sideTasks.push(hermesModels)
if (doDocs) sideTasks.push(installDocs)
const sidePromise = parallel(sideTasks)

const xcode = await xcodeSuite()
const crash = await crashVectors()
const side = (await sidePromise).filter(Boolean)

return {
  version,
  bundleId,
  results: [xcode, crash, ...side].filter(Boolean),
}
