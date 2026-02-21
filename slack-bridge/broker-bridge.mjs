#!/usr/bin/env node
/**
 * Slack broker pull bridge.
 *
 * Polls broker inbox, decrypts inbound Slack events, forwards them to the pi
 * agent, then sends replies back through broker /api/send.
 */

import * as net from "node:net";
import * as fs from "node:fs";
import * as path from "node:path";
import { homedir } from "node:os";
import { createServer } from "node:http";
import sodium from "libsodium-wrappers-sumo";
import {
  detectSuspiciousPatterns,
  wrapExternalContent,
  parseAllowedUsers,
  isAllowed,
  cleanMessage,
  validateSendParams,
  validateReactParams,
  createRateLimiter,
} from "./security.mjs";
import {
  stableStringify,
  canonicalizeEnvelope,
  canonicalizeOutbound,
  canonicalizeSendRequest,
} from "./crypto.mjs";

const SOCKET_DIR = path.join(homedir(), ".pi", "session-control");
const AGENT_TIMEOUT_MS = 120_000;
const API_PORT = parseInt(process.env.BRIDGE_API_PORT || "7890", 10);
const POLL_INTERVAL_MS = parseInt(process.env.SLACK_BROKER_POLL_INTERVAL_MS || "3000", 10);
const MAX_MESSAGES = parseInt(process.env.SLACK_BROKER_MAX_MESSAGES || "10", 10);
const DEDUPE_TTL_MS = parseInt(process.env.SLACK_BROKER_DEDUPE_TTL_MS || String(20 * 60 * 1000), 10);
const MAX_BACKOFF_MS = 30_000;

function ts() {
  return new Date().toISOString();
}

function logInfo(...args) {
  console.log(`[${ts()}]`, ...args);
}

function logError(...args) {
  console.error(`[${ts()}]`, ...args);
}

function logWarn(...args) {
  console.warn(`[${ts()}]`, ...args);
}

for (const key of [
  "SLACK_BROKER_URL",
  "SLACK_BROKER_WORKSPACE_ID",
  "SLACK_BROKER_SERVER_PRIVATE_KEY",
  "SLACK_BROKER_SERVER_PUBLIC_KEY",
  "SLACK_BROKER_SERVER_SIGNING_PRIVATE_KEY",
  "SLACK_BROKER_PUBLIC_KEY",
  "SLACK_BROKER_SIGNING_PUBLIC_KEY",
]) {
  if (!process.env[key]) {
    logError(`❌ Missing required env var for broker mode: ${key}`);
    process.exit(1);
  }
}

const ALLOWED_USERS = parseAllowedUsers(process.env.SLACK_ALLOWED_USERS);
if (ALLOWED_USERS.length === 0) {
  logWarn("⚠️  SLACK_ALLOWED_USERS not set — all workspace members can interact");
}

const slackRateLimiter = createRateLimiter({ maxRequests: 5, windowMs: 60_000 });
const apiRateLimiter = createRateLimiter({ maxRequests: 30, windowMs: 60_000 });
const directSlackRateLimiter = createRateLimiter({ maxRequests: 1, windowMs: 1_000 }); // 1 req/sec

const workspaceId = process.env.SLACK_BROKER_WORKSPACE_ID;
const brokerBaseUrl = String(process.env.SLACK_BROKER_URL || "").replace(/\/$/, "");

// Check if direct Slack API mode is available
const hasDirectSlackToken = Boolean(process.env.SLACK_BOT_TOKEN);
const outboundMode = hasDirectSlackToken ? "direct" : "broker";

const threadRegistry = new Map();
const threadLookup = new Map();
let threadCounter = 0;
const MAX_THREADS = 10_000;

let socketPath = null;

let cryptoState = null;

const dedupe = new Map();

function toBase64(bytes) {
  return Buffer.from(bytes).toString("base64");
}

function fromBase64(value) {
  return new Uint8Array(Buffer.from(value, "base64"));
}

function utf8Bytes(text) {
  return new TextEncoder().encode(text);
}

function utf8String(bytes) {
  return new TextDecoder().decode(bytes);
}

