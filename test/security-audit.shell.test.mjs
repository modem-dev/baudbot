import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import net from "node:net";
import { describe, it, beforeEach, afterEach, expect } from "vitest";

const scriptPath = path.resolve("bin/security-audit.sh");

let tmpRoot = "";

function setupFixture(homeDir) {
  fs.mkdirSync(path.join(homeDir, ".config"), { recursive: true });
  fs.mkdirSync(path.join(homeDir, ".ssh"), { recursive: true });
  fs.mkdirSync(path.join(homeDir, ".pi/agent"), { recursive: true });
  fs.mkdirSync(path.join(homeDir, "opt/baudbot/current/slack-bridge"), { recursive: true });
  fs.mkdirSync(path.join(homeDir, "baudbot/.git/hooks"), { recursive: true });
  fs.mkdirSync(path.join(homeDir, "logs"), { recursive: true });

  fs.writeFileSync(path.join(homeDir, ".config/.env"), "SLACK_BOT_TOKEN=xoxb-test\n");
  fs.chmodSync(path.join(homeDir, ".config/.env"), 0o600);
  fs.chmodSync(path.join(homeDir, ".ssh"), 0o700);
  fs.chmodSync(path.join(homeDir, ".pi"), 0o700);
  fs.chmodSync(path.join(homeDir, ".pi/agent"), 0o700);

  fs.writeFileSync(path.join(homeDir, "baudbot/.gitignore"), ".env\n");
  fs.writeFileSync(path.join(homeDir, "baudbot/.git/HEAD"), "ref: refs/heads/main\n");
  fs.writeFileSync(
    path.join(homeDir, ".pi/agent/baudbot-version.json"),
    JSON.stringify({ short: "testsha", deployed_at: "2026-01-01T00:00:00Z" }),
  );
  fs.writeFileSync(path.join(homeDir, "opt/baudbot/current/slack-bridge/security.mjs"), "// security\n");
  fs.writeFileSync(path.join(homeDir, "opt/baudbot/current/slack-bridge/security.test.mjs"), "// tests\n");
  fs.writeFileSync(path.join(homeDir, "logs/commands.log"), "");
}

function runAudit(homeDir, args = []) {
  const result = spawnSync("bash", [scriptPath, ...args], {
    cwd: path.resolve("."),
    encoding: "utf8",
    env: {
      ...process.env,
      BAUDBOT_HOME: homeDir,
      BAUDBOT_SRC: path.join(homeDir, "baudbot"),
      BAUDBOT_AGENT_USER: "baudbot_agent",
      BAUDBOT_RELEASE_ROOT: path.join(homeDir, "opt/baudbot"),
    },
  });

  return {
    status: result.status,
    output: `${result.stdout || ""}\n${result.stderr || ""}`,
  };
}

async function runAuditWithLocalBridge(homeDir, args = []) {
  return await new Promise((resolve, reject) => {
    const server = net.createServer((socket) => socket.end());

    const closeAndResolve = (result) => {
      server.close(() => resolve(result));
    };

    server.on("error", (err) => {
      if (err && err.code === "EADDRINUSE") {
        resolve(runAudit(homeDir, args));
        return;
      }
      reject(err);
    });

    server.listen(7890, "127.0.0.1", () => {
      closeAndResolve(runAudit(homeDir, args));
    });
  });
}

describe("security-audit.sh", () => {
  beforeEach(() => {
    tmpRoot = fs.mkdtempSync(path.join(os.tmpdir(), "baudbot-security-audit-"));
  });

  afterEach(() => {
    if (tmpRoot) {
      fs.rmSync(tmpRoot, { recursive: true, force: true });
      tmpRoot = "";
    }
  });

  it("reports missing SLACK_ALLOWED_USERS when unset", async () => {
    setupFixture(tmpRoot);

    const { output } = await runAuditWithLocalBridge(tmpRoot);
    expect(output).toContain("SLACK_ALLOWED_USERS not set");
  });

  it("reports configured SLACK_ALLOWED_USERS when set", async () => {
    setupFixture(tmpRoot);
    fs.appendFileSync(path.join(tmpRoot, ".config/.env"), "SLACK_ALLOWED_USERS=U12345\n");

    const { output } = await runAuditWithLocalBridge(tmpRoot);
    expect(output).toContain("SLACK_ALLOWED_USERS configured");
  });

  it("--fix tightens secret file permissions", () => {
    setupFixture(tmpRoot);
    fs.appendFileSync(path.join(tmpRoot, ".config/.env"), "SLACK_ALLOWED_USERS=U12345\n");
    fs.chmodSync(path.join(tmpRoot, ".config/.env"), 0o644);

    runAudit(tmpRoot, ["--fix"]);

    const mode = fs.statSync(path.join(tmpRoot, ".config/.env")).mode & 0o777;
    expect(mode).toBe(0o600);
  });
});
