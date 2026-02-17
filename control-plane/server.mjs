#!/usr/bin/env node
/**
 * Baudbot Control Plane
 *
 * Admin-owned web server for monitoring and configuring the baudbot agent.
 * Runs as the admin user — NOT as baudbot_agent. The agent cannot reach
 * this server (port 28800 is outside the firewall allowlist).
 *
 * Endpoints:
 *   GET  /health     — liveness check (no auth required)
 *   GET  /status     — agent processes, sessions, system info
 *   GET  /config     — agent configuration (secrets redacted)
 *   GET  /dashboard  — server-rendered HTML overview
 *
 * Env vars:
 *   BAUDBOT_CP_PORT       — listen port (default: 28800)
 *   BAUDBOT_CP_TOKEN      — bearer token for auth (required for non-health routes)
 *   BAUDBOT_AGENT_USER    — agent unix user (default: baudbot_agent)
 *   BAUDBOT_AGENT_HOME    — agent home dir (default: /home/<agent_user>)
 */

import { createServer } from "node:http";
import { execSync } from "node:child_process";
import { readFileSync, existsSync, readdirSync, statSync } from "node:fs";
import { timingSafeEqual } from "node:crypto";
import { join } from "node:path";
import express from "express";

// ── Config ──────────────────────────────────────────────────────────────────

const PORT = parseInt(process.env.BAUDBOT_CP_PORT || "28800", 10);
const TOKEN = process.env.BAUDBOT_CP_TOKEN || "";
const AGENT_USER = process.env.BAUDBOT_AGENT_USER || "baudbot_agent";
const AGENT_HOME = process.env.BAUDBOT_AGENT_HOME || `/home/${AGENT_USER}`;
const STARTED_AT = Date.now();

// ── Helpers ─────────────────────────────────────────────────────────────────

/** Run a shell command, return stdout or null on failure. */
function run(cmd, timeoutMs = 5000) {
  try {
    return execSync(cmd, { timeout: timeoutMs, encoding: "utf8" }).trim();
  } catch {
    return null;
  }
}

/** Timing-safe token comparison. */
function tokenMatches(provided) {
  if (!TOKEN || !provided) return false;
  const a = Buffer.from(TOKEN);
  const b = Buffer.from(provided);
  if (a.length !== b.length) return false;
  return timingSafeEqual(a, b);
}

/** Format milliseconds as human-readable duration. */
function formatDuration(ms) {
  const s = Math.floor(ms / 1000);
  const d = Math.floor(s / 86400);
  const h = Math.floor((s % 86400) / 3600);
  const m = Math.floor((s % 3600) / 60);
  const sec = s % 60;
  const parts = [];
  if (d) parts.push(`${d}d`);
  if (h) parts.push(`${h}h`);
  if (m) parts.push(`${m}m`);
  parts.push(`${sec}s`);
  return parts.join(" ");
}

/** Read .env file keys (not values) to show which are configured. */
function readEnvKeys(envPath) {
  try {
    const content = readFileSync(envPath, "utf8");
    return content
      .split("\n")
      .filter((l) => l.trim() && !l.startsWith("#"))
      .map((l) => {
        const eq = l.indexOf("=");
        if (eq === -1) return null;
        const key = l.slice(0, eq).trim();
        const val = l.slice(eq + 1).trim();
        return { key, isSet: val.length > 0 };
      })
      .filter(Boolean);
  } catch {
    return null;
  }
}

// ── Data collectors ─────────────────────────────────────────────────────────

function getAgentProcesses() {
  // ps for all processes owned by the agent user
  const raw = run(`ps -u ${AGENT_USER} -o pid,etimes,comm,args --no-headers 2>/dev/null`);
  if (!raw) return [];
  return raw.split("\n").filter(Boolean).map((line) => {
    const parts = line.trim().split(/\s+/);
    const pid = parseInt(parts[0], 10);
    const elapsed = parseInt(parts[1], 10); // seconds
    const comm = parts[2];
    const args = parts.slice(3).join(" ");
    return { pid, elapsed, comm, args };
  });
}

function getAgentStatus() {
  const procs = getAgentProcesses();
  const piSessions = procs.filter((p) => p.comm === "node" && p.args.includes("pi"));
  const bridge = procs.find((p) => p.args.includes("bridge.mjs"));

  return {
    running: procs.length > 0,
    processCount: procs.length,
    piSessions: piSessions.map((p) => ({
      pid: p.pid,
      uptime: formatDuration(p.elapsed * 1000),
      args: p.args,
    })),
    bridge: bridge
      ? { pid: bridge.pid, uptime: formatDuration(bridge.elapsed * 1000) }
      : null,
  };
}

function getPiSessionDetails() {
  // Look for pi control sockets to find named sessions
  const socketDir = join(AGENT_HOME, ".pi", "sockets");
  try {
    if (!existsSync(socketDir)) return [];
    return readdirSync(socketDir)
      .filter((f) => f.endsWith(".sock"))
      .map((f) => f.replace(".sock", ""));
  } catch {
    return [];
  }
}

