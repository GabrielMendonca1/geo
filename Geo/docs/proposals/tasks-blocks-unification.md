# Tasks ↔ Blocks Unification Plan

## Vision

A block with checkboxes IS a task list. A "task" is a scheduling/intent wrapper around a block (or a quick standalone item if no block). The four kinds — task, event, habit, milestone — survive as **form presets** that bias the UI and defaults, not as divergent behaviors. The underlying model is unified.

Result: no duplication between "checkboxes in a note" and "tasks linked to a note." One source of truth (the block), four ways to schedule it (the kinds), and a TaskCard that renders the actual checkboxes inline so you see the work, not a name.

---

## Problem Statement

### What's broken today

The current `TaskItem` struct is a 30-field bag with cosmetic differentiation. Real behavioral deltas across kinds:

| Kind | Unique behavior in code |
|---|---|
| `task` | None — baseline |
| `event` | None — same struct, different SF Symbol |
| `habit` | `recordHabitCompletion()`, `currentStreak`, `longestStreak`, `completionHistory` |
| `milestone` | `daysUntilMilestone` computed property |

That's it. `TaskKind` is a dropdown that pretends to be a feature.

Meanwhile, blocks already have a real todo system: markdown checkboxes (`[ ]`/`[x]`) parsed by `MarkdownBlockParser` into `EditorBlockKind.checkboxItem(checked:marker:)`, indexed by `MarkdownIndexingService` into `openTaskCount`/`completedTaskCount` per block. **The two systems do not talk to each other.** The `linkedBlockId` on a task is a display-only chip showing the block's title. Toggling a checkbox in a block has zero effect on any task. Creating a task with the same name as a checkbox creates duplicate truth.

### What this enables

