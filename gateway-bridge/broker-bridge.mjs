#!/usr/bin/env node
/**
 * Gateway bridge (Slack broker pull mode).
 *
 * Polls broker inbox, decrypts inbound Slack events, forwards them to the pi
 * agent, then sends replies back through broker /api/send.
 */

import * as net from "node:net";
import * as fs from "node:fs";
import * as path from "node:path";
import { homedir, uptime as getSystemUptimeSeconds } from "node:os";
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
  sanitizeOutboundText,
} from "./security.mjs";
import {
  formatGitHubEvent,
  shouldSkipEvent,
  parseIgnoredUsers,
  extractActor,
} from "./github-events.mjs";
import {
  canonicalizeEnvelope,
  canonicalizeProtocolRequest,
  canonicalizeSendRequest,
} from "./crypto.mjs";
import { applyGatewayEnvAliases } from "./env-aliases.mjs";

const gatewayAliasWarnings = applyGatewayEnvAliases(process.env).warnings;

const SOCKET_DIR = path.join(homedir(), ".pi", "session-control");
const AGENT_TIMEOUT_MS = 120_000;

function clampInt(value, min, max, fallback) {
  const parsed = Number.parseInt(String(value ?? ""), 10);
  if (!Number.isFinite(parsed)) return fallback;
  return Math.min(max, Math.max(min, parsed));
}

const API_PORT = clampInt(process.env.BRIDGE_API_PORT || "7890", 0, 65535, 7890);
const POLL_INTERVAL_MS = clampInt(process.env.SLACK_BROKER_POLL_INTERVAL_MS || "3000", 0, 60_000, 3000);
const MAX_MESSAGES = clampInt(process.env.SLACK_BROKER_MAX_MESSAGES || "10", 1, 100, 10);
const MAX_WAIT_SECONDS = 25;
const BROKER_WAIT_SECONDS = clampInt(process.env.SLACK_BROKER_WAIT_SECONDS || "20", 0, MAX_WAIT_SECONDS, 20);
const DEDUPE_TTL_MS = clampInt(
  process.env.SLACK_BROKER_DEDUPE_TTL_MS || String(20 * 60 * 1000),
  1_000,
  7 * 24 * 60 * 60 * 1000,
  20 * 60 * 1000,
);
const MAX_BACKOFF_MS = 30_000;
const INBOX_PROTOCOL_VERSION = "2026-02-1";
const BROKER_HEALTH_PATH = path.join(homedir(), ".pi", "agent", "broker-health.json");
const BAUDBOT_VERSION_PATH = path.join(homedir(), ".pi", "agent", "baudbot-version.json");
const CONTEXT_USAGE_PATH = path.join(homedir(), ".pi", "agent", "context-usage.json");
const LOG_BUFFER_MAX_LINES = 1000;

const logLineBuffer = [];

function ts() {
  return new Date().toISOString();
}

function formatLogArg(arg) {
  if (typeof arg === "string") return arg;
  if (arg instanceof Error) return arg.stack || arg.message;
  try {
    return JSON.stringify(arg);
  } catch {
    return String(arg);
  }
}

function pushLogLine(line) {
  const lines = String(line).split(/\r?\n/);
  for (const rawLine of lines) {
    const normalizedLine = rawLine.trimEnd();
    if (!normalizedLine) continue;
    logLineBuffer.push(normalizedLine);
  }

  const overflow = logLineBuffer.length - LOG_BUFFER_MAX_LINES;
  if (overflow > 0) {
    logLineBuffer.splice(0, overflow);
  }
}

function logWithLevel(level, ...args) {
  const timestampPrefix = `[${ts()}]`;
  const line = [timestampPrefix, ...args.map(formatLogArg)].join(" ");
  pushLogLine(line);

  if (level === "error") {
    console.error(timestampPrefix, ...args);
    return;
  }
  if (level === "warn") {
    console.warn(timestampPrefix, ...args);
    return;
  }
  console.log(timestampPrefix, ...args);
}

function logInfo(...args) {
  logWithLevel("info", ...args);
}

function logError(...args) {
  logWithLevel("error", ...args);
}

function logWarn(...args) {
  logWithLevel("warn", ...args);
}

for (const warning of gatewayAliasWarnings) {
  logWarn(warning);
}

