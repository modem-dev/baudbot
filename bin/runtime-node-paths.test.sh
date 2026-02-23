#!/bin/bash
# Guardrail: embedded Node versioned paths must not be hardcoded.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

echo "=== runtime node path drift check ==="

if command -v rg >/dev/null 2>&1; then
  matches="$(rg -n --glob '!node_modules/**' --glob '!.git/**' 'node-v[0-9]+\.[0-9]+\.[0-9]+-linux-x64' . || true)"
else
  matches="$(grep -RInE --exclude-dir=node_modules --exclude-dir=.git 'node-v[0-9]+\.[0-9]+\.[0-9]+-linux-x64' . || true)"
fi
if [ -n "$matches" ]; then
  echo "❌ Found hardcoded versioned Node paths:"
  echo "$matches" | sed 's/^/  /'
  exit 1
fi

echo "✅ No hardcoded versioned Node paths found"