// canonicalizeEnvelope, canonicalizeOutbound, canonicalizeSendRequest,
// and stableStringify are imported from ./crypto.mjs

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function findSessionSocket(targetId) {
  if (targetId) {
    const sock = path.join(SOCKET_DIR, `${targetId}.sock`);
    if (fs.existsSync(sock)) return sock;

    const aliasDir = path.join(SOCKET_DIR, "by-name");
    if (fs.existsSync(aliasDir)) {
      const aliasSock = path.join(aliasDir, `${targetId}.sock`);
      if (fs.existsSync(aliasSock)) return fs.realpathSync(aliasSock);
    }

    throw new Error(`Socket not found for session "${targetId}".`);
  }

  const socks = fs.readdirSync(SOCKET_DIR).filter((f) => f.endsWith(".sock"));
  if (socks.length === 0) throw new Error("No pi sessions with control sockets found");
  if (socks.length === 1) return path.join(SOCKET_DIR, socks[0]);
  throw new Error("Ambiguous — multiple sessions found");
}

function refreshSocket() {
  try {
    socketPath = findSessionSocket(process.env.PI_SESSION_ID);
  } catch {
    socketPath = null;
  }
}

/**
 * Fire-and-forget: deliver a message to the pi agent via its control socket.
 *
 * Connects, sends the message with mode "steer", waits only for the send
 * confirmation, then disconnects. The agent handles Slack replies itself
 * via the bridge's /send API endpoint — we do NOT wait for or return its
 * response.
 */
function sendToAgent(currentSocketPath, message) {
  return new Promise((resolve, reject) => {
    let settled = false;
    const settle = (fn, value) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      client.destroy();
      fn(value);
    };

    const client = net.createConnection(currentSocketPath, () => {
      client.write(JSON.stringify({ type: "send", message, mode: "steer" }) + "\n");
    });

    let buffer = "";

    client.on("data", (chunk) => {
      buffer += chunk.toString();
      const lines = buffer.split("\n");
      buffer = lines.pop() || "";

      for (const line of lines) {
        if (!line.trim()) continue;
        try {
          const msg = JSON.parse(line);

          if (msg.type === "response" && msg.command === "send") {
            if (msg.success) {
              settle(resolve, "delivered");
            } else {
              settle(reject, new Error(msg.error || "Failed to send message to agent"));
            }
            return;
          }
        } catch {
          // wait for more data
        }
      }
    });

    client.on("error", (err) => {
      settle(reject, new Error(`Socket error: ${err.message}`));
    });

    const timer = setTimeout(() => {
      settle(reject, new Error(`Agent send timed out after ${AGENT_TIMEOUT_MS / 1000}s`));
    }, AGENT_TIMEOUT_MS);
  });
}

let queue = Promise.resolve();
function enqueue(fn) {
  const p = queue.then(fn, fn);
  queue = p.then(() => {}, () => {});
  return p;
}

function evictOldThreads() {
  if (threadRegistry.size < MAX_THREADS) return;
  const evictCount = Math.max(1, Math.floor(MAX_THREADS * 0.1));
  let removed = 0;
  for (const [id, entry] of threadRegistry) {
    if (removed >= evictCount) break;
    threadLookup.delete(`${entry.channel}:${entry.thread_ts}`);
    threadRegistry.delete(id);
    removed++;
  }
}

function getThreadId(channel, threadTs) {
  const key = `${channel}:${threadTs}`;
  let id = threadLookup.get(key);
  if (!id) {
    evictOldThreads();
    threadCounter++;
    id = `thread-${threadCounter}`;
    threadRegistry.set(id, { channel, thread_ts: threadTs, createdAt: Date.now(), lastAccessAt: Date.now() });
    threadLookup.set(key, id);
  } else {
    const existing = threadRegistry.get(id);
    if (existing) {
      threadRegistry.delete(id);
      threadRegistry.set(id, { ...existing, lastAccessAt: Date.now() });
    }
  }
  return id;
}

function signRequest(action, timestamp, payloadField) {
  const canonical = canonicalizeOutbound(workspaceId, action, timestamp, payloadField);
  const sig = sodium.crypto_sign_detached(canonical, cryptoState.serverSignSecretKey);
  return toBase64(sig);
}

