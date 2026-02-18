#!/usr/bin/env node
/**
 * Slack ↔ Pi Control Agent Bridge
 *
 * Bridges @mentions in Slack to a pi session via its Unix domain socket.
 * Uses Socket Mode (no public URL needed).
 *
 * Required env vars:
 *   SLACK_BOT_TOKEN        - Slack bot OAuth token
 *   SLACK_APP_TOKEN        - Slack app-level token (for Socket Mode)
 *   SLACK_ALLOWED_USERS    - comma-separated Slack user IDs (REQUIRED, fail-closed)
 *
 * Optional:
 *   PI_SESSION_ID          - target pi session ID (defaults to auto-detect control-agent)
 *   SLACK_CHANNEL_ID       - if set, also responds to all messages in this channel (not just @mentions)
 *   SENTRY_CHANNEL_ID      - Slack channel ID for Sentry alerts (forwarded to agent)
 *   BRIDGE_API_PORT        - outbound API port (default: 7890)
 */

// Env vars loaded and validated by varlock (via `varlock run` or `start.sh`).
// No dotenv/varlock import needed — env is already in process.env.
import { App } from "@slack/bolt";
import * as net from "node:net";
import * as fs from "node:fs";
import * as path from "node:path";
import { homedir } from "node:os";
import { createServer } from "node:http";
import {
  detectSuspiciousPatterns,
  wrapExternalContent,
  parseAllowedUsers,
  isAllowed,
  cleanMessage,
  formatForSlack,
  validateSendParams,
  validateReactParams,
  createRateLimiter,
} from "./security.mjs";

// ── Config ──────────────────────────────────────────────────────────────────

const SOCKET_DIR = path.join(homedir(), ".pi", "session-control");
const AGENT_TIMEOUT_MS = 120_000;
const API_PORT = parseInt(process.env.BRIDGE_API_PORT || "7890", 10);

// Validate required env vars
for (const key of ["SLACK_BOT_TOKEN", "SLACK_APP_TOKEN"]) {
  if (!process.env[key]) {
    console.error(`❌ Missing required env var: ${key}`);
    process.exit(1);
  }
}

// ── Access Control (fail-closed) ────────────────────────────────────────────

const ALLOWED_USERS = parseAllowedUsers(process.env.SLACK_ALLOWED_USERS);

if (ALLOWED_USERS.length === 0) {
  console.error("❌ SLACK_ALLOWED_USERS is empty — refusing to start with open access.");
  console.error("   Set at least one Slack user ID (comma-separated).");
  process.exit(1);
}

console.log(`🔒 Access control: ${ALLOWED_USERS.length} allowed user(s)`);

// ── Rate Limiting ───────────────────────────────────────────────────────────

const slackRateLimiter = createRateLimiter({ maxRequests: 5, windowMs: 60_000 });
const apiRateLimiter = createRateLimiter({ maxRequests: 30, windowMs: 60_000 });

// ── Thread Registry ─────────────────────────────────────────────────────────
// Maps friendly thread IDs (e.g. "thread-1") to { channel, thread_ts }.
// Deterministic: same channel+thread_ts always maps to the same ID.

const threadRegistry = new Map();   // thread-N → { channel, thread_ts, createdAt }
const threadLookup = new Map();     // "channel:thread_ts" → thread-N
let threadCounter = 0;
const MAX_THREADS = 10_000;

/**
 * Evict the oldest entries when the registry exceeds MAX_THREADS.
 * Maps iterate in insertion order, so the first entries are the oldest.
 */
function evictOldThreads() {
  if (threadRegistry.size < MAX_THREADS) return;
  // Evict the oldest 10% to avoid evicting on every single new thread
  const evictCount = Math.max(1, Math.floor(MAX_THREADS * 0.1));
  let removed = 0;
  for (const [id, entry] of threadRegistry) {
    if (removed >= evictCount) break;
    const lookupKey = `${entry.channel}:${entry.thread_ts}`;
    threadLookup.delete(lookupKey);
    threadRegistry.delete(id);
    removed++;
  }
  console.log(`🧹 Evicted ${removed} old thread entries (registry size: ${threadRegistry.size})`);
}

