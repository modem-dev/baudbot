import { spawn } from "node:child_process";
import { describe, it, beforeEach, afterEach } from "vitest";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import os from "node:os";
import net from "node:net";

const REPO_ROOT = path.resolve(path.dirname(new URL(import.meta.url).pathname), "../..");
const SHIM_SCRIPT = path.join(REPO_ROOT, "pi/extensions/cli-session-shim.mjs");

let tmpDir = "";
let controlDir = "";
let tmuxLogPath = "";
let capturePath = "";
let tmuxScriptPath = "";
let unixSocketSupportCache = null;

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function createTempDir(prefix) {
  const roots = ["/tmp", os.tmpdir()];
  for (const root of roots) {
    try {
      return fs.mkdtempSync(path.join(root, prefix));
    } catch {
      // try next root
    }
  }
  throw new Error(`failed to create temp dir for prefix: ${prefix}`);
}

function setupFixture() {
  tmpDir = createTempDir("cli-shim-test-");
  controlDir = path.join(tmpDir, "session-control");
  tmuxLogPath = path.join(tmpDir, "tmux.log");
  capturePath = path.join(tmpDir, "capture.txt");
  tmuxScriptPath = path.join(tmpDir, "fake-tmux.sh");

  fs.mkdirSync(controlDir, { recursive: true });
  fs.writeFileSync(tmuxLogPath, "", "utf8");
  fs.writeFileSync(capturePath, "", "utf8");

  fs.writeFileSync(
    tmuxScriptPath,
    `#!/usr/bin/env bash
set -euo pipefail
log_file="${tmuxLogPath}"
capture_file="${capturePath}"
cmd="\${1:-}"
if [ -z "$cmd" ]; then
  exit 1
fi
if [ "$cmd" = "send-keys" ]; then
  shift
  if [ "$1" = "-t" ]; then
    shift 2
  fi
  if [ "\${1:-}" = "-l" ]; then
    shift
  fi
  message="\${1:-}"
  if [ "$message" = "C-c" ]; then
    printf '%s\\n' "abort" >> "$log_file"
  elif [ "$message" = "Enter" ]; then
    printf '%s\\n' "enter" >> "$log_file"
  else
    printf '%s\\n' "send:$message" >> "$log_file"
  fi
  exit 0
fi
if [ "$cmd" = "kill-session" ]; then
  printf '%s\\n' "kill-session" >> "$log_file"
  exit 0
fi
if [ "$cmd" = "capture-pane" ]; then
  cat "$capture_file"
  exit 0
fi
printf '%s\\n' "unexpected:$cmd" >> "$log_file"
exit 1
`,
    "utf8",
  );
  fs.chmodSync(tmuxScriptPath, 0o755);
}

function teardownFixture() {
  if (tmpDir) {
    fs.rmSync(tmpDir, { recursive: true, force: true });
    tmpDir = "";
    controlDir = "";
    tmuxLogPath = "";
    capturePath = "";
    tmuxScriptPath = "";
  }
}

async function startShim({ sessionId, sessionName }) {
  const shim = spawn(
    "node",
    [
      SHIM_SCRIPT,
      "--session-id",
      sessionId,
      "--session-name",
      sessionName,
      "--tmux-session",
      sessionName,
      "--control-dir",
      controlDir,
      "--turn-end-delay-ms",
      "100",
      "--capture-lines",
      "80",
      "--tmux-bin",
      tmuxScriptPath,
    ],
    {
      cwd: REPO_ROOT,
      env: process.env,
      stdio: ["ignore", "pipe", "pipe"],
    },
  );

  let stdout = "";
  let stderr = "";
  shim.stdout.on("data", (chunk) => {
    stdout += chunk.toString();
  });
  shim.stderr.on("data", (chunk) => {
    stderr += chunk.toString();
  });

  const socketPath = path.join(controlDir, `${sessionId}.sock`);
  const aliasPath = path.join(controlDir, `${sessionName}.alias`);

  for (let i = 0; i < 80; i += 1) {
    if (fs.existsSync(socketPath) && fs.existsSync(aliasPath)) {
      return { shim, socketPath, aliasPath };
    }

    if (shim.exitCode != null) {
      throw new Error(`shim exited early: code=${shim.exitCode} stdout=${stdout} stderr=${stderr}`);
    }

    await sleep(50);
  }

  throw new Error(`shim failed to start: stdout=${stdout} stderr=${stderr}`);
}

