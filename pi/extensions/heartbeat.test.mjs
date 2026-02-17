/**
 * Tests for heartbeat.ts logic.
 *
 * We can't test the pi extension hooks directly (they need the pi runtime),
 * but we can extract and test the pure functions: file reading, config
 * resolution, backoff computation, and env var handling.
 *
 * Run: node --test pi/extensions/heartbeat.test.mjs
 */

import { describe, it, beforeEach, afterEach } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import os from "node:os";

// ── Replicate pure functions from heartbeat.ts ──────────────────────────────

const DEFAULT_INTERVAL_MS = 10 * 60 * 1000; // 10 min
const MIN_INTERVAL_MS = 2 * 60 * 1000; // 2 min
const BACKOFF_MULTIPLIER = 2;
const MAX_BACKOFF_MS = 60 * 60 * 1000; // 1 hour

function isDisabledByEnv(envValue) {
  if (envValue == null) return false;
  const val = envValue.trim().toLowerCase();
  return val === "0" || val === "false" || val === "no";
}

function resolveConfig(env = {}) {
  const envInterval = parseInt(env.HEARTBEAT_INTERVAL_MS || "", 10);
  const intervalMs = Math.max(
    MIN_INTERVAL_MS,
    Number.isFinite(envInterval) ? envInterval : DEFAULT_INTERVAL_MS
  );
  const heartbeatFile =
    env.HEARTBEAT_FILE?.trim() ||
    path.join(os.homedir(), ".pi", "agent", "HEARTBEAT.md");
  const enabled = !isDisabledByEnv(env.HEARTBEAT_ENABLED);
  return { intervalMs, heartbeatFile, enabled };
}

function readHeartbeatFile(filepath) {
  try {
    if (!fs.existsSync(filepath)) return null;
    const content = fs.readFileSync(filepath, "utf-8").trim();
    const meaningful = content
      .split("\n")
      .filter((line) => {
        const trimmed = line.trim();
        return trimmed.length > 0 && !trimmed.startsWith("#");
      })
      .join("\n")
      .trim();
    return meaningful.length > 0 ? content : null;
  } catch {
    return null;
  }
}

function computeBackoffMs(consecutiveErrors, baseInterval) {
  if (consecutiveErrors <= 0) return baseInterval;
  const backoff = baseInterval * Math.pow(BACKOFF_MULTIPLIER, consecutiveErrors);
  return Math.min(backoff, MAX_BACKOFF_MS);
}

// ── Test helpers ────────────────────────────────────────────────────────────

let tmpDir;

function setup() {
  tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "heartbeat-test-"));
}

function teardown() {
  fs.rmSync(tmpDir, { recursive: true, force: true });
}

function writeFile(name, content) {
  const p = path.join(tmpDir, name);
  fs.writeFileSync(p, content, "utf-8");
  return p;
}

// ── Tests ───────────────────────────────────────────────────────────────────

