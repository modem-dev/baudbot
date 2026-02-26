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

describe("github-events node:test suite", () => {
  it("github-events", () => {
    expect(() => runNodeTest("slack-bridge/github-events.test.mjs")).not.toThrow();
  });
});
