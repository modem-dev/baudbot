import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";
import { StringEnum } from "@mariozechner/pi-ai";
import { Type } from "@sinclair/typebox";
import { existsSync, mkdirSync, readlinkSync, statSync } from "node:fs";
import net from "node:net";
import { homedir } from "node:os";
import { dirname, join, resolve } from "node:path";
import {
  absolutePath,
  discoverSubagentPackages,
  ensureSubagentStateEntry,
  expandHomePath,
  readSubagentState,
  resolveEffectiveState,
  resolveModelForProfile,
  resolvePathInPackage,
  writeSubagentState,
  type SubagentPackage,
} from "./subagent-registry.ts";

const SESSION_CONTROL_DIR_ENV = "PI_SESSION_CONTROL_DIR";
const TMUX_SPAWN_TIMEOUT_MS = 15_000;
const TMUX_QUERY_TIMEOUT_MS = 4_000;
const SOCKET_PROBE_TIMEOUT_MS = 300;
const READINESS_POLL_MS = 200;

type SpawnStage = "spawn" | "wait_alias" | "wait_socket" | "probe" | "aborted";

type ReadinessResult = {
  ready: boolean;
  aborted: boolean;
  stage: SpawnStage;
  aliasPath: string;
  socketPath: string | null;
  readyAfterMs: number;
};

type RuntimeStatus = {
  session_name: string;
  alias_exists: boolean;
  socket_exists: boolean;
  socket_alive: boolean;
  tmux_running: boolean;
};

const ACTIONS = [
  "list",
  "status",
  "install",
  "uninstall",
  "enable",
  "disable",
  "autostart_on",
  "autostart_off",
  "start",
  "stop",
  "reconcile",
] as const;

type Action = (typeof ACTIONS)[number];

function controlDir(): string {
  const configured = process.env[SESSION_CONTROL_DIR_ENV]?.trim();
  if (configured) return resolve(expandHomePath(configured));
  return join(homedir(), ".pi", "session-control");
}

