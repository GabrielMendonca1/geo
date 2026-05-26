# ADR-0001: Canonical Repository Shape

- Date: 2026-02-27
- Status: Accepted

## Context

The project previously relied on project metadata outside the active source root and had inconsistent artifact tracking, reducing agent reproducibility.

## Decision

Use `/Users/biel/Programming/magnum/magnum` as the canonical root for code, docs, scripts, and project metadata (`Geo.xcodeproj`).

## Consequences

1. Build/test commands run from one repository root.
2. Shared scheme and test action are committed in repo.
3. Build artifacts and user-local metadata are ignored.
4. Future automation and CI scripts can assume stable paths.