for (const key of [
  "SLACK_BROKER_URL",
  "SLACK_BROKER_ORG_ID",
  "SLACK_BROKER_SERVER_PRIVATE_KEY",
  "SLACK_BROKER_SERVER_PUBLIC_KEY",
  "SLACK_BROKER_SERVER_SIGNING_PRIVATE_KEY",
  "SLACK_BROKER_PUBLIC_KEY",
  "SLACK_BROKER_SIGNING_PUBLIC_KEY",
  "SLACK_BROKER_ACCESS_TOKEN",
]) {
  if (!process.env[key]) {
    const gatewayAlias = key.replace(/^SLACK_/, "GATEWAY_");
    logError(`❌ Missing required env var for broker mode: ${key} (or ${gatewayAlias})`);
    process.exit(1);
  }
}

const ALLOWED_USERS = parseAllowedUsers(process.env.SLACK_ALLOWED_USERS);
if (ALLOWED_USERS.length === 0) {
  logWarn("⚠️  GATEWAY_ALLOWED_USERS/SLACK_ALLOWED_USERS not set — all workspace members can interact");
}

const GITHUB_IGNORED_USERS = parseIgnoredUsers(process.env.GITHUB_IGNORED_USERS);

const slackRateLimiter = createRateLimiter({ maxRequests: 5, windowMs: 60_000 });
const apiRateLimiter = createRateLimiter({ maxRequests: 30, windowMs: 60_000 });

const brokerOrgId = String(process.env.SLACK_BROKER_ORG_ID || process.env.SLACK_BROKER_WORKSPACE_ID || "").trim();
const brokerBaseUrl = String(process.env.SLACK_BROKER_URL || "").replace(/\/$/, "");
const brokerAccessToken = String(process.env.SLACK_BROKER_ACCESS_TOKEN || "").trim();
const brokerAccessTokenExpiresAt = String(process.env.SLACK_BROKER_ACCESS_TOKEN_EXPIRES_AT || "").trim();
const outboundMode = "broker";

const threadRegistry = new Map();
const threadLookup = new Map();
let threadCounter = 0;
const MAX_THREADS = 10_000;

// Track inbound message timestamps pending a ✅ reaction.
// Key: "channel:thread_ts" (the thread root), Value: { channel, messageTs, receivedAt }
// When the agent replies via /send with a matching thread_ts, we react with ✅
// on the original inbound message and remove the entry.
const pendingAckReactions = new Map();
const PENDING_ACK_TTL_MS = 10 * 60 * 1000; // 10 minutes

/**
 * When the agent sends a reply in a thread, resolve the pending ack by
 * adding a ✅ reaction to the original inbound message and removing the entry.
 * Also prunes expired entries.
 */
function resolveAckReaction(channel, threadTs) {
  const now = Date.now();
  // Prune expired entries while we're here
  for (const [key, entry] of pendingAckReactions) {
    if (now - entry.receivedAt > PENDING_ACK_TTL_MS) {
      pendingAckReactions.delete(key);
    }
  }

  const threadKey = `${channel}:${threadTs}`;
  const pending = pendingAckReactions.get(threadKey);
  if (!pending) return;

  pendingAckReactions.delete(threadKey);
  _react(pending.channel, pending.messageTs, "white_check_mark").catch((err) => {
    logWarn(`✅ check reaction failed: ${err.message}`);
  });
}

let socketPath = null;

let cryptoState = null;

const dedupe = new Map();
let brokerTokenExpiryFormatWarned = false;
let brokerPollCount = 0;
const bridgeStartedAtMs = Date.now();

const brokerHealth = {
  started_at: new Date().toISOString(),
  updated_at: new Date().toISOString(),
  outbound_mode: outboundMode,
  broker_url: brokerBaseUrl,
  org_id: brokerOrgId,
  workspace_id: brokerOrgId,
  poll: {
    last_ok_at: null,
    last_error_at: null,
    consecutive_failures: 0,
    last_error: null,
  },
  inbound: {
    last_decrypt_ok_at: null,
    last_decrypt_error_at: null,
    last_process_ok_at: null,
    last_process_error_at: null,
    last_error: null,
  },
  ack: {
    last_ok_at: null,
    last_error_at: null,
    last_error: null,
  },
  outbound: {
    last_ok_at: null,
    last_error_at: null,
    last_error: null,
  },
};

function readAgentVersion() {
  const explicitVersion = String(process.env.BAUDBOT_AGENT_VERSION || "").trim();
  if (explicitVersion) return explicitVersion;

  try {
    const raw = fs.readFileSync(BAUDBOT_VERSION_PATH, "utf8");
    const parsed = JSON.parse(raw);
    if (typeof parsed.short === "string" && parsed.short.trim()) return parsed.short.trim();
    if (typeof parsed.sha === "string" && parsed.sha.trim()) return parsed.sha.trim();
  } catch {
    // Ignore read/parse failures. Observability metadata falls back to "unknown".
  }

  return "unknown";
}

