import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    include: [
      "pi/extensions/heartbeat.test.mjs",
      "pi/extensions/agent-spawn.test.mjs",
      "pi/extensions/memory.test.mjs",
      "test/legacy-node-tests.test.mjs",
      "test/broker-bridge.integration.test.mjs",
      "test/integrity-status-check.test.mjs",
      "test/shell-scripts.test.mjs",
      "test/security-audit.test.mjs",
      "test/github-events.test.mjs",
    ],
    testTimeout: 120_000,
    hookTimeout: 120_000,
    fileParallelism: false,
  },
});
