/**
 * Tool Guard Extension
 *
 * Defense-in-depth: intercepts tool calls and blocks dangerous patterns
 * before they reach the shell. Works alongside hornet-safe-bash but catches
 * commands at the pi level, before any shell is spawned.
 *
 * Ported from OpenClaw's dangerous-tools.ts + tool-policy.ts patterns.
 */

import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";
import { isToolCallEventType } from "@mariozechner/pi-coding-agent";

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
    pattern: /systemctl\s+(enable|start)\s+(?!hornet)/,
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
    pattern: />\s*\/home\/(?!hornet_agent).*\/\.ssh\/authorized_keys/,
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
  /rm\s+(-[a-zA-Z]*\s+)*\/home\/(?!hornet_agent)/,
];

export default function (pi: ExtensionAPI) {
  pi.on("tool_call", async (event, _ctx) => {
    // Guard bash/Bash tool calls
    if (isToolCallEventType("bash", event)) {
      const command = event.input.command ?? "";

      // Check deny rules
      for (const rule of BASH_DENY_RULES) {
        if (rule.pattern.test(command)) {
          if (rule.severity === "block") {
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
          console.error(
            `🛡️ TOOL-GUARD BLOCKED [sensitive-write]: Write to sensitive path\n   Command: ${command.slice(0, 200)}`,
          );
          return {
            block: true,
            reason: "🛡️ Blocked by tool-guard: Write to sensitive system path. This operation is not allowed.",
          };
        }
      }

      // Check sensitive delete paths
      for (const pattern of SENSITIVE_DELETE_PATHS) {
        if (pattern.test(command)) {
          console.error(
            `🛡️ TOOL-GUARD BLOCKED [sensitive-delete]: Delete of sensitive path\n   Command: ${command.slice(0, 200)}`,
          );
          return {
            block: true,
            reason: "🛡️ Blocked by tool-guard: Delete of sensitive system path. This operation is not allowed.",
          };
        }
      }
    }

    // Guard write tool — block writes to system paths
    if (isToolCallEventType("write", event)) {
      const filePath = (event.input as { path?: string }).path ?? "";
      if (
        filePath.startsWith("/etc/") ||
        filePath.startsWith("/root/") ||
        filePath.startsWith("/boot/") ||
        filePath.startsWith("/proc/") ||
        filePath.startsWith("/sys/") ||
        (filePath.startsWith("/home/") && !filePath.startsWith("/home/hornet_agent/"))
      ) {
        console.error(
          `🛡️ TOOL-GUARD BLOCKED [write-sensitive-path]: ${filePath}`,
        );
        return {
          block: true,
          reason: `🛡️ Blocked by tool-guard: Cannot write to ${filePath}. Only /home/hornet_agent/ is allowed.`,
        };
      }
    }

    // Guard edit tool — same path restrictions
    if (isToolCallEventType("edit", event)) {
      const filePath = (event.input as { path?: string }).path ?? "";
      if (
        filePath.startsWith("/etc/") ||
        filePath.startsWith("/root/") ||
        filePath.startsWith("/boot/") ||
        filePath.startsWith("/proc/") ||
        filePath.startsWith("/sys/") ||
        (filePath.startsWith("/home/") && !filePath.startsWith("/home/hornet_agent/"))
      ) {
        console.error(
          `🛡️ TOOL-GUARD BLOCKED [edit-sensitive-path]: ${filePath}`,
        );
        return {
          block: true,
          reason: `🛡️ Blocked by tool-guard: Cannot edit ${filePath}. Only /home/hornet_agent/ is allowed.`,
        };
      }
    }
  });

  pi.on("session_start", async (_event, ctx) => {
    ctx.ui.setStatus("tool-guard", "🛡️ Tool guard active");
  });
}
