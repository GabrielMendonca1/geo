#!/usr/bin/env bash
set -euo pipefail

staged_swift_views=()
while IFS= read -r file; do
  staged_swift_views+=("$file")
done < <(
  git diff --name-only --cached --diff-filter=ACMR \
    | rg '^Views/.*\.swift$' \
    || true
)

if [ ${#staged_swift_views[@]} -eq 0 ]; then
  echo "Boundary check skipped (no staged Swift view files)."
  exit 0
fi

pattern='\bFileManager\b|\bUserDefaults\b|import[[:space:]]+GRDB'
violations=()

for file in "${staged_swift_views[@]}"; do
  if [ ! -f "$file" ]; then
    continue
  fi

  if matches="$(rg -n "$pattern" "$file" || true)"; then
    if [ -n "$matches" ]; then
      violations+=("$matches")
    fi
  fi
done

if [ ${#violations[@]} -gt 0 ]; then
  echo "Boundary rule violation: Swift views must not access FileManager/UserDefaults/GRDB directly."
  echo
  printf '%s\n' "${violations[@]}"
  exit 1
fi

echo "Boundary check passed."
