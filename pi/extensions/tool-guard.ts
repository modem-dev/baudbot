/**
 * Tool Guard Extension
 *
 * Defense-in-depth: intercepts tool calls and blocks dangerous patterns
 * before they reach the shell. Works alongside baudbot-safe-bash but catches
 * commands at the pi level, before any shell is spawned.
 *
 * Configuration (env vars):
 *   BAUDBOT_AGENT_USER   — agent Unix username (default: baudbot_agent)
 *   BAUDBOT_AGENT_HOME   — agent home directory (default: /home/$BAUDBOT_AGENT_USER)
 *   BAUDBOT_SOURCE_DIR   — admin-owned source repo path (default: empty/disabled)
 */

import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";
import { isToolCallEventType } from "@mariozechner/pi-coding-agent";
import { appendFileSync } from "node:fs";

// ── Configuration ───────────────────────────────────────────────────────────
// All paths are configurable via env vars so Baudbot can be deployed for any user.
// Defaults match the standard setup (baudbot_agent user, source in admin home).
import { existsSync } from "node:fs";

const AGENT_USER = process.env.BAUDBOT_AGENT_USER || "baudbot_agent";
const AGENT_HOME = process.env.BAUDBOT_AGENT_HOME || `/home/${AGENT_USER}`;
const BAUDBOT_SRC_DIR = process.env.BAUDBOT_SOURCE_DIR || "";

// ── Audit logging ───────────────────────────────────────────────────────────
// Append-only log of every tool call for forensic analysis.
// Preferred: /var/log/baudbot/commands.log (root-owned, chattr +a for tamper-proof)
// Fallback: ~/logs/commands.log (agent-owned, not append-only but still useful)
const AUDIT_LOG_PRIMARY = "/var/log/baudbot/commands.log";
const AUDIT_LOG_FALLBACK = `${AGENT_HOME}/logs/commands.log`;
const AUDIT_LOG = existsSync(AUDIT_LOG_PRIMARY)
  ? AUDIT_LOG_PRIMARY
  : AUDIT_LOG_FALLBACK;

function auditLog(entry: {
  tool: string;
  command?: string;
  path?: string;
  blocked: boolean;
  rule?: string;
}) {
  try {
    const line = JSON.stringify({ ts: new Date().toISOString(), ...entry });
    appendFileSync(AUDIT_LOG, line + "\n");
  } catch {
    // Don't let logging failures break tool execution
  }
}

