# Tech Stack: Geo

## Core Frameworks & Languages
- **Language:** Swift (v5.9+)
- **UI Frameworks:** 
    - **SwiftUI:** Primary framework for application layout, views, and modern UI interactions.
    - **AppKit:** Leveraged for advanced macOS system integration, menu bar extra management, and multi-window handling where SwiftUI remains limited.

## Architecture & State Management
- **Pattern:** Observable Pattern using `@StateObject` and `@EnvironmentObject`.
- **Global Stores:** Centralized singleton stores (e.g., `BlocksStore`, `TagStore`, `LogStore`, `SessionManager`) to maintain state across the application lifecycle.
- **Dependency Management:** Swift Package Manager (SPM) for any external integrations.

## System Integration & Services
- **OCR Engine:** Apple Vision Framework for high-performance, on-device text recognition.
- **Input Management:** Global Hotkey monitoring via `CGEventTap` and `NSEvent`.
- **Permissions:** Custom `PermissionsManager` for Accessibility and Input Monitoring.
- **Media:** `CoreGraphics` for image processing.

## Persistence & Data
- **Storage:** Markdown files as source of truth with a SQLite index via GRDB.swift for metadata, tags, and full-text search.
