/**
 * Heartbeat Extension (v2 — programmatic health checks)
 *
 * Performs health checks in pure Node.js without consuming LLM tokens.
 * Only injects a prompt to the control-agent when something is actually wrong.
 *
 * Checks performed:
 *   1. Session liveness — expected aliases exist in ~/.pi/session-control/
 *   2. Gateway bridge — HTTP POST to localhost:7890/send returns 400
 *   3. Stale worktrees — ~/workspace/worktrees/ has dirs with no matching in-progress todo
 *   4. Stuck todos — in-progress for >2 hours with no matching dev-agent session
 *   5. Unanswered Slack mentions — app_mention events in bridge log with no reply within 5 min
 *
 * Configuration (env vars):
 *   HEARTBEAT_INTERVAL_MS   — interval between heartbeats (default: 600000 = 10 min)
 *   HEARTBEAT_ENABLED        — set to "0" or "false" to disable (default: enabled)
 *   HEARTBEAT_EXPECTED_SESSIONS — comma-separated session aliases to check (default: "sentry-agent")
 *   HEARTBEAT_CHECK_UNANSWERED_MENTIONS — enabled by default, set to "0", "false", or "no" to disable
 *
 * When all checks pass, zero LLM tokens are consumed. When something fails,
 * a targeted prompt is injected describing only the failures so the control-agent
 * can take action.
 */

