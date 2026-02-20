#!/usr/bin/env node
/**
 * Slack broker registration CLI.
 *
 * Registers this baudbot server with a Slack broker workspace using:
 * - broker URL
 * - workspace ID
 * - one-time auth code from OAuth callback
 *
 * On success, stores broker config and generated server key material in:
 * - admin config: ~/.baudbot/.env
 * - agent config: /home/baudbot_agent/.config/.env
 */

import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import readline from "node:readline";
import { webcrypto } from "node:crypto";

const { subtle } = webcrypto;

const WORKSPACE_ID_RE = /^T[A-Z0-9]+$/;
const ENV_KEYS = [
  "SLACK_BROKER_URL",
  "SLACK_BROKER_WORKSPACE_ID",
  "SLACK_BROKER_SERVER_PRIVATE_KEY",
  "SLACK_BROKER_SERVER_PUBLIC_KEY",
  "SLACK_BROKER_SERVER_SIGNING_PRIVATE_KEY",
  "SLACK_BROKER_SERVER_SIGNING_PUBLIC_KEY",
  "SLACK_BROKER_PUBLIC_KEY",
  "SLACK_BROKER_SIGNING_PUBLIC_KEY",
];

function createLogger(enabled) {
  return (message) => {
    if (enabled) console.log(`ℹ️  ${message}`);
  };
}

export function usageText() {
  return [
    "Usage:",
    "  sudo baudbot broker register [options]",
    "",
    "Options:",
    "  --broker-url URL       Broker base URL (e.g. https://broker.example.com)",
    "  --workspace-id ID      Slack workspace ID (e.g. T0123ABCD)",
    "  --auth-code CODE       One-time auth code from broker OAuth callback",
    "  -v, --verbose          Show detailed registration progress",
    "  -h, --help             Show this help",
    "",
    "If options are omitted, the command prompts interactively.",
  ].join("\n");
}

export function parseArgs(argv) {
  const out = {
    brokerUrl: "",
    workspaceId: "",
    authCode: "",
    verbose: false,
    help: false,
  };

  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];

    if (arg === "-h" || arg === "--help") {
      out.help = true;
      continue;
    }

    if (arg === "-v" || arg === "--verbose") {
      out.verbose = true;
      continue;
    }

    if (arg.startsWith("--broker-url=")) {
      out.brokerUrl = arg.slice("--broker-url=".length);
      continue;
    }
    if (arg === "--broker-url") {
      i++;
      out.brokerUrl = argv[i] || "";
      continue;
    }

    if (arg.startsWith("--workspace-id=")) {
      out.workspaceId = arg.slice("--workspace-id=".length);
      continue;
    }
    if (arg === "--workspace-id") {
      i++;
      out.workspaceId = argv[i] || "";
      continue;
    }

    if (arg.startsWith("--auth-code=")) {
      out.authCode = arg.slice("--auth-code=".length);
      continue;
    }
    if (arg === "--auth-code") {
      i++;
      out.authCode = argv[i] || "";
      continue;
    }

    throw new Error(`unknown argument: ${arg}`);
  }

  return out;
}

export function normalizeBrokerUrl(raw) {
  const trimmed = String(raw || "").trim();
  if (!trimmed) {
    throw new Error("broker URL is required");
  }

  let parsed;
  try {
    parsed = new URL(trimmed);
  } catch {
    throw new Error(`invalid broker URL: ${trimmed}`);
  }

  if (parsed.protocol !== "https:" && parsed.protocol !== "http:") {
    throw new Error("broker URL must use http:// or https://");
  }

  parsed.pathname = parsed.pathname.replace(/\/$/, "");
  parsed.search = "";
  parsed.hash = "";
  return parsed.toString().replace(/\/$/, "");
}

export function validateWorkspaceId(workspaceId) {
  return WORKSPACE_ID_RE.test(String(workspaceId || ""));
}

function decodeBase64Url(value) {
  const normalized = value.replace(/-/g, "+").replace(/_/g, "/");
  const padLength = (4 - (normalized.length % 4)) % 4;
  const padded = normalized + "=".repeat(padLength);
  return Buffer.from(padded, "base64");
}

function isLikelyBase64(value) {
  if (typeof value !== "string" || value.length === 0) return false;
  return /^[A-Za-z0-9+/]+={0,2}$/.test(value);
}