const agentVersion = readAgentVersion();

function countActivePiSessions() {
  try {
    const entries = fs.readdirSync(SOCKET_DIR, { withFileTypes: true });
    let activeSessions = 0;
    let activeDevAgents = 0;

    for (const entry of entries) {
      const name = entry.name;
      if (name.endsWith(".sock")) {
        activeSessions += 1;
      }
      if (/^dev-agent-.+\.alias$/.test(name) && (entry.isFile() || entry.isSymbolicLink())) {
        activeDevAgents += 1;
      }
    }

    return { activeSessions, activeDevAgents };
  } catch {
    return { activeSessions: 0, activeDevAgents: 0 };
  }
}

function readContextUsageSnapshot() {
  try {
    const raw = fs.readFileSync(CONTEXT_USAGE_PATH, "utf8");
    const parsed = JSON.parse(raw);
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) return null;

    const readFiniteNumber = (value) => (typeof value === "number" && Number.isFinite(value) ? value : null);
    const snapshot = {
      context_window_used_tokens: readFiniteNumber(parsed.context_window_used_tokens),
      context_window_limit_tokens: readFiniteNumber(parsed.context_window_limit_tokens),
      context_window_used_pct: readFiniteNumber(parsed.context_window_used_pct),
      session_total_tokens: readFiniteNumber(parsed.session_total_tokens),
      session_total_cost_usd: readFiniteNumber(parsed.session_total_cost_usd),
    };

    const hasAny = Object.values(snapshot).some((value) => value !== null);
    return hasAny ? snapshot : null;
  } catch {
    return null;
  }
}

function buildPullMeta(maxMessages, waitSeconds) {
  const { activeSessions, activeDevAgents } = countActivePiSessions();
  const bridgeUptimeHours = Math.max(0, (Date.now() - bridgeStartedAtMs) / (1000 * 60 * 60));
  const systemUptimeHours = Math.max(0, getSystemUptimeSeconds() / (60 * 60));
  const contextUsage = readContextUsageSnapshot();

  return {
    agent_version: agentVersion,
    bridge_uptime_hours: bridgeUptimeHours,
    system_uptime_hours: systemUptimeHours,
    heartbeat_runs: brokerPollCount,
    heartbeat_consecutive_errors: brokerHealth.poll.consecutive_failures,
    heartbeat_last_ok_at: brokerHealth.poll.last_ok_at,
    active_sessions: activeSessions,
    active_dev_agents: activeDevAgents,
    outbound_mode: outboundMode,
    poll_count: brokerPollCount + 1,
    max_messages: maxMessages,
    wait_seconds: waitSeconds,
    ...(contextUsage ? contextUsage : {}),
  };
}

function trimError(err) {
  const msg = err instanceof Error ? err.message : String(err || "unknown error");
  return msg.slice(0, 400);
}

function persistBrokerHealth() {
  brokerHealth.updated_at = new Date().toISOString();
  const dir = path.dirname(BROKER_HEALTH_PATH);
  const tmp = `${BROKER_HEALTH_PATH}.tmp`;
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(tmp, `${JSON.stringify(brokerHealth, null, 2)}\n`, { mode: 0o600 });
  fs.renameSync(tmp, BROKER_HEALTH_PATH);
}

function markHealth(section, ok, err = null) {
  const now = new Date().toISOString();

  if (section === "poll") {
    if (ok) {
      brokerHealth.poll.last_ok_at = now;
      brokerHealth.poll.consecutive_failures = 0;
      brokerHealth.poll.last_error = null;
    } else {
      brokerHealth.poll.last_error_at = now;
      brokerHealth.poll.consecutive_failures += 1;
      brokerHealth.poll.last_error = trimError(err);
    }
    persistBrokerHealth();
    return;
  }

  if (section === "inbound_decrypt") {
    if (ok) {
      brokerHealth.inbound.last_decrypt_ok_at = now;
    } else {
      brokerHealth.inbound.last_decrypt_error_at = now;
      brokerHealth.inbound.last_error = trimError(err);
    }
    persistBrokerHealth();
    return;
  }

  if (section === "inbound_process") {
    if (ok) {
      brokerHealth.inbound.last_process_ok_at = now;
    } else {
      brokerHealth.inbound.last_process_error_at = now;
      brokerHealth.inbound.last_error = trimError(err);
    }
    persistBrokerHealth();
    return;
  }

  if (section === "ack") {
    if (ok) {
      brokerHealth.ack.last_ok_at = now;
      brokerHealth.ack.last_error = null;
    } else {
      brokerHealth.ack.last_error_at = now;
      brokerHealth.ack.last_error = trimError(err);
    }
    persistBrokerHealth();
    return;
  }

  if (section === "outbound") {
    if (ok) {
      brokerHealth.outbound.last_ok_at = now;
      brokerHealth.outbound.last_error = null;
    } else {
      brokerHealth.outbound.last_error_at = now;
      brokerHealth.outbound.last_error = trimError(err);
    }
    persistBrokerHealth();
  }
}

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

