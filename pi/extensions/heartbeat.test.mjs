/**
 * Tests for heartbeat.ts v2 logic (programmatic health checks).
 *
 * We can't test the pi extension hooks directly (they need the pi runtime),
 * but we can extract and test the pure functions: config resolution, backoff
 * computation, env var handling, todo parsing, and check logic.
 *
 * Run: npx vitest run pi/extensions/heartbeat.test.mjs
 */

import { describe, it, beforeEach, afterEach } from "vitest";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import os from "node:os";

// ── Replicate pure functions from heartbeat.ts v2 ───────────────────────────

const DEFAULT_INTERVAL_MS = 10 * 60 * 1000; // 10 min
const MIN_INTERVAL_MS = 2 * 60 * 1000; // 2 min
const BACKOFF_MULTIPLIER = 2;
const MAX_BACKOFF_MS = 60 * 60 * 1000; // 1 hour
const STUCK_TODO_THRESHOLD_MS = 2 * 60 * 60 * 1000; // 2 hours

function isDisabledByEnv(envValue) {
  if (envValue == null) return false;
  const val = envValue.trim().toLowerCase();
  return val === "0" || val === "false" || val === "no";
}

function clampInt(value, min, max, fallback) {
  const parsed = parseInt(value ?? "", 10);
  if (!Number.isFinite(parsed)) return fallback;
  return Math.min(max, Math.max(min, parsed));
}

function getExpectedSessions(envValue) {
  if (envValue) return envValue.split(",").map((s) => s.trim()).filter(Boolean);
  return ["sentry-agent"];
}

function computeBackoffMs(consecutiveErrors, baseInterval) {
  if (consecutiveErrors <= 0) return baseInterval;
  const backoff = baseInterval * BACKOFF_MULTIPLIER ** consecutiveErrors;
  return Math.min(backoff, MAX_BACKOFF_MS);
}

function parseTodo(content) {
  try {
    const trimmed = content.trim();
    if (!trimmed.startsWith("{")) return null;
    let depth = 0,
      jsonEnd = -1;
    for (let i = 0; i < trimmed.length; i++) {
      if (trimmed[i] === "{") depth++;
      else if (trimmed[i] === "}") {
        depth--;
        if (depth === 0) {
          jsonEnd = i + 1;
          break;
        }
      }
    }
    if (jsonEnd === -1) return null;
    return JSON.parse(trimmed.substring(0, jsonEnd));
  } catch {
    return null;
  }
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
  fs.mkdirSync(path.dirname(p), { recursive: true });
  fs.writeFileSync(p, content, "utf-8");
  return p;
}

// ── Tests ───────────────────────────────────────────────────────────────────