function escapeRegex(s: string): string {
  return s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

type DenyRule = {
  id: string;
  pattern: RegExp;
  label: string;
  severity: "block" | "warn";
};

const BASH_DENY_RULES: DenyRule[] = [
  // ── Destructive ──────────────────────────────────────────────────────
  {
    id: "rm-rf-root",
    pattern: /rm\s+(-[a-zA-Z]*[rf][a-zA-Z]*\s+){1,2}(\/\s*$|\/\*|\/\s+)/,
    label: "Recursive delete of root filesystem",
    severity: "block",
  },
  {
    id: "dd-block-device",
    pattern: /dd\s+.*of=\/dev\/(sd|vd|nvme|xvd|loop)/,
    label: "dd write to block device",
    severity: "block",
  },
  {
    id: "mkfs-device",
    pattern: /mkfs\b.*\/dev\//,
    label: "mkfs on block device",
    severity: "block",
  },

  // ── Remote code execution ────────────────────────────────────────────
  {
    id: "curl-pipe-sh",
    pattern: /(curl|wget)\s+[^\n|]*\|\s*(ba)?sh/,
    label: "Piping download to shell",
    severity: "block",
  },

  // ── Reverse shells ───────────────────────────────────────────────────
  {
    id: "revshell-bash-tcp",
    pattern: /bash\s+-i\s+>(&|\|)\s*\/dev\/tcp\//,
    label: "Reverse shell (bash /dev/tcp)",
    severity: "block",
  },
  {
    id: "revshell-netcat",
    pattern: /\bnc\b.*-e\s*(\/bin\/)?(ba)?sh/,
    label: "Reverse shell (netcat)",
    severity: "block",
  },
  {
    id: "revshell-python",
    pattern: /python[23]?\s+-c\s+.*socket.*connect.*subprocess/s,
    label: "Reverse shell (python)",
    severity: "block",
  },
  {
    id: "revshell-perl",
    pattern: /perl\s+-e\s+.*socket.*INET.*exec/si,
    label: "Reverse shell (perl)",
    severity: "block",
  },

  // ── Persistence ──────────────────────────────────────────────────────
  {
    id: "crontab-modify",
    pattern: /crontab\s+-[erl]/,
    label: "Crontab modification",
    severity: "block",
  },
  {
    id: "cron-write",
    pattern: />\s*\/etc\/cron/,
    label: "Write to /etc/cron",
    severity: "block",
  },
  {
    id: "systemd-install",
    pattern: /systemctl\s+(enable|start)\s+(?!baudbot)/,
    label: "Installing/starting unknown systemd service",
    severity: "warn",
  },

  // ── Privilege escalation / system file writes ────────────────────────
  {
    id: "write-auth-files",
    pattern: />\s*\/etc\/(passwd|shadow|sudoers|group)/,
    label: "Write to system auth files",
    severity: "block",
  },
  {
    id: "ssh-key-injection-other",
    pattern: new RegExp(`>\\s*\\/home\\/(?!${AGENT_USER}).*\\/\\.ssh\\/authorized_keys`),
    label: "SSH key injection to another user",
    severity: "block",
  },
  {
    id: "ssh-key-injection-root",
    pattern: />\s*\/root\/\.ssh\/authorized_keys/,
    label: "SSH key injection to root",
    severity: "block",
  },
  {
    id: "chmod-777-sensitive",
    pattern: /chmod\s+(-[a-zA-Z]*\s+)?777\s+\/(etc|home|root|var|usr)/,
    label: "chmod 777 on sensitive path",
    severity: "block",
  },

  // ── Fork bomb ────────────────────────────────────────────────────────
  {
    id: "fork-bomb",
    pattern: /:\(\)\s*\{.*\|.*&.*\}/,
    label: "Fork bomb",
    severity: "block",
  },

  // ── Source repo protection ─────────────────────────────────────────────
  // Block chmod/chown on the baudbot source repo (admin-owned)
  // Only active when BAUDBOT_SOURCE_DIR is configured
  ...(BAUDBOT_SRC_DIR ? [
    {
      id: "chmod-baudbot-source",
      pattern: new RegExp(`chmod\\b.*${escapeRegex(BAUDBOT_SRC_DIR)}`),
      label: "chmod on baudbot source repo",
      severity: "block" as const,
    },
    {
      id: "chown-baudbot-source",
      pattern: new RegExp(`chown\\b.*${escapeRegex(BAUDBOT_SRC_DIR)}`),
      label: "chown on baudbot source repo",
      severity: "block" as const,
    },
    {
      id: "tee-baudbot-source",
      pattern: new RegExp(`tee\\s+.*${escapeRegex(BAUDBOT_SRC_DIR)}/`),
      label: "tee write to baudbot source repo",
      severity: "block" as const,
    },
  ] : []),
  // Block chmod/chown on protected runtime security files
  {
    id: "chmod-runtime-security",
    pattern: /chmod\b.*\/(\.pi\/agent\/extensions\/tool-guard|runtime\/slack-bridge\/security)\./,
    label: "chmod on protected runtime security file",
    severity: "block" as const,
  },

  // ── Credential exfiltration ──────────────────────────────────────────
  {
    id: "env-exfil-curl",
    pattern: /\benv\b.*\|\s*(curl|wget|nc)\b/,
    label: "Piping environment to network tool",
    severity: "block",
  },
  {
    id: "cat-env-curl",
    pattern: /cat\s+.*\.env.*\|\s*(curl|wget|nc)\b/,
    label: "Exfiltrating .env via network",
    severity: "block",
  },
  {
    id: "base64-exfil",
    pattern: /base64\s+.*\|\s*(curl|wget)\b/,
    label: "Base64-encoding data for exfiltration",
    severity: "block",
  },
];

// Paths that should never be written to
const SENSITIVE_WRITE_PATHS = [
  />\s*\/etc\//,
  />\s*\/root\//,
  />\s*\/boot\//,
  />\s*\/proc\//,
  />\s*\/sys\//,
];

// Paths that should never be deleted
const SENSITIVE_DELETE_PATHS = [
  /rm\s+(-[a-zA-Z]*\s+)*\/(etc|boot|root|usr|var|proc|sys)\b/,
  new RegExp(`rm\\s+(-[a-zA-Z]*\\s+)*\\/home\\/(?!${AGENT_USER})`),
];

// ── Workspace confinement ───────────────────────────────────────────────────
// ALLOW LIST: write/edit tools are confined to these prefixes.
// Everything else is blocked. This replaces the old deny-list approach.
const ALLOWED_WRITE_PREFIXES = [AGENT_HOME + "/"];

function isAllowedWritePath(filePath: string): boolean {
  return ALLOWED_WRITE_PREFIXES.some((p) => filePath.startsWith(p));
}

// ── Read-only source repo ───────────────────────────────────────────────────
// ── Protected runtime paths ─────────────────────────────────────────────────
// Security-critical files deployed to the agent's runtime directories.
// These are copies from the source repo that the agent must not modify.
const PROTECTED_RUNTIME_FILES = [
  `${AGENT_HOME}/.pi/agent/extensions/tool-guard.ts`,
  `${AGENT_HOME}/.pi/agent/extensions/tool-guard.test.mjs`,
  `${AGENT_HOME}/runtime/slack-bridge/security.mjs`,
  `${AGENT_HOME}/runtime/slack-bridge/security.test.mjs`,
];

function isProtectedPath(filePath: string): boolean {
  // Entire source repo is read-only (when configured)
  if (BAUDBOT_SRC_DIR && (filePath.startsWith(BAUDBOT_SRC_DIR + "/") || filePath === BAUDBOT_SRC_DIR)) {
    return true;
  }
  // Protected runtime security files
  for (const file of PROTECTED_RUNTIME_FILES) {
    if (filePath === file) return true;
  }
  return false;
}

export default function (pi: ExtensionAPI) {
  pi.on("tool_call", async (event, _ctx) => {
    // Guard bash/Bash tool calls
    if (isToolCallEventType("bash", event)) {
      const command = event.input.command ?? "";

      // Audit log (before any deny checks, so we log blocked commands too)
      auditLog({
        tool: "bash",
        command: command.slice(0, 2000),
        blocked: false,
      });

      // Check deny rules
      for (const rule of BASH_DENY_RULES) {
        if (rule.pattern.test(command)) {
          if (rule.severity === "block") {
            auditLog({
              tool: "bash",
              command: command.slice(0, 2000),
              blocked: true,
              rule: rule.id,
            });
            console.error(
              `🛡️ TOOL-GUARD BLOCKED [${rule.id}]: ${rule.label}\n   Command: ${command.slice(0, 200)}`,
            );
            return {
              block: true,
              reason: `🛡️ Blocked by tool-guard: ${rule.label} (${rule.id}). This command pattern is not allowed.`,
            };
          }
          // Warn but allow (for severity: "warn")
          console.warn(
            `🛡️ TOOL-GUARD WARNING [${rule.id}]: ${rule.label}\n   Command: ${command.slice(0, 200)}`,
          );
        }
      }

      // Check sensitive write paths
      for (const pattern of SENSITIVE_WRITE_PATHS) {
        if (pattern.test(command)) {
          auditLog({
            tool: "bash",
            command: command.slice(0, 2000),
            blocked: true,
            rule: "sensitive-write",
          });
          console.error(
            `🛡️ TOOL-GUARD BLOCKED [sensitive-write]: Write to sensitive path\n   Command: ${command.slice(0, 200)}`,
          );
          return {
            block: true,
            reason:
              "🛡️ Blocked by tool-guard: Write to sensitive system path. This operation is not allowed.",
          };
        }
      }

      // Check sensitive delete paths
      for (const pattern of SENSITIVE_DELETE_PATHS) {
        if (pattern.test(command)) {
          auditLog({
            tool: "bash",
            command: command.slice(0, 2000),
            blocked: true,
            rule: "sensitive-delete",
          });
          console.error(
            `🛡️ TOOL-GUARD BLOCKED [sensitive-delete]: Delete of sensitive path\n   Command: ${command.slice(0, 200)}`,
          );
          return {
            block: true,
            reason:
              "🛡️ Blocked by tool-guard: Delete of sensitive system path. This operation is not allowed.",
          };
        }
      }
    }

    // Guard write tool — workspace confinement + protected baudbot files
    if (isToolCallEventType("write", event)) {
      const filePath = (event.input as { path?: string }).path ?? "";

      // Audit log
      auditLog({ tool: "write", path: filePath, blocked: false });

      // ALLOW LIST: only permit writes under baudbot_agent's home
      if (!isAllowedWritePath(filePath)) {
        auditLog({
          tool: "write",
          path: filePath,
          blocked: true,
          rule: "workspace-confinement",
        });
        console.error(
          `🛡️ TOOL-GUARD BLOCKED [workspace-confinement]: ${filePath}`,
        );
        return {
          block: true,
          reason: `🛡️ Blocked by tool-guard: Cannot write to ${filePath}. Only ${AGENT_HOME}/ is allowed.`,
        };
      }
      // Block writes to read-only source repo and protected runtime files
      if (isProtectedPath(filePath)) {
        const rule = BAUDBOT_SRC_DIR && filePath.startsWith(BAUDBOT_SRC_DIR)
          ? "readonly-source"
          : "protected-runtime";
        auditLog({
          tool: "write",
          path: filePath,
          blocked: true,
          rule,
        });
        const desc = BAUDBOT_SRC_DIR && filePath.startsWith(BAUDBOT_SRC_DIR)
          ? `${filePath} is in the read-only source repo ~/baudbot/. Edit source and run deploy.sh instead.`
          : `${filePath} is a protected security file. Only the admin can modify it via deploy.sh.`;
        console.error(`🛡️ TOOL-GUARD BLOCKED [${rule}]: ${filePath}`);
        return {
          block: true,
          reason: `🛡️ Blocked by tool-guard: ${desc}`,
        };
      }
    }

    // Guard edit tool — same workspace confinement + protected paths
    if (isToolCallEventType("edit", event)) {
      const filePath = (event.input as { path?: string }).path ?? "";

      // Audit log
      auditLog({ tool: "edit", path: filePath, blocked: false });

      // ALLOW LIST: only permit edits under baudbot_agent's home
      if (!isAllowedWritePath(filePath)) {
        auditLog({
          tool: "edit",
          path: filePath,
          blocked: true,
          rule: "workspace-confinement",
        });
        console.error(
          `🛡️ TOOL-GUARD BLOCKED [workspace-confinement]: ${filePath}`,
        );
        return {
          block: true,
          reason: `🛡️ Blocked by tool-guard: Cannot edit ${filePath}. Only ${AGENT_HOME}/ is allowed.`,
        };
      }
      // Block edits to read-only source repo and protected runtime files
      if (isProtectedPath(filePath)) {
        const rule = BAUDBOT_SRC_DIR && filePath.startsWith(BAUDBOT_SRC_DIR)
          ? "readonly-source"
          : "protected-runtime";
        auditLog({
          tool: "edit",
          path: filePath,
          blocked: true,
          rule,
        });
        const desc = BAUDBOT_SRC_DIR && filePath.startsWith(BAUDBOT_SRC_DIR)
          ? `${filePath} is in the read-only source repo ~/baudbot/. Edit source and run deploy.sh instead.`
          : `${filePath} is a protected security file. Only the admin can modify it via deploy.sh.`;
        console.error(`🛡️ TOOL-GUARD BLOCKED [${rule}]: ${filePath}`);
        return {
          block: true,
          reason: `🛡️ Blocked by tool-guard: ${desc}`,
        };
      }
    }
  });

  pi.on("session_start", async (_event, ctx) => {
    ctx.ui.setStatus("tool-guard", "🛡️ Tool guard active");
  });
}
