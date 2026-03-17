import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";
import { Type } from "@sinclair/typebox";
import { appendFileSync, existsSync, mkdirSync, readFileSync, readlinkSync, statSync } from "node:fs";
import net from "node:net";
import { homedir } from "node:os";
import { dirname, join, resolve } from "node:path";

const SAFE_NAME_RE = /^[a-zA-Z0-9._-]+$/;
const SESSION_CONTROL_DIR_ENV = "PI_SESSION_CONTROL_DIR";

const MIN_READY_TIMEOUT_SEC = 1;
const MAX_READY_TIMEOUT_SEC = 60;
const DEFAULT_READY_TIMEOUT_SEC = 10;
const READINESS_POLL_MS = 200;
const SOCKET_PROBE_TIMEOUT_MS = 300;
const TMUX_SPAWN_TIMEOUT_MS = 15_000;

// Circuit breaker defaults
const CIRCUIT_FAILURE_THRESHOLD = 3;
const CIRCUIT_COOLDOWN_MS = 5 * 60 * 1000; // 5 minutes

type SpawnStage = "spawn" | "wait_alias" | "wait_socket" | "probe" | "aborted";

// ── Circuit Breaker ─────────────────────────────────────────────────────────

type CircuitState = "closed" | "open" | "half-open";

type CircuitBreaker = {
  state: CircuitState;
  consecutiveFailures: number;
  lastFailureAt: number | null;
  lastSuccessAt: number | null;
  totalFailures: number;
  totalSuccesses: number;
};

function createCircuitBreaker(): CircuitBreaker {
  return {
    state: "closed",
    consecutiveFailures: 0,
    lastFailureAt: null,
    lastSuccessAt: null,
    totalFailures: 0,
    totalSuccesses: 0,
  };
}

function recordSuccess(cb: CircuitBreaker): void {
  cb.consecutiveFailures = 0;
  cb.lastSuccessAt = Date.now();
  cb.totalSuccesses++;
  cb.state = "closed";
}

function recordFailure(cb: CircuitBreaker): void {
  cb.consecutiveFailures++;
  cb.lastFailureAt = Date.now();
  cb.totalFailures++;
  if (cb.consecutiveFailures >= CIRCUIT_FAILURE_THRESHOLD) {
    cb.state = "open";
  }
}

function isCircuitOpen(cb: CircuitBreaker): boolean {
  if (cb.state !== "open") return false;
  // Check if cooldown has elapsed — eligible for half-open probe
  if (cb.lastFailureAt && Date.now() - cb.lastFailureAt >= CIRCUIT_COOLDOWN_MS) {
    return false;
  }
  return true;
}

/** Transition to half-open state. Call only after input validation passes. */
function transitionToHalfOpen(cb: CircuitBreaker): void {
  if (cb.state === "open" && cb.lastFailureAt && Date.now() - cb.lastFailureAt >= CIRCUIT_COOLDOWN_MS) {
    cb.state = "half-open";
  }
}

function circuitStatus(cb: CircuitBreaker): string {
  const cooldownRemaining =
    cb.state === "open" && cb.lastFailureAt
      ? Math.max(0, CIRCUIT_COOLDOWN_MS - (Date.now() - cb.lastFailureAt))
      : 0;
  return [
    `State: ${cb.state}`,
    `Consecutive failures: ${cb.consecutiveFailures}/${CIRCUIT_FAILURE_THRESHOLD}`,
    `Total: ${cb.totalSuccesses} ok, ${cb.totalFailures} failed`,
    `Last success: ${cb.lastSuccessAt ? new Date(cb.lastSuccessAt).toISOString() : "never"}`,
    `Last failure: ${cb.lastFailureAt ? new Date(cb.lastFailureAt).toISOString() : "never"}`,
    cb.state === "open" ? `Cooldown remaining: ${Math.round(cooldownRemaining / 1000)}s` : "",
  ]
    .filter(Boolean)
    .join("\n  ");
}

// ── Lifecycle Log ───────────────────────────────────────────────────────────

