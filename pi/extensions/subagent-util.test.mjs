import { afterEach, describe, expect, it, vi } from "vitest";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import subagentUtilExtension from "./subagent-util.ts";

const SUBAGENTS_DIR_ENV = "BAUDBOT_SUBAGENTS_DIR";
const SUBAGENTS_STATE_FILE_ENV = "BAUDBOT_SUBAGENTS_STATE_FILE";

const ORIGINAL_SUBAGENTS_DIR = process.env[SUBAGENTS_DIR_ENV];
const ORIGINAL_SUBAGENTS_STATE = process.env[SUBAGENTS_STATE_FILE_ENV];

function createHarness(execImpl) {
  let registered = null;
  const pi = {
    registerTool(tool) {
      registered = tool;
    },
    exec: execImpl,
  };
  subagentUtilExtension(pi);
  if (!registered) throw new Error("subagent_util tool not registered");
  return registered;
}

function writeManifest(rootDir, manifest) {
  const packageDir = path.join(rootDir, manifest.id);
  const utilDir = path.join(packageDir, "utilities");
  mkdirSync(utilDir, { recursive: true });

  writeFileSync(path.join(packageDir, "subagent.json"), `${JSON.stringify(manifest, null, 2)}\n`, "utf-8");
  writeFileSync(path.join(packageDir, "SKILL.md"), "# Test Skill\n", "utf-8");
  writeFileSync(
    path.join(utilDir, "echo-args.sh"),
    [
      "#!/usr/bin/env bash",
      "set -euo pipefail",
      "echo \"utility ok\"",
      "echo \"$SUBAGENT_UTIL_ARGS_B64\"",
    ].join("\n") + "\n",
    "utf-8",
  );
}

describe("subagent_util extension tool", () => {
  const tempDirs = [];

  afterEach(() => {
    for (const dir of tempDirs) {
      rmSync(dir, { recursive: true, force: true });
    }
    tempDirs.length = 0;

    if (ORIGINAL_SUBAGENTS_DIR === undefined) delete process.env[SUBAGENTS_DIR_ENV];
    else process.env[SUBAGENTS_DIR_ENV] = ORIGINAL_SUBAGENTS_DIR;

    if (ORIGINAL_SUBAGENTS_STATE === undefined) delete process.env[SUBAGENTS_STATE_FILE_ENV];
    else process.env[SUBAGENTS_STATE_FILE_ENV] = ORIGINAL_SUBAGENTS_STATE;
  });

  it("lists package utilities", async () => {
    const root = mkdtempSync(path.join(tmpdir(), "subagent-util-test-"));
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
      utilities: [
        {
          name: "echo_args",
          description: "Echo encoded args",
          entrypoint: "utilities/echo-args.sh",
          timeout_sec: 5,
          max_output_bytes: 2048,
        },
      ],
    });

    process.env[SUBAGENTS_DIR_ENV] = subagentsDir;
    process.env[SUBAGENTS_STATE_FILE_ENV] = statePath;

    const tool = createHarness(async () => ({ stdout: "", stderr: "", code: 0, killed: false }));
    const result = await tool.execute(
      "tool-call",
      { action: "list", id: "sentry-agent" },
      undefined,
      undefined,
      {},
    );

    expect(result.isError).not.toBe(true);
    expect(result.details.utilities).toHaveLength(1);
    expect(result.details.utilities[0].name).toBe("echo_args");
  });

  it("runs declared utility", async () => {
    const root = mkdtempSync(path.join(tmpdir(), "subagent-util-test-"));
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
      utilities: [
        {
          name: "echo_args",
          description: "Echo encoded args",
          entrypoint: "utilities/echo-args.sh",
          timeout_sec: 5,
          max_output_bytes: 2048,
        },
      ],
    });

    writeFileSync(
      statePath,
      JSON.stringify(
        {
          version: 1,
          agents: {
            "sentry-agent": {
              installed: true,
              enabled: true,
            },
          },
        },
        null,
        2,
      ) + "\n",
      "utf-8",
    );

    process.env[SUBAGENTS_DIR_ENV] = subagentsDir;
    process.env[SUBAGENTS_STATE_FILE_ENV] = statePath;

    const execSpy = vi.fn(async (command, args) => {
      expect(command).toBe("bash");
      expect(args[0]).toBe("-lc");
      expect(args[1]).toContain("SUBAGENT_UTIL_ARGS_B64");
      return {
        stdout: "utility ok\nZXhhbXBsZQ==\n",
        stderr: "",
        code: 0,
        killed: false,
      };
    });

    const tool = createHarness(execSpy);
    const result = await tool.execute(
      "tool-call",
      {
        action: "run",
        id: "sentry-agent",
        utility: "echo_args",
        args: { issue_id: "123" },
      },
      undefined,
      undefined,
      {},
    );

    expect(result.isError).not.toBe(true);
    expect(result.details.exit_code).toBe(0);
    expect(result.details.stdout).toContain("utility ok");
    expect(execSpy).toHaveBeenCalledTimes(1);
  });
});