/**
 * Get or create a friendly thread ID for a channel + thread_ts pair.
 * Returns the thread ID string (e.g. "thread-3").
 */
function getThreadId(channel, threadTs) {
  const key = `${channel}:${threadTs}`;
  let id = threadLookup.get(key);
  if (!id) {
    evictOldThreads();
    threadCounter++;
    id = `thread-${threadCounter}`;
    threadRegistry.set(id, { channel, thread_ts: threadTs, createdAt: Date.now() });
    threadLookup.set(key, id);
    console.log(`🧵 Registered ${id} → channel=${channel} thread_ts=${threadTs}`);
  }
  return id;
}

// ── Session Socket ──────────────────────────────────────────────────────────

function findSessionSocket(targetId) {
  if (targetId) {
    // Try as UUID first
    const sock = path.join(SOCKET_DIR, `${targetId}.sock`);
    if (fs.existsSync(sock)) return sock;

    // Try as session name — check the alias symlinks
    const aliasDir = path.join(SOCKET_DIR, "by-name");
    if (fs.existsSync(aliasDir)) {
      const aliasSock = path.join(aliasDir, `${targetId}.sock`);
      if (fs.existsSync(aliasSock)) return fs.realpathSync(aliasSock);
    }

    // Fallback: scan sockets and try to match by name via RPC
    throw new Error(`Socket not found for session "${targetId}". Use the full session UUID from: ls ~/.pi/session-control/`);
  }
  // Auto-detect: pick the first available socket
  const socks = fs.readdirSync(SOCKET_DIR).filter((f) => f.endsWith(".sock"));
  if (socks.length === 0) throw new Error("No pi sessions with control sockets found");
  if (socks.length === 1) return path.join(SOCKET_DIR, socks[0]);
  console.log("Multiple sessions found. Set PI_SESSION_ID to pick one:");
  socks.forEach((s) => console.log(`  ${s.replace(".sock", "")}`));
  throw new Error("Ambiguous — multiple sessions found");
}

// ── Pi RPC Client ───────────────────────────────────────────────────────────

/**
 * Send a message to the pi agent and wait for its reply.
 *
 * Flow: connect → subscribe to turn_end → send message → wait for
 * turn_end event → get_message → return response → disconnect.
 */
function sendToAgent(socketPath, message) {
  return new Promise((resolve, reject) => {
    let settled = false;
    const settle = (fn, value) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      client.destroy();
      fn(value);
    };

    const client = net.createConnection(socketPath, () => {
      // Subscribe to turn_end first, then send
      client.write(JSON.stringify({ type: "subscribe", event: "turn_end" }) + "\n");
      client.write(JSON.stringify({ type: "send", message, mode: "steer" }) + "\n");
    });

    let buffer = "";

    client.on("data", (chunk) => {
      buffer += chunk.toString();
      const lines = buffer.split("\n");
      buffer = lines.pop() || ""; // keep incomplete trailing data

      for (const line of lines) {
        if (!line.trim()) continue;
        try {
          const msg = JSON.parse(line);

          // Ack responses for subscribe/send — skip
          if (msg.type === "response" && (msg.command === "subscribe" || msg.command === "send")) {
            if (msg.command === "send" && !msg.success) {
              settle(reject, new Error(msg.error || "Failed to send message to agent"));
            }
            continue;
          }

          // turn_end event — agent finished, fetch its reply
          if (msg.type === "event" && msg.event === "turn_end") {
            client.write(JSON.stringify({ type: "get_message" }) + "\n");
            continue;
          }

          // get_message response — done!
          if (msg.type === "response" && msg.command === "get_message") {
            const text = msg.data?.message?.content || "(no response)";
            settle(resolve, text);
            return;
          }
        } catch {
          // partial JSON, wait for more
        }
      }
    });

    client.on("error", (err) => {
      settle(reject, new Error(`Socket error: ${err.message}. Is the pi session still running?`));
    });

    const timer = setTimeout(() => {
      settle(reject, new Error(`Agent did not respond within ${AGENT_TIMEOUT_MS / 1000}s`));
    }, AGENT_TIMEOUT_MS);
  });
}

