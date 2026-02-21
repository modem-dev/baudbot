/**
 * Idle Compaction Extension
 *
 * Compacts the conversation context when the agent is truly idle — not just
 * "no recent turns" but "no active work at all". This prevents compacting
 * in the middle of a long-running dev agent task where we'd lose critical
 * context (which repo, which todo, which Slack thread to reply to).
 *
 * Compaction triggers when ALL of these are true:
 *   1. No turns for IDLE_DELAY_MS (default 5 min)
 *   2. No active dev-agent-* sessions (checked via session-control sockets)
 *   3. No in-progress todos (checked via todo files)
 *   4. Context usage exceeds COMPACT_THRESHOLD_PCT of the context window
 *
 * Configuration (env vars):
 *   IDLE_COMPACT_DELAY_MS         — idle time before checking (default: 300000 = 5 min)
 *   IDLE_COMPACT_THRESHOLD_PCT    — context % to trigger (default: 40)
 *   IDLE_COMPACT_ENABLED          — set to "0" or "false" to disable
 */

import type { ExtensionAPI, ExtensionContext } from "@mariozechner/pi-coding-agent";
import { readdirSync, readFileSync, readlinkSync, existsSync } from "node:fs";
import { join } from "node:path";
import { homedir } from "node:os";
import * as net from "node:net";

const DEFAULT_IDLE_DELAY_MS = 5 * 60 * 1000; // 5 minutes
const DEFAULT_THRESHOLD_PCT = 40;
const MIN_IDLE_DELAY_MS = 60 * 1000; // 1 minute minimum

const CONTROL_DIR = join(homedir(), ".pi", "session-control");
const TODO_DIR = process.env.PI_TODO_PATH || join(".pi", "todos");

function getConfig() {
  const envDelay = parseInt(process.env.IDLE_COMPACT_DELAY_MS || "", 10);
  const idleDelayMs = Math.max(
    MIN_IDLE_DELAY_MS,
    Number.isFinite(envDelay) ? envDelay : DEFAULT_IDLE_DELAY_MS
  );

  const envThreshold = parseInt(process.env.IDLE_COMPACT_THRESHOLD_PCT || "", 10);
  const thresholdPct = Number.isFinite(envThreshold)
    ? Math.max(10, Math.min(90, envThreshold))
    : DEFAULT_THRESHOLD_PCT;

  const envEnabled = process.env.IDLE_COMPACT_ENABLED?.trim().toLowerCase();
  const enabled = envEnabled !== "0" && envEnabled !== "false" && envEnabled !== "no";

  return { idleDelayMs, thresholdPct, enabled };
}

// ---------------------------------------------------------------------------
// Check for active dev agents by probing session-control sockets
// ---------------------------------------------------------------------------

function isSocketAlive(socketPath: string): Promise<boolean> {
  return new Promise((resolve) => {
    const socket = net.createConnection(socketPath);
    const timeout = setTimeout(() => {
      socket.removeAllListeners();
      socket.destroy();
      resolve(false);
    }, 300);

    const cleanup = (alive: boolean) => {
      clearTimeout(timeout);
      socket.removeAllListeners();
      if (alive) socket.end();
      else socket.destroy();
      resolve(alive);
    };

    socket.once("connect", () => cleanup(true));
    socket.once("error", () => cleanup(false));
  });
}

async function hasActiveDevAgents(): Promise<boolean> {
  try {
    const entries = readdirSync(CONTROL_DIR, { withFileTypes: true });

    for (const entry of entries) {
      if (!entry.name.endsWith(".alias")) continue;
      const aliasName = entry.name.slice(0, -".alias".length);
      if (!aliasName.startsWith("dev-agent-")) continue;

      // Resolve the symlink to find the socket file
      try {
        const target = readlinkSync(join(CONTROL_DIR, entry.name));
        const socketPath = join(CONTROL_DIR, target);
        if (await isSocketAlive(socketPath)) {
          return true;
        }
      } catch {
        // Broken symlink — skip
      }
    }

    return false;
  } catch {
    // If we can't read the directory, assume no active agents
    return false;
  }
}

