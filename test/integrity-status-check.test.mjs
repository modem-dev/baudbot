import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { afterEach, describe, expect, it } from "vitest";

const scriptPath = path.resolve("bin/checks/integrity-status.mjs");

const tmpDirs = [];

function runCheck(statusPath) {
  const result = spawnSync("node", [scriptPath, statusPath], {
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

describe("bin/checks/integrity-status.mjs", () => {
  it("reports missing status file", () => {
    const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "baudbot-integrity-check-"));
    tmpDirs.push(tmpDir);

    const payload = runCheck(path.join(tmpDir, "missing.json"));
    expect(payload.exists).toBe("0");
    expect(payload.status).toBe("missing");
  });

  it("normalizes valid status payload", () => {
    const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "baudbot-integrity-check-"));
    tmpDirs.push(tmpDir);

    const statusPath = path.join(tmpDir, "status.json");
    fs.writeFileSync(
      statusPath,
      JSON.stringify({
        status: "warn",
        checked_at: "2026-02-24T00:00:00Z",
        missing_files: 2,
        hash_mismatches: 1,
      }),
    );

    const payload = runCheck(statusPath);
    expect(payload.exists).toBe("1");
    expect(payload.status).toBe("warn");
    expect(payload.checked_at).toBe("2026-02-24T00:00:00Z");
    expect(payload.missing_files).toBe("2");
    expect(payload.hash_mismatches).toBe("1");
  });

  it("handles invalid JSON safely", () => {
    const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "baudbot-integrity-check-"));
    tmpDirs.push(tmpDir);

    const statusPath = path.join(tmpDir, "status.json");
    fs.writeFileSync(statusPath, "{not-json");

    const payload = runCheck(statusPath);
    expect(payload.exists).toBe("1");
    expect(payload.ok).toBe("0");
    expect(payload.error).toBe("parse_error");
  });
});