const LIFECYCLE_LOG_PATH = join(homedir(), ".pi", "agent", "logs", "worker-lifecycle.jsonl");

type LifecycleEvent = {
  timestamp: string;
  session_name: string;
  event: "spawn_started" | "spawn_success" | "spawn_failed" | "circuit_rejected";
  stage?: string;
  ready_after_ms?: number;
  error?: string;
};

function logLifecycleEvent(event: LifecycleEvent): void {
  try {
    mkdirSync(dirname(LIFECYCLE_LOG_PATH), { recursive: true });
    appendFileSync(LIFECYCLE_LOG_PATH, JSON.stringify(event) + "\n");
  } catch {
    // Best-effort — don't break spawn on logging failure
  }
}

type ReadinessResult = {
  ready: boolean;
  aborted: boolean;
  stage: SpawnStage;
  aliasPath: string;
  socketPath: string | null;
  readyAfterMs: number;
};

function controlDir(): string {
  const configured = process.env[SESSION_CONTROL_DIR_ENV]?.trim();
  if (configured) return resolve(expandHomePath(configured));
  return join(homedir(), ".pi", "session-control");
}

function expandHomePath(value: string): string {
  const trimmed = value.trim();
  if (trimmed === "~") return homedir();
  if (trimmed.startsWith("~/")) return join(homedir(), trimmed.slice(2));
  return trimmed;
}

function absolutePath(value: string): string {
  return resolve(expandHomePath(value));
}

function shellQuote(value: string): string {
  return `'${value.replace(/'/g, `'"'"'`)}'`;
}

function sleep(ms: number, signal?: AbortSignal): Promise<void> {
  if (ms <= 0) return Promise.resolve();
  return new Promise((resolveSleep) => {
    let settled = false;
    const finish = () => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      if (signal) signal.removeEventListener("abort", onAbort);
      resolveSleep();
    };
    const onAbort = () => finish();
    const timer = setTimeout(finish, ms);
    if (signal) {
      if (signal.aborted) {
        finish();
        return;
      }
      signal.addEventListener("abort", onAbort, { once: true });
    }
  });
}

function isSafeName(value: string): boolean {
  return SAFE_NAME_RE.test(value);
}

function clampReadyTimeout(value: number | undefined): number {
  if (value === undefined || !Number.isFinite(value)) return DEFAULT_READY_TIMEOUT_SEC;
  return Math.min(MAX_READY_TIMEOUT_SEC, Math.max(MIN_READY_TIMEOUT_SEC, Math.round(value)));
}

function resolveSocketPathFromAlias(aliasPath: string, socketDir: string): string | null {
  try {
    const target = readlinkSync(aliasPath);
    const resolved = resolve(socketDir, target);
    if (!resolved.endsWith(".sock")) return null;
    return resolved;
  } catch {
    return null;
  }
}

async function isSocketAlive(socketPath: string, timeoutMs: number, signal?: AbortSignal): Promise<boolean> {
  if (signal?.aborted) return false;
  return await new Promise((resolveAlive) => {
    let settled = false;
    const client = net.createConnection(socketPath);

    const finish = (value: boolean) => {
      if (settled) return;
      settled = true;
      clearTimeout(timeout);
      if (signal) signal.removeEventListener("abort", onAbort);
      client.removeAllListeners();
      client.destroy();
      resolveAlive(value);
    };

    const timeout = setTimeout(() => {
      finish(false);
    }, timeoutMs);

    client.once("connect", () => finish(true));
    client.once("error", () => finish(false));

    const onAbort = () => finish(false);
    if (signal) signal.addEventListener("abort", onAbort, { once: true });
  });
}