// ── Request Queue ───────────────────────────────────────────────────────────
// Serialize requests so we don't interleave multiple Slack messages into the
// same agent turn.

let queue = Promise.resolve();

function enqueue(fn) {
  const p = queue.then(fn, fn); // run even if previous rejected
  queue = p.then(() => {}, () => {}); // swallow so chain continues
  return p;
}

// ── Slack App ───────────────────────────────────────────────────────────────

const app = new App({
  token: process.env.SLACK_BOT_TOKEN,
  appToken: process.env.SLACK_APP_TOKEN,
  socketMode: true,
});

let socketPath = null;
try {
  socketPath = findSessionSocket(process.env.PI_SESSION_ID);
  console.log(`🔌 Using pi session socket: ${socketPath}`);
} catch {
  console.log(`⏳ No pi session socket found yet — will resolve when first message arrives`);
}

/** Re-resolve the socket path (handles session restarts). */
function refreshSocket() {
  try {
    socketPath = findSessionSocket(process.env.PI_SESSION_ID);
  } catch {
    socketPath = null;
  }
}

async function handleMessage(userMessage, event, say) {
  if (!isAllowed(event.user, ALLOWED_USERS)) {
    console.log(`🚫 Blocked message from <@${event.user}>: ${userMessage}`);
    await say({ text: "Sorry, I'm not configured to respond to you.", thread_ts: event.ts });
    return;
  }

  // Rate limiting (per-user, 5 msgs/min)
  if (!slackRateLimiter.check(event.user)) {
    console.log(`⏱️ Rate limited <@${event.user}>`);
    await say({ text: "Slow down — too many messages. Try again in a minute.", thread_ts: event.ts });
    return;
  }

  // Prompt injection detection (log only, don't block)
  const suspicious = detectSuspiciousPatterns(userMessage);
  if (suspicious.length > 0) {
    console.log(`⚠️  Suspicious patterns from <@${event.user}>: ${suspicious.join(", ")}`);
  }

  console.log(`💬 from <@${event.user}>: ${userMessage}`);

  // React with eyes to show we're working
  try {
    await app.client.reactions.add({
      token: process.env.SLACK_BOT_TOKEN,
      channel: event.channel,
      name: "eyes",
      timestamp: event.ts,
    });
  } catch {}

  try {
    // Always re-resolve the socket before sending (handles agent restarts).
    // Capture into a local to avoid TOCTOU with concurrent handleMessage calls.
    refreshSocket();
    const currentSocket = socketPath;
    if (!currentSocket) {
      await say({ text: "⏳ Agent is starting up — try again in a moment.", thread_ts: event.ts });
      return;
    }

    // Wrap the message with security boundaries before sending to agent
    const wrappedMessage = wrapExternalContent({
      text: userMessage,
      source: "Slack",
      user: event.user,
      channel: event.channel,
      threadTs: event.ts,
    });

    // Enrich with friendly thread ID so the agent can use /reply endpoint
    const threadId = getThreadId(event.channel, event.thread_ts || event.ts);
    const contextMessage = `${wrappedMessage}\n[Bridge-Thread-ID: ${threadId}]`;

    const reply = await enqueue(() => sendToAgent(currentSocket, contextMessage));
    const formatted = formatForSlack(reply);
    await say({ text: formatted, thread_ts: event.ts });

    // Swap eyes → checkmark
    try {
      await app.client.reactions.remove({
        token: process.env.SLACK_BOT_TOKEN,
        channel: event.channel,
        name: "eyes",
        timestamp: event.ts,
      });
      await app.client.reactions.add({
        token: process.env.SLACK_BOT_TOKEN,
        channel: event.channel,
        name: "white_check_mark",
        timestamp: event.ts,
      });
    } catch {}
  } catch (err) {
    console.error("Error:", err.message);
    refreshSocket();
    await say({ text: `❌ Error: ${err.message}`, thread_ts: event.ts });
  }
}

