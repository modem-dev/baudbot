import { spawnSync } from "node:child_process";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, it, expect } from "vitest";

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");

function runScript(relativePath) {
  const result = spawnSync("bash", [relativePath], {
    cwd: repoRoot,
    encoding: "utf8",
    env: process.env,
  });

  if (result.status !== 0) {
    const output = [result.stdout, result.stderr].filter(Boolean).join("\n");
    throw new Error(`${relativePath} failed (exit ${result.status})\n${output}`);
  }
}

describe("shell script test suites", () => {
  it("baudbot-safe-bash deny list", () => {
    expect(() => runScript("bin/baudbot-safe-bash.test.sh")).not.toThrow();
  });

  it("redact-logs", () => {
    expect(() => runScript("bin/redact-logs.test.sh")).not.toThrow();
  });

  it("env helper", () => {
    expect(() => runScript("bin/env.test.sh")).not.toThrow();
  });

});