- Open a task → see the actual breakdown checkboxes inline.
- Check a checkbox in a block → task progress updates.
- Habit blocks reset every occurrence (today's "Morning routine" template re-uns-checks for tomorrow).
- A "Project" block can have multiple tasks scheduled against it (Phase 1 due Mon, Phase 2 due Fri).
- Agents and humans both fill fewer fields per task — the kind preset infers most of the structure.
- The block becomes a true workspace (notes + checkboxes + linked schedules) rather than a sibling of tasks.

---

## Core Insight: Three Orthogonal Concerns

Currently entangled. Untangle them:

1. **Kind** — what the user MEANS this thing to be (task / event / habit / milestone). Drives form layout and defaults. UX layer.
2. **Block** — the actual content. Notes + checkboxes = the substance of the work.
3. **Schedule** — when this thing exists in time. Sum type, not nullable scattered fields.

Once separated, each can evolve without compromising the others. The kind dropdown becomes a UX shortcut for setting up the schedule + form defaults, not a behavior switch.

---

## Proposed Data Model

```swift
struct TaskItem {
    let id: String
    var title: String
    var blockId: String?
    var kind: TaskKind
    var schedule: Schedule
    var status: TaskStatus
    var priority: TaskPriority
    var tagIds: [String]
    var orderIndex: Int
    var quickNote: String
    let createdAt: Date
    var modifiedAt: Date

    var habitState: HabitState?
}

enum Schedule: Codable, Hashable {
    case anytime
    case dueBy(Date)
    case at(Date, duration: TimeInterval?)
    case recurring(rule: RecurrenceRule, timeOfDay: Date)
    case targeting(Date)
}

extension Schedule {
    var anchorDate: Date?
    var endDate: Date?
    var isRecurring: Bool
    var displayLabel: String
}

struct ScheduleAlerts: Codable, Hashable {
    var reminders: [ReminderOffset]
    var recurringReminders: [RecurringReminder]
    var firedReminders: [ReminderOffset]
    var smartReminder: Bool
    var snoozedUntil: Date?
}

struct HabitState: Codable, Hashable {
    var completionHistory: [Date]
    var currentStreak: Int
    var longestStreak: Int
    var resetCheckboxesOnComplete: Bool
}

enum TaskKind: String, Codable, CaseIterable, Hashable {
    case task, event, habit, milestone
}
```

### Field count: 30 → 12

The collapse comes from:

- `startTime`/`endTime`/`recurrence`/`timeOfDay` → `Schedule` enum (one field, type-safe shape per kind)
- `reminders`/`recurringReminders`/`firedReminders`/`smartReminder`/`snoozedUntil` → `ScheduleAlerts` struct (group of reminder concerns)
- `completionHistory`/`currentStreak`/`longestStreak` → `HabitState?` (nil when not a habit, zero waste)
- `notes` (long-form) → moved to the linked block. `quickNote` retained as ≤200 char inline scratch for un-linked tasks.
- `parentId` (subtask hierarchy) → DROPPED. Block checkboxes ARE subtasks. (See "Hard decisions" §C below for the one edge case where we lose something.)
- `linkedBlockId` → renamed `blockId` for first-class status.
- `context` → DROPPED. Use tags, or write it in the block.

---

## Kind Presets — Exact Behavior

Each kind is a **form template + default schedule + display intent.** Picking a kind is one decision that pre-fills 8 fields and hides irrelevant ones.

### Task

- **Default schedule**: `.anytime` (or `.dueBy(today)` if quick-add detects a date)
- **Form shows**: title, optional due date, priority, link block
- **Form hides**: time of day, recurrence, end time, milestone target
- **Block treatment**: checkboxes = subtasks (persistent). 0/N progress shown.
- **Completion**: status → completed. If recurrence somehow set (rare), advances. Otherwise terminal.
- **Use case**: "Buy milk." "Submit expense report by Friday." "Finish onboarding doc."

### Event

- **Default schedule**: `.at(now, duration: 1h)` (or all-day toggle)
- **Form shows**: title, start, end (or all-day), location-as-text, optional recurrence, link block
- **Form hides**: streak settings, milestone target
- **Block treatment**: checkboxes = agenda (persistent — meeting notes are valuable history)
- **Completion**: usually passive (time passes). Manual mark-complete optional.
- **Use case**: "Standup at 10:00." "1:1 with Sara Thursday 3pm." "Quarterly planning offsite."

### Habit

- **Default schedule**: `.recurring(rule: .daily, timeOfDay: 07:00)`
- **Form shows**: title, time of day, recurrence (default daily), link block, "reset checkboxes on complete" toggle (default ON)
- **Form hides**: due date, milestone target, end date (use recurrence end instead)
- **Block treatment**: checkboxes = today's ritual. Reset on completion (see §B below for the actual mechanism).
- **Completion**: records date in `completionHistory`, advances streak, resets block checkboxes if toggle on, advances `Schedule` to next occurrence.
- **Use case**: "Stretch every morning." "Weekly review every Sunday." "Take meds twice daily."

### Milestone

- **Default schedule**: `.targeting(today + 30d)`
- **Form shows**: title, target date, link block, priority
- **Form hides**: time of day, recurrence, reminders (a milestone is a date, not a time)
- **Block treatment**: checkboxes = breakdown of major beats. % complete visible as primary signal.
- **Completion**: hit the target (manual mark or all checkboxes done). Or postpone (move target date).
- **Use case**: "Ship v2 by April 30." "Hire 3 engineers by Q3." "Run first marathon by August."

---

## The Block ↔ Task Relationship

### Cardinality: 1 block → N tasks (many-to-one)

A block can have multiple tasks pointing to it. A task points to at most one block.

**Rationale**: a "Project" block legitimately needs multiple scheduled checkpoints (kickoff event, weekly standup habit, Phase 1 deliverable task, GA milestone). One block, four tasks. Forcing 1:1 would push users into duplicating block content per phase.

### What the block contributes

- **Long-form notes** — replaces the task `notes` field entirely.
- **Checkboxes** — subtasks. Counted by `MarkdownIndexingService` (already exists). Toggled inline from TaskCard.
- **Title** — falls back as the task title if no explicit task title set (or shown as breadcrumb above task title).
- **Tags** — block tags can propagate to linked tasks (configurable per-link, default off).
- **Day association** — a block tied to a daily note (`metadata.dayId`) anchors the task to that day for filtering.

### What the task contributes

- **Schedule** — when does this happen / when's it due / when does it repeat / when's the target.
- **Status** — pending/completed for the SCHEDULE (not the block — block always lives).
- **Priority, reminders, snooze, smart reminder** — scheduling concerns.
- **Habit state** — streak tracking lives on the task, not the block (a block can have multiple habits attached, each with own streak).

### Invariant

Deleting a task does NOT delete the block. Deleting a block soft-orphans its tasks (task gets `blockId = nil` and a banner: "Linked block was deleted. Title was '<old title>'").

---

## TaskCard Rendering — Three Visual States

### State A: No block linked (standalone)

```
┌────────────────────────────────────┐
│ ○ Buy milk                Today    │
│   priority · 5m                    │
└────────────────────────────────────┘
```

Same as today's compact task card. Quick-add flow lands here by default.

### State B: Block linked, no checkboxes (notes-only block)

```
┌────────────────────────────────────┐
│ ○ Q1 Planning             Apr 18   │
│   📄 Q1 Planning Doc      ›        │
└────────────────────────────────────┘
```

Block title shown as breadcrumb. Tap block chip → opens block in editor pane.

### State C: Block linked, has checkboxes (THE INTERESTING CASE)

```
┌────────────────────────────────────┐
│ ○ Website Redesign        Apr 18   │
│   📄 Project: Website     ›        │
│   ☐ Design mockup                  │
│   ☑ Send brief                     │
│   ☐ Review feedback                │
│   ━━━━━━━━━━━━━━━━━━━  1/3 done   │
│   ⚑ high · 🔁 weekly               │
└────────────────────────────────────┘
```

- Checkboxes rendered inline (max 5 visible by default; "+N more" link expands).
- Each checkbox is interactive — tap toggles the markdown in the block (via `BlockEventRouter.toggleCheckbox`, already implemented).
- Progress bar + count below.
- Card density setting (compact/comfortable) controls whether checkboxes show inline or collapse to a "1/3 done" pill.

### Habit-specific state C variant

```
┌────────────────────────────────────┐
│ ○ Morning Routine         07:00    │
│   📄 Routine Template     ›        │
│   ☐ Stretch                        │
│   ☐ Read 10 min                    │
│   ☐ Coffee                         │
│   🔁 Daily · 🔥 12 day streak      │
└────────────────────────────────────┘
```

When completed (today), all three flip to `[x]`. At next occurrence (tomorrow), they reset to `[ ]`. See §B for the reset mechanism.

### Milestone-specific state C variant

```
┌────────────────────────────────────┐
│ ⚑ Ship v2                 Apr 30   │
│   📄 v2 Release Plan      ›        │
│   ☑ Alpha test                     │
│   ☑ Beta test                      │
│   ☐ Press release                  │
│   ━━━━━━━━━━━━━━━━━━━  2/3 done   │
│   14 days left                     │
└────────────────────────────────────┘
```

Countdown is the dominant signal. Progress matters. Time-of-day hidden.

---

## New Behaviors That Emerge

### 1. Block as project hub (BlockEditor enhancement)

Open a block in the editor → top of the pane shows linked tasks:

```
📌 Linked schedules
   • Phase 1 Delivery — task, due Apr 18
   • Weekly review — habit, every Sunday
   • Ship v2 — milestone, Apr 30
   [+ Schedule this block]
```

`TasksStore.tasksLinked(to:)` already exists and is unused in BlockEditor — wire it up.

### 2. Auto-complete suggestion (NOT auto-action)

When `block.openTaskCount` drops to 0 and at least one checkbox completed → toast: "Mark Website Redesign as done?" with Undo. Never silently complete; the task may have meaning beyond the checkboxes.

For milestones: same trigger but stronger prompt ("All beats done. Ship it?").

### 3. Habit reset semantics (the trickiest mechanic)

**Mechanism (chosen): rewrite linked block's `[x]` → `[ ]` on occurrence advance, with snapshot to history.**

When habit task completes:
1. Append `Date()` to `habitState.completionHistory`.
2. Update streak.
3. If `resetCheckboxesOnComplete` AND `blockId != nil`:
   - Snapshot checkbox state into a separate audit log (see §H below).
   - Mutate block markdown: every `- [x]` → `- [ ]` (and other markers).
   - Persist block.
4. Advance `schedule` to next occurrence date.
5. Status stays `pending` for next occurrence (unless recurrence ended).

**Why mutate the block instead of overlaying state?** Markdown checkboxes have no stable IDs. Overlaying per-instance state means tracking checkbox-by-position or content-hash, which breaks when the user edits the block. Mutating the block keeps markdown as the single truth and preserves user expectations: when they look at "Morning Routine" tomorrow morning, the checkboxes are unchecked because that's the state.

Snapshot → completion history can include "what got checked." See §H.

### 4. Inline block creation from task form

Task form has a dropdown: link existing block / **+ Create new block**. Choosing "create new" auto-creates a block with the task title, sets `blockId`, opens for inline editing in a sheet (small editor). Save closes the sheet, returns to task form with block linked.

Reverse flow: in BlockEditor, "+ Schedule" button opens task form with `blockId` pre-filled.

### 5. Smart kind detection on quick-add (NLP layer)

Quick-add bar parses input to suggest kind + schedule:

| Input | Detected kind | Detected schedule |
|---|---|---|
| `Buy milk` | task | anytime |
| `Submit report by Friday` | task | dueBy(Friday) |
| `Standup at 10am` | event | at(today 10am, 30m) |
| `Stretch every morning` | habit | recurring(.daily, 07:00) |
| `Ship v2 by April 30` | milestone | targeting(Apr 30) |
| `1:1 with Sara Thursday 3pm for 1 hour` | event | at(Thu 3pm, 1h) |
| `Pay rent on the 1st of every month` | habit | recurring(.monthly, 09:00) |

Detection rules (Swift, not LLM):
- Time tokens (`at 10am`, `3pm`) → event.
- Recurrence tokens (`every`, `daily`, `weekly`, `each`) → habit.
- Target tokens (`by <date>`, `before <date>`, `ship/launch/finish/hit ... by`) → milestone if the date is >7 days out, task if ≤7.
- Default → task with `.anytime`.

User can always override the detected kind in the form before saving. Detected values pre-fill, never lock.

### 6. Convert between kinds

In task form, changing kind reapplies that kind's defaults to **empty** fields only — never overwrites filled ones. Switching task → event with no time set adds default time; with time set, keeps it. Switching task → habit prompts: "Use current schedule as recurrence rule, or reset?"

### 7. Convert between checkbox and standalone task

Right-click a checkbox in a block → "Promote to task" → creates a new TaskItem with that checkbox text as title, links back to the block. The original checkbox stays in the block (it IS the task now, in the same way a regular linked-block task works).

Reverse: right-click a standalone task with no block → "Add to block..." → picks block, deletes task, appends `- [ ] <title>` to block. Task becomes a checkbox inside that block.

### 8. Calendar integration (events flow naturally)

Events with `.at(date, duration:)` schedules already render on calendar. With block linkage, hovering an event on the calendar shows agenda checkboxes preview. Click → opens block (not task form).

### 9. Activity log (free win)

Once habit completion snapshots and checkbox toggles are first-class, "what did I check off today" becomes a queryable surface. Future feature, but the data shape supports it from day 1.

---

## Hard Architectural Decisions

### A. Block-task cardinality: 1:N (many tasks → one block) ✓

Decided above. A "Project" block needs multiple scheduled wrappers.

**Implication for UI**: when viewing a block in the editor, may show 0 to N task chips at the top. When deleting a block, warn that N tasks will be orphaned.

### B. Habit checkbox reset: mutate block markdown ✓

Decided above. Snapshot first, then rewrite `[x]` → `[ ]`. Markdown stays the single source of truth.

**Risk**: user edits block right at midnight while habit fires reset. Mitigation: reset operations go through `BlocksStore.update()`, which uses the existing file-watching grace period (0.8s). Reset is debounced and queued behind any in-flight user edit.

**Risk**: user adds/removes checkboxes between occurrences. Behavior: snapshot captures whatever was there at completion time. Reset operates on whatever's there now. No assumption of structural stability.

### C. Drop `parentId` (subtask hierarchy) ✓ — with one carve-out

Block checkboxes ARE subtasks. The current `parentId` field (TaskItem can have a parent task) is replaced by block-checkbox structure for 95% of cases.

The remaining 5%: a subtask that needs **its own schedule** (e.g., "submit form by Tue" within "complete onboarding"). Solution: that subtask becomes its own task linked to the same block. Two task chips at the top of the block in the editor, distinct schedules. No parent-child task hierarchy needed.

Loss accepted: cannot represent a TaskItem-level subtask tree without blocks. Almost no one will hit this.

### D. Drop `notes` field, add `quickNote` (≤200 chars) ✓

Long-form notes belong in blocks. `quickNote` is for un-linked tasks where you want one-line context ("with the new packaging"). UI enforces 200 char limit. Beyond → "Convert to block?" prompt.

Migration: existing `notes` content with >0 length and no linked block → auto-create block on first read, link it, clear `notes`. Existing `notes` with `linkedBlockId` set → append to block's markdown under a `## Notes` heading, clear `notes`.

### E. Drop `context` field ✓

Use tags, or write it in the block.

### F. Schedule as a sum type, not flat fields ✓

`Schedule` enum forces type-safe shape per kind. A milestone literally cannot have `endTime` or `timeOfDay`. A habit literally must have a recurrence rule. The compiler enforces what was previously runtime-implicit.

### G. Reminders live on the task, not the schedule ✓

Reminders are user preferences ("remind me 1h before"), not intrinsic to when the thing happens. Keep them in `ScheduleAlerts` struct on TaskItem. (This is mostly the same as today, just grouped.)

### H. Habit completion snapshots — design

```swift
struct HabitOccurrence: Codable, Hashable {
    let date: Date
    let checkboxes: [CheckboxSnapshot]
}

struct CheckboxSnapshot: Codable, Hashable {
    let text: String
    let wasChecked: Bool
}

struct HabitState {
    var occurrences: [HabitOccurrence]
    var currentStreak: Int
    var longestStreak: Int
    var resetCheckboxesOnComplete: Bool

    var completionHistory: [Date] { occurrences.map(\.date) }
}
```

`occurrences` replaces the simple `[Date]` `completionHistory`. Each occurrence captures what checkboxes existed and which were checked. Enables future "habit consistency report" view (which sub-rituals slip most).

Storage cost: small. ~1 KB per occurrence even with 20 checkboxes. A daily habit for a year = ~365 KB. Acceptable.

### I. The `MarkdownIndexingService` is async — how does TaskCard show counts synchronously?

Current: `IndexCoordinator` indexes blocks, stores `openTaskCount`/`completedTaskCount` in SQLite via `DatabaseService`.

New requirement: TaskCard needs these counts at render time, ideally instant.

**Decision**: TasksViewModel preloads counts for all blocks linked from visible tasks via `DatabaseService.taskCounts(for: blockIds)` batch query. Cache in viewmodel. Invalidate on block change notification. Render uses cached values (fall back to 0/0 + "loading" if cache miss, refresh on next tick).

For inline checkbox rendering (state C), TaskCard needs the actual checkbox text/state, not just counts. Same approach: viewmodel preloads `EditorBlock` array for visible-task linked blocks, filters to `checkboxItem` cases, caches. Cost: parsing ~10 blocks at render is fine (already fast in BlockEditor).

### J. Search across linked blocks

Today: search is task title only. New: search should match task title OR linked block content (including checkbox text). Implementation: TasksViewModel filters using both `task.title` and `database.blocksMatching(query)` joined to `task.blockId`.

### K. Tags propagation

When a block is linked to a task, optionally inherit block's tags into the task's `tagIds`. Setting per-link, default OFF. Avoid surprise tag pollution; user opts in per link.

---

## Edge Cases

| Case | Behavior |
|---|---|
| Block deleted while linked | Task `blockId` set to nil. Banner on task: "Linked block was deleted ('<title>')." Allow re-link or accept and dismiss. |
| Multiple tasks link to same block | All show in BlockEditor's "Linked schedules" header. Each renders independent TaskCard with own checkbox preview (same checkboxes, different schedules). |
| Block has nested checkboxes (markdown lists) | Render nested in TaskCard (indented). Counts include all levels. |
| Block has 50+ checkboxes | TaskCard shows first 5 + "+45 more" link. Link opens block in editor. |
| User adds/removes checkboxes after task creation | Counts and inline rendering update on next viewmodel refresh. No structural assumptions broken. |
| Habit recurrence ends (end date passes) | Status stays completed after final occurrence. Block NOT reset. Banner: "Habit completed." |
| Convert event → habit | Form prompts: "Use start time as time-of-day for the habit?" Default yes. |
| Convert habit → task | `habitState` cleared. Recurrence dropped. User confirms ("Lose streak history?"). |
| All-day event | `.at(midnight, duration: 24h * 60 * 60)` with all-day flag stored in display metadata (or duration of nil = all-day, choose one). |
| Snooze a habit | Snoozes current occurrence. Next occurrence still fires on schedule. |
| Snooze a milestone | Reschedule the target date instead. |
| Standalone task with `quickNote` then user wants to add a block | "Convert to block?" — creates block from quickNote text, links, clears quickNote. |
| Block linked to task gets renamed | Task title (if explicit) stays; if task title is empty/inherited, displays new block title. |
| User checks all checkboxes on a non-habit task's linked block | Toast: "Mark task done?" — never auto-complete. |
| User checks all checkboxes on a habit's linked block (within the occurrence window) | Same toast: "Complete this occurrence?" Confirming records, advances, resets. |
| Day rollover at midnight while card is rendering | Existing `DayManager` already handles this. TasksViewModel observes day change, refreshes. |
| Migration from old data | See "Migration" §below. Backward-compatible JSON via `decodeIfPresent`. |

---

## Migration Path

### Phase 0: Schema additions (backward-compatible)

Add new fields to `TaskItem` JSON without removing old ones. Decode both:

```swift
init(from decoder: Decoder) throws {
    // existing fields...

    if let schedule = try container.decodeIfPresent(Schedule.self, forKey: .schedule) {
        self.schedule = schedule
    } else {
        self.schedule = Schedule.fromLegacyFields(
            kind: kind,
            startTime: startTime,
            endTime: endTime,
            recurrence: recurrence
        )
    }

    if let alerts = try container.decodeIfPresent(ScheduleAlerts.self, forKey: .scheduleAlerts) {
        self.scheduleAlerts = alerts
    } else {
        self.scheduleAlerts = ScheduleAlerts(
            reminders: reminders,
            recurringReminders: recurringReminders,
            firedReminders: firedReminders,
            smartReminder: smartReminder,
            snoozedUntil: snoozedUntil
        )
    }

    if let habit = try container.decodeIfPresent(HabitState.self, forKey: .habitState) {
        self.habitState = habit
    } else if kind == .habit {
        self.habitState = HabitState(
            occurrences: completionHistory.map { HabitOccurrence(date: $0, checkboxes: []) },
            currentStreak: currentStreak,
            longestStreak: longestStreak,
            resetCheckboxesOnComplete: true
        )
    } else {
        self.habitState = nil
    }

    if let blockId = try container.decodeIfPresent(String.self, forKey: .blockId) {
        self.blockId = blockId
    } else {
        self.blockId = linkedBlockId
    }

    if let qn = try container.decodeIfPresent(String.self, forKey: .quickNote) {
        self.quickNote = qn
    } else {
        self.quickNote = notes.count <= 200 ? notes : ""
    }
}
```

Encode writes both old + new for one release cycle.

### Phase 1: Notes migration

Background task on first launch after upgrade:
- For tasks with `notes.count > 200` and `blockId == nil`: create a block titled `<task title>`, body = notes, link it, clear notes.
- For tasks with `notes.count > 0` and `blockId != nil`: append `\n\n## Notes (migrated)\n\n<notes>` to block, clear notes.
- Tasks with `notes.count <= 200` and no block: copy to `quickNote`, clear `notes`.

### Phase 2: UI cutover

- New `TaskFormView` per kind (4 small forms; shared header/footer components).
- New TaskCard with inline checkbox rendering (states A/B/C).
- BlockEditor "Linked schedules" header.

### Phase 3: Drop legacy fields

After 2-3 release cycles of dual-write, stop encoding old fields. Keep decode-fallback for one more cycle. Then drop entirely.

---

## Implementation Phases (ordered)

### Phase 1 — Foundation (data model, no UI changes)

1. Add `Schedule` enum + Codable conformance.
2. Add `ScheduleAlerts` struct.
3. Add `HabitState` struct + `HabitOccurrence`/`CheckboxSnapshot`.
4. Add new fields to `TaskItem` with dual decode/encode.
5. Add `Schedule.fromLegacyFields(...)` factory.
6. Unit tests: decode old JSON → new fields populated correctly. Round-trip tests.
7. Update `TasksStore.create/update` to write both shapes.

**Exit criteria**: existing app runs unchanged. New fields populated under the hood. Old data round-trips.

### Phase 2 — Block-task wiring

1. Rename `linkedBlockId` → `blockId` in code (keep JSON dual-key during transition).
2. `TasksViewModel.preloadBlockChildren(for tasks: [TaskItem])` — batch loads checkbox state for visible tasks.
3. Cache invalidation on block-change notifications.
4. New helper: `BlocksStore.checkboxes(in blockId:)` returning `[(text: String, checked: Bool, lineRange: Range<Int>)]`.
5. Helper: `BlocksStore.toggleCheckbox(in blockId:, at lineRange:)` — already exists in `BlockEventRouter`, expose via store API.

**Exit criteria**: viewmodel can answer "for this task, what are the linked block's checkboxes?" in O(1) after warmup.

### Phase 3 — TaskCard rendering update

1. New `TaskCardLinkedBlockSection` view — renders chip + inline checkboxes + progress bar.
2. Density setting: compact (pill only) vs comfortable (inline checkboxes).
3. Hook tap on checkbox → `BlocksStore.toggleCheckbox`. Optimistic UI update.
4. "+N more" link → opens block in editor pane.
5. Update `TaskLane`'s `Equatable` conformance to include cached checkbox state version.

**Exit criteria**: TaskCard renders states A/B/C visually. Tapping checkboxes updates block file. Visual QA against the mockups in this doc.

### Phase 4 — Form refactor (kind presets)

1. Split `TaskFormView` into `TaskKindForm.task / .event / .habit / .milestone` (4 views).
2. Shared `TaskFormHeader` (title, kind picker), `TaskFormFooter` (save/cancel).
3. Each kind form shows only its relevant fields (per the table above).
4. Kind switcher in form header — applies that kind's defaults to empty fields, prompts on conflicts.
5. Inline "+ Create block" flow.

**Exit criteria**: each kind has its own focused form. Kind switching reapplies defaults. Block-create-inline works end-to-end.

### Phase 5 — Habit reset mechanism

1. `TasksStore.completeHabit(_ task: TaskItem)`:
   - Records occurrence (date + checkbox snapshot).
   - Updates streak.
   - If `resetCheckboxesOnComplete && blockId != nil`: rewrites markdown `[x]` → `[ ]` via `BlocksStore.update()`.
   - Advances schedule.
2. Conflict guard: queue reset behind in-flight block edits via existing file-watching grace period.
3. Snapshot storage in `HabitState.occurrences`.
4. Tests: complete habit → block rewritten → next occurrence date set → snapshot persisted.

**Exit criteria**: completing a habit resets its block's checkboxes. Snapshots captured. No race conditions with user editing the block during reset.

### Phase 6 — BlockEditor integration

1. "Linked schedules" header at top of BlockEditor.
2. Reads `TasksStore.tasksLinked(to: blockId)`.
3. Each chip shows kind icon + title + schedule label. Click → opens task form.
4. "+ Schedule" button → opens task form pre-filled with `blockId`.

**Exit criteria**: opening a block shows its scheduled wrappers. Can create new tasks from the block context.

### Phase 7 — Auto-complete suggestions

1. Listen for `block.openTaskCount` transitions (N → 0) where N > 0.
2. For each task linked to that block: emit toast "Mark <task title> as done?" with Undo.
3. Special-case milestones: stronger prompt, primary CTA "Ship it."

**Exit criteria**: completing all checkboxes on a linked block triggers the toast. Dismissing or ignoring the toast does nothing.

### Phase 8 — Smart kind detection (NLP)

1. New `QuickAddParser` — pure Swift, no LLM. Regex-based.
2. Detects kind, date, time, recurrence from natural input.
3. Pre-fills task form with detected values; user confirms in form before save.
4. Tests: 50+ phrase fixtures with expected parse output.

**Exit criteria**: typing "Stretch every morning" in quick-add and pressing Enter creates a habit at 07:00 daily. Same for the other detection patterns.

### Phase 9 — Notes migration + drop legacy

1. Migration script (see Phase 1 above): notes → block or quickNote.
2. Stop writing legacy fields in encoder.
3. Two release cycles of decode-fallback only.
4. Drop legacy fields entirely.

---

## Open Questions

1. **Inline checkbox interaction polish**: should tapping a checkbox in TaskCard show a brief animation? Today's TaskCard checkbox uses a spring animation. Match that?

2. **Card height bound**: with up to 5 checkboxes inline, cards can get tall. Should we cap at 3 visible by default? Make it a per-user preference?

3. **Quick-add inline-block trigger**: should typing `Buy milk: + bread, + eggs` in quick-add auto-create a task with a 2-checkbox block? Or keep quick-add scoped to standalone tasks and require the form for block creation?

4. **Habit reset of partially-checked occurrences**: if user completes a habit having checked 2 of 3 boxes, do we still uncheck them? (Current decision: yes — snapshot captures partial, reset uns-checks all.) Or should partial-checks block completion?

5. **Block tag inheritance**: per-link toggle, or global setting?

6. **Milestone progress as checkbox-driven by default**: should `daysUntilMilestone` chip be replaced by a primary progress bar when a block is linked? Mock both, decide.

7. **Calendar block preview**: hover an event with linked block on calendar — show full block preview, or just checkbox progress? UI surface has limited room.

---

## Out of Scope (for this track)

- LLM-powered intent detection (Phase 8 is regex-only; LLM as a follow-up).
- Cross-block task aggregation views ("show all checkboxes due this week across all blocks").
- Recurring milestones (a milestone is by definition a single target date).
- Subtask scheduling within blocks (use a separate task linked to the same block instead).
- Block templates (nice-to-have for habits, but separate concern).
- Multi-user collaboration on shared blocks.
- iOS / mobile sync.

---

## Files Touched (estimated)

### New files

- `Features/Tasks/Domain/Schedule.swift`
- `Features/Tasks/Domain/ScheduleAlerts.swift`
- `Features/Tasks/Domain/HabitState.swift`
- `Features/Tasks/Domain/QuickAddParser.swift`
- `Features/Tasks/UI/TaskCardLinkedBlockSection.swift`
- `Features/Tasks/UI/TaskKindForm/TaskFormTask.swift`
- `Features/Tasks/UI/TaskKindForm/TaskFormEvent.swift`
- `Features/Tasks/UI/TaskKindForm/TaskFormHabit.swift`
- `Features/Tasks/UI/TaskKindForm/TaskFormMilestone.swift`
- `Features/Tasks/UI/TaskFormHeader.swift`
- `Features/Blocks/UI/BlockLinkedSchedulesHeader.swift`

### Modified files

- `Features/Tasks/Domain/TaskItem.swift` — collapse fields, add new struct refs, dual decode/encode
- `Features/Tasks/Data/TasksStore.swift` — new APIs, habit completion mechanic
- `Features/Tasks/UI/TasksViewModel.swift` — checkbox preload + cache, block-change subscriptions
- `Features/Tasks/UI/TasksPane.swift` — passes new state into TaskCard
- `Features/Tasks/UI/TaskFormView.swift` — becomes a router to per-kind forms
- `Features/Blocks/Data/BlocksStore.swift` — expose checkbox query/toggle APIs
- `Features/Blocks/UI/BlockEditor.swift` — add linked-schedules header
- `Shared/DesignSystem/Markdown/MarkdownIndexingService.swift` — emit change notifications on count delta
- `Services/Migration/StorageMigrationService.swift` — notes → block migration

### Deleted (after Phase 9)

- Legacy `notes`, `linkedBlockId`, `parentId`, `context`, `startTime`, `endTime`, `recurrence`, `reminders`, `recurringReminders`, `firedReminders`, `smartReminder`, `snoozedUntil`, `completionHistory`, `currentStreak`, `longestStreak` fields on `TaskItem`.

---

## Success Criteria

- TaskItem field count drops 30 → 12 (with sum types absorbing the rest type-safely).
- A task linked to a block with 3 checkboxes renders those checkboxes inline in its card.
- Tapping a checkbox in a TaskCard updates the block's markdown file.
- Completing a habit resets its linked block's checkboxes and snapshots state.
- Opening a block in the editor shows a chip for each scheduled wrapper.
- Quick-add "Stretch every morning" creates a daily habit at 07:00 without opening the form.
- Form-filling for any kind requires no more than 3 user inputs (title + maybe date + maybe block) for a sensible default task.
- All existing task data migrates without loss.
- An LLM agent can call `createTask(kind: "habit", title: "Stretch")` and get a usable result.
