# Incident History

Past incidents: what broke, root cause, how it was fixed, and what to watch for.
Use this to recognize recurring patterns and avoid re-investigating known issues.

**DO NOT store secrets, API keys, or tokens in this file.**

<!-- Example:
## 2026-02-15 — Sentry alert: "TypeError: Cannot read properties of undefined" in modem ingest
- **Root cause**: Missing null check in webhook handler when Stripe sends empty metadata
- **Fix**: PR #142 — added defensive check + test
- **Watch for**: Similar null access errors in other webhook handlers
-->