export async function generateServerKeyMaterial() {
  const serverBox = await subtle.generateKey({ name: "X25519" }, true, ["deriveBits"]);
  const serverBoxPublic = await subtle.exportKey("jwk", serverBox.publicKey);
  const serverBoxPrivate = await subtle.exportKey("jwk", serverBox.privateKey);

  const serverSign = await subtle.generateKey({ name: "Ed25519" }, true, ["sign", "verify"]);
  const serverSignPublic = await subtle.exportKey("jwk", serverSign.publicKey);
  const serverSignPrivate = await subtle.exportKey("jwk", serverSign.privateKey);

  return {
    server_pubkey: decodeBase64Url(serverBoxPublic.x).toString("base64"),
    server_private_key: decodeBase64Url(serverBoxPrivate.d).toString("base64"),
    server_signing_pubkey: decodeBase64Url(serverSignPublic.x).toString("base64"),
    server_signing_private_key: decodeBase64Url(serverSignPrivate.d).toString("base64"),
  };
}

export async function fetchBrokerPubkeys(brokerUrl, fetchImpl = fetch) {
  const endpoint = new URL("/api/broker-pubkey", brokerUrl);

  let response;
  try {
    response = await fetchImpl(endpoint, { method: "GET" });
  } catch (err) {
    throw new Error(`network failure fetching broker pubkey: ${err instanceof Error ? err.message : "unknown error"}`);
  }

  let body;
  try {
    body = await response.json();
  } catch {
    throw new Error("broker pubkey endpoint returned invalid JSON");
  }

  if (!response.ok || !body?.ok) {
    const errorMessage = body?.error || `HTTP ${response.status}`;
    throw new Error(`failed to fetch broker pubkey: ${errorMessage}`);
  }

  if (!isLikelyBase64(body.broker_pubkey) || !isLikelyBase64(body.broker_signing_pubkey)) {
    throw new Error("broker pubkey endpoint returned malformed keys");
  }

  return {
    broker_pubkey: body.broker_pubkey,
    broker_signing_pubkey: body.broker_signing_pubkey,
  };
}

export function mapRegisterError(status, errorText) {
  const text = String(errorText || "request failed");
  if (status === 403 && /invalid auth code/i.test(text)) {
    return "invalid auth code — re-run OAuth install and use the new auth code";
  }
  if (status === 403 && /auth code already consumed/i.test(text)) {
    return "auth code already consumed — re-install the Slack app to get a fresh code";
  }
  if (status === 409 && /already active/i.test(text)) {
    return "workspace already active — unregister the current server first";
  }
  if (status === 404 && /workspace not found/i.test(text)) {
    return "workspace not found — complete broker OAuth install first";
  }
  if (status >= 500) {
    return `broker server error (${status}) — ${text}`;
  }
  return `registration failed (${status}) — ${text}`;
}

export async function registerWithBroker({
  brokerUrl,
  workspaceId,
  authCode,
  serverKeys,
  fetchImpl = fetch,
  logger = () => {},
}) {
  logger(`Fetching broker public keys from ${new URL('/api/broker-pubkey', brokerUrl)}`);
  const fetchedBrokerKeys = await fetchBrokerPubkeys(brokerUrl, fetchImpl);

  const endpoint = new URL("/api/register", brokerUrl);
  const payload = {
    workspace_id: workspaceId,
    server_pubkey: serverKeys.server_pubkey,
    server_signing_pubkey: serverKeys.server_signing_pubkey,
    auth_code: authCode,
  };

  logger(`Registering workspace ${workspaceId} at ${endpoint}`);

  let response;
  try {
    response = await fetchImpl(endpoint, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload),
    });
  } catch (err) {
    throw new Error(`network failure registering workspace: ${err instanceof Error ? err.message : "unknown error"}`);
  }

  let body = {};
  try {
    body = await response.json();
  } catch {
    // keep default empty body for error handling
  }

  if (!response.ok || !body?.ok) {
    throw new Error(mapRegisterError(response.status, body?.error));
  }

  const registerBrokerPubkey = body?.broker_pubkey;
  const registerBrokerSigningPubkey = body?.broker_signing_pubkey;

  if (
    registerBrokerPubkey &&
    registerBrokerPubkey !== fetchedBrokerKeys.broker_pubkey
  ) {
    throw new Error("broker pubkey mismatch between /api/broker-pubkey and /api/register");
  }

  if (
    registerBrokerSigningPubkey &&
    registerBrokerSigningPubkey !== fetchedBrokerKeys.broker_signing_pubkey
  ) {
    throw new Error("broker signing pubkey mismatch between /api/broker-pubkey and /api/register");
  }

  return {
    broker_pubkey: registerBrokerPubkey || fetchedBrokerKeys.broker_pubkey,
    broker_signing_pubkey: registerBrokerSigningPubkey || fetchedBrokerKeys.broker_signing_pubkey,
    request_payload: payload,
  };
}

