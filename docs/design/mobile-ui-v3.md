# GeoMobile UI v3: Slate Design Language

## Canvas

Dark-only, forced via `.preferredColorScheme(.dark)` in RootView.

- **Canvas (bg):** Pure black `#000000` (slateCanvas)
- **Cards:** Dark grey `#1C1C1E` (slateCard), 20pt corner radius, 16pt padding, no border/shadow
- **Elevated surface:** `#2C2C2E` (slateElevated) for interactive elements

## Typography

SF Pro (system default, no monospaced). Text hierarchy:

- **Primary:** White (slateText)
- **Secondary:** White 0.55 opacity (slateTextDim)
- **Tertiary/Metadata:** White 0.38 opacity (slateTextFaint)

**Font sizes & weights:**
- Title (date header): `largeTitle` bold, white
- Body (card content): `body` regular, white
- Meta (time, type, schedule): `caption` dim, white 0.55
- Section header: `caption` dim, white 0.38

## Components

### Cards
Rounded rectangles, 20pt radius, 16pt padding, slate card background. No shadows or borders.

### Chips
Capsule shape, 1pt stroke (white 0.28), caption text (white 0.7), h-padding 10pt, v-padding 5pt. Truncate with "…" if needed.

### Week Strip
7 cells (Mon–Sun), each ~52pt height, 12pt radius.
- **Header:** 2-letter day abbreviation (caption2, dim, centered above)
- **Number:** Day of month (subheadline, white, centered)
- **Selection:** Stroke 1pt white 0.6 on selected cell; no stroke on unselected
- **Activity indicator:** 4pt dot (white 0.5) beneath day if tasks/events exist

### Section Headers
Caption text, dim opacity, e.g., "segunda, 21 jul"

## Pages

### Today
- **Top:** Large date title (pt-BR format, e.g., "24 de julho"), left-aligned, scrolls with content
- **Below title:** Week strip component; selecting a day filters agenda to that day's tasks+events
- **Sections:**
  - "Atrasadas" (only when selected date = today)
  - Agenda (tasks + calendar events merged by time, all-day first)
  - "Concluídas" (dim, at bottom, disclosure group)
- **Item card:** Metadata line (time + type), title (completed = white 0.38, no strikethrough), chips (tags below if any)
- **Gestures:** Tap checkbox to complete (haptic feedback), swipe-delete

### Chat, Agents, Settings
Same slate language; previous mono/terminal aesthetic superseded.

## Colors (Swift)

```swift
extension Color {
    static let slateCanvas = Color(red: 0, green: 0, blue: 0)
    static let slateCard = Color(red: 0x1C/255, green: 0x1C/255, blue: 0x1E/255)
    static let slateElevated = Color(red: 0x2C/255, green: 0x2C/255, blue: 0x2E/255)
    static let slateText = Color.white
    static let slateTextDim = Color.white.opacity(0.55)
    static let slateTextFaint = Color.white.opacity(0.38)
    static let slateStroke = Color.white.opacity(0.28)
}
```

## Radii (Swift)

```swift
enum SlateRadius {
    static let card: CGFloat = 20
    static let cell: CGFloat = 12
}
```

## Tab & Navigation

- **Tab bar:** Black background, icons white (selected) or white 0.4 (unselected)
- **Navigation bar:** Black background, title white
- **Tint:** White throughout
