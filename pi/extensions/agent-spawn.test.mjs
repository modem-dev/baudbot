import { afterEach, describe, expect, it, vi } from "vitest";
import { existsSync, mkdirSync, mkdtempSync, rmSync, symlinkSync, unlinkSync } from "node:fs";
import net from "node:net";
import { tmpdir } from "node:os";
import path from "node:path";
import agentSpawnExtension from "./agent-spawn.ts";

const CONTROL_DIR_ENV = "PI_SESSION_CONTROL_DIR";
const ORIGINAL_CONTROL_DIR = process.env[CONTROL_DIR_ENV];

function randomId() {
  return Math.random().toString(16).slice(2, 10);
}

function createExtensionHarness(execImpl) {
  const registeredTools = {};
  const pi = {
    registerTool(tool) {
      registeredTools[tool.name] = tool;
    },
    exec: execImpl,
  };
  agentSpawnExtension(pi);
  if (!registeredTools.agent_spawn) throw new Error("agent_spawn tool was not registered");
  return registeredTools.agent_spawn;
}

function startUnixSocketServer(socketPath) {
  return new Promise((resolve, reject) => {
    const server = net.createServer((client) => {
      client.end();
    });

    const onError = (err) => {
      server.close();
      reject(err);
    };

    server.once("error", onError);
    server.listen(socketPath, () => {
      server.off("error", onError);
      resolve(server);
    });
  });
}