async function brokerFetch(pathname, body) {
  const url = `${brokerBaseUrl}${pathname}`;
  const response = await fetch(url, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });

  let rawBody = "";
  let payload = {};
  try {
    rawBody = await response.text();
    payload = JSON.parse(rawBody);
  } catch {
    // keep empty payload, rawBody has the text
  }

  if (!response.ok || payload?.ok === false) {
    const detail = payload?.error || rawBody?.slice(0, 200) || "no response body";
    const headers = Object.fromEntries(response.headers.entries());
    const cfRay = headers["cf-ray"] || "n/a";
    throw new Error(
      `broker ${pathname} failed — HTTP ${response.status} | error: ${detail} | cf-ray: ${cfRay} | ` +
      `content-type: ${headers["content-type"] || "n/a"}`
    );
  }

  return payload;
}

async function pullInbox() {
  const timestamp = Math.floor(Date.now() / 1000);
  const signature = signRequest("inbox.pull", timestamp, String(MAX_MESSAGES));

  const payload = await brokerFetch("/api/inbox/pull", {
    workspace_id: workspaceId,
    max_messages: MAX_MESSAGES,
    timestamp,
    signature,
  });

  return Array.isArray(payload.messages) ? payload.messages : [];
}

async function ackInbox(messageIds) {
  if (messageIds.length === 0) return;
  const timestamp = Math.floor(Date.now() / 1000);
  const joined = messageIds.join(",");
  const signature = signRequest("inbox.ack", timestamp, joined);

  await brokerFetch("/api/inbox/ack", {
    workspace_id: workspaceId,
    message_ids: messageIds,
    timestamp,
    signature,
  });
}

async function sendViaBroker({ action, routing, body }) {
  const timestamp = Math.floor(Date.now() / 1000);
  const plaintext = utf8Bytes(JSON.stringify(body));
  const nonce = sodium.randombytes_buf(sodium.crypto_box_NONCEBYTES);
  const ciphertext = sodium.crypto_box_easy(
    plaintext,
    nonce,
    cryptoState.brokerPubkey,
    cryptoState.serverBoxSecretKey,
  );

  const encryptedBody = toBase64(ciphertext);
  const nonceB64 = toBase64(nonce);

  // Sign over full send payload (routing + nonce) to match broker's
  // canonicalizeSendRequest() from modem-dev/baudbot-services#12.
  const canonical = canonicalizeSendRequest(
    workspaceId, action, timestamp, encryptedBody, nonceB64, routing,
  );
  const sig = sodium.crypto_sign_detached(canonical, cryptoState.serverSignSecretKey);
  const signature = toBase64(sig);

  return brokerFetch("/api/send", {
    workspace_id: workspaceId,
    action,
    routing,
    encrypted_body: encryptedBody,
    nonce: nonceB64,
    timestamp,
    signature,
  });
}

/**
 * Sanitize error messages to prevent token leakage.
 * Replaces any SLACK_BOT_TOKEN occurrences with [REDACTED].
 */
function sanitizeError(error) {
  if (typeof error !== "string") {
    error = String(error);
  }
  const botToken = process.env.SLACK_BOT_TOKEN;
  if (botToken && botToken.length > 10) {
    // Replace the token with [REDACTED], being careful about partial matches
    error = error.replace(new RegExp(escapeRegex(botToken), 'g'), '[REDACTED]');
  }
  return error;
}

