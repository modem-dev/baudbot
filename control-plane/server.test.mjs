/**
 * Control plane server tests.
 *
 * Run with Vitest:
 *   npx vitest run control-plane/server.test.mjs
 */

import { describe, it, beforeAll, afterAll } from "vitest";
import assert from "node:assert/strict";

// ── Test helpers ────────────────────────────────────────────────────────────

/** Import the server module in a child process to avoid port conflicts. */
async function startServer({ token, port } = {}) {
  const { spawn } = await import("node:child_process");
  const p = port || 28801 + Math.floor(Math.random() * 100);
  const env = {
    ...process.env,
    BAUDBOT_CP_PORT: String(p),
    BAUDBOT_AGENT_USER: process.env.USER, // use current user for testing
    BAUDBOT_AGENT_HOME: process.env.HOME,
  };
  if (token) env.BAUDBOT_CP_TOKEN = token;

  const child = spawn("node", ["server.mjs"], {
    cwd: new URL(".", import.meta.url).pathname,
    env,
    stdio: ["ignore", "pipe", "pipe"],
  });

  let stderr = "";
  child.stderr.on("data", (chunk) => {
    stderr += chunk.toString();
  });

  // Wait for server to be ready
  await new Promise((resolve, reject) => {
    const timeout = setTimeout(() => reject(new Error(`server start timeout${stderr ? `: ${stderr.trim()}` : ""}`)), 5000);
    child.stdout.on("data", (chunk) => {
      if (chunk.toString().includes("listening")) {
        clearTimeout(timeout);
        resolve();
      }
    });
    child.on("error", (err) => {
      clearTimeout(timeout);
      reject(err);
    });
    child.on("exit", (code, signal) => {
      clearTimeout(timeout);
      reject(new Error(`server exited before ready (code=${code}, signal=${signal})${stderr ? `: ${stderr.trim()}` : ""}`));
    });
  });

  const base = `http://127.0.0.1:${p}`;
  return {
    base,
    port: p,
    async fetch(path, opts = {}) {
      return fetch(`${base}${path}`, opts);
    },
    close() {
      child.kill("SIGTERM");
    },
  };
}

// ── Tests: No auth ──────────────────────────────────────────────────────────

describe("control-plane (no auth)", () => {
  let server;

  beforeAll(async () => {
    server = await startServer();
  });
  afterAll(() => server?.close());

  it("GET /health returns 200", async () => {
    const res = await server.fetch("/health");
    assert.equal(res.status, 200);
    const body = await res.json();
    assert.equal(body.ok, true);
    assert.equal(typeof body.uptimeMs, "number");
    assert.equal(typeof body.uptime, "string");
  });

  it("GET /status returns 200 with expected shape", async () => {
    const res = await server.fetch("/status");
    assert.equal(res.status, 200);
    const body = await res.json();
    assert.equal(typeof body.agent, "object");
    assert.equal(typeof body.agent.running, "boolean");
    assert.equal(typeof body.agent.processCount, "number");
    assert.ok(Array.isArray(body.agent.piSessions));
    assert.equal(typeof body.system, "object");
    assert.ok(body.system.hostname === null || typeof body.system.hostname === "string");
    assert.ok(body.system.loadAvg === null || typeof body.system.loadAvg === "string");
    assert.ok(body.system.memory === null || typeof body.system.memory === "object");
    assert.ok(body.system.disk === null || typeof body.system.disk === "object");
    assert.equal(typeof body.controlPlane, "object");
    assert.equal(typeof body.controlPlane.port, "number");
  });

  it("GET /config returns 200 with expected shape", async () => {
    const res = await server.fetch("/config");
    assert.equal(res.status, 200);
    const body = await res.json();
    assert.equal(typeof body.envFile, "string");
    assert.ok(Array.isArray(body.variables));
  });

  it("GET /dashboard returns HTML", async () => {
    const res = await server.fetch("/dashboard");
    assert.equal(res.status, 200);
    const ct = res.headers.get("content-type");
    assert.ok(ct.includes("text/html"), `expected text/html, got ${ct}`);
    const html = await res.text();
    assert.ok(html.includes("baudbot"));
    assert.ok(html.includes("control plane"));
  });

  it("GET / redirects to /dashboard", async () => {
    const res = await server.fetch("/", { redirect: "manual" });
    assert.equal(res.status, 302);
    assert.ok(res.headers.get("location").includes("/dashboard"));
  });

  it("no auth required when BAUDBOT_CP_TOKEN is unset", async () => {
    const res = await server.fetch("/status");
    assert.equal(res.status, 200);
  });
});

// ── Tests: With auth ────────────────────────────────────────────────────────

describe("control-plane (with auth)", () => {
  let server;
  const TOKEN = "test-token-abc123";

  beforeAll(async () => {
    server = await startServer({ token: TOKEN });
  });
  afterAll(() => server?.close());

  it("GET /health works without auth", async () => {
    const res = await server.fetch("/health");
    assert.equal(res.status, 200);
  });

  it("GET /status returns 401 without auth", async () => {
    const res = await server.fetch("/status");
    assert.equal(res.status, 401);
    const body = await res.json();
    assert.equal(body.error, "unauthorized");
  });

  it("GET /status returns 401 with wrong token", async () => {
    const res = await server.fetch("/status", {
      headers: { Authorization: "Bearer wrong-token" },
    });
    assert.equal(res.status, 401);
  });

  it("GET /status returns 401 with malformed auth header", async () => {
    const res = await server.fetch("/status", {
      headers: { Authorization: "Basic dXNlcjpwYXNz" },
    });
    assert.equal(res.status, 401);
  });

  it("GET /status returns 200 with correct token", async () => {
    const res = await server.fetch("/status", {
      headers: { Authorization: `Bearer ${TOKEN}` },
    });
    assert.equal(res.status, 200);
  });

  it("GET /config returns 401 without auth", async () => {
    const res = await server.fetch("/config");
    assert.equal(res.status, 401);
  });

  it("GET /config returns 200 with correct token", async () => {
    const res = await server.fetch("/config", {
      headers: { Authorization: `Bearer ${TOKEN}` },
    });
    assert.equal(res.status, 200);
  });

  it("GET /dashboard returns 401 without auth", async () => {
    const res = await server.fetch("/dashboard");
    assert.equal(res.status, 401);
  });

  it("GET /dashboard returns 200 with correct token", async () => {
    const res = await server.fetch("/dashboard", {
      headers: { Authorization: `Bearer ${TOKEN}` },
    });
    assert.equal(res.status, 200);
  });

  it("auth is case-insensitive for Bearer prefix", async () => {
    const res = await server.fetch("/status", {
      headers: { Authorization: `bearer ${TOKEN}` },
    });
    assert.equal(res.status, 200);
  });
});