async function stopShim(shim) {
  if (!shim || shim.exitCode != null) return;

  shim.kill("SIGTERM");
  await new Promise((resolve) => {
    const timer = setTimeout(() => {
      if (shim.exitCode == null) {
        shim.kill("SIGKILL");
      }
      resolve(undefined);
    }, 2000);

    shim.once("exit", () => {
      clearTimeout(timer);
      resolve(undefined);
    });
  });
}

async function unixSocketsAvailable() {
  if (unixSocketSupportCache != null) {
    return unixSocketSupportCache;
  }

  const probePath = path.join(tmpDir, "probe.sock");
  unixSocketSupportCache = await new Promise((resolve) => {
    const server = net.createServer();
    server.once("error", () => resolve(false));
    server.listen(probePath, () => {
      server.close(() => {
        try {
          fs.unlinkSync(probePath);
        } catch {
          // ignore
        }
        resolve(true);
      });
    });
  });
  return unixSocketSupportCache;
}

function sendRpc(socketPath, command, options = {}) {
  const waitForEvent = options.waitForEvent === true;

  return new Promise((resolve, reject) => {
    const socket = net.createConnection(socketPath);
    socket.setEncoding("utf8");

    const timeout = setTimeout(() => {
      socket.destroy(new Error("timeout"));
    }, 5000);

    let buffer = "";
    let response = null;

    const cleanup = () => {
      clearTimeout(timeout);
      socket.removeAllListeners();
    };

    socket.on("connect", () => {
      socket.write(`${JSON.stringify(command)}\n`);
      if (waitForEvent) {
        socket.write(`${JSON.stringify({ type: "subscribe", event: "turn_end" })}\n`);
      }
    });

    socket.on("data", (chunk) => {
      buffer += chunk;
      let idx = buffer.indexOf("\n");
      while (idx !== -1) {
        const line = buffer.slice(0, idx).trim();
        buffer = buffer.slice(idx + 1);
        idx = buffer.indexOf("\n");
        if (!line) continue;

        const parsed = JSON.parse(line);
        if (parsed.type === "response" && parsed.command === command.type) {
          response = parsed;
          if (!waitForEvent) {
            cleanup();
            socket.end();
            resolve({ response });
            return;
          }
          continue;
        }

        if (waitForEvent && parsed.type === "event" && parsed.event === "turn_end") {
          cleanup();
          socket.end();
          resolve({ response, event: parsed });
          return;
        }
      }
    });

    socket.on("error", (error) => {
      cleanup();
      reject(error);
    });
  });
}

async function hasActiveDevAgentsLikeIdleCompact(controlRoot) {
  const entries = fs.readdirSync(controlRoot, { withFileTypes: true });
  for (const entry of entries) {
    if (!entry.name.endsWith(".alias")) continue;
    const aliasName = entry.name.slice(0, -".alias".length);
    if (!aliasName.startsWith("dev-agent-")) continue;

    const target = fs.readlinkSync(path.join(controlRoot, entry.name));
    const socketPath = path.join(controlRoot, target);

    const alive = await new Promise((resolve) => {
      const socket = net.createConnection(socketPath);
      const timer = setTimeout(() => {
        socket.destroy();
        resolve(false);
      }, 300);
      socket.once("connect", () => {
        clearTimeout(timer);
        socket.end();
        resolve(true);
      });
      socket.once("error", () => {
        clearTimeout(timer);
        resolve(false);
      });
    });

    if (alive) return true;
  }

  return false;
}

