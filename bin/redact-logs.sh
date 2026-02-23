#!/bin/bash
# Redact secrets from pi session logs.
#
# Scans .jsonl session files and replaces common secret patterns with [REDACTED].
# Run as baudbot_agent (needs read/write access to ~/.pi/agent/sessions/).
#
# Usage: ~/baudbot/bin/redact-logs.sh [--dry-run]
#
# Patterns redacted:
#   - API keys: sk-..., xoxb-..., xapp-..., ghp_..., AKIA...
#   - Bearer tokens in headers
#   - Private keys (PEM format)
#   - Generic password/secret assignments

set -euo pipefail

DRY_RUN=0
for arg in "$@"; do
  if [ "$arg" = "--dry-run" ]; then
    DRY_RUN=1
  fi
done

SESSION_DIR="${HOME}/.pi/agent/sessions"

if [ ! -d "$SESSION_DIR" ]; then
  echo "No sessions directory found at $SESSION_DIR"
  exit 0
fi

files_changed=0
files_scanned=0

while IFS= read -r -d '' logfile; do
  files_scanned=$((files_scanned + 1))

  # Quick check: does file contain anything that looks like a secret?
  if ! grep -qE '(sk-[a-zA-Z0-9]{20}|xoxb-|xapp-|ghp_|github_pat_|AKIA[A-Z0-9]{16}|Bearer[[:space:]]+[a-zA-Z0-9]|-----BEGIN)' "$logfile" 2>/dev/null; then
    continue
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    echo "WOULD REDACT: $logfile"
    files_changed=$((files_changed + 1))
    continue
  fi

  temp_file="$(mktemp "${TMPDIR:-/tmp}/redact-log.XXXXXX")"
  perl -0777 - "$logfile" > "$temp_file" <<'PERL'
my $text = do { local $/; <> };
$text =~ s/sk-[a-zA-Z0-9]{20,}/[REDACTED_API_KEY]/g;
$text =~ s/xoxb-[0-9A-Za-z-]{20,}/[REDACTED_SLACK_TOKEN]/g;
$text =~ s/xapp-[0-9A-Za-z-]{20,}/[REDACTED_SLACK_TOKEN]/g;
$text =~ s/ghp_[a-zA-Z0-9]{36}/[REDACTED_GITHUB_TOKEN]/g;
$text =~ s/github_pat_[a-zA-Z0-9_]{20,}/[REDACTED_GITHUB_TOKEN]/g;
$text =~ s/AKIA[A-Z0-9]{16}/[REDACTED_AWS_KEY]/g;
$text =~ s#(Bearer\s+)[A-Za-z0-9._~+/=-]+#${1}[REDACTED_BEARER]#ig;
$text =~ s/(password|secret|api_key|apikey|api-key)\s*[:=]\s*"[^"]{8,}"/$1=[REDACTED_SECRET]/ig;
$text =~ s/-----BEGIN[A-Z ]*PRIVATE KEY-----[^-]*-----END[A-Z ]*PRIVATE KEY-----/[REDACTED_PRIVATE_KEY]/g;
print $text;
PERL
  if ! cmp -s "$logfile" "$temp_file"; then
    mv "$temp_file" "$logfile"
    files_changed=$((files_changed + 1))
    echo "  ✓ Redacted: $logfile"
  else
    rm -f "$temp_file"
  fi

done < <(find "$SESSION_DIR" -name '*.jsonl' -print0 2>/dev/null)

echo ""
echo "Log redaction complete"
echo "  Files scanned: $files_scanned"
echo "  Files redacted: $files_changed"

if [ "$DRY_RUN" -eq 1 ] && [ "$files_changed" -gt 0 ]; then
  echo ""
  echo "  (dry run — no files were modified)"
fi
