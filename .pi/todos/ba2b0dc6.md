{
  "id": "ba2b0dc6",
  "title": "README: Restructure to match OpenClaw flow — pitch → install → details",
  "tags": [
    "readme"
  ],
  "status": "done",
  "created_at": "2026-02-17T05:04:46.492Z"
}

OpenClaw flow: tagline → one-paragraph pitch → install → quick start → channels/config → deeper docs.

Proposed new order:
1. Title + badges + tagline
2. Why (keep short)
3. Requirements (table, already concise)
4. Quick Start (install.sh — already 2 lines)
5. Configuration
6. **Capabilities** (NEW — agent roles + what they do)
7. **Integrations** (NEW — table)
8. How It Works (message flow diagram)
9. Architecture (detailed tree)
10. Operations
11. Tests
12. **Adding Agents** (NEW)
13. Security Stack
14. Security Details
15. License

This front-loads the "try it now" path (Why → Requirements → Install → Config), then explains what you get (Capabilities, Integrations, How It Works) for people who want to dig deeper.
