/**
 * Tool Guard Extension
 *
 * Defense-in-depth policy and guidance layer: intercepts tool calls and blocks
 * known-dangerous patterns before they reach the shell. This is not a full
 * containment boundary by itself.
 *
 * Configuration (env vars):
 *   BAUDBOT_AGENT_USER   — agent Unix username (default: baudbot_agent)
 *   BAUDBOT_AGENT_HOME   — agent home directory (default: /home/$BAUDBOT_AGENT_USER)
 *   BAUDBOT_SOURCE_DIR   — admin-owned source repo path (default: empty/disabled)
 */

import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";
import { isToolCallEventType } from "@mariozechner/pi-coding-agent";
import { appendFileSync, existsSync } from "node:fs";

// ── Configuration ───────────────────────────────────────────────────────────
const AGENT_USER = process.env.BAUDBOT_AGENT_USER || "baudbot_agent";
const AGENT_HOME = process.env.BAUDBOT_AGENT_HOME || `/home/${AGENT_USER}`;
const BAUDBOT_SRC_DIR = process.env.BAUDBOT_SOURCE_DIR || "";

// ── Audit logging ───────────────────────────────────────────────────────────
const AUDIT_LOG_PRIMARY = "/var/log/baudbot/commands.log";
const AUDIT_LOG_FALLBACK = `${AGENT_HOME}/logs/commands.log`;
const AUDIT_LOG = existsSync(AUDIT_LOG_PRIMARY)
  ? AUDIT_LOG_PRIMARY
  : AUDIT_LOG_FALLBACK;

type RiskTier = "low" | "medium" | "high";

