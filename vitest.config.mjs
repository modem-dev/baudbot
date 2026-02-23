import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    include: [
      "pi/extensions/cli-session-shim.test.mjs",
      "pi/extensions/heartbeat.test.mjs",
      "pi/extensions/memory.test.mjs",
      "test/legacy-node-tests.test.mjs",
      "test/broker-bridge.integration.test.mjs",
      "test/shell-scripts.test.mjs",
      "test/security-audit.test.mjs",
    ],
    testTimeout: 120_000,
    hookTimeout: 120_000,
    fileParallelism: false,
  },
});