function getSystemInfo() {
  const loadAvg = run("cat /proc/loadavg");
  const memRaw = run("free -m | grep Mem");
  let memory = null;
  if (memRaw) {
    const parts = memRaw.trim().split(/\s+/);
    memory = {
      totalMb: parseInt(parts[1], 10),
      usedMb: parseInt(parts[2], 10),
      availableMb: parseInt(parts[6], 10),
    };
  }

  const diskRaw = run("df -h / | tail -1");
  let disk = null;
  if (diskRaw) {
    const parts = diskRaw.trim().split(/\s+/);
    disk = { size: parts[1], used: parts[2], available: parts[3], pct: parts[4] };
  }

  return {
    loadAvg: loadAvg ? loadAvg.split(" ").slice(0, 3).join(" ") : null,
    memory,
    disk,
    hostname: run("hostname"),
  };
}

function getVersionInfo() {
  const versionPath = join(AGENT_HOME, ".pi", "agent", "baudbot-version.json");
  try {
    return JSON.parse(readFileSync(versionPath, "utf8"));
  } catch {
    return null;
  }
}

function getConfig() {
  const envPath = join(AGENT_HOME, ".config", ".env");
  const keys = readEnvKeys(envPath);
  return {
    envFile: keys !== null ? "present" : "missing",
    variables: keys || [],
  };
}

// ── Express app ─────────────────────────────────────────────────────────────

const app = express();
app.use(express.json());

// ── Auth middleware (skip /health) ──────────────────────────────────────────

app.use((req, res, next) => {
  if (req.path === "/health") return next();

  if (!TOKEN) {
    // No token configured — warn but allow (local-only server)
    return next();
  }

  const auth = req.headers.authorization || "";
  const match = auth.match(/^Bearer\s+(.+)$/i);
  if (!match || !tokenMatches(match[1])) {
    return res.status(401).json({ error: "unauthorized" });
  }
  next();
});

// ── Routes ──────────────────────────────────────────────────────────────────

app.get("/health", (_req, res) => {
  res.json({
    ok: true,
    uptime: formatDuration(Date.now() - STARTED_AT),
    uptimeMs: Date.now() - STARTED_AT,
  });
});

app.get("/status", (_req, res) => {
  const agent = getAgentStatus();
  const sessions = getPiSessionDetails();
  const system = getSystemInfo();
  const version = getVersionInfo();

  res.json({
    agent,
    sessions,
    system,
    version,
    controlPlane: {
      uptime: formatDuration(Date.now() - STARTED_AT),
      port: PORT,
    },
  });
});

app.get("/config", (_req, res) => {
  const config = getConfig();
  res.json(config);
});

// ── Dashboard ───────────────────────────────────────────────────────────────

app.get("/", (_req, res) => res.redirect("/dashboard"));

