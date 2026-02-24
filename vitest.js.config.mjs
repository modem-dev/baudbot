import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    include: ["pi/extensions/**/*.test.mjs", "test/**/*.test.mjs"],
    exclude: ["test/**/*.shell.test.mjs", "pi/extensions/tool-guard.test.mjs"],
    testTimeout: 120_000,
    hookTimeout: 120_000,
    fileParallelism: false,
  },
});
