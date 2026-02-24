import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { afterEach, describe, expect, it } from "vitest";

const scriptPath = path.resolve("bin/checks/slack-allowed-users.mjs");
const tmpDirs = [];

function runCheck(envPath) {
  const result = spawnSync("node", [scriptPath, envPath], {
    cwd: path.resolve("."),
    encoding: "utf8",
  });

  expect(result.status).toBe(0);
  return JSON.parse(result.stdout);
}

afterEach(() => {
  for (const dir of tmpDirs.splice(0)) {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

describe("bin/checks/slack-allowed-users.mjs", () => {
  it("reports when env file is missing", () => {
    const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "baudbot-slack-users-check-"));
    tmpDirs.push(tmpDir);

    const payload = runCheck(path.join(tmpDir, ".env"));
    expect(payload.exists).toBe("0");
    expect(payload.defined).toBe("0");
    expect(payload.count).toBe("0");
  });

  it("reports configured users count", () => {
    const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "baudbot-slack-users-check-"));
    tmpDirs.push(tmpDir);

    const envPath = path.join(tmpDir, ".env");
    fs.writeFileSync(envPath, "SLACK_ALLOWED_USERS=U1,U2,U3\n");

    const payload = runCheck(envPath);
    expect(payload.exists).toBe("1");
    expect(payload.defined).toBe("1");
    expect(payload.raw_non_empty).toBe("1");
    expect(payload.count).toBe("3");
  });

  it("handles empty allowed users setting", () => {
    const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "baudbot-slack-users-check-"));
    tmpDirs.push(tmpDir);

    const envPath = path.join(tmpDir, ".env");
    fs.writeFileSync(envPath, "SLACK_ALLOWED_USERS=\n");

    const payload = runCheck(envPath);
    expect(payload.defined).toBe("1");
    expect(payload.raw_non_empty).toBe("0");
    expect(payload.count).toBe("0");
  });
});