import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";
import { Type } from "@sinclair/typebox";
import { StringEnum } from "@mariozechner/pi-ai";
import { existsSync, readdirSync, readFileSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

const DEFAULT_INTERVAL_MS = 10 * 60 * 1000; // 10 minutes
const MIN_INTERVAL_MS = 2 * 60 * 1000; // 2 minutes
const BACKOFF_MULTIPLIER = 2;
const MAX_BACKOFF_MS = 60 * 60 * 1000; // 1 hour
const STUCK_TODO_THRESHOLD_MS = 2 * 60 * 60 * 1000; // 2 hours

const SOCKET_DIR = join(homedir(), ".pi", "session-control");
const WORKTREES_DIR = join(homedir(), "workspace", "worktrees");
const TODOS_DIR = join(homedir(), ".pi", "todos");
const BRIDGE_URL = "http://127.0.0.1:7890/send";
const BRIDGE_LOG_PRIMARY = join(homedir(), ".pi", "agent", "logs", "gateway-bridge.log");
const BRIDGE_LOG_LEGACY = join(homedir(), ".pi", "agent", "logs", "slack-bridge.log");
const SESSION_DIR = join(homedir(), ".pi", "agent", "sessions");
const UNANSWERED_MENTION_THRESHOLD_MS = 5 * 60 * 1000; // 5 minutes

type HeartbeatState = {
  enabled: boolean;
  intervalMs: number;
  lastRunAt: number | null;
  consecutiveErrors: number;
  totalRuns: number;
  lastFailures: string[];
};

type CheckResult = {
  name: string;
  ok: boolean;
  detail?: string;
};

const HEARTBEAT_STATE_ENTRY = "heartbeat-state";

function isDisabledByEnv(): boolean {
  const val = process.env.HEARTBEAT_ENABLED?.trim().toLowerCase();
  return val === "0" || val === "false" || val === "no";
}

function clampInt(value: string | undefined, min: number, max: number, fallback: number): number {
  const parsed = parseInt(value ?? "", 10);
  if (!Number.isFinite(parsed)) return fallback;
  return Math.min(max, Math.max(min, parsed));
}

function getExpectedSessions(): string[] {
  const env = process.env.HEARTBEAT_EXPECTED_SESSIONS?.trim();
  if (env) return env.split(",").map((s) => s.trim()).filter(Boolean);
  return ["sentry-agent"];
}

function isUnansweredMentionsCheckEnabled(): boolean {
  const val = process.env.HEARTBEAT_CHECK_UNANSWERED_MENTIONS?.trim().toLowerCase();
  // Default to enabled unless explicitly disabled
  return val !== "0" && val !== "false" && val !== "no";
}

function resolveBridgeLogPath(): string | null {
  if (existsSync(BRIDGE_LOG_PRIMARY)) return BRIDGE_LOG_PRIMARY;
  if (existsSync(BRIDGE_LOG_LEGACY)) return BRIDGE_LOG_LEGACY;
  return null;
}

// ── Health Check Functions ──────────────────────────────────────────────────

function checkSessions(): CheckResult[] {
  const results: CheckResult[] = [];
  const expected = getExpectedSessions();

  for (const alias of expected) {
    const aliasPath = join(SOCKET_DIR, `${alias}.alias`);
    if (!existsSync(aliasPath)) {
      results.push({
        name: `session:${alias}`,
        ok: false,
        detail: `Session "${alias}" alias not found in ${SOCKET_DIR}`,
      });
      continue;
    }

    // Check that the symlink target (.sock file) exists
    try {
      const { readlinkSync } = require("node:fs");
      const target = readlinkSync(aliasPath);
      const sockPath = join(SOCKET_DIR, target);
      if (!existsSync(sockPath)) {
        results.push({
          name: `session:${alias}`,
          ok: false,
          detail: `Session "${alias}" alias points to missing socket: ${target}`,
        });
      } else {
        results.push({ name: `session:${alias}`, ok: true });
      }
    } catch (err: unknown) {
      // readlinkSync failed — alias exists but isn't a valid symlink,
      // or we lack permissions. Report as unhealthy rather than masking.
      const msg = err instanceof Error ? err.message : String(err);
      results.push({
        name: `session:${alias}`,
        ok: false,
        detail: `Session "${alias}" alias exists but symlink unreadable: ${msg}`,
      });
    }
  }

  // Check for orphaned dev-agent sessions
  try {
    const files = readdirSync(SOCKET_DIR);
    const aliases = files.filter((f) => f.endsWith(".alias"));
    for (const alias of aliases) {
      const name = alias.replace(".alias", "");
      if (name.startsWith("dev-agent-")) {
        const hasTodo = hasMatchingTodo(name);
        if (!hasTodo) {
          results.push({
            name: `orphan:${name}`,
            ok: false,
            detail: `Dev agent session "${name}" has no matching in-progress todo — may be orphaned`,
          });
        }
      }
    }
  } catch {
    // Socket dir read failure — non-fatal
  }

  return results;
}

async function checkBridge(): Promise<CheckResult> {
  try {
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 5000);

    const response = await fetch(BRIDGE_URL, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: "{}",
      signal: controller.signal,
    });

    clearTimeout(timeout);

    if (response.status === 400) {
      return { name: "bridge", ok: true };
    }
    return {
      name: "bridge",
      ok: false,
      detail: `Gateway bridge returned HTTP ${response.status} (expected 400)`,
    };
  } catch (err: any) {
    return {
      name: "bridge",
      ok: false,
      detail: `Gateway bridge unreachable: ${err.message || err}`,
    };
  }
}

function checkWorktrees(): CheckResult[] {
  const results: CheckResult[] = [];

  if (!existsSync(WORKTREES_DIR)) return results;

  try {
    const entries = readdirSync(WORKTREES_DIR);
    for (const entry of entries) {
      const fullPath = join(WORKTREES_DIR, entry);
      try {
        if (!statSync(fullPath).isDirectory()) continue;
      } catch {
        continue;
      }

      // Check if there's a matching in-progress todo
      const hasMatch = hasMatchingInProgressTodo(entry);
      if (!hasMatch) {
        results.push({
          name: `worktree:${entry}`,
          ok: false,
          detail: `Stale worktree "${entry}" in ~/workspace/worktrees/ — no matching in-progress todo`,
        });
      }
    }
  } catch {
    // Read failure — non-fatal
  }

  return results;
}

/**
 * Parse a todo file. Todos have JSON front matter (a JSON object at the top of the file)
 * optionally followed by markdown body.
 */