function signProtocolRequest(action, timestamp, protocolRequestPayload) {
  const canonical = canonicalizeProtocolRequest(
    brokerOrgId,
    INBOX_PROTOCOL_VERSION,
    action,
    timestamp,
    protocolRequestPayload,
  );
  const sig = sodium.crypto_sign_detached(canonical, cryptoState.serverSignSecretKey);
  return toBase64(sig);
}

function signPullRequest(timestamp, maxMessages, waitSeconds) {
  return signProtocolRequest("inbox.pull", timestamp, {
    max_messages: maxMessages,
    wait_seconds: waitSeconds,
  });
}

function isBrokerAccessTokenExpired() {
  if (!brokerAccessToken || !brokerAccessTokenExpiresAt) return false;
  const ts = Date.parse(brokerAccessTokenExpiresAt);
  if (!Number.isFinite(ts)) {
    if (!brokerTokenExpiryFormatWarned) {
      logWarn("⚠️ invalid SLACK_BROKER_ACCESS_TOKEN_EXPIRES_AT/GATEWAY_BROKER_ACCESS_TOKEN_EXPIRES_AT format; expected ISO-8601 timestamp");
      brokerTokenExpiryFormatWarned = true;
    }
    return false;
  }
  return Date.now() >= ts;
}

function enforceBrokerTokenFreshnessOrExit() {
  if (!isBrokerAccessTokenExpired()) return;

  logError("❌ broker access token is expired; broker API auth will fail.");
  logError("   run: sudo baudbot broker register && sudo baudbot restart");
  process.exit(1);
}

async function brokerFetch(pathname, brokerRequestBody) {
  enforceBrokerTokenFreshnessOrExit();
  const url = `${brokerBaseUrl}${pathname}`;
  const headers = { "Content-Type": "application/json" };
  if (brokerAccessToken) {
    headers.Authorization = `Bearer ${brokerAccessToken}`;
  }
  const brokerHttpResponse = await fetch(url, {
    method: "POST",
    headers,
    body: JSON.stringify(brokerRequestBody),
  });

  let rawBrokerResponseText = "";
  let brokerResponseBody = {};
  try {
    rawBrokerResponseText = await brokerHttpResponse.text();
    brokerResponseBody = JSON.parse(rawBrokerResponseText);
  } catch {
    // keep empty response body; rawBrokerResponseText has the text
  }

  if (!brokerHttpResponse.ok || brokerResponseBody?.ok === false) {
    const detail = brokerResponseBody?.error || rawBrokerResponseText?.slice(0, 200) || "no response body";
    const responseHeaders = Object.fromEntries(brokerHttpResponse.headers.entries());
    const cfRay = responseHeaders["cf-ray"] || "n/a";
    throw new Error(
      `broker ${pathname} failed — HTTP ${brokerHttpResponse.status} | error: ${detail} | cf-ray: ${cfRay} | ` +
      `content-type: ${responseHeaders["content-type"] || "n/a"}`
    );
  }

  return brokerResponseBody;
}

async function pullInbox() {
  const timestamp = Math.floor(Date.now() / 1000);
  const signature = signPullRequest(timestamp, MAX_MESSAGES, BROKER_WAIT_SECONDS);

  const inboxPullRequestBody = {
    org_id: brokerOrgId,
    workspace_id: brokerOrgId,
    protocol_version: INBOX_PROTOCOL_VERSION,
    max_messages: MAX_MESSAGES,
    wait_seconds: BROKER_WAIT_SECONDS,
    timestamp,
    signature,
    meta: buildPullMeta(MAX_MESSAGES, BROKER_WAIT_SECONDS),
  };

  const inboxPullResponseBody = await brokerFetch("/api/inbox/pull", inboxPullRequestBody);

  return Array.isArray(inboxPullResponseBody.messages) ? inboxPullResponseBody.messages : [];
}

async function ackInbox(messageIds) {
  if (messageIds.length === 0) return;
  const timestamp = Math.floor(Date.now() / 1000);
  const signature = signProtocolRequest("inbox.ack", timestamp, { message_ids: messageIds });

  await brokerFetch("/api/inbox/ack", {
    org_id: brokerOrgId,
    workspace_id: brokerOrgId,
    protocol_version: INBOX_PROTOCOL_VERSION,
    message_ids: messageIds,
    timestamp,
    signature,
  });
}