// Handle @mentions
app.event("app_mention", async ({ event, say }) => {
  const userMessage = cleanMessage(event.text);
  if (!userMessage) {
    await say({ text: "👋 I'm here! Send me a message.", thread_ts: event.ts });
    return;
  }
  await handleMessage(userMessage, event, say);
});

// Handle DMs and optional channel messages
app.event("message", async ({ event, say }) => {
  const targetChannel = process.env.SLACK_CHANNEL_ID;
  const sentryChannel = process.env.SENTRY_CHANNEL_ID || "";
  const isDM = event.channel_type === "im";
  const isTargetChannel = targetChannel && event.channel === targetChannel;
  const isSentryChannel = event.channel === sentryChannel;

  // Forward #bots-sentry messages (including bot messages) as fire-and-forget
  if (isSentryChannel) {
    const text = event.text?.trim();
    if (!text) return;
    // Don't filter bot_id here — Sentry posts as a bot
    const wrappedSentryMessage = wrapExternalContent({
      text,
      source: "Slack (#bots-sentry)",
      user: event.user || event.bot_id || "sentry-bot",
      channel: event.channel,
      threadTs: event.ts,
    });

    // Enrich with friendly thread ID
    const sentryThreadId = getThreadId(event.channel, event.thread_ts || event.ts);
    const contextMessage = `${wrappedSentryMessage}\n[Bridge-Thread-ID: ${sentryThreadId}]`;

    try {
      // Re-resolve socket before sending (capture local to avoid TOCTOU)
      refreshSocket();
      const currentSocket = socketPath;
      if (!currentSocket) {
        console.log("⏳ Sentry alert dropped — agent not ready yet");
        return;
      }
      // Fire and forget — don't wait for agent response, don't reply in channel
      await enqueue(() => sendToAgent(currentSocket, contextMessage));
    } catch (err) {
      console.error("Sentry alert forward error:", err.message);
      refreshSocket();
    }
    return;
  }

  if (!isDM && !isTargetChannel) return;
  if (event.bot_id || event.subtype) return; // ignore bots and edits

  const userMessage = event.text?.trim();
  if (!userMessage) return;

  await handleMessage(userMessage, event, say);
});

// ── Outbound HTTP API ────────────────────────────────────────────────────────
// Local HTTP server so the control agent can send messages TO Slack via curl.
//
// POST http://localhost:7890/send
//   { "channel": "C07...", "text": "hello", "thread_ts": "1234.5678" }
//
// POST http://localhost:7890/reply
//   { "thread_id": "thread-1", "text": "hello" }
//
// POST http://localhost:7890/react
//   { "channel": "C07...", "timestamp": "1234.5678", "emoji": "white_check_mark" }