app.get("/dashboard", (_req, res) => {
  const agent = getAgentStatus();
  const sessions = getPiSessionDetails();
  const system = getSystemInfo();
  const version = getVersionInfo();
  const config = getConfig();

  const statusDot = agent.running ? "🟢" : "🔴";
  const bridgeDot = agent.bridge ? "🟢" : "⚪";

  const sessionsHtml = agent.piSessions.length
    ? agent.piSessions
        .map(
          (s) =>
            `<tr><td class="mono">${s.pid}</td><td>${esc(s.args)}</td><td>${s.uptime}</td></tr>`,
        )
        .join("")
    : '<tr><td colspan="3" class="muted">No active sessions</td></tr>';

  const socketSessionsHtml = sessions.length
    ? sessions.map((s) => `<li class="mono">${esc(s)}</li>`).join("")
    : '<li class="muted">None detected</li>';

  const configHtml = config.variables.length
    ? config.variables
        .map(
          (v) =>
            `<tr><td class="mono">${esc(v.key)}</td><td>${v.isSet ? "✅ set" : "⬜ empty"}</td></tr>`,
        )
        .join("")
    : `<tr><td colspan="2" class="muted">${config.envFile === "missing" ? "No .env file found" : "No variables"}</td></tr>`;

  const versionHtml = version
    ? `<code>${esc(version.gitSha?.slice(0, 8) || "unknown")}</code> &mdash; ${esc(version.deployedAt || version.timestamp || "unknown")}`
    : '<span class="muted">No version info</span>';

  res.setHeader("Content-Type", "text/html; charset=utf-8");
  res.send(`<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta http-equiv="refresh" content="30">
  <title>baudbot control plane</title>
  <style>
    * { margin: 0; padding: 0; box-sizing: border-box; }
    body {
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, monospace;
      background: #0a0a0a; color: #e0e0e0;
      padding: 24px; max-width: 900px; margin: 0 auto;
      line-height: 1.5;
    }
    h1 { font-size: 1.4em; margin-bottom: 4px; color: #fff; }
    h2 {
      font-size: 1em; color: #888; text-transform: uppercase;
      letter-spacing: 0.1em; margin: 28px 0 12px; padding-bottom: 4px;
      border-bottom: 1px solid #222;
    }
    .subtitle { color: #666; font-size: 0.85em; margin-bottom: 24px; }
    .card {
      background: #111; border: 1px solid #222; border-radius: 6px;
      padding: 16px; margin-bottom: 16px;
    }
    .row { display: flex; gap: 16px; flex-wrap: wrap; }
    .row > .card { flex: 1; min-width: 200px; }
    .stat-label { color: #666; font-size: 0.8em; text-transform: uppercase; letter-spacing: 0.05em; }
    .stat-value { font-size: 1.3em; margin-top: 2px; }
    table { width: 100%; border-collapse: collapse; }
    th { text-align: left; color: #666; font-size: 0.8em; text-transform: uppercase;
         letter-spacing: 0.05em; padding: 6px 8px; border-bottom: 1px solid #222; }
    td { padding: 6px 8px; border-bottom: 1px solid #1a1a1a; font-size: 0.9em; }
    .mono { font-family: "SF Mono", "Cascadia Code", "Fira Code", monospace; font-size: 0.85em; }
    .muted { color: #555; }
    ul { list-style: none; padding: 0; }
    li { padding: 4px 0; }
    .refresh-note { color: #444; font-size: 0.75em; margin-top: 32px; text-align: center; }
    a { color: #6a9ef5; text-decoration: none; }
    a:hover { text-decoration: underline; }
  </style>
</head>
<body>
  <h1>⚡ baudbot</h1>
  <div class="subtitle">control plane &mdash; port ${PORT}</div>

  <h2>Agent</h2>
  <div class="row">
    <div class="card">
      <div class="stat-label">Status</div>
      <div class="stat-value">${statusDot} ${agent.running ? "Running" : "Stopped"}</div>
    </div>
    <div class="card">
      <div class="stat-label">Processes</div>
      <div class="stat-value">${agent.processCount}</div>
    </div>
    <div class="card">
      <div class="stat-label">Slack Bridge</div>
      <div class="stat-value">${bridgeDot} ${agent.bridge ? `PID ${agent.bridge.pid} &mdash; ${agent.bridge.uptime}` : "Not running"}</div>
    </div>
    <div class="card">
      <div class="stat-label">Deploy Version</div>
      <div class="stat-value" style="font-size:0.95em">${versionHtml}</div>
    </div>
  </div>

  <h2>Pi Sessions</h2>
  <div class="card">
    <table>
      <thead><tr><th>PID</th><th>Command</th><th>Uptime</th></tr></thead>
      <tbody>${sessionsHtml}</tbody>
    </table>
  </div>

  <div class="card">
    <div class="stat-label" style="margin-bottom:8px">Named Sockets</div>
    <ul>${socketSessionsHtml}</ul>
  </div>

  <h2>System</h2>
  <div class="row">
    <div class="card">
      <div class="stat-label">Host</div>
      <div class="stat-value mono">${esc(system.hostname || "unknown")}</div>
    </div>
    <div class="card">
      <div class="stat-label">Load Average</div>
      <div class="stat-value mono">${esc(system.loadAvg || "n/a")}</div>
    </div>
    <div class="card">
      <div class="stat-label">Memory</div>
      <div class="stat-value">${system.memory ? `${system.memory.usedMb}/${system.memory.totalMb} MB` : "n/a"}</div>
    </div>
    <div class="card">
      <div class="stat-label">Disk</div>
      <div class="stat-value">${system.disk ? `${system.disk.used}/${system.disk.size} (${system.disk.pct})` : "n/a"}</div>
    </div>
  </div>

  <h2>Configuration</h2>
  <div class="card">
    <table>
      <thead><tr><th>Variable</th><th>Status</th></tr></thead>
      <tbody>${configHtml}</tbody>
    </table>
  </div>

  <div class="refresh-note">Auto-refreshes every 30 seconds &mdash; <a href="/dashboard">refresh now</a> &mdash; <a href="/status">JSON</a></div>
</body>
</html>`);
});

// ── HTML escaping ───────────────────────────────────────────────────────────

function esc(str) {
  if (!str) return "";
  return String(str)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

// ── Start ───────────────────────────────────────────────────────────────────

const server = createServer(app);

server.listen(PORT, "127.0.0.1", () => {
  console.log(`🔧 baudbot control plane listening on http://127.0.0.1:${PORT}/`);
  if (!TOKEN) {
    console.log("⚠️  No BAUDBOT_CP_TOKEN set — running without auth (localhost only)");
  }
});

function shutdown(signal) {
  console.log(`\n${signal} received — shutting down`);
  server.close(() => process.exit(0));
  setTimeout(() => process.exit(1), 5000);
}

process.on("SIGTERM", () => shutdown("SIGTERM"));
process.on("SIGINT", () => shutdown("SIGINT"));