function escapeRegex(string) {
  return string.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

/**
 * Send message to Slack using direct API call with bot token.
 * Used when SLACK_BOT_TOKEN is available.
 */
async function sendDirectToSlack(apiMethod, params) {
  // Rate limiting for direct API calls
  if (!directSlackRateLimiter.check('global')) {
    throw new Error('Rate limit exceeded for direct Slack API calls. Try again in a moment.');
  }

  try {
    const response = await fetch(`https://slack.com/api/${apiMethod}`, {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${process.env.SLACK_BOT_TOKEN}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify(params),
    });

    const data = await response.json();
    
    if (!response.ok || !data.ok) {
      const error = data.error || response.statusText;
      throw new Error(`Slack API ${apiMethod} failed: ${sanitizeError(error)}`);
    }
    
    return data;
  } catch (err) {
    // Sanitize any error messages to prevent token leakage
    const sanitizedMessage = sanitizeError(err.message || String(err));
    throw new Error(sanitizedMessage);
  }
}

async function say(channel, text, threadTs) {
  if (outboundMode === "direct") {
    const params = {
      channel,
      text,
      ...(threadTs ? { thread_ts: threadTs } : {}),
    };
    return await sendDirectToSlack("chat.postMessage", params);
  } else {
    // Fallback to broker mode
    await sendViaBroker({
      action: "chat.postMessage",
      routing: {
        channel,
        ...(threadTs ? { thread_ts: threadTs } : {}),
      },
      body: { text },
    });
  }
}

async function react(channel, threadTs, emoji) {
  if (outboundMode === "direct") {
    const params = {
      channel,
      timestamp: threadTs,
      name: emoji,
    };
    return await sendDirectToSlack("reactions.add", params);
  } else {
    // Fallback to broker mode
    await sendViaBroker({
      action: "reactions.add",
      routing: { channel, timestamp: threadTs, emoji },
      body: { emoji },
    });
  }
}

async function handleUserMessage(userMessage, event) {
  logInfo(`👤 message from <@${event.user}> in ${event.channel} (type: ${event.type}, ts: ${event.ts})`);

  if (!isAllowed(event.user, ALLOWED_USERS)) {
    logWarn(`🚫 user <@${event.user}> not in allowed list — rejecting`);
    await say(event.channel, "Sorry, I'm not configured to respond to you.", event.ts);
    return true;
  }

  if (!slackRateLimiter.check(event.user)) {
    await say(event.channel, "Slow down — too many messages. Try again in a minute.", event.ts);
    return true;
  }

  const suspicious = detectSuspiciousPatterns(userMessage);
  if (suspicious.length > 0) {
    logWarn(`⚠️ Suspicious patterns from <@${event.user}>: ${suspicious.join(", ")}`);
  }

  refreshSocket();
  const currentSocket = socketPath;
  if (!currentSocket) {
    logError("🔌 no pi socket found — agent may not be running");
    await say(event.channel, "⏳ Agent is starting up — try again in a moment.", event.ts);
    return true;
  }
  logInfo(`🔌 forwarding to agent via ${currentSocket}`);

  const wrappedMessage = wrapExternalContent({
    text: userMessage,
    source: "Slack (broker)",
    user: event.user,
    channel: event.channel,
    threadTs: event.ts,
  });

  const threadId = getThreadId(event.channel, event.thread_ts || event.ts);
  const contextMessage = `${wrappedMessage}\n[Bridge-Thread-ID: ${threadId}]`;

  // Fire-and-forget: deliver to agent, which will reply to Slack itself via /send API.
  await enqueue(() => sendToAgent(currentSocket, contextMessage));

  return true;
}

function pruneDedupe() {
  const now = Date.now();
  for (const [id, expiresAt] of dedupe.entries()) {
    if (expiresAt <= now) dedupe.delete(id);
  }
}

function verifyBrokerEnvelope(message) {
  const canonical = canonicalizeEnvelope(
    message.workspace_id,
    message.broker_timestamp,
    message.encrypted,
  );

  const sigBytes = fromBase64(message.broker_signature);
  return sodium.crypto_sign_verify_detached(sigBytes, canonical, cryptoState.brokerSigningPubkey);
}

function decryptEnvelope(message) {
  const plaintext = sodium.crypto_box_seal_open(
    fromBase64(message.encrypted),
    cryptoState.serverBoxPublicKey,
    cryptoState.serverBoxSecretKey,
  );
  if (!plaintext) {
    throw new Error(`failed to decrypt broker envelope (message_id: ${message.message_id || "unknown"})`);
  }
  return JSON.parse(utf8String(plaintext));
}

function isPoisonMessageError(err) {
  const message = err instanceof Error ? err.message : String(err);
  return message.includes("invalid broker envelope signature") || message.includes("failed to decrypt broker envelope");
}

async function processPulledMessage(message) {
  if (!verifyBrokerEnvelope(message)) {
    throw new Error("invalid broker envelope signature");
  }

  const payload = decryptEnvelope(message);
  logInfo(`📦 decrypted envelope — type: ${payload?.type || "unknown"}`);

  if (payload?.type !== "event_callback") {
    logInfo(`   ↳ ignoring non-event_callback type: ${payload?.type}`);
    return true;
  }

  const event = payload?.event;
  if (!event || typeof event !== "object") {
    logWarn("   ↳ event_callback with no event object");
    return true;
  }

  logInfo(`   ↳ event.type: ${event.type}, channel: ${event.channel || "n/a"}, user: ${event.user || "n/a"}`);

  if (event.type === "app_mention") {
    const userMessage = cleanMessage(String(event.text || ""));
    if (!userMessage) {
      logInfo("   ↳ empty app_mention — sending wave");
      await say(event.channel, "👋 I'm here! Send me a message.", event.ts);
      return true;
    }
    return handleUserMessage(userMessage, event);
  }

  if (event.type === "message") {
    if (event.bot_id || event.subtype) {
      logInfo(`   ↳ skipping bot/subtype message (bot_id: ${event.bot_id || "n/a"}, subtype: ${event.subtype || "n/a"})`);
      return true;
    }
    if (event.channel_type !== "im") {
      logInfo(`   ↳ skipping non-DM message (channel_type: ${event.channel_type})`);
      return true;
    }
    const text = String(event.text || "").trim();
    if (!text) return true;
    return handleUserMessage(text, event);
  }

  logInfo(`   ↳ unhandled event type: ${event.type}`);
  return true;
}

function startApiServer() {
  const server = createServer(async (req, res) => {
    if (req.method !== "POST") {
      res.writeHead(405, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ error: "Method not allowed" }));
      return;
    }

    const remoteAddr = req.socket.remoteAddress;
    if (remoteAddr !== "127.0.0.1" && remoteAddr !== "::1" && remoteAddr !== "::ffff:127.0.0.1") {
      res.writeHead(403, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ error: "Forbidden — local only" }));
      return;
    }

    if (!apiRateLimiter.check("global")) {
      res.writeHead(429, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ error: "Too many requests — try again later" }));
      return;
    }

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
        
        let result;
        if (outboundMode === "direct") {
          result = await sendDirectToSlack("chat.postMessage", {
            channel,
            text,
            ...(thread_ts ? { thread_ts } : {}),
          });
        } else {
          result = await sendViaBroker({
            action: "chat.postMessage",
            routing: { channel, ...(thread_ts ? { thread_ts } : {}) },
            body: { text },
          });
        }

        res.writeHead(200, { "Content-Type": "application/json" });
        res.end(JSON.stringify({ ok: true, ts: result.ts }));
        return;
      }

      if (pathname === "/reply") {
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

        const thread = threadRegistry.get(thread_id);
        if (!thread) {
          res.writeHead(404, { "Content-Type": "application/json" });
          res.end(JSON.stringify({ error: `Unknown thread_id: ${thread_id}` }));
          return;
        }

        let result;
        if (outboundMode === "direct") {
          result = await sendDirectToSlack("chat.postMessage", {
            channel: thread.channel,
            text,
            thread_ts: thread.thread_ts,
          });
        } else {
          result = await sendViaBroker({
            action: "chat.postMessage",
            routing: { channel: thread.channel, thread_ts: thread.thread_ts },
            body: { text },
          });
        }

        res.writeHead(200, { "Content-Type": "application/json" });
        res.end(JSON.stringify({ ok: true, ts: result.ts }));
        return;
      }

      if (pathname === "/react") {
        const validationError = validateReactParams(params);
        if (validationError) {
          res.writeHead(400, { "Content-Type": "application/json" });
          res.end(JSON.stringify({ error: validationError }));
          return;
        }

        const { channel, timestamp, emoji } = params;
        
        if (outboundMode === "direct") {
          await sendDirectToSlack("reactions.add", {
            channel,
            timestamp,
            name: emoji,
          });
        } else {
          await sendViaBroker({
            action: "reactions.add",
            routing: { channel, timestamp, emoji },
            body: { emoji },
          });
        }

        res.writeHead(200, { "Content-Type": "application/json" });
        res.end(JSON.stringify({ ok: true }));
        return;
      }

      res.writeHead(404, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ error: "Not found. Endpoints: POST /send, POST /reply, POST /react" }));
    } catch (err) {
      res.writeHead(500, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ error: err instanceof Error ? err.message : "unknown error" }));
    }
  });

  server.listen(API_PORT, "127.0.0.1", () => {
    logInfo(`📡 Outbound API listening on http://127.0.0.1:${API_PORT}`);
  });
}