function parseTodo(content: string): { status?: string; title?: string; created_at?: string } | null {
  try {
    // The JSON block is at the start of the file
    const trimmed = content.trim();
    if (!trimmed.startsWith("{")) return null;

    // Find the closing brace for the top-level JSON object,
    // skipping braces inside string values (handles escaped quotes too)
    let depth = 0;
    let jsonEnd = -1;
    let inString = false;
    let escapeNext = false;
    for (let i = 0; i < trimmed.length; i++) {
      const char = trimmed[i];
      if (escapeNext) {
        escapeNext = false;
        continue;
      }
      if (char === "\\") {
        escapeNext = true;
        continue;
      }
      if (char === '"') {
        inString = !inString;
        continue;
      }
      if (!inString) {
        if (char === "{") depth++;
        else if (char === "}") {
          depth--;
          if (depth === 0) {
            jsonEnd = i + 1;
            break;
          }
        }
      }
    }
    if (jsonEnd === -1) return null;

    return JSON.parse(trimmed.substring(0, jsonEnd));
  } catch {
    return null;
  }
}

function checkStuckTodos(): CheckResult[] {
  const results: CheckResult[] = [];
  const now = Date.now();

  if (!existsSync(TODOS_DIR)) return results;

  try {
    const files = readdirSync(TODOS_DIR).filter((f) => f.endsWith(".md"));

    for (const file of files) {
      try {
        const content = readFileSync(join(TODOS_DIR, file), "utf-8");
        const todo = parseTodo(content);
        if (!todo || todo.status !== "in-progress") continue;

        const createdAt = todo.created_at;
        if (!createdAt) continue;

        const createdTime = new Date(createdAt).getTime();
        if (Number.isNaN(createdTime)) continue;

        const age = now - createdTime;
        if (age < STUCK_TODO_THRESHOLD_MS) continue;

        // Check if there's a corresponding dev-agent session
        const todoId = file.replace(".md", "");
        const hasAgent = hasDevAgentForTodo(todoId);

        if (!hasAgent) {
          const title = todo.title || todoId;
          const hoursStuck = Math.round((age / (60 * 60 * 1000)) * 10) / 10;

          results.push({
            name: `stuck:TODO-${todoId}`,
            ok: false,
            detail: `Todo "TODO-${todoId}" (${title}) has been in-progress for ${hoursStuck}h with no dev-agent session`,
          });
        }
      } catch {
        // Individual file read failure — skip
      }
    }
  } catch {
    // Dir read failure — non-fatal
  }

  return results;
}

function checkUnansweredMentions(): CheckResult[] {
  const results: CheckResult[] = [];
  const now = Date.now();
  const bridgeLogPath = resolveBridgeLogPath();

  if (!bridgeLogPath) return results;

  try {
    // Read the last 500 lines of the bridge log to find recent app_mention events.
    // Support both bridge implementations:
    //   - broker-bridge.mjs: "... (type: app_mention, ts: 1234.5678)"
    //   - bridge.mjs:        "app_mention ... ts: 1234.5678"
    const { execSync } = require("node:child_process");
    const logTail = execSync(`tail -500 "${bridgeLogPath}"`, { encoding: "utf-8" });

    const mentionThreadTsSet = new Set<string>(extractMentionThreadTs(logTail));

    const oneHourAgo = now - 60 * 60 * 1000;

    // For each recent mention, check if we replied to it.
    for (const threadTs of mentionThreadTsSet) {
      const mentionTime = slackTsToMs(threadTs);
      if (mentionTime == null || mentionTime <= oneHourAgo) continue;

      const age = now - mentionTime;

      // Skip very recent mentions (< 5 min) - agent might still be processing.
      if (age < UNANSWERED_MENTION_THRESHOLD_MS) continue;

      // Check if we sent a reply to this thread_ts.
      const replied = hasRepliedToThread(threadTs);

      if (!replied) {
        const minutesAgo = Math.round(age / (60 * 1000));
        results.push({
          name: `unanswered:${threadTs}`,
          ok: false,
          detail: `Slack mention at ts ${threadTs} (${minutesAgo} min ago) has no reply — may have been lost during restart`,
        });
      }
    }
  } catch {
    // Log read failure or exec error - non-fatal.
    // Don't report this as a failure unless we have a specific problem to report.
  }

  return results;
}