describe("cli-session-shim", () => {
  beforeEach(setupFixture);
  afterEach(teardownFixture);

  it("creates and cleans up socket + alias", async () => {
    if (!(await unixSocketsAvailable())) return;

    const sessionId = "11111111-1111-4111-8111-111111111111";
    const sessionName = "dev-agent-myapp-aaaa1111";
    const { shim, socketPath, aliasPath } = await startShim({ sessionId, sessionName });

    assert.ok(fs.existsSync(socketPath), "socket should exist");
    assert.ok(fs.existsSync(aliasPath), "alias should exist");
    assert.equal(fs.readlinkSync(aliasPath), `${sessionId}.sock`);

    await stopShim(shim);

    assert.ok(!fs.existsSync(socketPath), "socket should be removed on shutdown");
    assert.ok(!fs.existsSync(aliasPath), "alias should be removed on shutdown");
  });

  it("handles send/get_message/get_summary/abort/clear", async () => {
    if (!(await unixSocketsAvailable())) return;

    const sessionId = "22222222-2222-4222-8222-222222222222";
    const sessionName = "dev-agent-myapp-bbbb2222";
    const { shim, socketPath } = await startShim({ sessionId, sessionName });

    fs.writeFileSync(capturePath, "Assistant: waiting for task\n", "utf8");

    const withEvent = await sendRpc(
      socketPath,
      {
        type: "send",
        message: "Implement fix\n\n<sender_info>{\"sessionName\":\"control-agent\"}</sender_info>",
        mode: "follow_up",
      },
      { waitForEvent: true },
    );

    assert.equal(withEvent.response.success, true);
    assert.equal(withEvent.event.type, "event");

    const tmuxLog = fs.readFileSync(tmuxLogPath, "utf8");
    assert.ok(tmuxLog.includes("send:Implement fix"), "message should be delivered to tmux");
    assert.ok(!tmuxLog.includes("sender_info"), "sender_info tag should be stripped before tmux delivery");

    fs.writeFileSync(capturePath, "Updated output line\nSecond line\n", "utf8");

    const getMessage = await sendRpc(socketPath, { type: "get_message" });
    assert.equal(getMessage.response.success, true);
    assert.ok(getMessage.response.data.message.content.includes("Updated output line"));

    const getSummary = await sendRpc(socketPath, { type: "get_summary" });
    assert.equal(getSummary.response.success, true);
    assert.ok(getSummary.response.data.summary.includes("CLI output snapshot"));

    const abortResult = await sendRpc(socketPath, { type: "abort" });
    assert.equal(abortResult.response.success, true);

    const afterAbortLog = fs.readFileSync(tmuxLogPath, "utf8");
    assert.ok(afterAbortLog.includes("abort"), "abort should send Ctrl+C to tmux");

    const clearResult = await sendRpc(socketPath, { type: "clear" });
    assert.equal(clearResult.response.success, false);
    assert.ok(clearResult.response.error.includes("not supported"));

    await stopShim(shim);
  });

  it("supports optional abort escalation to tmux kill-session", async () => {
    if (!(await unixSocketsAvailable())) return;

    const sessionId = "44444444-4444-4444-8444-444444444444";
    const sessionName = "dev-agent-myapp-dddd4444";
    const { shim, socketPath } = await startShim({ sessionId, sessionName });

    const abortResult = await sendRpc(socketPath, {
      type: "abort",
      hard: true,
      hardKillAfterMs: 50,
    });
    assert.equal(abortResult.response.success, true);

    await sleep(120);
    const tmuxLog = fs.readFileSync(tmuxLogPath, "utf8");
    assert.ok(tmuxLog.includes("kill-session"), "hard abort should escalate to tmux kill-session");

    await stopShim(shim);
  });

  it("is visible to idle-compact style dev-agent detection via alias+socket", async () => {
    if (!(await unixSocketsAvailable())) return;

    const sessionId = "33333333-3333-4333-8333-333333333333";
    const sessionName = "dev-agent-myapp-cccc3333";
    const { shim } = await startShim({ sessionId, sessionName });

    const detected = await hasActiveDevAgentsLikeIdleCompact(controlDir);
    assert.equal(detected, true);

    await stopShim(shim);
  });
});
