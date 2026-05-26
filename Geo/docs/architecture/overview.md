# Architecture Overview

Geo uses a feature-first structure. Every domain lives under `Features/<Domain>/` with its own `Data/`, `Domain/`, and `UI/` slices. Cross-cutting infrastructure, design tokens, platform integrations, and support utilities live under `Shared/`.

## Current Direction

1. App composition is centralized in `App`.
2. Feature boundaries are defined by repository and use-case contracts.
3. Infrastructure remains shared (storage, indexing, migrations, platform integration).
4. Each feature owns its persistence adapter, domain types, and UI surface.

## High-Level Boundaries

- `Features/*/Domain`: entities, use-case contracts, business rules.
- `Features/*/Data`: repository implementations and persistence adapters.
- `Features/*/UI`: SwiftUI/AppKit presentation and view-model glue.
- `Shared/Infrastructure`: DB, file watching, migrations, indexing.
- `Shared/DesignSystem`: visual tokens and reusable components.
- `Shared/Platform`: OS-level integrations.
- `Shared/Support`: logging, formatting, test fixtures.

## Rules

- UI must not directly touch persistence primitives.
- Domain logic should be test-first and deterministic.
- Side effects belong in repositories/services, not views.