function extractMentionThreadTs(logTail: string): string[] {
  const mentionThreadTsSet = new Set<string>();

  for (const line of logTail.split("\n")) {
    if (!line.includes("app_mention")) continue;

    const threadMatch = line.match(/\bthread_ts:\s*(\d+\.\d+)/);
    if (threadMatch?.[1]) {
      mentionThreadTsSet.add(threadMatch[1]);
      continue;
    }

    const tsMatch = line.match(/\bts:\s*(\d+\.\d+)/);
    if (tsMatch?.[1]) {
      mentionThreadTsSet.add(tsMatch[1]);
    }
  }

  return [...mentionThreadTsSet];
}

function slackTsToMs(ts: string): number | null {
  const parsed = Number.parseFloat(ts);
  if (!Number.isFinite(parsed) || parsed <= 0) return null;
  return Math.floor(parsed * 1000);
}

function hasRepliedToThread(threadTs: string): boolean {
  // Check multiple sources for evidence of a reply to this thread_ts.

  // 1. Check the reply tracking log (most reliable — written by the agent).
  //    File: ~/.pi/agent/slack-reply-log.jsonl
  //    Each line: {"thread_ts":"...","replied_at":"..."}
  const replyLogPath = join(homedir(), ".pi", "agent", "slack-reply-log.jsonl");
  if (existsSync(replyLogPath)) {
    try {
      const content = readFileSync(replyLogPath, "utf-8");
      const lines = content.split("\n");
      for (const line of lines) {
        const trimmed = line.trim();
        if (!trimmed) continue;
        try {
          const entry = JSON.parse(trimmed);
          if (entry?.thread_ts === threadTs) {
            return true;
          }
        } catch {
          // Ignore malformed JSONL lines and keep scanning.
        }
      }
    } catch {
      // File read error — fall through to other checks
    }
  }

  // 2. Check recent control-agent session logs for explicit outbound /send calls.
  //    Session files are in ~/.pi/agent/sessions/--home-baudbot_agent--/
  //    and named <timestamp>_<uuid>.jsonl.
  const controlAgentSessionDir = join(SESSION_DIR, "--home-baudbot_agent--");
  if (existsSync(controlAgentSessionDir)) {
    const escapeRegExp = (value: string): string => value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
    const threadTsPattern = new RegExp(`["']thread_ts["']\\s*:\\s*["']${escapeRegExp(threadTs)}["']`);

    try {
      const sessionFiles = readdirSync(controlAgentSessionDir)
        .filter((f) => f.endsWith(".jsonl"))
        .sort()
        .reverse()
        .slice(0, 3); // Check last 3 sessions

      for (const file of sessionFiles) {
        try {
          const content = readFileSync(join(controlAgentSessionDir, file), "utf-8");
          const lines = content.split("\n");

          for (const line of lines) {
            const trimmed = line.trim();
            if (!trimmed) continue;

            let parsed: any;
            try {
              parsed = JSON.parse(trimmed);
            } catch {
              continue;
            }

            if (parsed?.type !== "message") continue;
            if (parsed?.message?.role !== "assistant") continue;

            const items = parsed?.message?.content;
            if (!Array.isArray(items)) continue;

            for (const item of items) {
              if (item?.type !== "toolCall") continue;
              if (item?.name !== "bash") continue;

              const command = typeof item?.arguments?.command === "string" ? item.arguments.command : "";
              if (!command.includes("curl")) continue;
              if (!command.includes("/send")) continue;
              if (!threadTsPattern.test(command)) continue;

              return true;
            }
          }
        } catch {
          // File read error - skip
        }
      }
    } catch {
      // Dir read error
    }
  }

  return false;
}

// ── Helper Functions ────────────────────────────────────────────────────────