export function upsertEnvContent(existingContent, updates) {
  const existing = String(existingContent || "");
  const lines = existing.length > 0 ? existing.split(/\r?\n/) : [];
  const remaining = new Map(Object.entries(updates));

  const nextLines = lines.map((line) => {
    const match = line.match(/^([A-Za-z_][A-Za-z0-9_]*)=(.*)$/);
    if (!match) return line;

    const key = match[1];
    if (!remaining.has(key)) return line;

    const value = remaining.get(key);
    remaining.delete(key);
    return `${key}=${value}`;
  });

  if (nextLines.length > 0 && nextLines[nextLines.length - 1] !== "") {
    nextLines.push("");
  }

  for (const [key, value] of remaining.entries()) {
    nextLines.push(`${key}=${value}`);
  }

  return `${nextLines.join("\n").replace(/\n*$/, "")}\n`;
}

function readPasswdFile() {
  return fs.readFileSync("/etc/passwd", "utf8");
}

export function lookupUser(username, passwdText = readPasswdFile()) {
  const lines = passwdText.split(/\r?\n/);
  for (const line of lines) {
    if (!line || line.startsWith("#")) continue;
    const parts = line.split(":");
    if (parts.length < 7) continue;
    if (parts[0] !== username) continue;

    return {
      username: parts[0],
      uid: Number(parts[2]),
      gid: Number(parts[3]),
      home: parts[5],
    };
  }
  return null;
}

function readEnvFile(filePath) {
  if (!fs.existsSync(filePath)) {
    return {};
  }

  const out = {};
  const content = fs.readFileSync(filePath, "utf8");
  for (const line of content.split(/\r?\n/)) {
    const match = line.match(/^([A-Za-z_][A-Za-z0-9_]*)=(.*)$/);
    if (!match) continue;
    out[match[1]] = match[2];
  }
  return out;
}

export function resolveConfigTargets({ env = process.env } = {}) {
  const isRoot = typeof process.getuid === "function" && process.getuid() === 0;
  const explicitConfigUser = env.BAUDBOT_CONFIG_USER;
  const sudoUser = env.SUDO_USER;

  let adminUser;
  if (explicitConfigUser) {
    adminUser = explicitConfigUser;
  } else if (isRoot) {
    adminUser = sudoUser;
  } else {
    adminUser = os.userInfo().username;
  }

  if (!adminUser || adminUser === "root") {
    throw new Error("could not determine admin user (run as: sudo baudbot broker register)");
  }

  const adminRecord = lookupUser(adminUser);
  if (!adminRecord) {
    throw new Error(`admin user not found: ${adminUser}`);
  }

  const targets = [
    {
      label: "admin",
      user: adminRecord.username,
      uid: adminRecord.uid,
      gid: adminRecord.gid,
      path: path.join(adminRecord.home, ".baudbot", ".env"),
    },
  ];

  if (isRoot) {
    const agentUser = env.BAUDBOT_AGENT_USER || "baudbot_agent";
    const agentRecord = lookupUser(agentUser);
    if (agentRecord) {
      targets.push({
        label: "agent",
        user: agentRecord.username,
        uid: agentRecord.uid,
        gid: agentRecord.gid,
        path: path.join(agentRecord.home, ".config", ".env"),
      });
    }
  }

  return targets;
}

function writeEnvFile(target, updates) {
  const dir = path.dirname(target.path);
  fs.mkdirSync(dir, { recursive: true });

  if (typeof process.getuid === "function" && process.getuid() === 0) {
    fs.chownSync(dir, target.uid, target.gid);
  }

  const existing = fs.existsSync(target.path)
    ? fs.readFileSync(target.path, "utf8")
    : "";

  const next = upsertEnvContent(existing, updates);

  const tmpPath = `${target.path}.tmp-${process.pid}`;
  fs.writeFileSync(tmpPath, next, { mode: 0o600 });
  fs.renameSync(tmpPath, target.path);
  fs.chmodSync(target.path, 0o600);

  if (typeof process.getuid === "function" && process.getuid() === 0) {
    fs.chownSync(target.path, target.uid, target.gid);
  }
}

