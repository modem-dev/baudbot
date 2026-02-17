/**
 * Heartbeat Extension
 *
 * Periodically injects a heartbeat prompt into the agent's conversation so it
 * can perform health checks, clean up stale resources, and act proactively
 * without waiting for external events.
 *
 * The heartbeat reads a configurable checklist file (HEARTBEAT.md) and sends
 * it as a follow-up message. If the file is empty or missing, no heartbeat
 * fires (saves tokens).
 *
 * Configuration (env vars):
 *   HEARTBEAT_INTERVAL_MS   — interval between heartbeats (default: 600000 = 10 min)
 *   HEARTBEAT_FILE           — path to checklist file (default: ~/.pi/agent/HEARTBEAT.md)
 *   HEARTBEAT_ENABLED        — set to "0" or "false" to disable (default: enabled)
 *
 * Inspired by OpenClaw's HEARTBEAT.md pattern — a user-configurable Markdown
 * checklist that the agent evaluates on each tick.
 */

import type { ExtensionAPI, ExtensionContext } from "@mariozechner/pi-coding-agent";
import { Type } from "@sinclair/typebox";
import { StringEnum } from "@mariozechner/pi-ai";
import { existsSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

const DEFAULT_INTERVAL_MS = 10 * 60 * 1000; // 10 minutes
const DEFAULT_HEARTBEAT_FILE = join(homedir(), ".pi", "agent", "HEARTBEAT.md");

// Minimum interval to prevent accidental token burn (2 minutes)
const MIN_INTERVAL_MS = 2 * 60 * 1000;

// Maximum consecutive errors before backing off
const MAX_CONSECUTIVE_ERRORS = 5;
const BACKOFF_MULTIPLIER = 2;
const MAX_BACKOFF_MS = 60 * 60 * 1000; // 1 hour

type HeartbeatState = {
  enabled: boolean;
  intervalMs: number;
  heartbeatFile: string;
  lastRunAt: number | null;
  consecutiveErrors: number;
  totalRuns: number;
};

const HEARTBEAT_STATE_ENTRY = "heartbeat-state";

function isDisabledByEnv(): boolean {
  const val = process.env.HEARTBEAT_ENABLED?.trim().toLowerCase();
  return val === "0" || val === "false" || val === "no";
}

function resolveConfig(): { intervalMs: number; heartbeatFile: string; enabled: boolean } {
  const envInterval = parseInt(process.env.HEARTBEAT_INTERVAL_MS || "", 10);
  const intervalMs = Math.max(
    MIN_INTERVAL_MS,
    Number.isFinite(envInterval) ? envInterval : DEFAULT_INTERVAL_MS
  );
  const heartbeatFile = process.env.HEARTBEAT_FILE?.trim() || DEFAULT_HEARTBEAT_FILE;
  const enabled = !isDisabledByEnv();
  return { intervalMs, heartbeatFile, enabled };
}

function readHeartbeatFile(filepath: string): string | null {
  try {
    if (!existsSync(filepath)) return null;
    const content = readFileSync(filepath, "utf-8").trim();
    // Skip if empty or only comments/whitespace
    const meaningful = content
      .split("\n")
      .filter((line) => {
        const trimmed = line.trim();
        return trimmed.length > 0 && !trimmed.startsWith("#");
      })
      .join("\n")
      .trim();
    return meaningful.length > 0 ? content : null;
  } catch {
    return null;
  }
}

function computeBackoffMs(consecutiveErrors: number, baseInterval: number): number {
  if (consecutiveErrors <= 0) return baseInterval;
  const backoff = baseInterval * Math.pow(BACKOFF_MULTIPLIER, consecutiveErrors);
  return Math.min(backoff, MAX_BACKOFF_MS);
}

export default function heartbeatExtension(pi: ExtensionAPI): void {
  let timer: ReturnType<typeof setTimeout> | null = null;
  let state: HeartbeatState = {
    enabled: true,
    intervalMs: DEFAULT_INTERVAL_MS,
    heartbeatFile: DEFAULT_HEARTBEAT_FILE,
    lastRunAt: null,
    consecutiveErrors: 0,
    totalRuns: 0,
  };

  function saveState() {
    pi.appendEntry(HEARTBEAT_STATE_ENTRY, {
      lastRunAt: state.lastRunAt,
      consecutiveErrors: state.consecutiveErrors,
      totalRuns: state.totalRuns,
    });
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

  function fireHeartbeat() {
    try {
      const content = readHeartbeatFile(state.heartbeatFile);
      if (!content) {
        // No checklist — skip silently, re-arm for next interval
        armTimer();
        return;
      }

      const now = Date.now();
      state.lastRunAt = now;
      state.totalRuns += 1;

      const prompt = [
        `🫀 **Heartbeat** (run #${state.totalRuns}, ${new Date(now).toISOString()})`,
        ``,
        `Review the following checklist and take action on any items that need attention.`,
        `If everything is healthy, respond briefly with what you checked. Do NOT take action unless something is wrong.`,
        ``,
        `---`,
        content,
        `---`,
        ``,
        `If you find issues, fix them. If everything looks good, say so briefly and move on.`,
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

      // Success — reset error counter
      state.consecutiveErrors = 0;
      saveState();
    } catch (err) {
      // Increment error counter for backoff — never let the heartbeat die
      state.consecutiveErrors += 1;
      try {
        saveState();
      } catch {
        // Best-effort state persistence — don't let a save failure prevent re-arm
      }
    } finally {
      // Always re-arm the timer, even after errors (with backoff)
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
          return {
            content: [
              {
                type: "text" as const,
                text: [
                  `Heartbeat Status:`,
                  `  Enabled: ${state.enabled ? "✅" : "⏹"}`,
                  `  Interval: ${state.intervalMs / 1000}s`,
                  `  Next fire: ${nextIn}`,
                  `  Total runs: ${state.totalRuns}`,
                  `  Consecutive errors: ${state.consecutiveErrors}`,
                  `  Last run: ${state.lastRunAt ? new Date(state.lastRunAt).toISOString() : "never"}`,
                  `  Checklist: ${state.heartbeatFile}`,
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
                text: `✅ Heartbeat resumed (every ${state.intervalMs / 1000}s).`,
              },
            ],
          };
        }

        case "trigger": {
          fireHeartbeat();
          return {
            content: [{ type: "text" as const, text: "🫀 Heartbeat triggered." }],
          };
        }

        case "config": {
          const content = readHeartbeatFile(state.heartbeatFile);
          return {
            content: [
              {
                type: "text" as const,
                text: [
                  `Heartbeat Configuration:`,
                  `  File: ${state.heartbeatFile}`,
                  `  File exists: ${existsSync(state.heartbeatFile) ? "yes" : "no"}`,
                  `  Has content: ${content ? "yes" : "no (empty or comments only)"}`,
                  `  Interval: ${state.intervalMs / 1000}s (env: HEARTBEAT_INTERVAL_MS)`,
                  `  Min interval: ${MIN_INTERVAL_MS / 1000}s`,
                  `  Backoff multiplier: ${BACKOFF_MULTIPLIER}x per error`,
                  `  Max backoff: ${MAX_BACKOFF_MS / 1000}s`,
                  ``,
                  content ? `Current checklist:\n${content}` : `(no checklist loaded)`,
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
      }
    }

    // Apply env config
    const config = resolveConfig();
    state.intervalMs = config.intervalMs;
    state.heartbeatFile = config.heartbeatFile;
    state.enabled = config.enabled;

    if (state.enabled) {
      armTimer();
    }
  });

  pi.on("session_shutdown", async () => {
    stopTimer();
  });
}
