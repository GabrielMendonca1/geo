#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUT="$SCRIPT_DIR/geo-mcp-bridge"

swiftc -O -o "$OUT" "$SCRIPT_DIR/main.swift"

echo "Built: $OUT"
echo ""
echo "Install to Claude Code config:"
echo '  Add to ~/.claude/settings.json:'
echo '  {'
echo '    "mcpServers": {'
echo '      "geo": {'
echo "        \"command\": \"$OUT\""
echo '      }'
echo '    }'
echo '  }'
