import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";
import { Type } from "@sinclair/typebox";
import { existsSync, mkdirSync, readlinkSync, statSync } from "node:fs";
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

type SpawnStage = "spawn" | "wait_alias" | "wait_socket" | "probe" | "aborted";

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
  pi.registerTool({
    name: "agent_spawn",
    label: "Agent Spawn",
    description:
      "Spawn a pi session in tmux and verify readiness through session-control alias/socket with a bounded timeout.",
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
      };

      if (readiness.aborted) {
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
}