describe("heartbeat: readHeartbeatFile", () => {
  beforeEach(setup);
  afterEach(teardown);

  it("returns null for missing file", () => {
    assert.equal(readHeartbeatFile("/nonexistent/HEARTBEAT.md"), null);
  });

  it("returns null for empty file", () => {
    const p = writeFile("HEARTBEAT.md", "");
    assert.equal(readHeartbeatFile(p), null);
  });

  it("returns null for whitespace-only file", () => {
    const p = writeFile("HEARTBEAT.md", "   \n  \n   ");
    assert.equal(readHeartbeatFile(p), null);
  });

  it("returns null for comment-only file", () => {
    const p = writeFile("HEARTBEAT.md", "# Heartbeat Checklist\n# Just comments\n");
    assert.equal(readHeartbeatFile(p), null);
  });

  it("returns null for heading-only file (no actionable items)", () => {
    const p = writeFile(
      "HEARTBEAT.md",
      "# Heartbeat Checklist\n\n## Section\n\n### Subsection\n"
    );
    assert.equal(readHeartbeatFile(p), null);
  });

  it("returns content when checklist items exist", () => {
    const content = "# Checklist\n- Check agents are alive\n- Check bridge\n";
    const p = writeFile("HEARTBEAT.md", content);
    const result = readHeartbeatFile(p);
    assert.notEqual(result, null);
    assert.ok(result.includes("Check agents are alive"));
    assert.ok(result.includes("Check bridge"));
  });

  it("returns content with mixed headings and items", () => {
    const content =
      "# Heartbeat\n\n- [ ] Check sessions\n\n## Optional\n\n- [ ] Check disk\n";
    const p = writeFile("HEARTBEAT.md", content);
    const result = readHeartbeatFile(p);
    assert.notEqual(result, null);
    assert.ok(result.includes("Check sessions"));
    assert.ok(result.includes("Check disk"));
  });

  it("returns full content including headings when items exist", () => {
    const content = "# Title\n- item\n";
    const p = writeFile("HEARTBEAT.md", content);
    const result = readHeartbeatFile(p);
    // Should return the full content (including the heading), not just the items
    assert.ok(result.includes("# Title"));
    assert.ok(result.includes("- item"));
  });

  it("handles file with only a plain text line", () => {
    const p = writeFile("HEARTBEAT.md", "Check everything\n");
    const result = readHeartbeatFile(p);
    assert.notEqual(result, null);
    assert.ok(result.includes("Check everything"));
  });
});

describe("heartbeat: resolveConfig", () => {
  it("returns defaults with no env vars", () => {
    const config = resolveConfig({});
    assert.equal(config.intervalMs, DEFAULT_INTERVAL_MS);
    assert.equal(config.enabled, true);
    assert.ok(config.heartbeatFile.endsWith("HEARTBEAT.md"));
  });

  it("respects HEARTBEAT_INTERVAL_MS", () => {
    const config = resolveConfig({ HEARTBEAT_INTERVAL_MS: "300000" });
    assert.equal(config.intervalMs, 300_000);
  });

  it("enforces minimum interval", () => {
    const config = resolveConfig({ HEARTBEAT_INTERVAL_MS: "1000" }); // 1 second
    assert.equal(config.intervalMs, MIN_INTERVAL_MS);
  });

  it("enforces minimum for zero", () => {
    const config = resolveConfig({ HEARTBEAT_INTERVAL_MS: "0" });
    assert.equal(config.intervalMs, MIN_INTERVAL_MS);
  });

  it("enforces minimum for negative", () => {
    const config = resolveConfig({ HEARTBEAT_INTERVAL_MS: "-5000" });
    assert.equal(config.intervalMs, MIN_INTERVAL_MS);
  });

  it("handles non-numeric HEARTBEAT_INTERVAL_MS", () => {
    const config = resolveConfig({ HEARTBEAT_INTERVAL_MS: "not-a-number" });
    assert.equal(config.intervalMs, DEFAULT_INTERVAL_MS);
  });

  it("handles empty HEARTBEAT_INTERVAL_MS", () => {
    const config = resolveConfig({ HEARTBEAT_INTERVAL_MS: "" });
    assert.equal(config.intervalMs, DEFAULT_INTERVAL_MS);
  });

  it("respects HEARTBEAT_FILE", () => {
    const config = resolveConfig({ HEARTBEAT_FILE: "/custom/path/HB.md" });
    assert.equal(config.heartbeatFile, "/custom/path/HB.md");
  });

  it("trims HEARTBEAT_FILE whitespace", () => {
    const config = resolveConfig({ HEARTBEAT_FILE: "  /custom/HB.md  " });
    assert.equal(config.heartbeatFile, "/custom/HB.md");
  });

  it("uses default when HEARTBEAT_FILE is empty", () => {
    const config = resolveConfig({ HEARTBEAT_FILE: "   " });
    assert.ok(config.heartbeatFile.endsWith("HEARTBEAT.md"));
  });
});