async function waitForSessionReadiness(
  readyAlias: string,
  timeoutSec: number,
  signal?: AbortSignal,
): Promise<ReadinessResult> {
  const socketDir = controlDir();
  const aliasPath = join(socketDir, `${readyAlias}.alias`);
  const startedAt = Date.now();
  const deadline = startedAt + timeoutSec * 1000;
  let stage: SpawnStage = "wait_alias";
  let socketPath: string | null = null;

  while (true) {
    if (signal?.aborted) {
      return {
        ready: false,
        aborted: true,
        stage: "aborted",
        aliasPath,
        socketPath,
        readyAfterMs: Date.now() - startedAt,
      };
    }
    if (Date.now() > deadline) break;

    if (existsSync(aliasPath)) {
      socketPath = resolveSocketPathFromAlias(aliasPath, socketDir);
      if (socketPath && existsSync(socketPath)) {
        stage = "probe";
        const remainingProbeMs = deadline - Date.now();
        if (remainingProbeMs <= 0) break;
        const probeTimeoutMs = Math.min(SOCKET_PROBE_TIMEOUT_MS, remainingProbeMs);
        if (await isSocketAlive(socketPath, probeTimeoutMs, signal)) {
          return {
            ready: true,
            aborted: false,
            stage,
            aliasPath,
            socketPath,
            readyAfterMs: Date.now() - startedAt,
          };
        }
      } else {
        stage = "wait_socket";
      }
    } else {
      stage = "wait_alias";
    }
    const remainingPollMs = deadline - Date.now();
    if (remainingPollMs <= 0) break;
    await sleep(Math.min(READINESS_POLL_MS, remainingPollMs), signal);
  }

  return {
    ready: false,
    aborted: false,
    stage,
    aliasPath,
    socketPath,
    readyAfterMs: Date.now() - startedAt,
  };
}

type AgentSpawnInput = {
  session_name: string;
  cwd: string;
  skill_path: string;
  model: string;
  ready_alias?: string;
  ready_timeout_sec?: number;
  log_path?: string;
};