async function sendViaBroker({ action, routing, actionRequestBody }) {
  const timestamp = Math.floor(Date.now() / 1000);
  const plaintext = utf8Bytes(JSON.stringify(actionRequestBody));
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
    brokerOrgId, action, timestamp, encryptedBody, nonceB64, routing,
  );
  const sig = sodium.crypto_sign_detached(canonical, cryptoState.serverSignSecretKey);
  const signature = toBase64(sig);

  try {
    const result = await brokerFetch("/api/send", {
      org_id: brokerOrgId,
      workspace_id: brokerOrgId,
      action,
      routing,
      encrypted_body: encryptedBody,
      nonce: nonceB64,
      timestamp,
      signature,
    });
    markHealth("outbound", true);
    return result;
  } catch (err) {
    markHealth("outbound", false, err);
    throw err;
  }
}

async function say(channel, text, threadTs) {
  await sendViaBroker({
    action: "chat.postMessage",
    routing: {
      channel,
      ...(threadTs ? { thread_ts: threadTs } : {}),
    },
    actionRequestBody: { text },
  });
}

async function _react(channel, threadTs, emoji) {
  await sendViaBroker({
    action: "reactions.add",
    routing: { channel, timestamp: threadTs, emoji },
    actionRequestBody: { emoji },
  });
}

function sanitizeOutboundMessage(text, contextLabel) {
  const sanitized = sanitizeOutboundText(text);
  if (sanitized.blocked) {
    logWarn(`🛡️ outbound message blocked (${contextLabel}): ${sanitized.reasons.join(", ")}`);
  } else if (sanitized.redacted) {
    logWarn(`🧼 outbound message redacted (${contextLabel}): ${sanitized.reasons.join(", ")}`);
  }
  return sanitized.text;
}

async function handleUserMessage(userMessage, event) {
  const threadTs = event.thread_ts || event.ts;
  logInfo(
    `👤 message from <@${event.user}> in ${event.channel} (type: ${event.type}, thread_ts: ${threadTs}, ts: ${event.ts})`
  );

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

  // React with 👀 immediately so the user knows we saw their message.
  const ackChannel = event.channel;
  const ackMessageTs = event.ts;
  _react(ackChannel, ackMessageTs, "eyes").catch((err) => {
    logWarn(`👀 eyes reaction failed: ${err.message}`);
  });

  // Track this message so we can add ✅ when the agent replies.
  const threadKey = `${ackChannel}:${threadTs}`;
  pendingAckReactions.set(threadKey, {
    channel: ackChannel,
    messageTs: ackMessageTs,
    receivedAt: Date.now(),
  });

  refreshSocket();
  const currentSocket = socketPath;
  if (!currentSocket) {
    logError("🔌 no pi socket found — agent may not be running");
    await say(event.channel, "🔌 Agent is not connected — it may be restarting or the session expired. Run `sudo baudbot restart` to bring it back.", event.ts);
    return true;
  }
  logInfo(`🔌 forwarding to agent via ${currentSocket}`);

  const wrappedMessage = wrapExternalContent({
    text: userMessage,
    source: "Slack (broker)",
    user: event.user,
    channel: event.channel,
    threadTs,
  });

  const threadId = getThreadId(event.channel, threadTs);
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
  const routingId = String(message?.org_id || message?.workspace_id || "");
  if (!routingId) {
    throw new Error(`missing broker envelope org_id/workspace_id (message_id: ${message?.message_id || "unknown"})`);
  }

  const canonical = canonicalizeEnvelope(
    routingId,
    message.broker_timestamp,
    message.encrypted,
  );

  const sigBytes = fromBase64(message.broker_signature);
  return sodium.crypto_sign_verify_detached(sigBytes, canonical, cryptoState.brokerSigningPubkey);
}

function decryptEnvelope(message) {
  let plaintext;
  try {
    plaintext = sodium.crypto_box_seal_open(
      fromBase64(message.encrypted),
      cryptoState.serverBoxPublicKey,
      cryptoState.serverBoxSecretKey,
    );
  } catch {
    // Wrap libsodium errors (e.g., "incorrect key pair for the given ciphertext")
    // into a format that isPoisonMessageError() can detect
    throw new Error(`failed to decrypt broker envelope (message_id: ${message.message_id || "unknown"})`);
  }
  if (!plaintext) {
    throw new Error(`failed to decrypt broker envelope (message_id: ${message.message_id || "unknown"})`);
  }
  return JSON.parse(utf8String(plaintext));
}