describe("heartbeat: isDisabledByEnv", () => {
  it('returns false for undefined', () => {
    assert.equal(isDisabledByEnv(undefined), false);
  });

  it('returns false for null', () => {
    assert.equal(isDisabledByEnv(null), false);
  });

  it('returns false for empty string', () => {
    assert.equal(isDisabledByEnv(""), false);
  });

  it('returns false for "1"', () => {
    assert.equal(isDisabledByEnv("1"), false);
  });

  it('returns false for "true"', () => {
    assert.equal(isDisabledByEnv("true"), false);
  });

  it('returns false for "yes"', () => {
    assert.equal(isDisabledByEnv("yes"), false);
  });

  it('returns true for "0"', () => {
    assert.equal(isDisabledByEnv("0"), true);
  });

  it('returns true for "false"', () => {
    assert.equal(isDisabledByEnv("false"), true);
  });

  it('returns true for "no"', () => {
    assert.equal(isDisabledByEnv("no"), true);
  });

  it('returns true for "FALSE" (case insensitive)', () => {
    assert.equal(isDisabledByEnv("FALSE"), true);
  });

  it('returns true for " false " (with whitespace)', () => {
    assert.equal(isDisabledByEnv(" false "), true);
  });

  it('returns true for "No" (mixed case)', () => {
    assert.equal(isDisabledByEnv("No"), true);
  });

  it("enabled=false when HEARTBEAT_ENABLED=0", () => {
    const config = resolveConfig({ HEARTBEAT_ENABLED: "0" });
    assert.equal(config.enabled, false);
  });

  it("enabled=false when HEARTBEAT_ENABLED=false", () => {
    const config = resolveConfig({ HEARTBEAT_ENABLED: "false" });
    assert.equal(config.enabled, false);
  });

  it("enabled=false when HEARTBEAT_ENABLED=no", () => {
    const config = resolveConfig({ HEARTBEAT_ENABLED: "no" });
    assert.equal(config.enabled, false);
  });

  it("enabled=true when HEARTBEAT_ENABLED=1", () => {
    const config = resolveConfig({ HEARTBEAT_ENABLED: "1" });
    assert.equal(config.enabled, true);
  });

  it("enabled=true when HEARTBEAT_ENABLED unset", () => {
    const config = resolveConfig({});
    assert.equal(config.enabled, true);
  });
});

describe("heartbeat: computeBackoffMs", () => {
  const base = 600_000; // 10 min

  it("returns base interval with 0 errors", () => {
    assert.equal(computeBackoffMs(0, base), base);
  });

  it("returns base interval with negative errors", () => {
    assert.equal(computeBackoffMs(-1, base), base);
  });

  it("doubles on 1 error", () => {
    assert.equal(computeBackoffMs(1, base), base * 2);
  });

  it("quadruples on 2 errors", () => {
    assert.equal(computeBackoffMs(2, base), base * 4);
  });

  it("8x on 3 errors (capped)", () => {
    // 600_000 * 8 = 4_800_000 > MAX_BACKOFF (3_600_000), so capped
    assert.equal(computeBackoffMs(3, base), MAX_BACKOFF_MS);
  });

  it("8x on 3 errors (small base, uncapped)", () => {
    // 60_000 * 8 = 480_000 < MAX_BACKOFF, so not capped
    assert.equal(computeBackoffMs(3, 60_000), 60_000 * 8);
  });

  it("caps at MAX_BACKOFF_MS", () => {
    // 10 errors with 10 min base = 10 * 2^10 = 10240 min — way past 60 min max
    assert.equal(computeBackoffMs(10, base), MAX_BACKOFF_MS);
  });

  it("caps at MAX_BACKOFF_MS for very large error counts", () => {
    assert.equal(computeBackoffMs(100, base), MAX_BACKOFF_MS);
  });

  it("works with smaller base interval", () => {
    assert.equal(computeBackoffMs(1, 120_000), 240_000); // 2 min → 4 min
  });

  it("backoff progression is monotonically increasing", () => {
    let prev = base;
    for (let i = 1; i <= 10; i++) {
      const current = computeBackoffMs(i, base);
      assert.ok(current >= prev, `backoff at ${i} errors (${current}) should be >= ${prev}`);
      prev = current;
    }
  });
});

