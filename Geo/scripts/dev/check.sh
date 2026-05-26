#!/usr/bin/env bash
set -euo pipefail

./scripts/dev/build.sh
./scripts/dev/test.sh
./scripts/dev/check_boundaries.sh

tracked_changed_paths="$(
  {
    git diff --name-only --diff-filter=ACMR
    git diff --name-only --cached --diff-filter=ACMR
  } | sort -u
)"

untracked_paths="$(git ls-files --others --exclude-standard)"

if echo "$tracked_changed_paths"$'\n'"$untracked_paths" | rg -q '(^build/|\.DS_Store$|(^|/)xcuserdata/)'; then
  echo "Tracked or untracked generated artifact detected."
  echo "Changed paths:"
  echo "$tracked_changed_paths"
  echo "Untracked paths:"
  echo "$untracked_paths"
  exit 1
fi

echo "Check passed."