async function startPollLoop() {
  let backoffMs = POLL_INTERVAL_MS;
  let pollCount = 0;
  let lastStatusLog = Date.now();
  const STATUS_LOG_INTERVAL_MS = 60_000; // log a status line every 60s even when idle

  while (true) {
    try {
      pruneDedupe();

      const messages = await pullInbox();
      pollCount++;
      const ackIds = [];

      if (messages.length > 0) {
        logInfo(`📬 pulled ${messages.length} message(s) from broker`);
      }

      // Periodic idle status log so you know the bridge is alive
      if (messages.length === 0 && Date.now() - lastStatusLog >= STATUS_LOG_INTERVAL_MS) {
        logInfo(`💤 idle — ${pollCount} polls since start, dedupe cache: ${dedupe.size} entries`);
        lastStatusLog = Date.now();
      }

      for (const message of messages) {
        if (!message?.message_id) {
          logWarn("⚠️ skipping message with no message_id:", JSON.stringify(message).slice(0, 200));
          continue;
        }
        if (dedupe.has(message.message_id)) {
          if (!verifyBrokerEnvelope(message)) {
            logError(`❌ dedupe hit but invalid signature (${message.message_id})`);
            // Treat as poison-pill and ack so it cannot block the queue.
            ackIds.push(message.message_id);
            continue;
          }
          ackIds.push(message.message_id);
          continue;
        }

        try {
          logInfo(`📩 processing message ${message.message_id}`);
          const ok = await processPulledMessage(message);
          if (ok) {
            dedupe.set(message.message_id, Date.now() + DEDUPE_TTL_MS);
            ackIds.push(message.message_id);
            logInfo(`✅ processed & acked message ${message.message_id}`);
          } else {
            logWarn(`⚠️ message ${message.message_id} returned not-ok, will retry next poll`);
          }
        } catch (err) {
          const errMsg = err instanceof Error ? err.message : "unknown error";
          const errStack = err instanceof Error ? err.stack : "";
          logError(`❌ message processing failed (${message.message_id}): ${errMsg}`);
          if (errStack) logError(`   stack: ${errStack}`);
          if (isPoisonMessageError(err)) {
            logError(`   ↳ poison message — acking to unblock queue`);
            // Ack poison-pill messages (bad signature/decrypt failures) so they
            // don't block the queue indefinitely.
            ackIds.push(message.message_id);
          }
        }
      }

      if (ackIds.length > 0) {
        await ackInbox(ackIds);
        logInfo(`📤 acked ${ackIds.length} message(s)`);
      }

      backoffMs = POLL_INTERVAL_MS;
      await sleep(POLL_INTERVAL_MS);
    } catch (err) {
      const errMsg = err instanceof Error ? err.message : "unknown error";
      const errStack = err instanceof Error ? err.stack : "";
      logError(`❌ inbox poll failed: ${errMsg}`);
      if (errStack) logError(`   stack: ${errStack}`);
      logError(`   ↳ backing off ${backoffMs}ms before next attempt`);
      await sleep(backoffMs);
      backoffMs = Math.min(MAX_BACKOFF_MS, Math.max(POLL_INTERVAL_MS, backoffMs * 2));
    }
  }
}