// ---------------------------------------------------------------------------
// Check for in-progress todos
// ---------------------------------------------------------------------------

function hasInProgressTodos(): boolean {
  try {
    const todoPath = TODO_DIR.startsWith("/") ? TODO_DIR : join(process.cwd(), TODO_DIR);
    if (!existsSync(todoPath)) return false;

    const files = readdirSync(todoPath).filter((f) => f.endsWith(".md"));

    for (const file of files) {
      try {
        const content = readFileSync(join(todoPath, file), "utf-8");
        // Front matter is a JSON block at the start of the file
        const jsonEnd = content.indexOf("\n\n");
        const jsonStr = jsonEnd > 0 ? content.slice(0, jsonEnd) : content;
        const frontMatter = JSON.parse(jsonStr.trim());
        if (frontMatter.status === "in-progress" || frontMatter.status === "in_progress") {
          return true;
        }
      } catch {
        // Skip files we can't parse
      }
    }

    return false;
  } catch {
    return false;
  }
}

// ---------------------------------------------------------------------------
// Extension
// ---------------------------------------------------------------------------

export default function idleCompactExtension(pi: ExtensionAPI): void {
  let idleTimer: ReturnType<typeof setTimeout> | null = null;
  let lastCtx: ExtensionContext | null = null;
  let compacting = false;
  let enabled = true;
  let idleDelayMs = DEFAULT_IDLE_DELAY_MS;
  let thresholdPct = DEFAULT_THRESHOLD_PCT;

  function cancelTimer() {
    if (idleTimer) {
      clearTimeout(idleTimer);
      idleTimer = null;
    }
  }

  function armTimer() {
    cancelTimer();
    if (!enabled || !lastCtx) return;

    idleTimer = setTimeout(() => {
      idleTimer = null;
      void checkAndCompact();
    }, idleDelayMs);
  }

  async function checkAndCompact() {
    if (!lastCtx || compacting) return;

    // Check 1: context usage above threshold?
    const usage = lastCtx.getContextUsage();
    if (!usage || usage.tokens === null || usage.contextWindow === null) return;

    const pctUsed = (usage.tokens / usage.contextWindow) * 100;
    if (pctUsed < thresholdPct) {
      return; // Not worth compacting yet
    }

    // Check 2: any active dev agents?
    if (await hasActiveDevAgents()) {
      // Dev agent running — don't compact, re-arm and check again later
      armTimer();
      return;
    }

    // Check 3: any in-progress todos?
    if (hasInProgressTodos()) {
      // Work in progress — don't compact, re-arm and check again later
      armTimer();
      return;
    }

    // All clear — compact
    compacting = true;
    lastCtx.compact({
      customInstructions:
        "This is an idle-period compaction. Preserve all operational context: " +
        "active session names, repo paths, Slack thread references (channel + thread_ts), " +
        "any pending user requests, and memory file locations. Be thorough — the full " +
        "conversation history won't be available after this.",
      onComplete: () => {
        compacting = false;
      },
      onError: () => {
        compacting = false;
        // Re-arm to try again later
        armTimer();
      },
    });
  }

  // ── Events ────────────────────────────────────────────────────────────────

  pi.on("session_start", async () => {
    const config = getConfig();
    enabled = config.enabled;
    idleDelayMs = config.idleDelayMs;
    thresholdPct = config.thresholdPct;
  });

  // When a turn starts, cancel any pending idle compaction — we're active
  pi.on("turn_start", async () => {
    cancelTimer();
  });

  // When a turn ends, start the idle countdown
  pi.on("turn_end", async (_event, ctx) => {
    lastCtx = ctx;
    if (enabled) {
      armTimer();
    }
  });

  pi.on("session_shutdown", async () => {
    cancelTimer();
  });
}