function shellQuote(value: string): string {
  return `'${value.replace(/'/g, `"'"'`)}'`;
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

    const timeout = setTimeout(() => finish(false), timeoutMs);
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

function resolveSkillPath(pkg: SubagentPackage): string | null {
  const skillPathRaw = pkg.manifest.skill_path.trim();
  if (skillPathRaw.startsWith("/") || skillPathRaw.startsWith("~")) {
    const skillPath = absolutePath(skillPathRaw);
    if (!existsSync(skillPath)) return null;
    return skillPath;
  }

  const resolved = resolvePathInPackage(pkg.root_dir, skillPathRaw);
  if (!resolved || !existsSync(resolved)) return null;
  return resolved;
}

function resolveCwdPath(pkg: SubagentPackage): string {
  const cwdRaw = pkg.manifest.cwd.trim();
  if (!cwdRaw) return absolutePath("~");

  if (cwdRaw.startsWith("/") || cwdRaw.startsWith("~")) {
    return absolutePath(cwdRaw);
  }

  const resolved = resolvePathInPackage(pkg.root_dir, cwdRaw);
  if (!resolved) return absolutePath("~");
  return resolved;
}

async function resolveRuntimeStatus(pi: ExtensionAPI, pkg: SubagentPackage): Promise<RuntimeStatus> {
  const socketDir = controlDir();
  const aliasPath = join(socketDir, `${pkg.manifest.ready_alias}.alias`);
  const aliasExists = existsSync(aliasPath);
  const socketPath = aliasExists ? resolveSocketPathFromAlias(aliasPath, socketDir) : null;
  const socketExists = !!socketPath && existsSync(socketPath);
  const socketAlive = socketExists && socketPath ? await isSocketAlive(socketPath, SOCKET_PROBE_TIMEOUT_MS) : false;

  let tmuxRunning = false;
  const tmuxResult = await pi.exec("tmux", ["has-session", "-t", pkg.manifest.session_name], {
    timeout: TMUX_QUERY_TIMEOUT_MS,
  });
  tmuxRunning = tmuxResult.code === 0;

  return {
    session_name: pkg.manifest.session_name,
    alias_exists: aliasExists,
    socket_exists: socketExists,
    socket_alive: socketAlive,
    tmux_running: tmuxRunning,
  };
}

function packageSummary(piPackages: SubagentPackage[], state: ReturnType<typeof readSubagentState>) {
  return piPackages.map((pkg) => {
    const effective = resolveEffectiveState(pkg, state);
    return {
      id: pkg.id,
      name: pkg.manifest.name,
      description: pkg.manifest.description,
      session_name: pkg.manifest.session_name,
      model_profile: pkg.manifest.model_profile,
      installed: effective.installed,
      enabled: effective.enabled,
      autostart: effective.autostart,
      package_root: pkg.root_dir,
    };
  });
}

async function startPackage(pi: ExtensionAPI, pkg: SubagentPackage, signal?: AbortSignal) {
  const modelResult = resolveModelForProfile(pkg.manifest);
  if (!modelResult.model) {
    return {
      ok: false,
      error: modelResult.error ?? `unable to resolve model for ${pkg.id}`,
    };
  }

  const cwdPath = resolveCwdPath(pkg);
  if (!existsSync(cwdPath) || !statSync(cwdPath).isDirectory()) {
    return {
      ok: false,
      error: `cwd does not exist: ${cwdPath}`,
    };
  }

  const skillPath = resolveSkillPath(pkg);
  if (!skillPath) {
    return {
      ok: false,
      error: `skill_path does not exist for ${pkg.id}`,
    };
  }

  const logPath = join(homedir(), ".pi", "agent", "logs", `spawn-${pkg.manifest.session_name}.log`);
  mkdirSync(dirname(logPath), { recursive: true });

  const tmuxCommand = [
    `cd ${shellQuote(cwdPath)}`,
    'export PATH="$HOME/.varlock/bin:$HOME/opt/node/bin:$PATH"',
    `export PI_SESSION_NAME=${shellQuote(pkg.manifest.session_name)}`,
    `exec varlock run --path "$HOME/.config/" -- pi --session-control --skill ${shellQuote(skillPath)} --model ${shellQuote(modelResult.model)} > ${shellQuote(logPath)} 2>&1`,
  ].join(" && ");

  const spawnResult = await pi.exec("tmux", ["new-session", "-d", "-s", pkg.manifest.session_name, tmuxCommand], {
    timeout: TMUX_SPAWN_TIMEOUT_MS,
    signal,
  });

  if (spawnResult.code !== 0) {
    return {
      ok: false,
      error: `tmux spawn failed for ${pkg.id}`,
      details: {
        stdout: spawnResult.stdout,
        stderr: spawnResult.stderr,
        exit_code: spawnResult.code,
      },
    };
  }

  const readiness = await waitForSessionReadiness(pkg.manifest.ready_alias, pkg.manifest.ready_timeout_sec, signal);
  if (!readiness.ready) {
    return {
      ok: false,
      error: readiness.aborted
        ? `readiness aborted for ${pkg.id}`
        : `readiness timeout for ${pkg.id} after ${pkg.manifest.ready_timeout_sec}s`,
      details: {
        stage: readiness.stage,
        alias_path: readiness.aliasPath,
        socket_path: readiness.socketPath,
        ready_after_ms: readiness.readyAfterMs,
        log_path: logPath,
      },
    };
  }

  return {
    ok: true,
    details: {
      session_name: pkg.manifest.session_name,
      ready_alias: pkg.manifest.ready_alias,
      model: modelResult.model,
      cwd: cwdPath,
      skill_path: skillPath,
      log_path: logPath,
      ready_after_ms: readiness.readyAfterMs,
    },
  };
}

async function stopPackage(pi: ExtensionAPI, pkg: SubagentPackage) {
  const result = await pi.exec("tmux", ["kill-session", "-t", pkg.manifest.session_name], {
    timeout: TMUX_QUERY_TIMEOUT_MS,
  });

  if (result.code !== 0) {
    return {
      ok: false,
      error: `tmux session ${pkg.manifest.session_name} not running`,
    };
  }

  return {
    ok: true,
    details: {
      session_name: pkg.manifest.session_name,
    },
  };
}

function requireId(action: Action, id: string | undefined): string | null {
  const needsId = action !== "list" && action !== "reconcile";
  if (!needsId) return null;
  const trimmed = id?.trim() ?? "";
  if (trimmed) return null;
  return `action ${action} requires id`;
}

export default function subagentManagerExtension(pi: ExtensionAPI): void {
  pi.registerTool({
    name: "subagent_manage",
    label: "Subagent Manager",
    description:
      "Manage built-in subagent packages (list/status/install/uninstall/enable/disable/autostart/start/stop/reconcile).",
    parameters: Type.Object({
      action: StringEnum(ACTIONS),
      id: Type.Optional(Type.String({ description: "Subagent id for non-list actions" })),
      ready_timeout_sec: Type.Optional(Type.Number({ minimum: 1, maximum: 60 })),
    }),
    async execute(_toolCallId, params, signal) {
      const action = params.action as Action;
      const id = typeof params.id === "string" ? params.id.trim() : undefined;

      const missingIdError = requireId(action, id);
      if (missingIdError) {
        return {
          content: [{ type: "text", text: missingIdError }],
          isError: true,
          details: { error: "missing_id", action },
        };
      }

      const discovery = discoverSubagentPackages();
      const state = readSubagentState();
      const pkgById = new Map(discovery.packages.map((pkg) => [pkg.id, pkg]));

      if (action === "list") {
        return {
          content: [{ type: "text", text: `Found ${discovery.packages.length} subagent package(s).` }],
          details: {
            packages: packageSummary(discovery.packages, state),
            diagnostics: discovery.diagnostics,
          },
        };
      }

      if (action === "reconcile") {
        const started: Array<Record<string, unknown>> = [];
        const skipped: Array<Record<string, unknown>> = [];
        const errors: Array<Record<string, unknown>> = [];

        for (const pkg of discovery.packages) {
          const effective = resolveEffectiveState(pkg, state);
          if (!effective.installed || !effective.enabled || !effective.autostart) {
            skipped.push({ id: pkg.id, reason: "not_autostart_enabled" });
            continue;
          }

          const runtime = await resolveRuntimeStatus(pi, pkg);
          if (runtime.socket_alive && runtime.tmux_running) {
            skipped.push({ id: pkg.id, reason: "already_running", runtime });
            continue;
          }

          const result = await startPackage(pi, pkg, signal);
          if (result.ok) {
            started.push({ id: pkg.id, ...result.details });
          } else {
            errors.push({ id: pkg.id, error: result.error, details: result.details ?? null });
          }
        }

        return {
          content: [{ type: "text", text: `Reconcile complete: started=${started.length}, skipped=${skipped.length}, errors=${errors.length}.` }],
          isError: errors.length > 0,
          details: {
            started,
            skipped,
            errors,
            diagnostics: discovery.diagnostics,
          },
        };
      }

      const pkg = id ? pkgById.get(id) : undefined;
      if (!pkg) {
        return {
          content: [{ type: "text", text: `Unknown subagent id: ${id}` }],
          isError: true,
          details: {
            error: "unknown_id",
            id,
            available: discovery.packages.map((entry) => entry.id),
          },
        };
      }

      const stateEntry = ensureSubagentStateEntry(state, pkg.id);
      const setTimeoutOverride = typeof params.ready_timeout_sec === "number" && Number.isFinite(params.ready_timeout_sec)
        ? Math.min(60, Math.max(1, Math.round(params.ready_timeout_sec)))
        : undefined;

      if (setTimeoutOverride !== undefined) {
        pkg.manifest.ready_timeout_sec = setTimeoutOverride;
      }

      switch (action) {
        case "status": {
          const runtime = await resolveRuntimeStatus(pi, pkg);
          const effective = resolveEffectiveState(pkg, state);
          return {
            content: [{ type: "text", text: `Status for ${pkg.id}: enabled=${effective.enabled}, running=${runtime.socket_alive && runtime.tmux_running}` }],
            details: {
              id: pkg.id,
              effective,
              runtime,
              diagnostics: discovery.diagnostics,
            },
          };
        }

        case "install": {
          stateEntry.installed = true;
          if (stateEntry.enabled === undefined) stateEntry.enabled = true;
          writeSubagentState(state);
          return {
            content: [{ type: "text", text: `Installed ${pkg.id}.` }],
            details: { id: pkg.id, state: stateEntry },
          };
        }

        case "uninstall": {
          stateEntry.installed = false;
          stateEntry.enabled = false;
          stateEntry.autostart = false;
          writeSubagentState(state);

          const stopResult = await stopPackage(pi, pkg);
          return {
            content: [{ type: "text", text: stopResult.ok ? `Uninstalled ${pkg.id} and stopped session.` : `Uninstalled ${pkg.id}. Session was not running.` }],
            details: {
              id: pkg.id,
              state: stateEntry,
              stop: stopResult,
            },
          };
        }

        case "enable": {
          stateEntry.installed = true;
          stateEntry.enabled = true;
          writeSubagentState(state);
          return {
            content: [{ type: "text", text: `Enabled ${pkg.id}.` }],
            details: { id: pkg.id, state: stateEntry },
          };
        }

        case "disable": {
          stateEntry.enabled = false;
          stateEntry.autostart = false;
          writeSubagentState(state);
          const stopResult = await stopPackage(pi, pkg);
          return {
            content: [{ type: "text", text: stopResult.ok ? `Disabled ${pkg.id} and stopped session.` : `Disabled ${pkg.id}. Session was not running.` }],
            details: {
              id: pkg.id,
              state: stateEntry,
              stop: stopResult,
            },
          };
        }

        case "autostart_on": {
          stateEntry.installed = true;
          stateEntry.enabled = true;
          stateEntry.autostart = true;
          writeSubagentState(state);
          return {
            content: [{ type: "text", text: `Autostart enabled for ${pkg.id}.` }],
            details: { id: pkg.id, state: stateEntry },
          };
        }

        case "autostart_off": {
          stateEntry.autostart = false;
          writeSubagentState(state);
          return {
            content: [{ type: "text", text: `Autostart disabled for ${pkg.id}.` }],
            details: { id: pkg.id, state: stateEntry },
          };
        }

        case "start": {
          const effective = resolveEffectiveState(pkg, state);
          if (!effective.installed || !effective.enabled) {
            return {
              content: [{ type: "text", text: `Cannot start ${pkg.id}: installed=${effective.installed}, enabled=${effective.enabled}.` }],
              isError: true,
              details: { id: pkg.id, effective },
            };
          }

          const runtime = await resolveRuntimeStatus(pi, pkg);
          if (runtime.socket_alive && runtime.tmux_running) {
            return {
              content: [{ type: "text", text: `${pkg.id} is already running.` }],
              details: { id: pkg.id, runtime },
            };
          }

          const startResult = await startPackage(pi, pkg, signal);
          return {
            content: [{ type: "text", text: startResult.ok ? `Started ${pkg.id}.` : `Failed to start ${pkg.id}: ${startResult.error}` }],
            isError: !startResult.ok,
            details: {
              id: pkg.id,
              result: startResult,
            },
          };
        }

        case "stop": {
          const stopResult = await stopPackage(pi, pkg);
          return {
            content: [{ type: "text", text: stopResult.ok ? `Stopped ${pkg.id}.` : `Failed to stop ${pkg.id}: ${stopResult.error}` }],
            isError: !stopResult.ok,
            details: {
              id: pkg.id,
              result: stopResult,
            },
          };
        }

        default: {
          return {
            content: [{ type: "text", text: `Unsupported action: ${action}` }],
            isError: true,
            details: { action },
          };
        }
      }
    },
  });
}