describe("heartbeat v2: isDisabledByEnv", () => {
  it("returns false for undefined", () => {
    assert.equal(isDisabledByEnv(undefined), false);
  });

  it("returns false for null", () => {
    assert.equal(isDisabledByEnv(null), false);
  });

  it("returns false for empty string", () => {
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
});

describe("heartbeat v2: clampInt", () => {
  it("returns fallback for undefined", () => {
    assert.equal(clampInt(undefined, 100, 1000, 500), 500);
  });

  it("returns fallback for empty string", () => {
    assert.equal(clampInt("", 100, 1000, 500), 500);
  });

  it("returns fallback for non-numeric", () => {
    assert.equal(clampInt("abc", 100, 1000, 500), 500);
  });

  it("clamps to min", () => {
    assert.equal(clampInt("50", 100, 1000, 500), 100);
  });

  it("clamps to max", () => {
    assert.equal(clampInt("2000", 100, 1000, 500), 1000);
  });

  it("returns value when in range", () => {
    assert.equal(clampInt("750", 100, 1000, 500), 750);
  });

  it("handles negative values", () => {
    assert.equal(clampInt("-5", 0, 100, 50), 0);
  });
});

describe("heartbeat v2: getExpectedSessions", () => {
  it("returns default sentry-agent when no env", () => {
    const result = getExpectedSessions(undefined);
    assert.deepEqual(result, ["sentry-agent"]);
  });

  it("returns default for empty string", () => {
    const result = getExpectedSessions("");
    assert.deepEqual(result, ["sentry-agent"]);
  });

  it("parses comma-separated list", () => {
    const result = getExpectedSessions("sentry-agent,dev-agent-foo");
    assert.deepEqual(result, ["sentry-agent", "dev-agent-foo"]);
  });

  it("trims whitespace", () => {
    const result = getExpectedSessions(" sentry-agent , monitor ");
    assert.deepEqual(result, ["sentry-agent", "monitor"]);
  });

  it("filters empty entries", () => {
    const result = getExpectedSessions("sentry-agent,,monitor,");
    assert.deepEqual(result, ["sentry-agent", "monitor"]);
  });
});

describe("heartbeat v2: computeBackoffMs", () => {
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

  it("caps at MAX_BACKOFF_MS on 3 errors (with 10min base)", () => {
    // 600_000 * 8 = 4_800_000 > MAX_BACKOFF (3_600_000)
    assert.equal(computeBackoffMs(3, base), MAX_BACKOFF_MS);
  });

  it("8x on 3 errors (small base, uncapped)", () => {
    assert.equal(computeBackoffMs(3, 60_000), 60_000 * 8);
  });

  it("caps at MAX_BACKOFF_MS for large error counts", () => {
    assert.equal(computeBackoffMs(10, base), MAX_BACKOFF_MS);
    assert.equal(computeBackoffMs(100, base), MAX_BACKOFF_MS);
  });

  it("works with smaller base interval", () => {
    assert.equal(computeBackoffMs(1, 120_000), 240_000);
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

describe("heartbeat v2: parseTodo", () => {
  it("parses valid JSON front matter", () => {
    const content = `{
  "id": "abc123",
  "title": "Fix the bug",
  "status": "in-progress",
  "created_at": "2026-02-22T10:00:00.000Z"
}

## Notes
Some markdown body here.`;

    const result = parseTodo(content);
    assert.equal(result.id, "abc123");
    assert.equal(result.title, "Fix the bug");
    assert.equal(result.status, "in-progress");
    assert.equal(result.created_at, "2026-02-22T10:00:00.000Z");
  });

  it("parses JSON-only todo (no body)", () => {
    const content = `{"id": "def456", "status": "done", "title": "Ship it"}`;
    const result = parseTodo(content);
    assert.equal(result.id, "def456");
    assert.equal(result.status, "done");
  });

  it("handles nested objects in JSON", () => {
    const content = `{
  "id": "nested",
  "title": "Nested test",
  "tags": ["a", "b"],
  "meta": {"key": "value"}
}`;
    const result = parseTodo(content);
    assert.equal(result.id, "nested");
    assert.deepEqual(result.tags, ["a", "b"]);
    assert.deepEqual(result.meta, { key: "value" });
  });

  it("returns null for non-JSON content", () => {
    const result = parseTodo("# Just a markdown heading\n\nSome text.");
    assert.equal(result, null);
  });

  it("returns null for empty content", () => {
    assert.equal(parseTodo(""), null);
  });

  it("returns null for malformed JSON", () => {
    assert.equal(parseTodo("{ broken json"), null);
  });

  it("handles whitespace before JSON", () => {
    const content = `  \n  {"id": "ws", "status": "open"}`;
    const result = parseTodo(content);
    assert.equal(result.id, "ws");
  });

  it("handles braces inside string values", () => {
    const content = `{"id": "brace1", "title": "Fix {bug} in {module}", "status": "open"}`;
    const result = parseTodo(content);
    assert.equal(result.id, "brace1");
    assert.equal(result.title, "Fix {bug} in {module}");
    assert.equal(result.status, "open");
  });

  it("handles escaped quotes inside strings", () => {
    const content = `{"id": "esc1", "title": "Fix \\"quoted\\" thing", "status": "done"}`;
    const result = parseTodo(content);
    assert.equal(result.id, "esc1");
    assert.equal(result.status, "done");
  });

  it("handles braces and escapes together", () => {
    const content = `{"id": "combo", "title": "Deploy {v2} with \\"zero-token\\" mode", "status": "in-progress", "created_at": "2026-01-01T00:00:00Z"}`;
    const result = parseTodo(content);
    assert.equal(result.id, "combo");
    assert.equal(result.status, "in-progress");
  });

  it("ignores content after closing brace", () => {
    const content = `{"id": "extra", "status": "open"}

## This is the body
Not part of JSON.`;
    const result = parseTodo(content);
    assert.equal(result.id, "extra");
    assert.equal(result.status, "open");
  });
});

describe("heartbeat v2: hasMatchingInProgressTodo logic", () => {
  // Replicate the matching logic from the extension
  function matchesWorktree(content, worktreeName) {
    const pathPattern = `worktrees/${worktreeName}`;
    const escapedName = worktreeName.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
    const boundaryPattern = new RegExp(`(?:^|[\\s\`"'/])${escapedName}(?:$|[\\s\`"'/])`, "m");
    return content.includes(pathPattern) || boundaryPattern.test(content);
  }

  it("matches worktree name in path context", () => {
    const content = `Branch: ~/workspace/worktrees/fix/sentry-alert`;
    assert.ok(matchesWorktree(content, "fix/sentry-alert"));
  });

  it("matches worktree name after space boundary", () => {
    const content = `Working on fix/sentry-alert for the issue`;
    assert.ok(matchesWorktree(content, "fix/sentry-alert"));
  });

  it("matches worktree name in backticks", () => {
    const content = "Branch: `fix/sentry-alert`";
    assert.ok(matchesWorktree(content, "fix/sentry-alert"));
  });

  it("does NOT match short substring in unrelated word", () => {
    // "fix" should NOT match "prefix" or "fixation" or "the fix was applied"
    // Actually "the fix was" has "fix" after a space — that IS a match.
    // But "prefix" should NOT match.
    const content = `{"title": "prefix configuration update", "status": "in-progress"}`;
    assert.ok(!matchesWorktree(content, "fix"));
  });

  it("does NOT match partial word in title", () => {
    const content = `{"title": "Refixing the deployment", "status": "in-progress"}`;
    assert.ok(!matchesWorktree(content, "fix"));
  });

  it("matches when worktree name appears at start of line", () => {
    const content = `fix/sentry-alert is the branch name`;
    assert.ok(matchesWorktree(content, "fix/sentry-alert"));
  });

  it("matches when worktree name is in quotes", () => {
    const content = `Branch is "fix/sentry-alert" on main`;
    assert.ok(matchesWorktree(content, "fix/sentry-alert"));
  });
});

describe("heartbeat v2: stuck todo detection logic", () => {
  it("identifies stuck in-progress todo (over threshold)", () => {
    const now = Date.now();
    const threeHoursAgo = new Date(now - 3 * 60 * 60 * 1000).toISOString();
    const todo = parseTodo(
      `{"id": "stuck1", "status": "in-progress", "title": "Stuck task", "created_at": "${threeHoursAgo}"}`
    );

    assert.equal(todo.status, "in-progress");
    const age = now - new Date(todo.created_at).getTime();
    assert.ok(age > STUCK_TODO_THRESHOLD_MS, "should be over threshold");
  });

  it("does not flag recent in-progress todo", () => {
    const now = Date.now();
    const thirtyMinAgo = new Date(now - 30 * 60 * 1000).toISOString();
    const todo = parseTodo(
      `{"id": "recent1", "status": "in-progress", "title": "Active task", "created_at": "${thirtyMinAgo}"}`
    );

    const age = now - new Date(todo.created_at).getTime();
    assert.ok(age < STUCK_TODO_THRESHOLD_MS, "should be under threshold");
  });

  it("ignores non-in-progress todos", () => {
    const now = Date.now();
    const dayAgo = new Date(now - 24 * 60 * 60 * 1000).toISOString();
    const todo = parseTodo(
      `{"id": "done1", "status": "done", "title": "Old done task", "created_at": "${dayAgo}"}`
    );

    assert.equal(todo.status, "done");
    // Even though it's old, it's done — should not be flagged
  });

  it("ignores blocked todos", () => {
    const now = Date.now();
    const dayAgo = new Date(now - 24 * 60 * 60 * 1000).toISOString();
    const todo = parseTodo(
      `{"id": "blocked1", "status": "blocked", "title": "Blocked task", "created_at": "${dayAgo}"}`
    );

    assert.notEqual(todo.status, "in-progress");
  });
});

describe("heartbeat v2: fireHeartbeat error handling", () => {
  // Simulate the try/catch/finally pattern from fireHeartbeat
  function simulateFireHeartbeat(state, checkFails, saveThrows) {
    let timerArmed = false;

    try {
      state.totalRuns += 1;
      const failures = checkFails ? [{ name: "bridge", detail: "unreachable" }] : [];

      if (failures.length > 0) {
        // Would inject prompt — simulate sendMessage
        if (saveThrows) throw new Error("sendMessage failed");
      }

      state.consecutiveErrors = 0;
      state.lastFailures = failures.map((f) => `${f.name}: ${f.detail}`);

      if (saveThrows) throw new Error("saveState failed");
    } catch {
      state.consecutiveErrors += 1;
      try {
        if (saveThrows) throw new Error("saveState failed in catch");
      } catch {
        // Best-effort
      }
    } finally {
      timerArmed = true;
    }

    return { timerArmed, state };
  }

  it("resets consecutiveErrors on all-healthy check", () => {
    const state = { consecutiveErrors: 3, totalRuns: 5, lastFailures: [] };
    const result = simulateFireHeartbeat(state, false, false);
    assert.equal(result.state.consecutiveErrors, 0);
    assert.equal(result.state.totalRuns, 6);
    assert.equal(result.timerArmed, true);
  });

  it("still resets errors when failures are found (prompt injected successfully)", () => {
    const state = { consecutiveErrors: 0, totalRuns: 5, lastFailures: [] };
    const result = simulateFireHeartbeat(state, true, false);
    assert.equal(result.state.consecutiveErrors, 0);
    assert.equal(result.state.lastFailures.length, 1);
    assert.equal(result.timerArmed, true);
  });

  it("increments errors when sendMessage throws", () => {
    const state = { consecutiveErrors: 0, totalRuns: 5, lastFailures: [] };
    const result = simulateFireHeartbeat(state, true, true);
    assert.equal(result.state.consecutiveErrors, 1);
    assert.equal(result.timerArmed, true, "timer should always re-arm");
  });

  it("re-arms timer even when everything throws", () => {
    const state = { consecutiveErrors: 0, totalRuns: 0, lastFailures: [] };
    const result = simulateFireHeartbeat(state, true, true);
    assert.equal(result.timerArmed, true, "timer must re-arm regardless of errors");
  });

  it("success after errors resets to base interval", () => {
    const state = { consecutiveErrors: 5, totalRuns: 10, lastFailures: [] };
    const result = simulateFireHeartbeat(state, false, false);
    assert.equal(result.state.consecutiveErrors, 0);
    assert.equal(computeBackoffMs(result.state.consecutiveErrors, 600_000), 600_000);
  });
});