function startApiServer() {
  const server = createServer(async (req, res) => {
    // Only accept POST
    if (req.method !== "POST") {
      res.writeHead(405, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ error: "Method not allowed" }));
      return;
    }

    // Only accept local connections
    const remoteAddr = req.socket.remoteAddress;
    if (remoteAddr !== "127.0.0.1" && remoteAddr !== "::1" && remoteAddr !== "::ffff:127.0.0.1") {
      res.writeHead(403, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ error: "Forbidden — local only" }));
      return;
    }

    // Rate limit the API (30 req/min global)
    if (!apiRateLimiter.check("global")) {
      res.writeHead(429, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ error: "Too many requests — try again later" }));
      return;
    }

    // Read body
    let body = "";
    for await (const chunk of req) body += chunk;

    let params;
    try {
      params = JSON.parse(body);
    } catch {
      res.writeHead(400, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ error: "Invalid JSON" }));
      return;
    }

    try {
      const url = new URL(req.url, `http://localhost:${API_PORT}`);
      const pathname = url.pathname;

      if (pathname === "/send") {
        const validationError = validateSendParams(params);
        if (validationError) {
          res.writeHead(400, { "Content-Type": "application/json" });
          res.end(JSON.stringify({ error: validationError }));
          return;
        }

        const { channel, text, thread_ts } = params;
        const result = await app.client.chat.postMessage({
          token: process.env.SLACK_BOT_TOKEN,
          channel,
          text,
          ...(thread_ts && { thread_ts }),
        });

        console.log(`📤 Sent to ${channel}: ${text.slice(0, 80)}${text.length > 80 ? "..." : ""}`);
        res.writeHead(200, { "Content-Type": "application/json" });
        res.end(JSON.stringify({ ok: true, ts: result.ts, channel: result.channel }));

      } else if (pathname === "/reply") {
        // Look up thread by friendly ID and post a reply
        const { thread_id, text } = params;

        if (typeof thread_id !== "string" || !thread_id) {
          res.writeHead(400, { "Content-Type": "application/json" });
          res.end(JSON.stringify({ error: "thread_id must be a non-empty string" }));
          return;
        }
        if (typeof text !== "string" || text.length === 0) {
          res.writeHead(400, { "Content-Type": "application/json" });
          res.end(JSON.stringify({ error: "text must be a non-empty string" }));
          return;
        }
        if (text.length > 4000) {
          res.writeHead(400, { "Content-Type": "application/json" });
          res.end(JSON.stringify({ error: "text too long (max 4000)" }));
          return;
        }

        const thread = threadRegistry.get(thread_id);
        if (!thread) {
          res.writeHead(404, { "Content-Type": "application/json" });
          res.end(JSON.stringify({ error: `Unknown thread_id: ${thread_id}` }));
          return;
        }

        const result = await app.client.chat.postMessage({
          token: process.env.SLACK_BOT_TOKEN,
          channel: thread.channel,
          text,
          thread_ts: thread.thread_ts,
        });

        console.log(`📤 Reply to ${thread_id} (${thread.channel}): ${text.slice(0, 80)}${text.length > 80 ? "..." : ""}`);
        res.writeHead(200, { "Content-Type": "application/json" });
        res.end(JSON.stringify({ ok: true, ts: result.ts, channel: result.channel }));

      } else if (pathname === "/react") {
        const validationError = validateReactParams(params);
        if (validationError) {
          res.writeHead(400, { "Content-Type": "application/json" });
          res.end(JSON.stringify({ error: validationError }));
          return;
        }

        const { channel, timestamp, emoji } = params;
        await app.client.reactions.add({
          token: process.env.SLACK_BOT_TOKEN,
          channel,
          timestamp,
          name: emoji,
        });

        res.writeHead(200, { "Content-Type": "application/json" });
        res.end(JSON.stringify({ ok: true }));

      } else {
        res.writeHead(404, { "Content-Type": "application/json" });
        res.end(JSON.stringify({ error: "Not found. Endpoints: POST /send, POST /reply, POST /react" }));
      }
    } catch (err) {
      console.error("API error:", err.message);
      res.writeHead(500, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ error: err.message }));
    }
  });

  server.listen(API_PORT, "127.0.0.1", () => {
    console.log(`📡 Outbound API listening on http://127.0.0.1:${API_PORT}`);
    console.log(`   POST /send   {"channel":"C...","text":"...","thread_ts":"..."}`);
    console.log(`   POST /reply  {"thread_id":"thread-1","text":"..."}`);
    console.log(`   POST /react  {"channel":"C...","timestamp":"...","emoji":"..."}`);
  });
}

// ── Start ───────────────────────────────────────────────────────────────────

(async () => {
  await app.start();
  startApiServer();
  console.log("⚡ Slack bridge is running!");
  console.log("   • @mention the bot in any channel");
  console.log("   • DM the bot directly");
  if (process.env.SLACK_CHANNEL_ID) {
    console.log(`   • All messages in channel ${process.env.SLACK_CHANNEL_ID}`);
  }
})();
