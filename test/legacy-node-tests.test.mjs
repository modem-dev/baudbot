import { spawnSync } from "node:child_process";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, it, expect } from "vitest";

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");

function runNodeTest(relativePath) {
  const result = spawnSync("node", ["--test", relativePath], {
    cwd: repoRoot,
    encoding: "utf8",
    env: process.env,
  });

  if (result.status !== 0) {
    const output = [result.stdout, result.stderr].filter(Boolean).join("\n");
    throw new Error(`${relativePath} failed (exit ${result.status})\n${output}`);
  }
}

describe("legacy node:test suites", () => {
  it("tool-guard", () => {
    expect(() => runNodeTest("pi/extensions/tool-guard.test.mjs")).not.toThrow();
  });

  it("bridge security", () => {
    expect(() => runNodeTest("slack-bridge/security.test.mjs")).not.toThrow();
  });

  it("extension scanner", () => {
    expect(() => runNodeTest("bin/scan-extensions.test.mjs")).not.toThrow();
  });

  it("broker register", () => {
    expect(() => runNodeTest("bin/broker-register.test.mjs")).not.toThrow();
  });
});
