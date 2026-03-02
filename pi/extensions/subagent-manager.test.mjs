import { afterEach, describe, expect, it, vi } from "vitest";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import net from "node:net";
import { tmpdir } from "node:os";
import path from "node:path";
import subagentManagerExtension from "./subagent-manager.ts";

const SUBAGENTS_DIR_ENV = "BAUDBOT_SUBAGENTS_DIR";
const SUBAGENTS_STATE_FILE_ENV = "BAUDBOT_SUBAGENTS_STATE_FILE";
const SESSION_CONTROL_DIR_ENV = "PI_SESSION_CONTROL_DIR";

const ORIGINAL_SUBAGENTS_DIR = process.env[SUBAGENTS_DIR_ENV];
const ORIGINAL_SUBAGENTS_STATE = process.env[SUBAGENTS_STATE_FILE_ENV];
const ORIGINAL_CONTROL_DIR = process.env[SESSION_CONTROL_DIR_ENV];
const ORIGINAL_OPENAI_KEY = process.env.OPENAI_API_KEY;

function createHarness(execImpl) {
  let registered = null;
  const pi = {
    registerTool(tool) {
      registered = tool;
    },
    exec: execImpl,
  };
  subagentManagerExtension(pi);
  if (!registered) throw new Error("subagent_manage tool not registered");
  return registered;
}

function writeManifest(rootDir, manifest) {
  const packageDir = path.join(rootDir, manifest.id);
  mkdirSync(packageDir, { recursive: true });
  writeFileSync(path.join(packageDir, "subagent.json"), `${JSON.stringify(manifest, null, 2)}\n`, "utf-8");
  writeFileSync(path.join(packageDir, "SKILL.md"), "# Test Skill\n", "utf-8");
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

describe("subagent_manage extension tool", () => {
  const tempDirs = [];
  const servers = [];

  afterEach(async () => {
    for (const server of servers) {
      await new Promise((resolve) => server.close(() => resolve(undefined)));
    }
    servers.length = 0;

    for (const dir of tempDirs) {
      rmSync(dir, { recursive: true, force: true });
    }
    tempDirs.length = 0;

    if (ORIGINAL_SUBAGENTS_DIR === undefined) delete process.env[SUBAGENTS_DIR_ENV];
    else process.env[SUBAGENTS_DIR_ENV] = ORIGINAL_SUBAGENTS_DIR;

    if (ORIGINAL_SUBAGENTS_STATE === undefined) delete process.env[SUBAGENTS_STATE_FILE_ENV];
    else process.env[SUBAGENTS_STATE_FILE_ENV] = ORIGINAL_SUBAGENTS_STATE;

    if (ORIGINAL_CONTROL_DIR === undefined) delete process.env[SESSION_CONTROL_DIR_ENV];
    else process.env[SESSION_CONTROL_DIR_ENV] = ORIGINAL_CONTROL_DIR;

    if (ORIGINAL_OPENAI_KEY === undefined) delete process.env.OPENAI_API_KEY;
    else process.env.OPENAI_API_KEY = ORIGINAL_OPENAI_KEY;
  });

  it("lists discovered subagent packages", async () => {
    const root = mkdtempSync(path.join(tmpdir(), "subagent-manager-test-"));
    tempDirs.push(root);

    const subagentsDir = path.join(root, "subagents");
    const statePath = path.join(root, "subagents-state.json");
    mkdirSync(subagentsDir, { recursive: true });

    writeManifest(subagentsDir, {
      id: "sentry-agent",
      name: "Sentry Agent",
      description: "Incident triage agent",
      session_name: "sentry-agent",
      model_profile: "cheap_tier",
      autostart: true,
    });

    process.env[SUBAGENTS_DIR_ENV] = subagentsDir;
    process.env[SUBAGENTS_STATE_FILE_ENV] = statePath;

    const execSpy = vi.fn(async (command, args) => {
      if (command === "tmux" && args[0] === "has-session") {
        return { stdout: "", stderr: "", code: 1, killed: false };
      }
      return { stdout: "", stderr: "", code: 0, killed: false };
    });

    const tool = createHarness(execSpy);
    const result = await tool.execute("tool-call", { action: "list" }, undefined, undefined, {});

    expect(result.isError).not.toBe(true);
    expect(result.details.packages).toHaveLength(1);
    expect(result.details.packages[0].id).toBe("sentry-agent");
    expect(result.details.packages[0].autostart).toBe(true);
  });

  it("enable action writes state overrides", async () => {
    const root = mkdtempSync(path.join(tmpdir(), "subagent-manager-test-"));
    tempDirs.push(root);

    const subagentsDir = path.join(root, "subagents");
    const statePath = path.join(root, "subagents-state.json");
    mkdirSync(subagentsDir, { recursive: true });

    writeManifest(subagentsDir, {
      id: "sentry-agent",
      name: "Sentry Agent",
      description: "Incident triage agent",
      session_name: "sentry-agent",
      model_profile: "cheap_tier",
    });

    process.env[SUBAGENTS_DIR_ENV] = subagentsDir;
    process.env[SUBAGENTS_STATE_FILE_ENV] = statePath;

    const tool = createHarness(async () => ({ stdout: "", stderr: "", code: 0, killed: false }));
    const result = await tool.execute(
      "tool-call",
      { action: "enable", id: "sentry-agent" },
      undefined,
      undefined,
      {},
    );

    expect(result.isError).not.toBe(true);
    const state = JSON.parse(readFileSync(statePath, "utf-8"));
    expect(state.agents["sentry-agent"].installed).toBe(true);
    expect(state.agents["sentry-agent"].enabled).toBe(true);
  });

  it("reconcile starts missing autostart-enabled subagent", async () => {
    const root = mkdtempSync(path.join(tmpdir(), "subagent-manager-test-"));
    tempDirs.push(root);

    const subagentsDir = path.join(root, "subagents");
    const statePath = path.join(root, "subagents-state.json");
    const controlDir = path.join(root, "session-control");
    mkdirSync(subagentsDir, { recursive: true });
    mkdirSync(controlDir, { recursive: true });

    writeManifest(subagentsDir, {
      id: "sentry-agent",
      name: "Sentry Agent",
      description: "Incident triage agent",
      session_name: "sentry-agent",
      model_profile: "cheap_tier",
      autostart: true,
      ready_timeout_sec: 3,
    });

    process.env[SUBAGENTS_DIR_ENV] = subagentsDir;
    process.env[SUBAGENTS_STATE_FILE_ENV] = statePath;
    process.env[SESSION_CONTROL_DIR_ENV] = controlDir;
    process.env.OPENAI_API_KEY = "test-openai-key";

    const socketPath = path.join(controlDir, "sentry-agent.sock");
    const aliasPath = path.join(controlDir, "sentry-agent.alias");

    const execSpy = vi.fn(async (command, args) => {
      if (command === "tmux" && args[0] === "has-session") {
        return { stdout: "", stderr: "", code: 1, killed: false };
      }

      if (command === "tmux" && args[0] === "new-session") {
        const server = await startUnixSocketServer(socketPath);
        servers.push(server);
        symlinkSync(path.basename(socketPath), aliasPath);
        return { stdout: "", stderr: "", code: 0, killed: false };
      }

      return { stdout: "", stderr: "", code: 0, killed: false };
    });

    const tool = createHarness(execSpy);
    const result = await tool.execute(
      "tool-call",
      { action: "reconcile" },
      undefined,
      undefined,
      {},
    );

    expect(result.isError).not.toBe(true);
    expect(result.details.started).toHaveLength(1);
    expect(result.details.started[0].id).toBe("sentry-agent");
  });
});
