# Subagent Packages

Subagents are packaged under `pi/subagents/<id>/`.

Each package includes:

- `subagent.json` — manifest (id, lifecycle defaults, model profile, session name)
- `SKILL.md` — prompt/persona instructions for the subagent session
- `utilities/` — optional scripts callable via the `subagent_util` tool

These packages are deployed to `~/.pi/agent/subagents/` and managed by:

- Extension tool: `subagent_manage`
- CLI: `baudbot subagents ...`