async function prompt(question) {
  const rl = readline.createInterface({
    input: process.stdin,
    output: process.stdout,
  });

  const answer = await new Promise((resolve) => {
    rl.question(question, resolve);
  });

  rl.close();
  return String(answer || "").trim();
}

async function collectInputs(parsedArgs) {
  const configTargets = resolveConfigTargets();
  const existing = readEnvFile(configTargets[0].path);

  const brokerUrl = parsedArgs.brokerUrl
    || existing.SLACK_BROKER_URL
    || (await prompt("Broker URL: "));

  const workspaceId = parsedArgs.workspaceId
    || existing.SLACK_BROKER_WORKSPACE_ID
    || (await prompt("Workspace ID (starts with T): "));

  const authCode = parsedArgs.authCode || (await prompt("Auth code: "));

  if (!authCode) {
    throw new Error("auth code is required");
  }

  return {
    brokerUrl: normalizeBrokerUrl(brokerUrl),
    workspaceId: workspaceId.trim(),
    authCode,
    configTargets,
  };
}

export async function runRegistration({
  brokerUrl,
  workspaceId,
  authCode,
  fetchImpl = fetch,
  logger = () => {},
}) {
  if (!validateWorkspaceId(workspaceId)) {
    throw new Error("workspace ID must match Slack team ID format (e.g. T0123ABCD)");
  }

  const normalizedBrokerUrl = normalizeBrokerUrl(brokerUrl);

  logger("Generating server key material...");
  const serverKeys = await generateServerKeyMaterial();
  const registration = await registerWithBroker({
    brokerUrl: normalizedBrokerUrl,
    workspaceId,
    authCode,
    serverKeys,
    fetchImpl,
    logger,
  });

  return {
    updates: {
      SLACK_BROKER_URL: normalizedBrokerUrl,
      SLACK_BROKER_WORKSPACE_ID: workspaceId,
      SLACK_BROKER_SERVER_PRIVATE_KEY: serverKeys.server_private_key,
      SLACK_BROKER_SERVER_PUBLIC_KEY: serverKeys.server_pubkey,
      SLACK_BROKER_SERVER_SIGNING_PRIVATE_KEY: serverKeys.server_signing_private_key,
      SLACK_BROKER_SERVER_SIGNING_PUBLIC_KEY: serverKeys.server_signing_pubkey,
      SLACK_BROKER_PUBLIC_KEY: registration.broker_pubkey,
      SLACK_BROKER_SIGNING_PUBLIC_KEY: registration.broker_signing_pubkey,
    },
  };
}

export async function main(argv = process.argv.slice(2)) {
  const parsed = parseArgs(argv);

  if (parsed.help) {
    console.log(usageText());
    return 0;
  }

  const verbose = parsed.verbose || process.env.BAUDBOT_VERBOSE === "1";
  const logger = createLogger(verbose);

  for (const key of ENV_KEYS) {
    if (!key.startsWith("SLACK_BROKER_")) {
      throw new Error(`unexpected env key: ${key}`);
    }
  }

  if (typeof process.getuid === "function" && process.getuid() !== 0) {
    throw new Error("broker registration requires root (run: sudo baudbot broker register)");
  }

  logger("Collecting registration inputs...");
  const input = await collectInputs(parsed);
  logger(`Using broker ${input.brokerUrl} for workspace ${input.workspaceId}`);
  logger(`Config targets: ${input.configTargets.map((t) => t.path).join(", ")}`);

  const { updates } = await runRegistration({ ...input, logger });

  for (const target of input.configTargets) {
    logger(`Writing broker config to ${target.path}`);
    writeEnvFile(target, updates);
  }

  console.log("✅ Slack broker registration succeeded.");
  console.log("Updated config files:");
  for (const target of input.configTargets) {
    console.log(`  - ${target.path}`);
  }
  console.log("Next step: sudo baudbot restart");

  return 0;
}

if (import.meta.url === `file://${process.argv[1]}`) {
  main().catch((err) => {
    const message = err instanceof Error ? err.message : String(err);
    console.error(`❌ ${message}`);
    process.exit(1);
  });
}