export default function agentSpawnExtension(pi: ExtensionAPI): void {
  const circuit = createCircuitBreaker();

  pi.registerTool({
    name: "agent_spawn",
    label: "Agent Spawn",
    description:
      "Spawn a pi session in tmux and verify readiness through session-control alias/socket with a bounded timeout. " +
      "Includes a circuit breaker: after 3 consecutive failures, spawns are rejected for 5 minutes to prevent resource waste.",
    parameters: Type.Object({
      session_name: Type.String({ description: "Target session name (also PI_SESSION_NAME)" }),
      cwd: Type.String({ description: "Working directory for the new session" }),
      skill_path: Type.String({ description: "Absolute or ~/ path to skill file/directory" }),
      model: Type.String({ description: "Model ID for the spawned session" }),
      ready_alias: Type.Optional(Type.String({ description: "Alias to verify for readiness (default: session_name)" })),
      ready_timeout_sec: Type.Optional(Type.Number({ description: "Readiness timeout in seconds (default 10, max 60)" })),
      log_path: Type.Optional(Type.String({ description: "Log file path (default ~/.pi/agent/logs/spawn-<session>.log)" })),
    }),
    async execute(_toolCallId, params, signal) {
      const input = params as AgentSpawnInput;
      const sessionName = input.session_name?.trim();
      const readyAlias = (input.ready_alias ?? sessionName)?.trim();
      const cwdPath = absolutePath(input.cwd ?? "");
      const skillPath = absolutePath(input.skill_path ?? "");
      const model = input.model?.trim();
      const readyTimeoutSec = clampReadyTimeout(input.ready_timeout_sec);

      // Circuit breaker check
      if (isCircuitOpen(circuit)) {
        const cooldownLeft = circuit.lastFailureAt
          ? Math.max(0, CIRCUIT_COOLDOWN_MS - (Date.now() - circuit.lastFailureAt))
          : 0;
        logLifecycleEvent({
          timestamp: new Date().toISOString(),
          session_name: sessionName || "unknown",
          event: "circuit_rejected",
          error: `Circuit open after ${circuit.consecutiveFailures} failures. Cooldown: ${Math.round(cooldownLeft / 1000)}s`,
        });
        return {
          content: [{
            type: "text",
            text:
              `⚡ Circuit breaker OPEN — ${circuit.consecutiveFailures} consecutive spawn failures. ` +
              `Refusing new spawns for ${Math.round(cooldownLeft / 1000)}s to prevent resource waste. ` +
              `Investigate the root cause (check logs, API keys, model availability).`,
          }],
          isError: true,
          details: {
            error: "circuit_open",
            circuit: {
              state: circuit.state,
              consecutive_failures: circuit.consecutiveFailures,
              cooldown_remaining_sec: Math.round(cooldownLeft / 1000),
              last_failure: circuit.lastFailureAt ? new Date(circuit.lastFailureAt).toISOString() : null,
            },
          },
        };
      }

      if (!sessionName || !isSafeName(sessionName)) {
        return {
          content: [{ type: "text", text: "Invalid session_name. Use only letters, numbers, '.', '_', and '-'." }],
          isError: true,
          details: { error: "invalid_session_name" },
        };
      }
      if (!readyAlias || !isSafeName(readyAlias)) {
        return {
          content: [{ type: "text", text: "Invalid ready_alias. Use only letters, numbers, '.', '_', and '-'." }],
          isError: true,
          details: { error: "invalid_ready_alias" },
        };
      }
      if (!model) {
        return {
          content: [{ type: "text", text: "Missing model." }],
          isError: true,
          details: { error: "missing_model" },
        };
      }
      if (!existsSync(cwdPath) || !statSync(cwdPath).isDirectory()) {
        return {
          content: [{ type: "text", text: `Working directory not found: ${cwdPath}` }],
          isError: true,
          details: { error: "cwd_not_found", cwd: cwdPath },
        };
      }
      if (!existsSync(skillPath)) {
        return {
          content: [{ type: "text", text: `Skill path not found: ${skillPath}` }],
          isError: true,
          details: { error: "skill_path_not_found", skill_path: skillPath },
        };
      }

      const logPath = input.log_path?.trim()
        ? absolutePath(input.log_path)
        : join(homedir(), ".pi", "agent", "logs", `spawn-${sessionName}.log`);
      try {
        mkdirSync(dirname(logPath), { recursive: true });
      } catch (error) {
        return {
          content: [{ type: "text", text: `Failed to prepare log path: ${logPath}` }],
          isError: true,
          details: {
            spawned: false,
            ready: false,
            stage: "spawn",
            error: "log_path_prepare_failed",
            session_name: sessionName,
            ready_alias: readyAlias,
            log_path: logPath,
            reason: error instanceof Error ? error.message : String(error),
          },
        };
      }

      // All validation passed — now safe to transition circuit to half-open
      // (allows exactly one probe attempt to test recovery)
      transitionToHalfOpen(circuit);

      logLifecycleEvent({
        timestamp: new Date().toISOString(),
        session_name: sessionName,
        event: "spawn_started",
      });

      const tmuxCommand = [
        `cd ${shellQuote(cwdPath)}`,
        'export PATH="$HOME/.varlock/bin:$HOME/opt/node/bin:$PATH"',
        `export PI_SESSION_NAME=${shellQuote(sessionName)}`,
        `exec varlock run --path "$HOME/.config/" -- pi --session-control --skill ${shellQuote(skillPath)} --model ${shellQuote(model)} > ${shellQuote(logPath)} 2>&1`,
      ].join(" && ");

      const spawnResult = await pi.exec(
        "tmux",
        ["new-session", "-d", "-s", sessionName, tmuxCommand],
        {
          timeout: TMUX_SPAWN_TIMEOUT_MS,
          signal,
        },
      );

      if (spawnResult.code !== 0) {
        recordFailure(circuit);
        logLifecycleEvent({
          timestamp: new Date().toISOString(),
          session_name: sessionName,
          event: "spawn_failed",
          stage: "spawn",
          error: `tmux exit code ${spawnResult.code}`,
        });
        return {
          content: [{ type: "text", text: `Failed to spawn tmux session ${sessionName}.` }],
          isError: true,
          details: {
            spawned: false,
            ready: false,
            stage: "spawn",
            error: "spawn_failed",
            session_name: sessionName,
            ready_alias: readyAlias,
            log_path: logPath,
            stdout: spawnResult.stdout,
            stderr: spawnResult.stderr,
            exit_code: spawnResult.code,
            circuit_state: circuit.state,
            circuit_failures: circuit.consecutiveFailures,
          },
        };
      }

      const readiness = await waitForSessionReadiness(readyAlias, readyTimeoutSec, signal);
      const details = {
        spawned: true,
        ready: readiness.ready,
        aborted: readiness.aborted,
        session_name: sessionName,
        ready_alias: readyAlias,
        alias_path: readiness.aliasPath,
        socket_path: readiness.socketPath,
        log_path: logPath,
        ready_after_ms: readiness.readyAfterMs,
        stage: readiness.stage,
        error: readiness.ready ? null : readiness.aborted ? "readiness_aborted" : "readiness_timeout",
        circuit_state: circuit.state,
        circuit_failures: circuit.consecutiveFailures,
      };

      if (readiness.aborted) {
        recordFailure(circuit);
        logLifecycleEvent({
          timestamp: new Date().toISOString(),
          session_name: sessionName,
          event: "spawn_failed",
          stage: "aborted",
          error: "readiness_aborted",
        });
        return {
          content: [{
            type: "text",
            text: `Spawned ${sessionName}, but readiness check was cancelled. Session/logs were left intact at ${logPath}.`,
          }],
          isError: true,
          details,
        };
      }

      if (!readiness.ready) {
        recordFailure(circuit);
        logLifecycleEvent({
          timestamp: new Date().toISOString(),
          session_name: sessionName,
          event: "spawn_failed",
          stage: readiness.stage,
          ready_after_ms: readiness.readyAfterMs,
          error: "readiness_timeout",
        });
        return {
          content: [{
            type: "text",
            text:
              `Spawned ${sessionName}, but readiness check timed out after ${readyTimeoutSec}s ` +
              `(stage: ${readiness.stage}). Session/logs were left intact at ${logPath}.`,
          }],
          isError: true,
          details,
        };
      }

      recordSuccess(circuit);
      logLifecycleEvent({
        timestamp: new Date().toISOString(),
        session_name: sessionName,
        event: "spawn_success",
        stage: readiness.stage,
        ready_after_ms: readiness.readyAfterMs,
      });

      return {
        content: [{
          type: "text",
          text:
            `Spawned ${sessionName} and verified readiness via alias ${readyAlias} ` +
            `in ${readiness.readyAfterMs}ms.`,
        }],
        details,
      };
    },
  });

  // ── spawn_status tool ─────────────────────────────────────────────────────

  pi.registerTool({
    name: "spawn_status",
    label: "Spawn Status",
    description:
      "Check the agent_spawn circuit breaker state and recent worker lifecycle events.",
    parameters: Type.Object({}),
    async execute() {
      let recentEvents = "";
      try {
        if (existsSync(LIFECYCLE_LOG_PATH)) {
          const lines = readFileSync(LIFECYCLE_LOG_PATH, "utf-8")
            .trimEnd()
            .split("\n")
            .slice(-20);
          recentEvents = lines
            .map((line: string) => {
              try {
                const e = JSON.parse(line) as LifecycleEvent;
                return `  ${e.timestamp} ${e.event} ${e.session_name}${e.error ? ` (${e.error})` : ""}${e.ready_after_ms ? ` [${e.ready_after_ms}ms]` : ""}`;
              } catch {
                return `  (unparseable)`;
              }
            })
            .join("\n");
        }
      } catch {
        recentEvents = "  (no lifecycle log)";
      }

      return {
        content: [{
          type: "text" as const,
          text: [
            "Spawn Circuit Breaker:",
            `  ${circuitStatus(circuit)}`,
            "",
            "Recent lifecycle events:",
            recentEvents || "  (none)",
          ].join("\n"),
        }],
        details: {
          circuit: {
            state: circuit.state,
            consecutive_failures: circuit.consecutiveFailures,
            total_successes: circuit.totalSuccesses,
            total_failures: circuit.totalFailures,
          },
        },
      };
    },
  });
}
