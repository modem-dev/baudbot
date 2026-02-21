#!/bin/bash
# Run ShellCheck across Baudbot shell scripts.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

if ! command -v shellcheck >/dev/null 2>&1; then
  echo "❌ shellcheck not found in PATH" >&2
  echo "Install it, then re-run: npm run lint:shell" >&2
  exit 1
fi

FILES=()
while IFS= read -r file; do
  FILES+=("$file")
done < <(
  find bin hooks -type f \
    \( -name '*.sh' -o -name 'baudbot' -o -name 'baudbot-safe-bash' -o -name 'baudbot-docker' -o -name 'pre-commit' \) \
    | sort
)

FILES+=(setup.sh start.sh install.sh bootstrap.sh)

shellcheck -s bash -S warning "${FILES[@]}"

echo "✅ ShellCheck passed (${#FILES[@]} files)"
