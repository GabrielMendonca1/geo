# Math Renderer Parity Plan

Issue #6 — scope and direction for closing the LaTeX gap with KaTeX.

## 1. Current state

`Shared/DesignSystem/Editor/MathRenderer.swift` is a ~390-line hand-rolled Unicode-substitution renderer. It maps Greek letters, operators, relations, arrows and misc symbols to Unicode, handles `\frac` (inline slash, no stacked layout), `\sqrt` (single radical, no overline bar), `\mathbb`/`\mathcal`, accents (combining marks), `\text`/`\mathbf`, and `^`/`_` with Unicode super/subscripts or baseline offset. Output is an `NSAttributedString` consumed by `InlineFormat.applySpans` (inline `$…$`) and `BlockRowView.MathBlockDisplayWrapper` (block `$$…$$`). Hard limits: **no stacked fractions**, **no real radical bar**, **no matrices/`pmatrix`/`bmatrix`**, **no `align`/`cases`**, **no integral limits stacked above/below**, **no big-operator sizing**, **no proper script positioning** beyond the Unicode subset.

## 2. Recommendation

**SwiftMath.** Pure-Swift, SPM-installable, no ObjC bridging headers, renders to a `CGContext` so it composes cleanly into AppKit views; matches Geo's existing SPM-only dep style (GRDB, swift-markdown, WhisperKit). It covers stacked fractions, radicals with vinculum, matrices, big operators with limits, and most production LaTeX users write in notes. It is materially smaller and faster than a per-span `WKWebView`, which would be catastrophic for inline math on a page with dozens of spans. iosMath works but adds an ObjC dependency for no upside over SwiftMath. KaTeX-in-WebKit and extending the Unicode renderer are both rejected (former: perf; latter: dead-end for matrices/align).

## 3. Integration steps

1. **Add SPM dep** — register `https://github.com/mgriebling/SwiftMath` in `Geo.xcodeproj` Package Dependencies (same pattern as GRDB/WhisperKit at `project.pbxproj:2541-2566`), product `SwiftMath` linked into the `Geo` target.
2. **New file `Shared/DesignSystem/Editor/MathImageRenderer.swift`** — wraps `MTMathUILabel`/`MTMathListBuilder` from SwiftMath. Exposes `render(latex:fontSize:color:) -> NSImage` (and size) by drawing the math list into a bitmap-backed `CGContext`. Cache by `(latex, fontSize, colorHex)` keyed `NSCache` to avoid re-rendering on every keystroke.
3. **Extend `MathRenderer.render`** — keep current signature; internally try SwiftMath first, fall back to the existing Unicode path on parse failure. For attributed-string consumers, wrap the rendered `NSImage` in an `NSTextAttachment` so it inlines inside `NSAttributedString` runs. This preserves `InlineFormat.swift:496` and `BlockRowView.swift:603` call sites unchanged.
4. **Block-math view upgrade** — `MathBlockDisplayWrapper` (`BlockRowView.swift:597`) switches to a thin `NSViewRepresentable` over `MTMathUILabel` for sharper display math (no rasterization), since block math gets a dedicated view anyway.
5. **Parser — no changes required.** `InlineFormat.mathRegex` and `MarkdownBlockParser` already isolate the LaTeX substring; only the renderer changes.
6. **Fallback strategy** — if `MTMathListBuilder` returns an error (unsupported macro, malformed), log via existing logger and fall back to current Unicode renderer so the span still produces something readable instead of an empty box.
7. **Color/theme** — pass `palette.editorForeground` through to SwiftMath's `textColor`; verify dark-mode contrast.

## 4. Migration risk

- **Round-trip safe** — math is stored as raw LaTeX (`block.mathContent`, `.geoMath` attr). Renderer swap does not touch persistence.
- **Inline layout shift** — attachment-based inline math has different baseline metrics than Unicode glyphs; existing notes will reflow slightly. Acceptable; not lossy.
- **Unsupported macros** — SwiftMath does not implement every LaTeX command. Fallback (step 6) catches this. Survey: scan user blocks for `\begin{align}`, `\cases`, custom macros — SwiftMath handles `align`, `matrix`, `pmatrix`, `bmatrix`, `cases`; rare user-defined `\newcommand` will fall back.
- **Tests** — `InlineFormatStressTests` BUG 12 (`testMathReplacementCorruptsLaterSpans`) depends on math-replacement producing length-1 attachment; with attachments this stays length 1, so the existing invariant holds. Re-run all `*Math*` tests to confirm.
- **Performance** — first render of a complex equation is ~1–5ms; cache makes repeats free. Inline regression risk is low vs. WebKit, which is why WebKit was rejected.

## 5. Time estimate

**1 day.** SPM registration (10 min), `MathImageRenderer` wrapper (~150 LOC, half day), block-view swap and theming (1–2 hr), tests + parity sweep on real notes (1–2 hr).

## 6. Test plan

- Unit: new `MathImageRendererTests` covering `\frac`, `\sqrt`, `pmatrix`, `bmatrix`, `align`, `\sum_{i=0}^n`, `\int_a^b`, `\cases`, unknown macro → fallback. Assert non-empty `NSImage` size and no thrown errors.
- Unit: snapshot a stable set of expressions to PNG and diff to detect rendering regressions on SwiftMath upgrades.
- Regression: full `InlineFormatStressTests` + `BlockPrefixDetectorTests` (esp. BUG 12) must stay green.
- Manual: scroll a synthetic block list of 200 inline-math spans; ensure no jank (validates cache + attachment path).
- Manual: dark-mode contrast on display math.
