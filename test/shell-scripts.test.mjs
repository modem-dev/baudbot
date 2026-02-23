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

  it("json helper", () => {
    expect(() => runScript("bin/lib/json-common.test.sh")).not.toThrow();
  });

  it("deploy helpers", () => {
    expect(() => runScript("bin/lib/deploy-common.test.sh")).not.toThrow();
  });

  it("doctor helpers", () => {
    expect(() => runScript("bin/lib/doctor-common.test.sh")).not.toThrow();
  });

  it("remote common helpers", () => {
    expect(() => runScript("bin/lib/remote-common.test.sh")).not.toThrow();
  });

  it("remote ssh helpers", () => {
    expect(() => runScript("bin/lib/remote-ssh.test.sh")).not.toThrow();
  });

  it("remote hetzner adapter", () => {
    expect(() => runScript("bin/lib/remote-hetzner.test.sh")).not.toThrow();
  });

  it("baudbot cli", () => {
    expect(() => runScript("bin/baudbot.test.sh")).not.toThrow();
  });

  it("remote cli", () => {
    expect(() => runScript("bin/remote.test.sh")).not.toThrow();
  });

  it("cli agent runner helpers", () => {
    expect(() => runScript("pi/skills/control-agent/scripts/run-cli-agent.test.sh")).not.toThrow();
  });

});