describe("heartbeat: fireHeartbeat error handling", () => {
  // Simulate the try/catch/finally pattern from fireHeartbeat to verify
  // that the error counter and re-arm behavior work correctly.

  function simulateFireHeartbeat(state, sendThrows, saveThrows) {
    let timerArmed = false;

    try {
      state.totalRuns += 1;

      if (sendThrows) throw new Error("sendMessage failed");

      // Success — reset error counter
      state.consecutiveErrors = 0;

      if (saveThrows) throw new Error("saveState failed");
    } catch {
      state.consecutiveErrors += 1;
      try {
        if (saveThrows) throw new Error("saveState failed in catch");
      } catch {
        // Best-effort — don't prevent re-arm
      }
    } finally {
      timerArmed = true;
    }

    return { timerArmed, state };
  }

  it("resets consecutiveErrors on success", () => {
    const state = { consecutiveErrors: 3, totalRuns: 5 };
    const result = simulateFireHeartbeat(state, false, false);
    assert.equal(result.state.consecutiveErrors, 0);
    assert.equal(result.state.totalRuns, 6);
    assert.equal(result.timerArmed, true);
  });

  it("increments consecutiveErrors on sendMessage failure", () => {
    const state = { consecutiveErrors: 0, totalRuns: 5 };
    const result = simulateFireHeartbeat(state, true, false);
    assert.equal(result.state.consecutiveErrors, 1);
    assert.equal(result.timerArmed, true, "timer should always re-arm");
  });

  it("accumulates errors across multiple failures", () => {
    const state = { consecutiveErrors: 4, totalRuns: 10 };
    const result = simulateFireHeartbeat(state, true, false);
    assert.equal(result.state.consecutiveErrors, 5);
    assert.equal(result.timerArmed, true, "timer should always re-arm");
  });

  it("re-arms timer even when both send and save throw", () => {
    const state = { consecutiveErrors: 0, totalRuns: 0 };
    const result = simulateFireHeartbeat(state, true, true);
    assert.equal(result.timerArmed, true, "timer must re-arm regardless of errors");
    assert.equal(result.state.consecutiveErrors, 1);
  });

  it("consecutive errors increase backoff delay", () => {
    const base = 600_000;
    // After 1 error: 2x
    assert.equal(computeBackoffMs(1, base), 1_200_000);
    // After 2 errors: 4x (capped at max)
    assert.equal(computeBackoffMs(2, base), 2_400_000);
    // After 3 errors: would be 8x = 4.8M but capped at 3.6M
    assert.equal(computeBackoffMs(3, base), MAX_BACKOFF_MS);
  });

  it("success after errors resets to base interval", () => {
    const state = { consecutiveErrors: 5, totalRuns: 10 };
    const result = simulateFireHeartbeat(state, false, false);
    assert.equal(result.state.consecutiveErrors, 0);
    // With 0 errors, backoff returns base interval
    assert.equal(computeBackoffMs(result.state.consecutiveErrors, 600_000), 600_000);
  });
});

describe("heartbeat: deploy checklist file", () => {
  beforeEach(setup);
  afterEach(teardown);

  it("default HEARTBEAT.md has actionable checklist items", () => {
    // Read the actual shipped HEARTBEAT.md
    const heartbeatPath = path.join(
      path.dirname(new URL(import.meta.url).pathname),
      "..",
      "skills",
      "control-agent",
      "HEARTBEAT.md"
    );
    const result = readHeartbeatFile(heartbeatPath);
    assert.notEqual(result, null, "HEARTBEAT.md should have actionable content");
    assert.ok(
      result.includes("list_sessions"),
      "should check agent sessions"
    );
    assert.ok(
      result.includes("email monitor") || result.includes("email_monitor"),
      "should check email monitor"
    );
  });

  it("HEARTBEAT.md file exists in skills directory", () => {
    const heartbeatPath = path.join(
      path.dirname(new URL(import.meta.url).pathname),
      "..",
      "skills",
      "control-agent",
      "HEARTBEAT.md"
    );
    assert.ok(fs.existsSync(heartbeatPath), "HEARTBEAT.md should exist");
  });
});