function auditLog(entry: {
  tool: string;
  command?: string;
  path?: string;
  blocked: boolean;
  warned?: boolean;
  rule?: string;
  tier?: RiskTier;
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
  tier: RiskTier;
  rationale: string;
  saferAlternative: string;
};

function buildSafetyReason(input: {
  tier: RiskTier;
  label: string;
  ruleId: string;
  rationale: string;
  saferAlternative: string;
  nextStep?: string;
}): string {
  const nextStep = input.nextStep || "Stop and choose a safer command. If this is truly required, ask for admin approval.";
  return [
    `🛡️ Safety interruption (${input.tier}-risk): ${input.label} [${input.ruleId}]`,
    `Why risky: ${input.rationale}`,
    `Safer option: ${input.saferAlternative}`,
    `Next step: ${nextStep}`,
  ].join("\n");
}

const BASH_DENY_RULES: DenyRule[] = [
  {
    id: "rm-rf-root",
    pattern: /rm\s+(-[a-zA-Z]*[rf][a-zA-Z]*\s+){1,2}(\/\s*$|\/\*|\/\s+)/,
    label: "Recursive delete of root filesystem",
    severity: "block",
    tier: "high",
    rationale: "This can destroy the host filesystem and permanently break the system.",
    saferAlternative: "Delete only a scoped workspace path under your own home directory.",
  },
  {
    id: "dd-block-device",
    pattern: /dd\s+.*of=\/dev\/(sd|vd|nvme|xvd|loop)/,
    label: "dd write to block device",
    severity: "block",
    tier: "high",
    rationale: "Raw writes to block devices can corrupt disks and destroy data.",
    saferAlternative: "Write to a regular file in your workspace instead.",
  },
  {
    id: "mkfs-device",
    pattern: /mkfs\b.*\/dev\//,
    label: "mkfs on block device",
    severity: "block",
    tier: "high",
    rationale: "Formatting a block device erases data and can take systems offline.",
    saferAlternative: "Use a temp file or loopback image in your workspace for tests.",
  },
  {
    id: "curl-pipe-sh",
    pattern: /(curl|wget)\s+[^\n|]*\|\s*(ba)?sh/,
    label: "Piping download to shell",
    severity: "block",
    tier: "high",
    rationale: "Executing network content directly bypasses review and can run malicious code.",
    saferAlternative: "Download, inspect, and verify scripts before execution.",
  },
  {
    id: "revshell-bash-tcp",
    pattern: /bash\s+-i\s+>(&|\|)\s*\/dev\/tcp\//,
    label: "Reverse shell (bash /dev/tcp)",
    severity: "block",
    tier: "high",
    rationale: "Reverse shells are a direct remote-control/exfiltration pattern.",
    saferAlternative: "Use approved service channels and authenticated APIs only.",
  },
  {
    id: "revshell-netcat",
    pattern: /\bnc\b.*-e\s*(\/bin\/)?(ba)?sh/,
    label: "Reverse shell (netcat)",
    severity: "block",
    tier: "high",
    rationale: "This creates an unauthorized remote command channel.",
    saferAlternative: "Use project-approved communication bridges.",
  },
  {
    id: "revshell-python",
    pattern: /python[23]?\s+-c\s+.*socket.*connect.*subprocess/s,
    label: "Reverse shell (python)",
    severity: "block",
    tier: "high",
    rationale: "Inline reverse shells enable remote command execution.",
    saferAlternative: "Use explicit scripts reviewed in source control.",
  },
  {
    id: "revshell-perl",
    pattern: /perl\s+-e\s+.*socket.*INET.*exec/si,
    label: "Reverse shell (perl)",
    severity: "block",
    tier: "high",
    rationale: "Inline reverse shells enable remote command execution.",
    saferAlternative: "Use explicit scripts reviewed in source control.",
  },
  {
    id: "crontab-modify",
    pattern: /crontab\s+-[erl]/,
    label: "Crontab modification",
    severity: "block",
    tier: "high",
    rationale: "Cron changes can create hidden persistence.",
    saferAlternative: "Use managed service configuration and admin-reviewed automation.",
  },
  {
    id: "cron-write",
    pattern: />\s*\/etc\/cron/,
    label: "Write to /etc/cron",
    severity: "block",
    tier: "high",
    rationale: "Writing cron entries can install stealthy persistence.",
    saferAlternative: "Use approved runtime scripts and deployment workflow.",
  },
  {
    id: "systemd-install",
    pattern: /systemctl\s+(enable|start)\s+(?!baudbot)/,
    label: "Installing/starting unknown systemd service",
    severity: "warn",
    tier: "medium",
    rationale: "Starting unknown services can change host behavior unexpectedly.",
    saferAlternative: "Operate only Baudbot-related units unless explicitly approved.",
  },
  {
    id: "write-auth-files",
    pattern: />\s*\/etc\/(passwd|shadow|sudoers|group)/,
    label: "Write to system auth files",
    severity: "block",
    tier: "high",
    rationale: "Auth file edits can create or escalate privileged access.",
    saferAlternative: "Do not modify system auth files from agent workflows.",
  },
  {
    id: "ssh-key-injection-other",
    pattern: new RegExp(`>\\s*\\/home\\/(?!${AGENT_USER}).*\\/\\.ssh\\/authorized_keys`),
    label: "SSH key injection to another user",
    severity: "block",
    tier: "high",
    rationale: "Injecting SSH keys grants persistent account access.",
    saferAlternative: "Only manage keys for the dedicated agent user via approved setup scripts.",
  },
  {
    id: "ssh-key-injection-root",
    pattern: />\s*\/root\/\.ssh\/authorized_keys/,
    label: "SSH key injection to root",
    severity: "block",
    tier: "high",
    rationale: "Root key injection is direct privilege escalation.",
    saferAlternative: "Never write to root SSH authorization from agent runtime.",
  },
  {
    id: "chmod-777-sensitive",
    pattern: /chmod\s+(-[a-zA-Z]*\s+)?777\s+\/(etc|home|root|var|usr)/,
    label: "chmod 777 on sensitive path",
    severity: "block",
    tier: "high",
    rationale: "World-writable sensitive paths weaken host security.",
    saferAlternative: "Use least-privilege permissions on only required files.",
  },
  {
    id: "fork-bomb",
    pattern: /:\(\)\s*\{.*\|.*&.*\}/,
    label: "Fork bomb",
    severity: "block",
    tier: "high",
    rationale: "Fork bombs can exhaust system resources and cause outage.",
    saferAlternative: "Use controlled load tests with explicit process limits.",
  },
  ...(BAUDBOT_SRC_DIR ? [
    {
      id: "chmod-baudbot-source",
      pattern: new RegExp(`chmod\\b.*${escapeRegex(BAUDBOT_SRC_DIR)}`),
      label: "chmod on baudbot source repo",
      severity: "block" as const,
      tier: "high" as const,
      rationale: "Source permissions are admin-managed; changing them weakens separation.",
      saferAlternative: "Request admin deploy changes from source instead.",
    },
    {
      id: "chown-baudbot-source",
      pattern: new RegExp(`chown\\b.*${escapeRegex(BAUDBOT_SRC_DIR)}`),
      label: "chown on baudbot source repo",
      severity: "block" as const,
      tier: "high" as const,
      rationale: "Changing source ownership breaks source/runtime trust boundaries.",
      saferAlternative: "Keep source admin-owned and deploy via approved scripts.",
    },
    {
      id: "tee-baudbot-source",
      pattern: new RegExp(`tee\\s+.*${escapeRegex(BAUDBOT_SRC_DIR)}/`),
      label: "tee write to baudbot source repo",
      severity: "block" as const,
      tier: "high" as const,
      rationale: "Direct source writes bypass release controls.",
      saferAlternative: "Edit through admin-owned workflow and redeploy.",
    },
  ] : []),
  {
    id: "chmod-runtime-security",
    pattern: /chmod\b.*\/(\.pi\/agent\/extensions\/tool-guard|runtime\/slack-bridge\/security)\./,
    label: "chmod on protected runtime security file",
    severity: "block" as const,
    tier: "high" as const,
    rationale: "Changing security file permissions can disable protections.",
    saferAlternative: "Only admins may update protected files through deploy.",
  },
  {
    id: "env-exfil-curl",
    pattern: /\benv\b.*\|\s*(curl|wget|nc)\b/,
    label: "Piping environment to network tool",
    severity: "block",
    tier: "high",
    rationale: "Environment data often contains credentials and secrets.",
    saferAlternative: "Inspect needed variables locally without transmitting them.",
  },
  {
    id: "cat-env-curl",
    pattern: /cat\s+.*\.env.*\|\s*(curl|wget|nc)\b/,
    label: "Exfiltrating .env via network",
    severity: "block",
    tier: "high",
    rationale: ".env files commonly contain API keys and secrets.",
    saferAlternative: "Never transmit .env contents; use secret managers.",
  },
  {
    id: "base64-exfil",
    pattern: /base64\s+.*\|\s*(curl|wget)\b/,
    label: "Base64-encoding data for exfiltration",
    severity: "block",
    tier: "high",
    rationale: "Base64 + network transfer is a common data exfiltration pattern.",
    saferAlternative: "Keep sensitive data local and minimized.",
  },
];

const SENSITIVE_WRITE_PATHS = [
  />\s*\/etc\//,
  />\s*\/root\//,
  />\s*\/boot\//,
  />\s*\/proc\//,
  />\s*\/sys\//,
];

const SENSITIVE_DELETE_PATHS = [
  /rm\s+(-[a-zA-Z]*\s+)*\/(etc|boot|root|usr|var|proc|sys)\b/,
  new RegExp(`rm\\s+(-[a-zA-Z]*\\s+)*\\/home\\/(?!${AGENT_USER})`),
];

const ALLOWED_WRITE_PREFIXES = [AGENT_HOME + "/"];

function isAllowedWritePath(filePath: string): boolean {
  return ALLOWED_WRITE_PREFIXES.some((p) => filePath.startsWith(p));
}

const PROTECTED_RUNTIME_FILES = [
  `${AGENT_HOME}/.pi/agent/extensions/tool-guard.ts`,
  `${AGENT_HOME}/.pi/agent/extensions/tool-guard.test.mjs`,
  `${AGENT_HOME}/runtime/slack-bridge/security.mjs`,
  `${AGENT_HOME}/runtime/slack-bridge/security.test.mjs`,
];

function isProtectedPath(filePath: string): boolean {
  if (BAUDBOT_SRC_DIR && (filePath.startsWith(BAUDBOT_SRC_DIR + "/") || filePath === BAUDBOT_SRC_DIR)) {
    return true;
  }
  for (const file of PROTECTED_RUNTIME_FILES) {
    if (filePath === file) return true;
  }
  return false;
}

export default function (pi: ExtensionAPI) {
  pi.on("tool_call", async (event, _ctx) => {
    if (isToolCallEventType("bash", event)) {
      const command = event.input.command ?? "";

      auditLog({
        tool: "bash",
        command: command.slice(0, 2000),
        blocked: false,
      });

      for (const rule of BASH_DENY_RULES) {
        if (rule.pattern.test(command)) {
          if (rule.severity === "block") {
            auditLog({
              tool: "bash",
              command: command.slice(0, 2000),
              blocked: true,
              warned: false,
              rule: rule.id,
              tier: rule.tier,
            });
            console.error(
              `🛡️ TOOL-GUARD BLOCKED [${rule.id}]: ${rule.label}\n   Command: ${command.slice(0, 200)}`,
            );
            return {
              block: true,
              reason: buildSafetyReason({
                tier: rule.tier,
                label: rule.label,
                ruleId: rule.id,
                rationale: rule.rationale,
                saferAlternative: rule.saferAlternative,
              }),
            };
          }

          auditLog({
            tool: "bash",
            command: command.slice(0, 2000),
            blocked: false,
            warned: true,
            rule: rule.id,
            tier: rule.tier,
          });
          console.warn(
            `🛡️ TOOL-GUARD CAUTION [${rule.id}] (${rule.tier}): ${rule.label}\n   Command: ${command.slice(0, 200)}\n   Why risky: ${rule.rationale}\n   Safer option: ${rule.saferAlternative}`,
          );
        }
      }

      for (const pattern of SENSITIVE_WRITE_PATHS) {
        if (pattern.test(command)) {
          auditLog({
            tool: "bash",
            command: command.slice(0, 2000),
            blocked: true,
            rule: "sensitive-write",
            tier: "high",
          });
          console.error(
            `🛡️ TOOL-GUARD BLOCKED [sensitive-write]: Write to sensitive path\n   Command: ${command.slice(0, 200)}`,
          );
          return {
            block: true,
            reason: buildSafetyReason({
              tier: "high",
              label: "Write to sensitive system path",
              ruleId: "sensitive-write",
              rationale: "Direct writes to core system paths can compromise host integrity.",
              saferAlternative: "Write only inside approved agent-owned workspace paths.",
            }),
          };
        }
      }

      for (const pattern of SENSITIVE_DELETE_PATHS) {
        if (pattern.test(command)) {
          auditLog({
            tool: "bash",
            command: command.slice(0, 2000),
            blocked: true,
            rule: "sensitive-delete",
            tier: "high",
          });
          console.error(
            `🛡️ TOOL-GUARD BLOCKED [sensitive-delete]: Delete of sensitive path\n   Command: ${command.slice(0, 200)}`,
          );
          return {
            block: true,
            reason: buildSafetyReason({
              tier: "high",
              label: "Delete of sensitive system path",
              ruleId: "sensitive-delete",
              rationale: "Deleting system directories can cause outage or data loss.",
              saferAlternative: "Delete only scoped files under your own workspace.",
            }),
          };
        }
      }
    }

    if (isToolCallEventType("write", event)) {
      const filePath = (event.input as { path?: string }).path ?? "";
      auditLog({ tool: "write", path: filePath, blocked: false });

      if (!isAllowedWritePath(filePath)) {
        auditLog({
          tool: "write",
          path: filePath,
          blocked: true,
          rule: "workspace-confinement",
          tier: "high",
        });
        console.error(`🛡️ TOOL-GUARD BLOCKED [workspace-confinement]: ${filePath}`);
        return {
          block: true,
          reason: buildSafetyReason({
            tier: "high",
            label: "Write outside agent-owned workspace",
            ruleId: "workspace-confinement",
            rationale: "Writing outside the allowed workspace violates runtime boundaries.",
            saferAlternative: `Write only under ${AGENT_HOME}/`,
          }),
        };
      }

      if (isProtectedPath(filePath)) {
        const rule = BAUDBOT_SRC_DIR && filePath.startsWith(BAUDBOT_SRC_DIR)
          ? "readonly-source"
          : "protected-runtime";
        auditLog({
          tool: "write",
          path: filePath,
          blocked: true,
          rule,
          tier: "high",
        });
        const desc = BAUDBOT_SRC_DIR && filePath.startsWith(BAUDBOT_SRC_DIR)
          ? "Source repo paths are admin-managed and read-only to the agent workflow."
          : "This runtime file is security-critical and admin-managed.";
        console.error(`🛡️ TOOL-GUARD BLOCKED [${rule}]: ${filePath}`);
        return {
          block: true,
          reason: buildSafetyReason({
            tier: "high",
            label: "Write to protected path",
            ruleId: rule,
            rationale: desc,
            saferAlternative: "Edit in approved source workflow and deploy via admin controls.",
          }),
        };
      }
    }

    if (isToolCallEventType("edit", event)) {
      const filePath = (event.input as { path?: string }).path ?? "";
      auditLog({ tool: "edit", path: filePath, blocked: false });

      if (!isAllowedWritePath(filePath)) {
        auditLog({
          tool: "edit",
          path: filePath,
          blocked: true,
          rule: "workspace-confinement",
          tier: "high",
        });
        console.error(`🛡️ TOOL-GUARD BLOCKED [workspace-confinement]: ${filePath}`);
        return {
          block: true,
          reason: buildSafetyReason({
            tier: "high",
            label: "Edit outside agent-owned workspace",
            ruleId: "workspace-confinement",
            rationale: "Editing outside the allowed workspace violates runtime boundaries.",
            saferAlternative: `Edit only under ${AGENT_HOME}/`,
          }),
        };
      }

      if (isProtectedPath(filePath)) {
        const rule = BAUDBOT_SRC_DIR && filePath.startsWith(BAUDBOT_SRC_DIR)
          ? "readonly-source"
          : "protected-runtime";
        auditLog({
          tool: "edit",
          path: filePath,
          blocked: true,
          rule,
          tier: "high",
        });
        const desc = BAUDBOT_SRC_DIR && filePath.startsWith(BAUDBOT_SRC_DIR)
          ? "Source repo paths are admin-managed and read-only to the agent workflow."
          : "This runtime file is security-critical and admin-managed.";
        console.error(`🛡️ TOOL-GUARD BLOCKED [${rule}]: ${filePath}`);
        return {
          block: true,
          reason: buildSafetyReason({
            tier: "high",
            label: "Edit to protected path",
            ruleId: rule,
            rationale: desc,
            saferAlternative: "Edit in approved source workflow and deploy via admin controls.",
          }),
        };
      }
    }
  });

  pi.on("session_start", async (_event, ctx) => {
    ctx.ui.setStatus("tool-guard", "🛡️ Tool guard active");
  });
}