(async () => {
  await sodium.ready;

  const serverSignSeed = fromBase64(process.env.SLACK_BROKER_SERVER_SIGNING_PRIVATE_KEY);
  const signKeypair = sodium.crypto_sign_seed_keypair(serverSignSeed);

  cryptoState = {
    serverBoxSecretKey: fromBase64(process.env.SLACK_BROKER_SERVER_PRIVATE_KEY),
    serverBoxPublicKey: fromBase64(process.env.SLACK_BROKER_SERVER_PUBLIC_KEY),
    brokerPubkey: fromBase64(process.env.SLACK_BROKER_PUBLIC_KEY),
    brokerSigningPubkey: fromBase64(process.env.SLACK_BROKER_SIGNING_PUBLIC_KEY),
    serverSignSecretKey: signKeypair.privateKey,
  };

  refreshSocket();
  startApiServer();
  logInfo("⚡ Slack broker pull bridge is running!");
  logInfo(`   outbound mode: ${outboundMode} ${outboundMode === "direct" ? "(using SLACK_BOT_TOKEN)" : "(via broker)"}`);
  logInfo(`   broker: ${brokerBaseUrl}`);
  logInfo(`   workspace: ${workspaceId}`);
  logInfo(`   poll interval: ${POLL_INTERVAL_MS}ms, max messages: ${MAX_MESSAGES}`);
  logInfo(`   allowed users: ${ALLOWED_USERS.length || "all"}`);
  logInfo(`   pi socket: ${socketPath || "(not found — will retry on message)"}`);
  await startPollLoop();
})();