function isPoisonMessageError(err) {
  const message = err instanceof Error ? err.message : String(err);
  return (
    message.includes("invalid broker envelope signature")
    || message.includes("failed to decrypt broker envelope")
    || message.includes("missing broker envelope org_id/workspace_id")
  );
}

function isGenericEnvelope(payload) {
  return (
    payload != null &&
    typeof payload === "object" &&
    typeof payload.source === "string" &&
    typeof payload.type === "string" &&
    "payload" in payload &&
    typeof payload.broker_timestamp === "number"
  );
}

async function handleSlackPayload(slackEventEnvelopePayload) {
  logInfo(`📦 slack payload — type: ${slackEventEnvelopePayload?.type || "unknown"}`);

  if (slackEventEnvelopePayload?.type !== "event_callback") {
    logInfo(`   ↳ ignoring non-event_callback type: ${slackEventEnvelopePayload?.type}`);
    return true;
  }

  const event = slackEventEnvelopePayload?.event;
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

async function handleGitHubEvent(type, payload) {
  const actor = extractActor(type, payload);
  const repo = payload?.repository?.full_name || "unknown/repo";
  logInfo(`🐙 github event: ${type} (action: ${payload?.action || "n/a"}) repo: ${repo} actor: ${actor || "n/a"}`);

  // Filtering: skip noisy or self-generated events
  const skipReason = shouldSkipEvent(type, payload, GITHUB_IGNORED_USERS);
  if (skipReason) {
    logInfo(`   ↳ skipping: ${skipReason}`);
    return true;
  }

  const { message, isPing, isUnknown } = formatGitHubEvent(type, payload);

  if (isPing) {
    logInfo("   ↳ ping event — webhook configured successfully");
    return true;
  }

  if (isUnknown) {
    logWarn(`   ↳ unhandled github event type: ${type} — forwarding minimal summary`);
  }

  if (!message) {
    logWarn(`   ↳ formatter returned no message for ${type} — skipping`);
    return true;
  }

  refreshSocket();
  const currentSocket = socketPath;
  if (!currentSocket) {
    logError("🔌 no pi socket found for github event — agent may not be running");
    return true;
  }

  await enqueue(() => sendToAgent(currentSocket, message));
  logInfo(`   ↳ forwarded to agent`);
  return true;
}

async function handleDashboardEvent(type, payload) {
  logInfo(`📊 dashboard event: ${type}`, JSON.stringify(payload).slice(0, 200));
  // TODO: implement dashboard event handling (env updates, config changes)
  return true;
}

async function handleSystemEvent(type, payload) {
  logInfo(`⚙️ system event: ${type}`, JSON.stringify(payload).slice(0, 200));
  // TODO: implement system event handling
  return true;
}

async function processPulledMessage(message) {
  if (!verifyBrokerEnvelope(message)) {
    throw new Error("invalid broker envelope signature");
  }

  let payload;
  try {
    payload = decryptEnvelope(message);
    markHealth("inbound_decrypt", true);
  } catch (err) {
    markHealth("inbound_decrypt", false, err);
    throw err;
  }

  // Generic envelope dispatch
  if (isGenericEnvelope(payload)) {
    logInfo(`📦 generic envelope — source: ${payload.source}, type: ${payload.type}`);
    switch (payload.source) {
      case "slack":
        return handleSlackPayload(payload.payload);
      case "github":
        return handleGitHubEvent(payload.type, payload.payload);
      case "dashboard":
        return handleDashboardEvent(payload.type, payload.payload);
      case "system":
        return handleSystemEvent(payload.type, payload.payload);
      default:
        logWarn(`⚠️ unknown event source: ${payload.source} — acking to avoid blocking queue`);
        return true;
    }
  }

  // Legacy: raw Slack event_callback (backwards compat during rollout)
  logInfo(`📦 legacy envelope — type: ${payload?.type || "unknown"}`);
  return handleSlackPayload(payload);
}

function getLogLinesForResponse(url) {
  const nParam = url.searchParams.get("n");
  const filterParam = url.searchParams.get("filter");

  let requestedLineCount = null;
  if (nParam !== null) {
    const parsedN = Number.parseInt(nParam, 10);
    if (!Number.isFinite(parsedN) || parsedN < 1) {
      throw new Error("n must be a positive integer");
    }
    requestedLineCount = Math.min(parsedN, LOG_BUFFER_MAX_LINES);
  }

  let lines = logLineBuffer.slice();

  const normalizedFilter = filterParam?.trim().toLowerCase();
  if (normalizedFilter) {
    lines = lines.filter((line) => line.toLowerCase().includes(normalizedFilter));
  }

  if (requestedLineCount !== null) {
    lines = lines.slice(-requestedLineCount);
  }

  return lines;
}

/** Reference to the HTTP server so we can close it on shutdown. */
let apiServer = null;
let shuttingDown = false;

/**
 * Graceful shutdown: close the HTTP server (releases the port), then exit.
 * Called on SIGTERM/SIGINT so restarts don't fight over the port.
 */
function gracefulShutdown(signal) {
  if (shuttingDown) return;
  shuttingDown = true;
  logInfo(`🛑 received ${signal} — shutting down gracefully`);
  if (apiServer) {
    apiServer.close(() => {
      logInfo("🛑 HTTP server closed, exiting");
      process.exit(0);
    });
    // Force exit after 5s if connections don't drain
    setTimeout(() => {
      logWarn("🛑 forceful exit after 5s timeout");
      process.exit(1);
    }, 5000).unref();
  } else {
    process.exit(0);
  }
}

process.on("SIGTERM", () => gracefulShutdown("SIGTERM"));
process.on("SIGINT", () => gracefulShutdown("SIGINT"));

function startApiServer() {
  const server = createServer(async (req, res) => {
    const url = new URL(req.url, `http://localhost:${API_PORT}`);
    const pathname = url.pathname;

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

    if (pathname === "/logs") {
      if (req.method !== "GET") {
        res.writeHead(405, { "Content-Type": "application/json" });
        res.end(JSON.stringify({ error: "Method not allowed" }));
        return;
      }

      try {
        const lines = getLogLinesForResponse(url);
        res.writeHead(200, { "Content-Type": "text/plain; charset=utf-8" });
        res.end(lines.length > 0 ? `${lines.join("\n")}\n` : "");
        return;
      } catch (err) {
        res.writeHead(400, { "Content-Type": "application/json" });
        res.end(JSON.stringify({ error: err instanceof Error ? err.message : "invalid query params" }));
        return;
      }
    }

    if (req.method !== "POST") {
      res.writeHead(405, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ error: "Method not allowed" }));
      return;
    }

    let rawApiRequestBody = "";
    for await (const chunk of req) rawApiRequestBody += chunk;

    let apiRequestBody;
    try {
      apiRequestBody = JSON.parse(rawApiRequestBody);
    } catch {
      res.writeHead(400, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ error: "Invalid JSON" }));
      return;
    }

    try {
      if (pathname === "/send") {
        const validationError = validateSendParams(apiRequestBody);
        if (validationError) {
          res.writeHead(400, { "Content-Type": "application/json" });
          res.end(JSON.stringify({ error: validationError }));
          return;
        }

        const { channel, text, thread_ts } = apiRequestBody;
        const safeText = sanitizeOutboundMessage(text, "/send");

        const result = await sendViaBroker({
          action: "chat.postMessage",
          routing: { channel, ...(thread_ts ? { thread_ts } : {}) },
          actionRequestBody: { text: safeText },
        });

        // If this is a threaded reply, check for a pending ✅ ack reaction.
        if (thread_ts) {
          resolveAckReaction(channel, thread_ts);
        }

        res.writeHead(200, { "Content-Type": "application/json" });
        res.end(JSON.stringify({ ok: true, ts: result.ts }));
        return;
      }

      if (pathname === "/reply") {
        const { thread_id, text } = apiRequestBody;
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

        const safeText = sanitizeOutboundMessage(text, "/reply");
        const result = await sendViaBroker({
          action: "chat.postMessage",
          routing: { channel: thread.channel, thread_ts: thread.thread_ts },
          actionRequestBody: { text: safeText },
        });

        // Check for a pending ✅ ack reaction on the /reply path too.
        resolveAckReaction(thread.channel, thread.thread_ts);

        res.writeHead(200, { "Content-Type": "application/json" });
        res.end(JSON.stringify({ ok: true, ts: result.ts }));
        return;
      }

      if (pathname === "/react") {
        const validationError = validateReactParams(apiRequestBody);
        if (validationError) {
          res.writeHead(400, { "Content-Type": "application/json" });
          res.end(JSON.stringify({ error: validationError }));
          return;
        }

        const { channel, timestamp, emoji } = apiRequestBody;

        await sendViaBroker({
          action: "reactions.add",
          routing: { channel, timestamp, emoji },
          actionRequestBody: { emoji },
        });

        res.writeHead(200, { "Content-Type": "application/json" });
        res.end(JSON.stringify({ ok: true }));
        return;
      }

      res.writeHead(404, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ error: "Not found. Endpoints: POST /send, POST /reply, POST /react, GET /logs" }));
    } catch (err) {
      res.writeHead(500, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ error: err instanceof Error ? err.message : "unknown error" }));
    }
  });

  // Retry with backoff if the port is still held by a dying predecessor.
  const MAX_BIND_RETRIES = 5;
  const BIND_RETRY_DELAY_MS = 2000;
  let bindAttempt = 0;

  function tryListen() {
    bindAttempt++;
    server.listen(API_PORT, "127.0.0.1");
  }

  server.on("listening", () => {
    apiServer = server;
    logInfo(`📡 Outbound API listening on http://127.0.0.1:${API_PORT}`);
  });

  server.on("error", (err) => {
    if (err.code === "EADDRINUSE" && bindAttempt < MAX_BIND_RETRIES) {
      logWarn(`⚠️ port ${API_PORT} in use, retrying in ${BIND_RETRY_DELAY_MS}ms (attempt ${bindAttempt}/${MAX_BIND_RETRIES})`);
      server.close();
      setTimeout(tryListen, BIND_RETRY_DELAY_MS);
    } else {
      logError(`❌ HTTP server error: ${err.message}`);
      process.exit(1);
    }
  });

  tryListen();
}

