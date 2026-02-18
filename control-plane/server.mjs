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
 *   GET  /logs       — recent session log entries (JSON)
 *   GET  /dashboard  — server-rendered HTML overview (status + logs tabs)
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

/** Timing-safe token comparison (constant-time regardless of length mismatch). */
function tokenMatches(provided) {
  if (!TOKEN || !provided) return false;
  const a = Buffer.from(TOKEN);
  const b = Buffer.from(provided);
  // Pad to equal length to avoid leaking token length via timing
  const len = Math.max(a.length, b.length);
  const aPadded = Buffer.alloc(len);
  const bPadded = Buffer.alloc(len);
  a.copy(aPadded);
  b.copy(bPadded);
  return timingSafeEqual(aPadded, bPadded) && a.length === b.length;
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

/** HTML-escape a string. */
function esc(str) {
  if (!str) return "";
  return String(str)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
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

// ── Session logs ────────────────────────────────────────────────────────────

/**
 * Find all session JSONL files under the agent's session directory.
 * Returns them sorted by modification time (most recent first).
 */
function findSessionFiles() {
  const sessionsDir = join(AGENT_HOME, ".pi", "agent", "sessions");
  const files = [];
  try {
    if (!existsSync(sessionsDir)) return files;
    for (const subdir of readdirSync(sessionsDir)) {
      const subdirPath = join(sessionsDir, subdir);
      try {
        const entries = readdirSync(subdirPath);
        for (const f of entries) {
          if (!f.endsWith(".jsonl")) continue;
          const fullPath = join(subdirPath, f);
          try {
            const st = statSync(fullPath);
            files.push({ path: fullPath, name: f, dir: subdir, mtime: st.mtimeMs, size: st.size });
          } catch {}
        }
      } catch {}
    }
  } catch {}
  files.sort((a, b) => b.mtime - a.mtime);
  return files;
}

/**
 * Read the last N entries from a JSONL session file.
 * Returns parsed objects, filtered to useful types (messages and tool results).
 */
function tailSessionFile(filePath, maxEntries = 50) {
  try {
    const content = readFileSync(filePath, "utf8");
    const lines = content.trim().split("\n").filter(Boolean);
    const entries = [];
    // Read from the end
    for (let i = lines.length - 1; i >= 0 && entries.length < maxEntries * 3; i--) {
      try {
        entries.unshift(JSON.parse(lines[i]));
      } catch {}
    }
    return entries;
  } catch {
    return [];
  }
}

/**
 * Extract a readable summary from a session entry.
 */
function summarizeEntry(entry) {
  const base = {
    type: entry.type,
    timestamp: entry.timestamp,
    id: entry.id,
  };

  if (entry.type === "session") {
    return { ...base, detail: `Session started (cwd: ${entry.cwd || "unknown"})` };
  }

  if (entry.type === "message") {
    const msg = entry.message || {};
    const role = msg.role || "unknown";
    let text = "";

    if (Array.isArray(msg.content)) {
      const textParts = msg.content.filter((c) => c.type === "text").map((c) => c.text || "");
      text = textParts.join(" ");
    } else if (typeof msg.content === "string") {
      text = msg.content;
    }

    // For tool calls, extract the tool name
    if (role === "assistant" && Array.isArray(msg.content)) {
      const toolUse = msg.content.find((c) => c.type === "tool_use");
      if (toolUse) {
        return { ...base, role, detail: `Tool call: ${toolUse.name}`, toolName: toolUse.name };
      }
    }

    // For tool results, show tool name and truncated output
    if (role === "toolResult" || msg.role === "tool") {
      const toolName = msg.toolName || "unknown";
      return { ...base, role: "toolResult", detail: text.slice(0, 200), toolName };
    }

    return { ...base, role, detail: text.slice(0, 300) };
  }

  if (entry.type === "compaction") {
    return { ...base, detail: "Session compacted" };
  }

  // Skip noise: thinking_level_change, model_change, custom, etc.
  return null;
}

/**
 * Get recent log entries across all sessions or a specific one.
 * @param {object} opts
 * @param {string} [opts.session] - Filter by session filename substring
 * @param {number} [opts.lines=50] - Max entries to return
 * @param {boolean} [opts.messagesOnly=true] - Only show message-type entries
 */
function getRecentLogs({ session, lines = 50, messagesOnly = true } = {}) {
  let files = findSessionFiles();

  // Filter by session name if provided
  if (session) {
    files = files.filter((f) => f.name.includes(session) || f.dir.includes(session));
  }

  // Take the most recent files (limit to 10 to avoid reading too many)
  files = files.slice(0, 10);

  const allEntries = [];

  for (const file of files) {
    const raw = tailSessionFile(file.path, lines);
    // Extract session name from the first entry
    const sessionEntry = raw.find((e) => e.type === "session");
    const sessionId = sessionEntry?.id || file.name.replace(".jsonl", "");

    for (const entry of raw) {
      const summary = summarizeEntry(entry);
      if (!summary) continue;
      if (messagesOnly && !["message", "session", "compaction"].includes(summary.type)) continue;
      allEntries.push({ ...summary, sessionId });
    }
  }

  // Sort by timestamp descending, take the requested number
  allEntries.sort((a, b) => (b.timestamp || "").localeCompare(a.timestamp || ""));
  return allEntries.slice(0, lines);
}

/**
 * List available sessions with metadata (for session picker).
 */
function listSessions() {
  const files = findSessionFiles();
  return files.slice(0, 20).map((f) => {
    // Parse session name from first line
    let sessionName = null;
    try {
      const firstLine = readFileSync(f.path, "utf8").split("\n")[0];
      const parsed = JSON.parse(firstLine);
      if (parsed.type === "session") {
        sessionName = parsed.name || parsed.id;
      }
    } catch {}

    return {
      file: f.name,
      dir: f.dir,
      sessionId: sessionName || f.name.replace(".jsonl", ""),
      modified: new Date(f.mtime).toISOString(),
      sizeKb: Math.round(f.size / 1024),
    };
  });
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

app.get("/logs", (req, res) => {
  const session = req.query.session || undefined;
  const lines = Math.min(parseInt(req.query.lines || "50", 10), 500);
  const entries = getRecentLogs({ session, lines });
  res.json({ entries, count: entries.length });
});

app.get("/sessions", (_req, res) => {
  const sessions = listSessions();
  res.json({ sessions });
});

// ── Dashboard ───────────────────────────────────────────────────────────────

app.get("/", (_req, res) => res.redirect("/dashboard"));

app.get("/dashboard", (req, res) => {
  const tab = req.query.tab || "status";
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

  // Build logs HTML
  const logs = getRecentLogs({ lines: 100 });
  const logsHtml = logs.length
    ? logs
        .map((entry) => {
          const time = entry.timestamp
            ? new Date(entry.timestamp).toLocaleTimeString("en-US", { hour12: false })
            : "";
          const date = entry.timestamp
            ? new Date(entry.timestamp).toLocaleDateString("en-US", { month: "short", day: "numeric" })
            : "";
          const roleClass = entry.role === "user" ? "log-user" : entry.role === "assistant" ? "log-assistant" : "log-tool";
          const roleLabel = entry.role === "user" ? "USER" : entry.role === "assistant" ? "AGENT" : entry.role === "toolResult" ? "TOOL" : entry.type?.toUpperCase() || "";
          const detail = esc(entry.detail || "").replace(/\n/g, "<br>");
          const toolBadge = entry.toolName ? `<span class="tool-badge">${esc(entry.toolName)}</span> ` : "";
          return `<div class="log-entry ${roleClass}"><span class="log-time">${date} ${time}</span><span class="log-role">${roleLabel}</span>${toolBadge}<span class="log-detail">${detail}</span></div>`;
        })
        .join("")
    : '<div class="muted" style="padding:16px">No session logs found</div>';

  const statusTabClass = tab === "status" ? "tab-active" : "";
  const logsTabClass = tab === "logs" ? "tab-active" : "";

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

    /* Tabs */
    .tabs { display: flex; gap: 0; margin-bottom: 24px; border-bottom: 1px solid #222; }
    .tab { padding: 8px 20px; color: #666; cursor: pointer; text-decoration: none;
           font-size: 0.9em; border-bottom: 2px solid transparent; transition: all 0.15s; }
    .tab:hover { color: #aaa; }
    .tab-active { color: #fff; border-bottom-color: #6a9ef5; }
    .tab-content { display: none; }
    .tab-content.active { display: block; }

    /* Logs */
    .log-entry { padding: 4px 8px; border-bottom: 1px solid #1a1a1a; font-size: 0.82em;
                 display: flex; gap: 8px; align-items: baseline; }
    .log-entry:hover { background: #151515; }
    .log-time { color: #555; font-family: "SF Mono", monospace; font-size: 0.85em; white-space: nowrap; min-width: 110px; }
    .log-role { font-family: "SF Mono", monospace; font-size: 0.8em; min-width: 50px;
                font-weight: 600; text-transform: uppercase; }
    .log-user .log-role { color: #6a9ef5; }
    .log-assistant .log-role { color: #7ec87e; }
    .log-tool .log-role { color: #c89b6e; }
    .log-detail { color: #bbb; word-break: break-word; flex: 1; }
    .tool-badge { background: #1a1a2e; color: #8888cc; padding: 1px 6px; border-radius: 3px;
                  font-size: 0.85em; font-family: "SF Mono", monospace; }
    .log-scroll { max-height: 600px; overflow-y: auto; }
  </style>
</head>
<body>
  <h1>⚡ baudbot</h1>
  <div class="subtitle">control plane &mdash; port ${PORT}</div>

  <div class="tabs">
    <a href="/dashboard?tab=status" class="tab ${statusTabClass}">Status</a>
    <a href="/dashboard?tab=logs" class="tab ${logsTabClass}">Logs</a>
  </div>

  <div class="tab-content ${tab === "status" ? "active" : ""}">
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
  </div>

  <div class="tab-content ${tab === "logs" ? "active" : ""}">
    <h2>Recent Activity</h2>
    <div class="card">
      <div class="log-scroll">${logsHtml}</div>
    </div>
  </div>

  <div class="refresh-note">Auto-refreshes every 30s &mdash; <a href="/dashboard?tab=${tab}">refresh now</a> &mdash; JSON: <a href="/status">/status</a> <a href="/logs">/logs</a> <a href="/sessions">/sessions</a></div>
</body>
</html>`);
});

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