describe("agent_spawn extension tool", () => {
  const tempDirs = [];
  const servers = [];
  const cleanupPaths = [];

  afterEach(async () => {
    for (const server of servers) {
      await new Promise((resolve) => server.close(() => resolve(undefined)));
    }
    servers.length = 0;

    for (const p of cleanupPaths) {
      try {
        if (existsSync(p)) unlinkSync(p);
      } catch {
        // Ignore cleanup failures.
      }
    }
    cleanupPaths.length = 0;

    for (const dir of tempDirs) {
      rmSync(dir, { recursive: true, force: true });
    }
    tempDirs.length = 0;

    if (ORIGINAL_CONTROL_DIR === undefined) {
      delete process.env[CONTROL_DIR_ENV];
    } else {
      process.env[CONTROL_DIR_ENV] = ORIGINAL_CONTROL_DIR;
    }
  });

  it("spawns and reports ready when alias/socket becomes available", async () => {
    const root = mkdtempSync(path.join(tmpdir(), "agent-spawn-test-"));
    tempDirs.push(root);
    const worktree = path.join(root, "worktree");
    const skillPath = path.join(root, "dev-skill");
    const controlDir = path.join(root, "session-control");
    process.env[CONTROL_DIR_ENV] = controlDir;
    mkdirSync(worktree, { recursive: true });
    mkdirSync(skillPath, { recursive: true });
    mkdirSync(controlDir, { recursive: true });

    const sessionName = `dev-agent-test-${randomId()}`;
    const aliasPath = path.join(controlDir, `${sessionName}.alias`);
    const socketPath = path.join(controlDir, `${sessionName}.sock`);
    cleanupPaths.push(aliasPath, socketPath);

    const execSpy = vi.fn(async (command, args) => {
      expect(command).toBe("tmux");
      expect(args.slice(0, 4)).toEqual(["new-session", "-d", "-s", sessionName]);
      expect(args[4]).toContain(`export PI_SESSION_NAME='${sessionName}'`);
      expect(args[4]).toContain("--session-control");
      expect(args[4]).toContain(`--skill '${skillPath}'`);
      expect(args[4]).toContain("--model 'anthropic/claude-opus-4-6'");

      const server = await startUnixSocketServer(socketPath);
      servers.push(server);
      symlinkSync(path.basename(socketPath), aliasPath);
      return { stdout: "", stderr: "", code: 0, killed: false };
    });

    const tool = createExtensionHarness(execSpy);
    const result = await tool.execute(
      "tool-call-id",
      {
        session_name: sessionName,
        cwd: worktree,
        skill_path: skillPath,
        model: "anthropic/claude-opus-4-6",
        ready_timeout_sec: 5,
      },
      undefined,
      undefined,
      {},
    );

    expect(result.isError).not.toBe(true);
    expect(result.details.spawned).toBe(true);
    expect(result.details.ready).toBe(true);
    expect(result.details.session_name).toBe(sessionName);
    expect(result.details.ready_alias).toBe(sessionName);
    expect(result.details.alias_path).toBe(aliasPath);
    expect(result.details.socket_path).toBe(socketPath);
    expect(execSpy).toHaveBeenCalledTimes(1);
  });

  it("returns readiness timeout and does not issue cleanup commands", async () => {
    const root = mkdtempSync(path.join(tmpdir(), "agent-spawn-test-"));
    tempDirs.push(root);
    const worktree = path.join(root, "worktree");
    const skillPath = path.join(root, "dev-skill");
    const controlDir = path.join(root, "session-control");
    process.env[CONTROL_DIR_ENV] = controlDir;
    mkdirSync(worktree, { recursive: true });
    mkdirSync(skillPath, { recursive: true });
    mkdirSync(controlDir, { recursive: true });

    const sessionName = `dev-agent-timeout-${randomId()}`;
    const calls = [];
    const execSpy = vi.fn(async (command, args) => {
      calls.push([command, args]);
      return { stdout: "", stderr: "", code: 0, killed: false };
    });

    const tool = createExtensionHarness(execSpy);
    const result = await tool.execute(
      "tool-call-id",
      {
        session_name: sessionName,
        cwd: worktree,
        skill_path: skillPath,
        model: "anthropic/claude-opus-4-6",
        ready_timeout_sec: 1,
      },
      undefined,
      undefined,
      {},
    );

    expect(result.isError).toBe(true);
    expect(result.details.spawned).toBe(true);
    expect(result.details.ready).toBe(false);
    expect(result.details.error).toBe("readiness_timeout");
    expect(calls).toHaveLength(1);
    expect(calls[0][0]).toBe("tmux");
    expect(String(result.content[0].text)).toContain("left intact");
  });

  it("rejects invalid session_name before executing tmux", async () => {
    const root = mkdtempSync(path.join(tmpdir(), "agent-spawn-test-"));
    tempDirs.push(root);
    const worktree = path.join(root, "worktree");
    const skillPath = path.join(root, "dev-skill");
    const controlDir = path.join(root, "session-control");
    process.env[CONTROL_DIR_ENV] = controlDir;
    mkdirSync(worktree, { recursive: true });
    mkdirSync(skillPath, { recursive: true });
    mkdirSync(controlDir, { recursive: true });

    const execSpy = vi.fn(async () => ({ stdout: "", stderr: "", code: 0, killed: false }));
    const tool = createExtensionHarness(execSpy);
    const result = await tool.execute(
      "tool-call-id",
      {
        session_name: "bad name",
        cwd: worktree,
        skill_path: skillPath,
        model: "anthropic/claude-opus-4-6",
      },
      undefined,
      undefined,
      {},
    );

    expect(result.isError).toBe(true);
    expect(String(result.content[0].text)).toContain("Invalid session_name");
    expect(execSpy).not.toHaveBeenCalled();
  });

  it("honors abort signal while waiting for readiness", async () => {
    const root = mkdtempSync(path.join(tmpdir(), "agent-spawn-test-"));
    tempDirs.push(root);
    const worktree = path.join(root, "worktree");
    const skillPath = path.join(root, "dev-skill");
    const controlDir = path.join(root, "session-control");
    process.env[CONTROL_DIR_ENV] = controlDir;
    mkdirSync(worktree, { recursive: true });
    mkdirSync(skillPath, { recursive: true });
    mkdirSync(controlDir, { recursive: true });

    const sessionName = `dev-agent-abort-${randomId()}`;
    const execSpy = vi.fn(async () => ({ stdout: "", stderr: "", code: 0, killed: false }));
    const tool = createExtensionHarness(execSpy);

    const controller = new AbortController();
    const abortTimer = setTimeout(() => controller.abort(), 25);
    const startedAt = Date.now();
    const result = await tool.execute(
      "tool-call-id",
      {
        session_name: sessionName,
        cwd: worktree,
        skill_path: skillPath,
        model: "anthropic/claude-opus-4-6",
        ready_timeout_sec: 60,
      },
      controller.signal,
      undefined,
      {},
    );
    clearTimeout(abortTimer);

    expect(result.isError).toBe(true);
    expect(result.details.error).toBe("readiness_aborted");
    expect(result.details.aborted).toBe(true);
    expect(Date.now() - startedAt).toBeLessThan(1000);
  });

  it("opens circuit breaker after 3 consecutive failures", async () => {
    const root = mkdtempSync(path.join(tmpdir(), "agent-spawn-test-"));
    tempDirs.push(root);
    const worktree = path.join(root, "worktree");
    const skillPath = path.join(root, "dev-skill");
    const controlDir = path.join(root, "session-control");
    process.env[CONTROL_DIR_ENV] = controlDir;
    mkdirSync(worktree, { recursive: true });
    mkdirSync(skillPath, { recursive: true });
    mkdirSync(controlDir, { recursive: true });

    // Spawns succeed at tmux level but readiness always times out (1s timeout)
    const execSpy = vi.fn(async () => ({ stdout: "", stderr: "", code: 0, killed: false }));
    const tool = createExtensionHarness(execSpy);

    const params = {
      session_name: `dev-agent-circuit-${randomId()}`,
      cwd: worktree,
      skill_path: skillPath,
      model: "anthropic/claude-opus-4-6",
      ready_timeout_sec: 1,
    };

    // Fail 3 times (readiness timeout)
    for (let i = 0; i < 3; i++) {
      params.session_name = `dev-agent-circuit-${randomId()}`;
      const result = await tool.execute("id", params, undefined, undefined, {});
      expect(result.isError).toBe(true);
      expect(result.details.error).toBe("readiness_timeout");
    }

    // 4th attempt should be rejected by circuit breaker
    params.session_name = `dev-agent-circuit-${randomId()}`;
    const rejected = await tool.execute("id", params, undefined, undefined, {});
    expect(rejected.isError).toBe(true);
    expect(rejected.details.error).toBe("circuit_open");
    expect(String(rejected.content[0].text)).toContain("Circuit breaker OPEN");
  });

  it("exposes spawn_status tool", () => {
    const registeredTools = {};
    const pi = {
      registerTool(tool) {
        registeredTools[tool.name] = tool;
      },
      exec: async () => ({ stdout: "", stderr: "", code: 0 }),
    };
    agentSpawnExtension(pi);
    expect(registeredTools.spawn_status).toBeDefined();
    expect(registeredTools.spawn_status.name).toBe("spawn_status");
  });
});