async function startPollLoop() {
  let backoffMs = POLL_INTERVAL_MS;
  let lastStatusLog = Date.now();
  const STATUS_LOG_INTERVAL_MS = 60_000; // log a status line every 60s even when idle

  while (true) {
    let pollSucceeded = false;
    try {
      pruneDedupe();

      const messages = await pullInbox();
      pollSucceeded = true;
      markHealth("poll", true);
      brokerPollCount++;
      const ackIds = [];

      if (messages.length > 0) {
        logInfo(`📬 pulled ${messages.length} message(s) from broker`);
      }

      // Periodic idle status log so you know the bridge is alive
      if (messages.length === 0 && Date.now() - lastStatusLog >= STATUS_LOG_INTERVAL_MS) {
        logInfo(`💤 idle — ${brokerPollCount} polls since start, dedupe cache: ${dedupe.size} entries`);
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
            markHealth("inbound_process", true);
            dedupe.set(message.message_id, Date.now() + DEDUPE_TTL_MS);
            ackIds.push(message.message_id);
            logInfo(`✅ processed & acked message ${message.message_id}`);
          } else {
            logWarn(`⚠️ message ${message.message_id} returned not-ok, will retry next poll`);
          }
        } catch (err) {
          markHealth("inbound_process", false, err);
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
        try {
          await ackInbox(ackIds);
          markHealth("ack", true);
          logInfo(`📤 acked ${ackIds.length} message(s)`);
        } catch (err) {
          markHealth("ack", false, err);
          throw err;
        }
      }

      backoffMs = POLL_INTERVAL_MS;
      if (BROKER_WAIT_SECONDS <= 0) {
        await sleep(POLL_INTERVAL_MS);
      }
    } catch (err) {
      if (!pollSucceeded) {
        markHealth("poll", false, err);
        const errMsg = err instanceof Error ? err.message : "unknown error";
        const errStack = err instanceof Error ? err.stack : "";
        logError(`❌ inbox poll failed: ${errMsg}`);
        if (errStack) logError(`   stack: ${errStack}`);
      } else {
        const errMsg = err instanceof Error ? err.message : "unknown error";
        const errStack = err instanceof Error ? err.stack : "";
        logError(`❌ broker cycle failed after successful poll: ${errMsg}`);
        if (errStack) logError(`   stack: ${errStack}`);
      }
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

  enforceBrokerTokenFreshnessOrExit();

  refreshSocket();
  startApiServer();
  persistBrokerHealth();
  logInfo("⚡ Gateway bridge (broker pull mode) is running!");
  logInfo(`   outbound mode: ${outboundMode} (via broker)`);
  logInfo(`   broker: ${brokerBaseUrl}`);
  logInfo(`   org: ${brokerOrgId}`);
  logInfo(`   inbox protocol: ${INBOX_PROTOCOL_VERSION}`);
  logInfo(`   broker auth token: ${brokerAccessToken ? "configured" : "not configured"}`);
  logInfo(
    `   poll mode: ${BROKER_WAIT_SECONDS > 0 ? `long-poll (${BROKER_WAIT_SECONDS}s)` : "short-poll"}, ` +
    `interval: ${POLL_INTERVAL_MS}ms, max messages: ${MAX_MESSAGES}`,
  );
  logInfo(`   allowed users: ${ALLOWED_USERS.length || "all"}`);
  logInfo(`   pi socket: ${socketPath || "(not found — will retry on message)"}`);
  await startPollLoop();
})();