function hasMatchingTodo(devAgentName: string): boolean {
  // dev-agent-<repo>-<todo-short> → extract todo short ID
  const parts = devAgentName.split("-");
  if (parts.length < 4) return false;
  const todoShort = parts[parts.length - 1];

  if (!existsSync(TODOS_DIR)) return false;

  try {
    const files = readdirSync(TODOS_DIR);
    return files.some((f) => f.startsWith(todoShort));
  } catch {
    return false;
  }
}

function hasMatchingInProgressTodo(worktreeName: string): boolean {
  if (!existsSync(TODOS_DIR)) return false;

  // Worktree dirs are branch names (e.g. "fix/sentry-alert-handling").
  // Match against full path patterns stored in todo bodies to avoid false
  // positives from short substrings like "fix" matching any mention of "fix".
  // We check for:
  //   1. The worktree name as part of a path (e.g. "worktrees/fix/some-name")
  //   2. The worktree name preceded by a word boundary (space, quote, backtick, or line start)
  const pathPattern = `worktrees/${worktreeName}`;
  const escapedName = worktreeName.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const boundaryPattern = new RegExp(`(?:^|[\\s\`"'/])${escapedName}(?:$|[\\s\`"'/])`, "m");

  try {
    const files = readdirSync(TODOS_DIR).filter((f) => f.endsWith(".md"));
    for (const file of files) {
      try {
        const content = readFileSync(join(TODOS_DIR, file), "utf-8");
        const todo = parseTodo(content);
        if (todo?.status === "in-progress") {
          if (content.includes(pathPattern) || boundaryPattern.test(content)) return true;
        }
      } catch {
        // skip unreadable todo files
      }
    }
  } catch {
    // Dir read failure
  }

  return false;
}

function hasDevAgentForTodo(todoId: string): boolean {
  try {
    const files = readdirSync(SOCKET_DIR);
    const aliases = files.filter((f) => f.endsWith(".alias") && f.startsWith("dev-agent-"));
    return aliases.some((a) => a.includes(todoId.substring(0, 8)));
  } catch {
    return false;
  }
}

// ── Extension ───────────────────────────────────────────────────────────────

export default function heartbeatExtension(pi: ExtensionAPI): void {
  let timer: ReturnType<typeof setTimeout> | null = null;
  const state: HeartbeatState = {
    enabled: true,
    intervalMs: DEFAULT_INTERVAL_MS,
    lastRunAt: null,
    consecutiveErrors: 0,
    totalRuns: 0,
    lastFailures: [],
  };

  function saveState() {
    pi.appendEntry(HEARTBEAT_STATE_ENTRY, {
      lastRunAt: state.lastRunAt,
      consecutiveErrors: state.consecutiveErrors,
      totalRuns: state.totalRuns,
      lastFailures: state.lastFailures,
    });
  }

  function computeBackoffMs(consecutiveErrors: number, baseInterval: number): number {
    if (consecutiveErrors <= 0) return baseInterval;
    const backoff = baseInterval * BACKOFF_MULTIPLIER ** consecutiveErrors;
    return Math.min(backoff, MAX_BACKOFF_MS);
  }

  function armTimer() {
    if (timer) clearTimeout(timer);
    timer = null;

    if (!state.enabled) return;

    const delay = computeBackoffMs(state.consecutiveErrors, state.intervalMs);
    timer = setTimeout(() => {
      fireHeartbeat();
    }, delay);
  }

  async function fireHeartbeat() {
    try {
      const now = Date.now();
      state.lastRunAt = now;
      state.totalRuns += 1;

      // Run all checks
      const sessionResults = checkSessions();
      const bridgeResult = await checkBridge();
      const worktreeResults = checkWorktrees();
      const stuckTodoResults = checkStuckTodos();
      const unansweredMentionResults = isUnansweredMentionsCheckEnabled() 
        ? checkUnansweredMentions() 
        : [];

      const allResults: CheckResult[] = [
        ...sessionResults,
        bridgeResult,
        ...worktreeResults,
        ...stuckTodoResults,
        ...unansweredMentionResults,
      ];

      const failures = allResults.filter((r) => !r.ok);
      state.lastFailures = failures.map((f) => `${f.name}: ${f.detail}`);

      if (failures.length === 0) {
        // Everything healthy — NO LLM tokens consumed!
        state.consecutiveErrors = 0;
        saveState();
        armTimer();
        return;
      }

      // Something is wrong — inject a prompt so the control-agent can fix it
      const failureList = failures
        .map((f) => `- **${f.name}**: ${f.detail}`)
        .join("\n");

      const prompt = [
        `🫀 **Heartbeat** (run #${state.totalRuns}, ${new Date(now).toISOString()})`,
        ``,
        `**${failures.length} health check failure(s) detected** — take action:`,
        ``,
        failureList,
        ``,
        `All other checks passed. Fix the issues above and report what you did.`,
      ].join("\n");

      pi.sendMessage(
        {
          customType: "heartbeat",
          content: prompt,
          display: true,
        },
        {
          deliverAs: "followUp",
          triggerTurn: true,
        }
      );

      state.consecutiveErrors = 0;
      saveState();
    } catch {
      state.consecutiveErrors += 1;
      try {
        saveState();
      } catch {
        // Best-effort
      }
    } finally {
      armTimer();
    }
  }

  function stopTimer() {
    if (timer) {
      clearTimeout(timer);
      timer = null;
    }
  }

  // ── Tool: heartbeat control ───────────────────────────────────────────────

  pi.registerTool({
    name: "heartbeat",
    label: "Heartbeat",
    description:
      "Manage the periodic heartbeat loop. " +
      "Actions: status (check state), pause (stop heartbeats), resume (restart), " +
      "trigger (fire one now), config (show configuration).",
    parameters: Type.Object({
      action: StringEnum(["status", "pause", "resume", "trigger", "config"] as const),
    }),
    async execute(_toolCallId, params, _signal, _onUpdate, _ctx) {
      switch (params.action) {
        case "status": {
          const nextIn = timer
            ? `~${Math.round(computeBackoffMs(state.consecutiveErrors, state.intervalMs) / 1000)}s`
            : "paused";
          const failureInfo = state.lastFailures.length > 0
            ? `\n  Last failures:\n${state.lastFailures.map(f => `    - ${f}`).join("\n")}`
            : "\n  Last check: all healthy ✅";
          return {
            content: [
              {
                type: "text" as const,
                text: [
                  `Heartbeat Status:`,
                  `  Enabled: ${state.enabled ? "✅" : "⏹"}`,
                  `  Mode: programmatic (zero-token when healthy)`,
                  `  Interval: ${state.intervalMs / 1000}s`,
                  `  Next fire: ${nextIn}`,
                  `  Total runs: ${state.totalRuns}`,
                  `  Consecutive errors: ${state.consecutiveErrors}`,
                  `  Last run: ${state.lastRunAt ? new Date(state.lastRunAt).toISOString() : "never"}`,
                  failureInfo,
                ].join("\n"),
              },
            ],
          };
        }

        case "pause": {
          state.enabled = false;
          stopTimer();
          saveState();
          return {
            content: [{ type: "text" as const, text: "⏹ Heartbeat paused." }],
          };
        }

        case "resume": {
          state.enabled = true;
          state.consecutiveErrors = 0;
          armTimer();
          saveState();
          return {
            content: [
              {
                type: "text" as const,
                text: `✅ Heartbeat resumed (every ${state.intervalMs / 1000}s, zero-token when healthy).`,
              },
            ],
          };
        }

        case "trigger": {
          // Run checks immediately and report results
          const sessionResults = checkSessions();
          const bridgeResult = await checkBridge();
          const worktreeResults = checkWorktrees();
          const stuckTodoResults = checkStuckTodos();
          const unansweredMentionResults = isUnansweredMentionsCheckEnabled()
            ? checkUnansweredMentions()
            : [];

          const allResults: CheckResult[] = [
            ...sessionResults,
            bridgeResult,
            ...worktreeResults,
            ...stuckTodoResults,
            ...unansweredMentionResults,
          ];

          const failures = allResults.filter((r) => !r.ok);
          const passes = allResults.filter((r) => r.ok);

          if (failures.length === 0) {
            return {
              content: [
                {
                  type: "text" as const,
                  text: `🫀 All ${allResults.length} checks passed: ${passes.map(r => r.name).join(", ")}`,
                },
              ],
            };
          }

          // If there are failures, also fire the normal heartbeat flow
          // (which will inject the prompt for the agent to act on)
          fireHeartbeat();

          return {
            content: [
              {
                type: "text" as const,
                text: [
                  `🫀 ${failures.length} failure(s) detected — heartbeat prompt injected for action:`,
                  ...failures.map((f) => `  ❌ ${f.name}: ${f.detail}`),
                  ...passes.map((r) => `  ✅ ${r.name}`),
                ].join("\n"),
              },
            ],
          };
        }

        case "config": {
          const expected = getExpectedSessions();
          const checkUnanswered = isUnansweredMentionsCheckEnabled();
          return {
            content: [
              {
                type: "text" as const,
                text: [
                  `Heartbeat Configuration:`,
                  `  Mode: programmatic (v2 — zero-token when healthy)`,
                  `  Interval: ${state.intervalMs / 1000}s (env: HEARTBEAT_INTERVAL_MS)`,
                  `  Min interval: ${MIN_INTERVAL_MS / 1000}s`,
                  `  Backoff multiplier: ${BACKOFF_MULTIPLIER}x per error`,
                  `  Max backoff: ${MAX_BACKOFF_MS / 1000}s`,
                  `  Expected sessions: ${expected.join(", ")} (env: HEARTBEAT_EXPECTED_SESSIONS)`,
                  `  Check unanswered mentions: ${checkUnanswered ? "enabled" : "disabled"} (env: HEARTBEAT_CHECK_UNANSWERED_MENTIONS)`,
                  `  Unanswered mention threshold: ${UNANSWERED_MENTION_THRESHOLD_MS / (60 * 1000)} min`,
                  `  Stuck todo threshold: ${STUCK_TODO_THRESHOLD_MS / (60 * 60 * 1000)}h`,
                  `  Bridge URL: ${BRIDGE_URL}`,
                  `  Bridge log (primary): ${BRIDGE_LOG_PRIMARY}`,
                  `  Bridge log (legacy fallback): ${BRIDGE_LOG_LEGACY}`,
                  `  Socket dir: ${SOCKET_DIR}`,
                  `  Worktrees dir: ${WORKTREES_DIR}`,
                  `  Todos dir: ${TODOS_DIR}`,
                  `  Session dir: ${SESSION_DIR}`,
                ].join("\n"),
              },
            ],
          };
        }

        default:
          return {
            content: [{ type: "text" as const, text: `Unknown action: ${params.action}` }],
          };
      }
    },
  });

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  pi.on("session_start", async (_event, ctx) => {
    // Restore persisted state
    for (const entry of ctx.sessionManager.getEntries()) {
      const e = entry as { type: string; customType?: string; data?: any };
      if (e.type === "custom" && e.customType === HEARTBEAT_STATE_ENTRY && e.data) {
        if (typeof e.data.consecutiveErrors === "number")
          state.consecutiveErrors = e.data.consecutiveErrors;
        if (typeof e.data.totalRuns === "number") state.totalRuns = e.data.totalRuns;
        if (typeof e.data.lastRunAt === "number") state.lastRunAt = e.data.lastRunAt;
        if (Array.isArray(e.data.lastFailures)) state.lastFailures = e.data.lastFailures;
      }
    }

    // Apply env config
    const envInterval = process.env.HEARTBEAT_INTERVAL_MS;
    state.intervalMs = clampInt(envInterval, MIN_INTERVAL_MS, MAX_BACKOFF_MS, DEFAULT_INTERVAL_MS);
    state.enabled = !isDisabledByEnv();

    if (state.enabled) {
      armTimer();
    }
  });

  pi.on("session_shutdown", async () => {
    stopTimer();
  });
}
