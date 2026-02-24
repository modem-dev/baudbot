import { afterEach, describe, expect, it } from "vitest";
import { createServer } from "node:http";
import { spawn } from "node:child_process";
import net from "node:net";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import sodium from "libsodium-wrappers-sumo";
import {
  canonicalizeEnvelope,
  canonicalizeProtocolRequest,
} from "../slack-bridge/crypto.mjs";

function b64(bytes = 32, fill = 1) {
  return Buffer.alloc(bytes, fill).toString("base64");
}

function toBase64(bytes) {
  return Buffer.from(bytes).toString("base64");
}

function waitFor(condition, timeoutMs = 10_000, intervalMs = 50, onTimeoutMessage = "timeout waiting for condition") {
  const start = Date.now();
  return new Promise((resolve, reject) => {
    const tick = () => {
      if (condition()) return resolve();
      if (Date.now() - start > timeoutMs) return reject(new Error(onTimeoutMessage));
      setTimeout(tick, intervalMs);
    };
    tick();
  });
}

async function reserveFreePort() {
  const server = createServer((_req, res) => {
    res.writeHead(204);
    res.end();
  });

  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const address = server.address();
  if (!address || typeof address === "string") {
    await new Promise((resolve) => server.close(() => resolve(undefined)));
    throw new Error("failed to reserve free port");
  }

  const port = address.port;
  await new Promise((resolve) => server.close(() => resolve(undefined)));
  return port;
}

describe("broker pull bridge semi-integration", () => {
  const children = [];
  const servers = [];
  const tempDirs = [];

  // Strip real broker credentials from inherited env so spawned bridges don't
  // fail with "broker access token is expired" when the host token is stale.
  function cleanEnv(overrides = {}) {
    const env = { ...process.env, ...overrides };
    if (!overrides.SLACK_BROKER_ACCESS_TOKEN_EXPIRES_AT) {
      delete env.SLACK_BROKER_ACCESS_TOKEN_EXPIRES_AT;
    }
    return env;
  }

  afterEach(async () => {
    for (const child of children) {
      if (!child.killed) child.kill("SIGTERM");
    }
    // Give child processes a moment to exit so they stop writing to tempDirs
    await new Promise((resolve) => setTimeout(resolve, 100));
    for (const server of servers) {
      await new Promise((resolve) => server.close(() => resolve(undefined)));
    }
    for (const dir of tempDirs) {
      rmSync(dir, { recursive: true, force: true, maxRetries: 3, retryDelay: 100 });
    }
    children.length = 0;
    servers.length = 0;
    tempDirs.length = 0;
  });

  it("serves in-memory recent logs via GET /logs", async () => {
    await sodium.ready;

    const apiPort = await reserveFreePort();

    const broker = createServer(async (req, res) => {
      if (req.method === "POST" && req.url === "/api/inbox/pull") {
        res.writeHead(200, { "Content-Type": "application/json" });
        res.end(JSON.stringify({ ok: true, messages: [] }));
        return;
      }

      if (req.method === "POST" && req.url === "/api/inbox/ack") {
        res.writeHead(200, { "Content-Type": "application/json" });
        res.end(JSON.stringify({ ok: true, acked: 0 }));
        return;
      }

      if (req.method === "POST" && req.url === "/api/send") {
        res.writeHead(200, { "Content-Type": "application/json" });
        res.end(JSON.stringify({ ok: true, ts: "1234.5678" }));
        return;
      }

      res.writeHead(404, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ ok: false, error: "not found" }));
    });

    await new Promise((resolve) => broker.listen(0, "127.0.0.1", resolve));
    servers.push(broker);

    const brokerAddress = broker.address();
    if (!brokerAddress || typeof brokerAddress === "string") {
      throw new Error("failed to get broker test server address");
    }

    const testFileDir = path.dirname(fileURLToPath(import.meta.url));
    const repoRoot = path.dirname(testFileDir);
    const bridgePath = path.join(repoRoot, "slack-bridge", "broker-bridge.mjs");
    const bridgeCwd = path.join(repoRoot, "slack-bridge");

    let bridgeStdout = "";
    let bridgeStderr = "";

    const bridge = spawn("node", [bridgePath], {
      cwd: bridgeCwd,
      env: {
        ...cleanEnv(),
        SLACK_BROKER_URL: `http://127.0.0.1:${brokerAddress.port}`,
        SLACK_BROKER_WORKSPACE_ID: "T123BROKER",
        SLACK_BROKER_SERVER_PRIVATE_KEY: b64(32, 11),
        SLACK_BROKER_SERVER_PUBLIC_KEY: b64(32, 12),
        SLACK_BROKER_SERVER_SIGNING_PRIVATE_KEY: b64(32, 13),
        SLACK_BROKER_PUBLIC_KEY: b64(32, 14),
        SLACK_BROKER_SIGNING_PUBLIC_KEY: b64(32, 15),
        SLACK_BROKER_ACCESS_TOKEN: "test-broker-token",
        SLACK_ALLOWED_USERS: "U_ALLOWED",
        SLACK_BROKER_POLL_INTERVAL_MS: "100",
        BRIDGE_API_PORT: String(apiPort),
      },
      stdio: ["ignore", "pipe", "pipe"],
    });

    bridge.stdout.on("data", (chunk) => {
      bridgeStdout += chunk.toString();
    });
    bridge.stderr.on("data", (chunk) => {
      bridgeStderr += chunk.toString();
    });

    children.push(bridge);

    await waitFor(
      () => bridgeStdout.includes("Outbound API listening"),
      10_000,
      50,
      `timeout waiting for startup log; stdout=${bridgeStdout}; stderr=${bridgeStderr}`,
    );

    const allLogsResponse = await fetch(`http://127.0.0.1:${apiPort}/logs`);
    expect(allLogsResponse.status).toBe(200);
    expect(allLogsResponse.headers.get("content-type")).toContain("text/plain");
    const allLogsText = await allLogsResponse.text();
    expect(allLogsText).toContain("Outbound API listening");

    const filteredLogsResponse = await fetch(`http://127.0.0.1:${apiPort}/logs?filter=outbound`);
    expect(filteredLogsResponse.status).toBe(200);
    const filteredLogsText = await filteredLogsResponse.text();
    expect(filteredLogsText.toLowerCase()).toContain("outbound api listening");

    const limitedLogsResponse = await fetch(`http://127.0.0.1:${apiPort}/logs?n=1`);
    expect(limitedLogsResponse.status).toBe(200);
    const limitedLogsText = await limitedLogsResponse.text();
    const limitedLines = limitedLogsText.trim() ? limitedLogsText.trim().split("\n") : [];
    expect(limitedLines.length).toBeLessThanOrEqual(1);

    const invalidNResponse = await fetch(`http://127.0.0.1:${apiPort}/logs?n=0`);
    expect(invalidNResponse.status).toBe(400);
    const invalidNBody = await invalidNResponse.json();
    expect(invalidNBody.error).toContain("positive integer");
  });

  it("acks poison messages from broker to avoid infinite retry loops", async () => {
    await sodium.ready;

    let pullCount = 0;
    let ackPayload = null;

    const broker = createServer(async (req, res) => {
      if (req.method === "POST" && req.url === "/api/inbox/pull") {
        pullCount += 1;
        const messages = pullCount === 1
          ? [{
              message_id: "m-poison-1",
              workspace_id: "T123BROKER",
              encrypted: b64(64),
              broker_timestamp: Math.floor(Date.now() / 1000),
              // valid-length signature bytes, but not valid for payload/key
              broker_signature: b64(64),
            }]
          : [];

        res.writeHead(200, { "Content-Type": "application/json" });
        res.end(JSON.stringify({ ok: true, messages }));
        return;
      }

      if (req.method === "POST" && req.url === "/api/inbox/ack") {
        let raw = "";
        for await (const chunk of req) raw += chunk;
        ackPayload = JSON.parse(raw);

        res.writeHead(200, { "Content-Type": "application/json" });
        res.end(JSON.stringify({ ok: true, acked: ackPayload.message_ids?.length ?? 0 }));
        return;
      }

      if (req.method === "POST" && req.url === "/api/send") {
        res.writeHead(200, { "Content-Type": "application/json" });
        res.end(JSON.stringify({ ok: true, ts: "1234.5678" }));
        return;
      }

      res.writeHead(404, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ ok: false, error: "not found" }));
    });

    await new Promise((resolve) => broker.listen(0, "127.0.0.1", resolve));
    servers.push(broker);

    const address = broker.address();
    if (!address || typeof address === "string") {
      throw new Error("failed to get broker test server address");
    }
    const brokerUrl = `http://127.0.0.1:${address.port}`;

    const testFileDir = path.dirname(fileURLToPath(import.meta.url));
    const repoRoot = path.dirname(testFileDir);
    const bridgePath = path.join(repoRoot, "slack-bridge", "broker-bridge.mjs");
    const bridgeCwd = path.join(repoRoot, "slack-bridge");

    let bridgeStdout = "";
    let bridgeStderr = "";
    let bridgeExit = null;

    const bridge = spawn("node", [bridgePath], {
      cwd: bridgeCwd,
      env: {
        ...cleanEnv(),
        SLACK_BROKER_URL: brokerUrl,
        SLACK_BROKER_WORKSPACE_ID: "T123BROKER",
        SLACK_BROKER_SERVER_PRIVATE_KEY: b64(32, 11),
        SLACK_BROKER_SERVER_PUBLIC_KEY: b64(32, 12),
        SLACK_BROKER_SERVER_SIGNING_PRIVATE_KEY: b64(32, 13),
        SLACK_BROKER_PUBLIC_KEY: b64(32, 14),
        SLACK_BROKER_SIGNING_PUBLIC_KEY: b64(32, 15),
        SLACK_BROKER_ACCESS_TOKEN: "test-broker-token",
        SLACK_ALLOWED_USERS: "U_ALLOWED",
        SLACK_BROKER_POLL_INTERVAL_MS: "50",
        BRIDGE_API_PORT: "0",
      },
      stdio: ["ignore", "pipe", "pipe"],
    });

    bridge.stdout.on("data", (chunk) => {
      bridgeStdout += chunk.toString();
    });
    bridge.stderr.on("data", (chunk) => {
      bridgeStderr += chunk.toString();
    });
    const bridgeExited = new Promise((_, reject) => {
      bridge.on("error", (err) => {
        if (ackPayload !== null) return;
        reject(new Error(`bridge spawn error: ${err.message}; stdout=${bridgeStdout}; stderr=${bridgeStderr}`));
      });
      bridge.on("exit", (code, signal) => {
        bridgeExit = { code, signal };
        if (ackPayload !== null) return;
        reject(new Error(`bridge exited early: code=${code} signal=${signal}; stdout=${bridgeStdout}; stderr=${bridgeStderr}`));
      });
    });

    children.push(bridge);

    const ackWait = waitFor(
      () => ackPayload !== null,
      10_000,
      50,
      `timeout waiting for ack; pullCount=${pullCount}; exit=${JSON.stringify(bridgeExit)}; stdout=${bridgeStdout}; stderr=${bridgeStderr}`,
    );

    await Promise.race([ackWait, bridgeExited]);

    expect(ackPayload.workspace_id).toBe("T123BROKER");
    expect(ackPayload.protocol_version).toBe("2026-02-1");
    expect(ackPayload.message_ids).toContain("m-poison-1");

    const signKeypair = sodium.crypto_sign_seed_keypair(new Uint8Array(Buffer.alloc(32, 13)));
    const canonical = canonicalizeProtocolRequest("T123BROKER", "2026-02-1", "inbox.ack", ackPayload.timestamp, {
      message_ids: ackPayload.message_ids,
    });
    const sigBytes = new Uint8Array(Buffer.from(ackPayload.signature, "base64"));
    const valid = sodium.crypto_sign_verify_detached(sigBytes, canonical, signKeypair.publicKey);
    expect(valid).toBe(true);
  });

  it("forwards user messages to agent in fire-and-forget mode without get_message/turn_end RPCs", async () => {
    await sodium.ready;

    const testFileDir = path.dirname(fileURLToPath(import.meta.url));
    const repoRoot = path.dirname(testFileDir);
    const bridgePath = path.join(repoRoot, "slack-bridge", "broker-bridge.mjs");
    const bridgeCwd = path.join(repoRoot, "slack-bridge");

    const tempHome = mkdtempSync(path.join(tmpdir(), "baudbot-broker-test-"));
    tempDirs.push(tempHome);

    const sessionDir = path.join(tempHome, ".pi", "session-control");
    mkdirSync(sessionDir, { recursive: true });
    const sessionId = "11111111-1111-1111-1111-111111111111";
    const socketFile = path.join(sessionDir, `${sessionId}.sock`);

    const receivedCommands = [];
    const agentSocket = net.createServer((conn) => {
      let buffer = "";
      conn.on("data", (chunk) => {
        buffer += chunk.toString();
        const lines = buffer.split("\n");
        buffer = lines.pop() || "";
        for (const line of lines) {
          if (!line.trim()) continue;
          const msg = JSON.parse(line);
          receivedCommands.push(msg);
          if (msg.type === "send") {
            conn.write(`${JSON.stringify({ type: "response", command: "send", success: true })}\n`);
          }
        }
      });
    });
    await new Promise((resolve) => agentSocket.listen(socketFile, resolve));
    servers.push(agentSocket);

    const serverBox = sodium.crypto_box_keypair();
    const brokerBox = sodium.crypto_box_keypair();
    const brokerSign = sodium.crypto_sign_keypair();
    const serverSignSeed = sodium.randombytes_buf(sodium.crypto_sign_SEEDBYTES);

    const workspaceId = "T123BROKER";
    const eventPayload = {
      type: "event_callback",
      event: {
        type: "app_mention",
        user: "U_ALLOWED",
        channel: "C123",
        ts: "1730000000.000100",
        text: "<@U_BOT> hello from test",
      },
    };

    const encrypted = sodium.crypto_box_seal(
      Buffer.from(JSON.stringify(eventPayload)),
      serverBox.publicKey,
    );
    const brokerTimestamp = Math.floor(Date.now() / 1000);
    const encryptedB64 = toBase64(encrypted);
    const brokerSignature = toBase64(
      sodium.crypto_sign_detached(
        canonicalizeEnvelope(workspaceId, brokerTimestamp, encryptedB64),
        brokerSign.privateKey,
      ),
    );

    let pullCount = 0;
    let ackPayload = null;
    const sendPayloads = [];

    const broker = createServer(async (req, res) => {
      if (req.method === "POST" && req.url === "/api/inbox/pull") {
        pullCount += 1;
        const messages = pullCount === 1
          ? [{
              message_id: "m-valid-1",
              workspace_id: workspaceId,
              encrypted: encryptedB64,
              broker_timestamp: brokerTimestamp,
              broker_signature: brokerSignature,
            }]
          : [];

        res.writeHead(200, { "Content-Type": "application/json" });
        res.end(JSON.stringify({ ok: true, messages }));
        return;
      }

      if (req.method === "POST" && req.url === "/api/inbox/ack") {
        let raw = "";
        for await (const chunk of req) raw += chunk;
        ackPayload = JSON.parse(raw);
        res.writeHead(200, { "Content-Type": "application/json" });
        res.end(JSON.stringify({ ok: true, acked: ackPayload.message_ids?.length ?? 0 }));
        return;
      }

      if (req.method === "POST" && req.url === "/api/send") {
        let raw = "";
        for await (const chunk of req) raw += chunk;
        sendPayloads.push(JSON.parse(raw));
        res.writeHead(200, { "Content-Type": "application/json" });
        res.end(JSON.stringify({ ok: true, ts: "1234.5678" }));
        return;
      }

      res.writeHead(404, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ ok: false, error: "not found" }));
    });

    await new Promise((resolve) => broker.listen(0, "127.0.0.1", resolve));
    servers.push(broker);

    const address = broker.address();
    if (!address || typeof address === "string") {
      throw new Error("failed to get broker test server address");
    }
    const brokerUrl = `http://127.0.0.1:${address.port}`;

    let bridgeStdout = "";
    let bridgeStderr = "";
    let bridgeExit = null;

    const bridge = spawn("node", [bridgePath], {
      cwd: bridgeCwd,
      env: {
        ...cleanEnv(),
        HOME: tempHome,
        PI_SESSION_ID: sessionId,
        SLACK_BROKER_URL: brokerUrl,
        SLACK_BROKER_WORKSPACE_ID: workspaceId,
        SLACK_BROKER_SERVER_PRIVATE_KEY: toBase64(serverBox.privateKey),
        SLACK_BROKER_SERVER_PUBLIC_KEY: toBase64(serverBox.publicKey),
        SLACK_BROKER_SERVER_SIGNING_PRIVATE_KEY: toBase64(serverSignSeed),
        SLACK_BROKER_PUBLIC_KEY: toBase64(brokerBox.publicKey),
        SLACK_BROKER_SIGNING_PUBLIC_KEY: toBase64(brokerSign.publicKey),
        SLACK_BROKER_ACCESS_TOKEN: "test-broker-token",
        SLACK_ALLOWED_USERS: "U_ALLOWED",
        SLACK_BROKER_POLL_INTERVAL_MS: "50",
        BRIDGE_API_PORT: "0",
      },
      stdio: ["ignore", "pipe", "pipe"],
    });

    bridge.stdout.on("data", (chunk) => {
      bridgeStdout += chunk.toString();
    });
    bridge.stderr.on("data", (chunk) => {
      bridgeStderr += chunk.toString();
    });

    const bridgeExited = new Promise((_, reject) => {
      bridge.on("error", (err) => {
        if (ackPayload !== null) return;
        reject(new Error(`bridge spawn error: ${err.message}; stdout=${bridgeStdout}; stderr=${bridgeStderr}`));
      });
      bridge.on("exit", (code, signal) => {
        bridgeExit = { code, signal };
        if (ackPayload !== null) return;
        reject(new Error(`bridge exited early: code=${code} signal=${signal}; stdout=${bridgeStdout}; stderr=${bridgeStderr}`));
      });
    });

    children.push(bridge);

    const completeWait = waitFor(
      () => ackPayload !== null && receivedCommands.length > 0,
      12_000,
      50,
      `timeout waiting for forward+ack; pullCount=${pullCount}; commands=${JSON.stringify(receivedCommands)}; sendPayloads=${JSON.stringify(sendPayloads)}; exit=${JSON.stringify(bridgeExit)}; stdout=${bridgeStdout}; stderr=${bridgeStderr}`,
    );

    await Promise.race([completeWait, bridgeExited]);

    expect(ackPayload.workspace_id).toBe(workspaceId);
    expect(ackPayload.message_ids).toContain("m-valid-1");

    expect(receivedCommands.length).toBe(1);
    expect(receivedCommands[0].type).toBe("send");
    expect(receivedCommands[0].mode).toBe("steer");
    expect(receivedCommands[0]).not.toHaveProperty("wait_until");
    expect(receivedCommands.some((cmd) => cmd.type === "subscribe")).toBe(false);
    expect(receivedCommands.some((cmd) => cmd.type === "get_message")).toBe(false);

    expect(sendPayloads.some((payload) => payload.action === "chat.postMessage")).toBe(false);

    // Bridge now sends an 👀 reaction on inbound messages (fire-and-forget)
    const reactionPayloads = sendPayloads.filter((payload) => payload.action === "reactions.add");
    expect(reactionPayloads.length).toBe(1);
    expect(reactionPayloads[0].routing.channel).toBe("C123");
    expect(reactionPayloads[0].routing.timestamp).toBe("1730000000.000100");
    expect(reactionPayloads[0].routing.emoji).toBe("eyes");
  });

  it("uses protocol-versioned inbox.pull signatures with wait_seconds by default", async () => {
    await sodium.ready;

    const workspaceId = "T123BROKER";
    const signingSeed = Buffer.alloc(32, 21);
    const signKeypair = sodium.crypto_sign_seed_keypair(new Uint8Array(signingSeed));
    let pullPayload = null;

    const tempHome = mkdtempSync(path.join(tmpdir(), "baudbot-broker-test-"));
    tempDirs.push(tempHome);
    const contextUsageDir = path.join(tempHome, ".pi", "agent");
    mkdirSync(contextUsageDir, { recursive: true });
    writeFileSync(
      path.join(contextUsageDir, "context-usage.json"),
      `${JSON.stringify({
        generated_at: "2026-02-23T00:00:00.000Z",
        session_id: "session-test",
        context_window_used_tokens: 12345,
        context_window_limit_tokens: 200000,
        context_window_used_pct: 6.1725,
        session_total_tokens: 54321,
        session_total_cost_usd: 1.25,
      }, null, 2)}\n`,
    );

    const broker = createServer(async (req, res) => {
      if (req.method === "POST" && req.url === "/api/inbox/pull") {
        let raw = "";
        for await (const chunk of req) raw += chunk;
        pullPayload = JSON.parse(raw);

        res.writeHead(200, { "Content-Type": "application/json" });
        res.end(JSON.stringify({ ok: true, messages: [] }));
        return;
      }

      if (req.method === "POST" && req.url === "/api/inbox/ack") {
        res.writeHead(200, { "Content-Type": "application/json" });
        res.end(JSON.stringify({ ok: true, acked: 0 }));
        return;
      }

      if (req.method === "POST" && req.url === "/api/send") {
        res.writeHead(200, { "Content-Type": "application/json" });
        res.end(JSON.stringify({ ok: true, ts: "1234.5678" }));
        return;
      }

      res.writeHead(404, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ ok: false, error: "not found" }));
    });

    await new Promise((resolve) => broker.listen(0, "127.0.0.1", resolve));
    servers.push(broker);

    const address = broker.address();
    if (!address || typeof address === "string") {
      throw new Error("failed to get broker test server address");
    }
    const brokerUrl = `http://127.0.0.1:${address.port}`;

    const testFileDir = path.dirname(fileURLToPath(import.meta.url));
    const repoRoot = path.dirname(testFileDir);
    const bridgePath = path.join(repoRoot, "slack-bridge", "broker-bridge.mjs");
    const bridgeCwd = path.join(repoRoot, "slack-bridge");

    const bridge = spawn("node", [bridgePath], {
      cwd: bridgeCwd,
      env: {
        ...cleanEnv(),
        HOME: tempHome,
        SLACK_BROKER_URL: brokerUrl,
        SLACK_BROKER_WORKSPACE_ID: workspaceId,
        SLACK_BROKER_SERVER_PRIVATE_KEY: b64(32, 11),
        SLACK_BROKER_SERVER_PUBLIC_KEY: b64(32, 12),
        SLACK_BROKER_SERVER_SIGNING_PRIVATE_KEY: signingSeed.toString("base64"),
        SLACK_BROKER_PUBLIC_KEY: b64(32, 14),
        SLACK_BROKER_SIGNING_PUBLIC_KEY: b64(32, 15),
        SLACK_BROKER_ACCESS_TOKEN: "test-broker-token",
        SLACK_ALLOWED_USERS: "U_ALLOWED",
        SLACK_BROKER_POLL_INTERVAL_MS: "50",
        BRIDGE_API_PORT: "0",
      },
      stdio: ["ignore", "pipe", "pipe"],
    });
    children.push(bridge);

    await waitFor(() => pullPayload !== null, 10_000, 50, "timeout waiting for inbox pull request");

    expect(pullPayload.workspace_id).toBe(workspaceId);
    expect(pullPayload.protocol_version).toBe("2026-02-1");
    expect(pullPayload.max_messages).toBe(10);
    expect(pullPayload.wait_seconds).toBe(20);
    expect(pullPayload.meta).toBeTruthy();
    expect(pullPayload.meta.outbound_mode).toBe("broker");
    expect(pullPayload.meta.poll_count).toBeGreaterThanOrEqual(1);
    expect(pullPayload.meta.max_messages).toBe(10);
    expect(pullPayload.meta.wait_seconds).toBe(20);
    expect(typeof pullPayload.meta.bridge_uptime_hours).toBe("number");
    expect(typeof pullPayload.meta.system_uptime_hours).toBe("number");
    expect(typeof pullPayload.meta.active_sessions).toBe("number");
    expect(typeof pullPayload.meta.active_dev_agents).toBe("number");
    expect(typeof pullPayload.meta.agent_version).toBe("string");
    expect(pullPayload.meta.heartbeat_runs).toBeGreaterThanOrEqual(0);
    expect(pullPayload.meta.heartbeat_consecutive_errors).toBeGreaterThanOrEqual(0);
    expect(pullPayload.meta.context_window_used_tokens).toBe(12345);
    expect(pullPayload.meta.context_window_limit_tokens).toBe(200000);
    expect(pullPayload.meta.context_window_used_pct).toBe(6.1725);
    expect(pullPayload.meta.session_total_tokens).toBe(54321);
    expect(pullPayload.meta.session_total_cost_usd).toBe(1.25);

    const canonical = canonicalizeProtocolRequest(workspaceId, "2026-02-1", "inbox.pull", pullPayload.timestamp, {
      max_messages: 10,
      wait_seconds: 20,
    });
    const sigBytes = new Uint8Array(Buffer.from(pullPayload.signature, "base64"));
    const valid = sodium.crypto_sign_verify_detached(sigBytes, canonical, signKeypair.publicKey);
    expect(valid).toBe(true);

    bridge.kill("SIGTERM");
  });

  it("uses protocol-versioned inbox.pull signature with wait_seconds=0", async () => {
    await sodium.ready;

    const workspaceId = "T123BROKER";
    const signingSeed = Buffer.alloc(32, 22);
    const signKeypair = sodium.crypto_sign_seed_keypair(new Uint8Array(signingSeed));
    let pullPayload = null;

    const broker = createServer(async (req, res) => {
      if (req.method === "POST" && req.url === "/api/inbox/pull") {
        let raw = "";
        for await (const chunk of req) raw += chunk;
        pullPayload = JSON.parse(raw);

        res.writeHead(200, { "Content-Type": "application/json" });
        res.end(JSON.stringify({ ok: true, messages: [] }));
        return;
      }

      if (req.method === "POST" && req.url === "/api/inbox/ack") {
        res.writeHead(200, { "Content-Type": "application/json" });
        res.end(JSON.stringify({ ok: true, acked: 0 }));
        return;
      }

      if (req.method === "POST" && req.url === "/api/send") {
        res.writeHead(200, { "Content-Type": "application/json" });
        res.end(JSON.stringify({ ok: true, ts: "1234.5678" }));
        return;
      }

      res.writeHead(404, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ ok: false, error: "not found" }));
    });

    await new Promise((resolve) => broker.listen(0, "127.0.0.1", resolve));
    servers.push(broker);

    const address = broker.address();
    if (!address || typeof address === "string") {
      throw new Error("failed to get broker test server address");
    }
    const brokerUrl = `http://127.0.0.1:${address.port}`;

    const testFileDir = path.dirname(fileURLToPath(import.meta.url));
    const repoRoot = path.dirname(testFileDir);
    const bridgePath = path.join(repoRoot, "slack-bridge", "broker-bridge.mjs");
    const bridgeCwd = path.join(repoRoot, "slack-bridge");

    const bridge = spawn("node", [bridgePath], {
      cwd: bridgeCwd,
      env: {
        ...cleanEnv(),
        SLACK_BROKER_URL: brokerUrl,
        SLACK_BROKER_WORKSPACE_ID: workspaceId,
        SLACK_BROKER_SERVER_PRIVATE_KEY: b64(32, 11),
        SLACK_BROKER_SERVER_PUBLIC_KEY: b64(32, 12),
        SLACK_BROKER_SERVER_SIGNING_PRIVATE_KEY: signingSeed.toString("base64"),
        SLACK_BROKER_PUBLIC_KEY: b64(32, 14),
        SLACK_BROKER_SIGNING_PUBLIC_KEY: b64(32, 15),
        SLACK_BROKER_ACCESS_TOKEN: "test-broker-token",
        SLACK_ALLOWED_USERS: "U_ALLOWED",
        SLACK_BROKER_POLL_INTERVAL_MS: "50",
        SLACK_BROKER_WAIT_SECONDS: "0",
        BRIDGE_API_PORT: "0",
      },
      stdio: ["ignore", "pipe", "pipe"],
    });
    children.push(bridge);

    await waitFor(() => pullPayload !== null, 10_000, 50, "timeout waiting for protocol inbox pull request");

    expect(pullPayload.workspace_id).toBe(workspaceId);
    expect(pullPayload.protocol_version).toBe("2026-02-1");
    expect(pullPayload.max_messages).toBe(10);
    expect(pullPayload.wait_seconds).toBe(0);

    const canonical = canonicalizeProtocolRequest(workspaceId, "2026-02-1", "inbox.pull", pullPayload.timestamp, {
      max_messages: 10,
      wait_seconds: 0,
    });
    const sigBytes = new Uint8Array(Buffer.from(pullPayload.signature, "base64"));
    const valid = sodium.crypto_sign_verify_detached(sigBytes, canonical, signKeypair.publicKey);
    expect(valid).toBe(true);

    bridge.kill("SIGTERM");
  });

  it("clamps max_messages before signing pull requests", async () => {
    await sodium.ready;

    const workspaceId = "T123BROKER";
    const signingSeed = Buffer.alloc(32, 23);
    const signKeypair = sodium.crypto_sign_seed_keypair(new Uint8Array(signingSeed));
    let pullPayload = null;

    const broker = createServer(async (req, res) => {
      if (req.method === "POST" && req.url === "/api/inbox/pull") {
        let raw = "";
        for await (const chunk of req) raw += chunk;
        pullPayload = JSON.parse(raw);

        res.writeHead(200, { "Content-Type": "application/json" });
        res.end(JSON.stringify({ ok: true, messages: [] }));
        return;
      }

      if (req.method === "POST" && req.url === "/api/inbox/ack") {
        res.writeHead(200, { "Content-Type": "application/json" });
        res.end(JSON.stringify({ ok: true, acked: 0 }));
        return;
      }

      if (req.method === "POST" && req.url === "/api/send") {
        res.writeHead(200, { "Content-Type": "application/json" });
        res.end(JSON.stringify({ ok: true, ts: "1234.5678" }));
        return;
      }

      res.writeHead(404, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ ok: false, error: "not found" }));
    });

    await new Promise((resolve) => broker.listen(0, "127.0.0.1", resolve));
    servers.push(broker);

    const address = broker.address();
    if (!address || typeof address === "string") {
      throw new Error("failed to get broker test server address");
    }
    const brokerUrl = `http://127.0.0.1:${address.port}`;

    const testFileDir = path.dirname(fileURLToPath(import.meta.url));
    const repoRoot = path.dirname(testFileDir);
    const bridgePath = path.join(repoRoot, "slack-bridge", "broker-bridge.mjs");
    const bridgeCwd = path.join(repoRoot, "slack-bridge");

    const bridge = spawn("node", [bridgePath], {
      cwd: bridgeCwd,
      env: {
        ...cleanEnv(),
        SLACK_BROKER_URL: brokerUrl,
        SLACK_BROKER_WORKSPACE_ID: workspaceId,
        SLACK_BROKER_SERVER_PRIVATE_KEY: b64(32, 11),
        SLACK_BROKER_SERVER_PUBLIC_KEY: b64(32, 12),
        SLACK_BROKER_SERVER_SIGNING_PRIVATE_KEY: signingSeed.toString("base64"),
        SLACK_BROKER_PUBLIC_KEY: b64(32, 14),
        SLACK_BROKER_SIGNING_PUBLIC_KEY: b64(32, 15),
        SLACK_BROKER_ACCESS_TOKEN: "test-broker-token",
        SLACK_ALLOWED_USERS: "U_ALLOWED",
        SLACK_BROKER_POLL_INTERVAL_MS: "50",
        SLACK_BROKER_MAX_MESSAGES: "999",
        BRIDGE_API_PORT: "0",
      },
      stdio: ["ignore", "pipe", "pipe"],
    });
    children.push(bridge);

    await waitFor(() => pullPayload !== null, 10_000, 50, "timeout waiting for clamped inbox pull request");

    expect(pullPayload.workspace_id).toBe(workspaceId);
    expect(pullPayload.protocol_version).toBe("2026-02-1");
    expect(pullPayload.max_messages).toBe(100);
    expect(pullPayload.wait_seconds).toBe(20);

    const canonical = canonicalizeProtocolRequest(workspaceId, "2026-02-1", "inbox.pull", pullPayload.timestamp, {
      max_messages: 100,
      wait_seconds: 20,
    });
    const sigBytes = new Uint8Array(Buffer.from(pullPayload.signature, "base64"));
    const valid = sodium.crypto_sign_verify_detached(sigBytes, canonical, signKeypair.publicKey);
    expect(valid).toBe(true);

    bridge.kill("SIGTERM");
  });

  it("sends broker bearer token when configured", async () => {
    await sodium.ready;

    const workspaceId = "T123BROKER";
    const bridgeApiPort = await reserveFreePort();
    let outboundAuthorization = null;

    const broker = createServer(async (req, res) => {
      if (req.method === "POST" && req.url === "/api/inbox/pull") {
        res.writeHead(200, { "Content-Type": "application/json" });
        res.end(JSON.stringify({ ok: true, messages: [] }));
        return;
      }

      if (req.method === "POST" && req.url === "/api/send") {
        outboundAuthorization = req.headers.authorization || null;
        res.writeHead(200, { "Content-Type": "application/json" });
        res.end(JSON.stringify({ ok: true, ts: "1234.5678" }));
        return;
      }

      if (req.method === "POST" && req.url === "/api/inbox/ack") {
        res.writeHead(200, { "Content-Type": "application/json" });
        res.end(JSON.stringify({ ok: true, acked: 0 }));
        return;
      }

      res.writeHead(404, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ ok: false, error: "not found" }));
    });

    await new Promise((resolve) => broker.listen(0, "127.0.0.1", resolve));
    servers.push(broker);

    const address = broker.address();
    if (!address || typeof address === "string") {
      throw new Error("failed to get broker test server address");
    }
    const brokerUrl = `http://127.0.0.1:${address.port}`;

    const testFileDir = path.dirname(fileURLToPath(import.meta.url));
    const repoRoot = path.dirname(testFileDir);
    const bridgePath = path.join(repoRoot, "slack-bridge", "broker-bridge.mjs");
    const bridgeCwd = path.join(repoRoot, "slack-bridge");

    const bridge = spawn("node", [bridgePath], {
      cwd: bridgeCwd,
      env: {
        ...cleanEnv(),
        SLACK_BROKER_URL: brokerUrl,
        SLACK_BROKER_WORKSPACE_ID: workspaceId,
        SLACK_BROKER_SERVER_PRIVATE_KEY: b64(32, 11),
        SLACK_BROKER_SERVER_PUBLIC_KEY: b64(32, 12),
        SLACK_BROKER_SERVER_SIGNING_PRIVATE_KEY: Buffer.alloc(32, 24).toString("base64"),
        SLACK_BROKER_PUBLIC_KEY: b64(32, 14),
        SLACK_BROKER_SIGNING_PUBLIC_KEY: b64(32, 15),
        SLACK_BROKER_ACCESS_TOKEN: "test-broker-token",
        SLACK_ALLOWED_USERS: "U_ALLOWED",
        SLACK_BROKER_POLL_INTERVAL_MS: "50",
        SLACK_BROKER_WAIT_SECONDS: "0",
        BRIDGE_API_PORT: String(bridgeApiPort),
      },
      stdio: ["ignore", "pipe", "pipe"],
    });
    children.push(bridge);

    const start = Date.now();
    // Bridge local API may not be ready immediately after spawn; retry until it accepts /send.
    while (Date.now() - start < 10_000) {
      try {
        const res = await fetch(`http://127.0.0.1:${bridgeApiPort}/send`, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ channel: "C123", text: "hello" }),
        });
        if (res.ok) break;
      } catch {
        // retry while bridge boots
      }
      await new Promise((resolve) => setTimeout(resolve, 100));
    }

    await waitFor(() => outboundAuthorization !== null, 10_000, 50, "timeout waiting for broker /api/send call");
    expect(outboundAuthorization).toBe("Bearer test-broker-token");

    bridge.kill("SIGTERM");
  });

  it("exits when broker access token is missing", async () => {
    await sodium.ready;

    const testFileDir = path.dirname(fileURLToPath(import.meta.url));
    const repoRoot = path.dirname(testFileDir);
    const bridgePath = path.join(repoRoot, "slack-bridge", "broker-bridge.mjs");
    const bridgeCwd = path.join(repoRoot, "slack-bridge");

    let bridgeStdout = "";
    let bridgeStderr = "";

    const envWithoutBrokerToken = { ...process.env };
    delete envWithoutBrokerToken.SLACK_BROKER_ACCESS_TOKEN;

    const bridge = spawn("node", [bridgePath], {
      cwd: bridgeCwd,
      env: {
        ...envWithoutBrokerToken,
        SLACK_BROKER_URL: "http://127.0.0.1:65535",
        SLACK_BROKER_WORKSPACE_ID: "T123BROKER",
        SLACK_BROKER_SERVER_PRIVATE_KEY: b64(32, 11),
        SLACK_BROKER_SERVER_PUBLIC_KEY: b64(32, 12),
        SLACK_BROKER_SERVER_SIGNING_PRIVATE_KEY: Buffer.alloc(32, 26).toString("base64"),
        SLACK_BROKER_PUBLIC_KEY: b64(32, 14),
        SLACK_BROKER_SIGNING_PUBLIC_KEY: b64(32, 15),
        SLACK_ALLOWED_USERS: "U_ALLOWED",
        BRIDGE_API_PORT: "0",
      },
      stdio: ["ignore", "pipe", "pipe"],
    });

    bridge.stdout.on("data", (chunk) => {
      bridgeStdout += chunk.toString();
    });
    bridge.stderr.on("data", (chunk) => {
      bridgeStderr += chunk.toString();
    });

    children.push(bridge);

    const exited = await new Promise((resolve) => {
      bridge.on("exit", (code, signal) => resolve({ code, signal }));
    });

    expect(exited.code).toBe(1);
    expect(`${bridgeStdout}\n${bridgeStderr}`).toContain("Missing required env var for broker mode: SLACK_BROKER_ACCESS_TOKEN");
  });

  it("exits when broker access token is expired", async () => {
    await sodium.ready;

    const testFileDir = path.dirname(fileURLToPath(import.meta.url));
    const repoRoot = path.dirname(testFileDir);
    const bridgePath = path.join(repoRoot, "slack-bridge", "broker-bridge.mjs");
    const bridgeCwd = path.join(repoRoot, "slack-bridge");

    let bridgeStdout = "";
    let bridgeStderr = "";

    const bridge = spawn("node", [bridgePath], {
      cwd: bridgeCwd,
      env: {
        ...process.env,
        SLACK_BROKER_URL: "http://127.0.0.1:65535",
        SLACK_BROKER_WORKSPACE_ID: "T123BROKER",
        SLACK_BROKER_SERVER_PRIVATE_KEY: b64(32, 11),
        SLACK_BROKER_SERVER_PUBLIC_KEY: b64(32, 12),
        SLACK_BROKER_SERVER_SIGNING_PRIVATE_KEY: Buffer.alloc(32, 25).toString("base64"),
        SLACK_BROKER_PUBLIC_KEY: b64(32, 14),
        SLACK_BROKER_SIGNING_PUBLIC_KEY: b64(32, 15),
        SLACK_BROKER_ACCESS_TOKEN: "expired-token",
        SLACK_BROKER_ACCESS_TOKEN_EXPIRES_AT: "2000-01-01T00:00:00.000Z",
        SLACK_ALLOWED_USERS: "U_ALLOWED",
        BRIDGE_API_PORT: "0",
      },
      stdio: ["ignore", "pipe", "pipe"],
    });

    bridge.stdout.on("data", (chunk) => {
      bridgeStdout += chunk.toString();
    });
    bridge.stderr.on("data", (chunk) => {
      bridgeStderr += chunk.toString();
    });

    children.push(bridge);

    const exited = await new Promise((resolve) => {
      bridge.on("exit", (code, signal) => resolve({ code, signal }));
    });

    expect(exited.code).toBe(1);
    expect(`${bridgeStdout}\n${bridgeStderr}`).toContain("broker access token is expired");
  });

  it("dispatches generic envelope with source=slack to Slack handler", async () => {
    await sodium.ready;

    const testFileDir = path.dirname(fileURLToPath(import.meta.url));
    const repoRoot = path.dirname(testFileDir);
    const bridgePath = path.join(repoRoot, "slack-bridge", "broker-bridge.mjs");
    const bridgeCwd = path.join(repoRoot, "slack-bridge");

    const tempHome = mkdtempSync(path.join(tmpdir(), "baudbot-broker-test-"));
    tempDirs.push(tempHome);

    const sessionDir = path.join(tempHome, ".pi", "session-control");
    mkdirSync(sessionDir, { recursive: true });
    const sessionId = "22222222-2222-2222-2222-222222222222";
    const socketFile = path.join(sessionDir, `${sessionId}.sock`);

    const receivedCommands = [];
    const agentSocket = net.createServer((conn) => {
      let buffer = "";
      conn.on("data", (chunk) => {
        buffer += chunk.toString();
        const lines = buffer.split("\n");
        buffer = lines.pop() || "";
        for (const line of lines) {
          if (!line.trim()) continue;
          const msg = JSON.parse(line);
          receivedCommands.push(msg);
          if (msg.type === "send") {
            conn.write(`${JSON.stringify({ type: "response", command: "send", success: true })}\n`);
          }
        }
      });
    });
    await new Promise((resolve) => agentSocket.listen(socketFile, resolve));
    servers.push(agentSocket);

    const serverBox = sodium.crypto_box_keypair();
    const brokerBox = sodium.crypto_box_keypair();
    const brokerSign = sodium.crypto_sign_keypair();
    const serverSignSeed = sodium.randombytes_buf(sodium.crypto_sign_SEEDBYTES);

    const testWorkspaceId = "T123BROKER";

    // Generic envelope wrapping a Slack event_callback
    const genericEnvelope = {
      source: "slack",
      type: "event_callback",
      broker_timestamp: Math.floor(Date.now() / 1000),
      payload: {
        type: "event_callback",
        event: {
          type: "app_mention",
          user: "U_ALLOWED",
          channel: "C456",
          ts: "1730000000.000200",
          text: "<@U_BOT> generic envelope test",
        },
      },
    };

    const encrypted = sodium.crypto_box_seal(
      Buffer.from(JSON.stringify(genericEnvelope)),
      serverBox.publicKey,
    );
    const brokerTimestamp = Math.floor(Date.now() / 1000);
    const encryptedB64 = toBase64(encrypted);
    const brokerSignature = toBase64(
      sodium.crypto_sign_detached(
        canonicalizeEnvelope(testWorkspaceId, brokerTimestamp, encryptedB64),
        brokerSign.privateKey,
      ),
    );

    let pullCount = 0;
    let ackPayload = null;

    const broker = createServer(async (req, res) => {
      if (req.method === "POST" && req.url === "/api/inbox/pull") {
        pullCount += 1;
        const messages = pullCount === 1
          ? [{
              message_id: "m-generic-slack-1",
              workspace_id: testWorkspaceId,
              encrypted: encryptedB64,
              broker_timestamp: brokerTimestamp,
              broker_signature: brokerSignature,
            }]
          : [];
        res.writeHead(200, { "Content-Type": "application/json" });
        res.end(JSON.stringify({ ok: true, messages }));
        return;
      }

      if (req.method === "POST" && req.url === "/api/inbox/ack") {
        let raw = "";
        for await (const chunk of req) raw += chunk;
        ackPayload = JSON.parse(raw);
        res.writeHead(200, { "Content-Type": "application/json" });
        res.end(JSON.stringify({ ok: true, acked: ackPayload.message_ids?.length ?? 0 }));
        return;
      }

      if (req.method === "POST" && req.url === "/api/send") {
        res.writeHead(200, { "Content-Type": "application/json" });
        res.end(JSON.stringify({ ok: true, ts: "1234.5678" }));
        return;
      }

      res.writeHead(404, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ ok: false, error: "not found" }));
    });

    await new Promise((resolve) => broker.listen(0, "127.0.0.1", resolve));
    servers.push(broker);

    const address = broker.address();
    if (!address || typeof address === "string") {
      throw new Error("failed to get broker test server address");
    }

    let bridgeStdout = "";
    let bridgeStderr = "";
    let bridgeExit = null;

    const bridge = spawn("node", [bridgePath], {
      cwd: bridgeCwd,
      env: {
        ...cleanEnv(),
        HOME: tempHome,
        PI_SESSION_ID: sessionId,
        SLACK_BROKER_URL: `http://127.0.0.1:${address.port}`,
        SLACK_BROKER_WORKSPACE_ID: testWorkspaceId,
        SLACK_BROKER_SERVER_PRIVATE_KEY: toBase64(serverBox.privateKey),
        SLACK_BROKER_SERVER_PUBLIC_KEY: toBase64(serverBox.publicKey),
        SLACK_BROKER_SERVER_SIGNING_PRIVATE_KEY: toBase64(serverSignSeed),
        SLACK_BROKER_PUBLIC_KEY: toBase64(brokerBox.publicKey),
        SLACK_BROKER_SIGNING_PUBLIC_KEY: toBase64(brokerSign.publicKey),
        SLACK_BROKER_ACCESS_TOKEN: "test-broker-token",
        SLACK_ALLOWED_USERS: "U_ALLOWED",
        SLACK_BROKER_POLL_INTERVAL_MS: "50",
        BRIDGE_API_PORT: "0",
      },
      stdio: ["ignore", "pipe", "pipe"],
    });

    bridge.stdout.on("data", (chunk) => { bridgeStdout += chunk.toString(); });
    bridge.stderr.on("data", (chunk) => { bridgeStderr += chunk.toString(); });

    const bridgeExited = new Promise((_, reject) => {
      bridge.on("error", (err) => {
        if (ackPayload !== null) return;
        reject(new Error(`bridge spawn error: ${err.message}; stdout=${bridgeStdout}; stderr=${bridgeStderr}`));
      });
      bridge.on("exit", (code, signal) => {
        bridgeExit = { code, signal };
        if (ackPayload !== null) return;
        reject(new Error(`bridge exited early: code=${code} signal=${signal}; stdout=${bridgeStdout}; stderr=${bridgeStderr}`));
      });
    });

    children.push(bridge);

    const completeWait = waitFor(
      () => ackPayload !== null && receivedCommands.length > 0,
      12_000,
      50,
      `timeout waiting for generic envelope forward+ack; pullCount=${pullCount}; commands=${JSON.stringify(receivedCommands)}; exit=${JSON.stringify(bridgeExit)}; stdout=${bridgeStdout}; stderr=${bridgeStderr}`,
    );

    await Promise.race([completeWait, bridgeExited]);

    // Verify the message was acked
    expect(ackPayload.message_ids).toContain("m-generic-slack-1");

    // Verify the agent received the message (forwarded through Slack handler)
    expect(receivedCommands.length).toBe(1);
    expect(receivedCommands[0].type).toBe("send");
    expect(receivedCommands[0].mode).toBe("steer");
    expect(receivedCommands[0].message).toContain("generic envelope test");

    // Verify generic envelope log line appeared
    expect(bridgeStdout).toContain("generic envelope");
    expect(bridgeStdout).toContain("source: slack");
  });

  it("dispatches generic envelope with source=dashboard and acks", async () => {
    await sodium.ready;

    const testFileDir = path.dirname(fileURLToPath(import.meta.url));
    const repoRoot = path.dirname(testFileDir);
    const bridgePath = path.join(repoRoot, "slack-bridge", "broker-bridge.mjs");
    const bridgeCwd = path.join(repoRoot, "slack-bridge");

    const serverBox = sodium.crypto_box_keypair();
    const brokerBox = sodium.crypto_box_keypair();
    const brokerSign = sodium.crypto_sign_keypair();
    const serverSignSeed = sodium.randombytes_buf(sodium.crypto_sign_SEEDBYTES);

    const testWorkspaceId = "T123BROKER";

    const dashboardEnvelope = {
      source: "dashboard",
      type: "config.updated",
      broker_timestamp: Math.floor(Date.now() / 1000),
      payload: {
        key: "SOME_CONFIG",
        value: "new_value",
      },
    };

    const encrypted = sodium.crypto_box_seal(
      Buffer.from(JSON.stringify(dashboardEnvelope)),
      serverBox.publicKey,
    );
    const brokerTimestamp = Math.floor(Date.now() / 1000);
    const encryptedB64 = toBase64(encrypted);
    const brokerSignature = toBase64(
      sodium.crypto_sign_detached(
        canonicalizeEnvelope(testWorkspaceId, brokerTimestamp, encryptedB64),
        brokerSign.privateKey,
      ),
    );

    let pullCount = 0;
    let ackPayload = null;

    const broker = createServer(async (req, res) => {
      if (req.method === "POST" && req.url === "/api/inbox/pull") {
        pullCount += 1;
        const messages = pullCount === 1
          ? [{
              message_id: "m-dashboard-1",
              workspace_id: testWorkspaceId,
              encrypted: encryptedB64,
              broker_timestamp: brokerTimestamp,
              broker_signature: brokerSignature,
            }]
          : [];
        res.writeHead(200, { "Content-Type": "application/json" });
        res.end(JSON.stringify({ ok: true, messages }));
        return;
      }

      if (req.method === "POST" && req.url === "/api/inbox/ack") {
        let raw = "";
        for await (const chunk of req) raw += chunk;
        ackPayload = JSON.parse(raw);
        res.writeHead(200, { "Content-Type": "application/json" });
        res.end(JSON.stringify({ ok: true, acked: ackPayload.message_ids?.length ?? 0 }));
        return;
      }

      if (req.method === "POST" && req.url === "/api/send") {
        res.writeHead(200, { "Content-Type": "application/json" });
        res.end(JSON.stringify({ ok: true, ts: "1234.5678" }));
        return;
      }

      res.writeHead(404, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ ok: false, error: "not found" }));
    });

    await new Promise((resolve) => broker.listen(0, "127.0.0.1", resolve));
    servers.push(broker);

    const address = broker.address();
    if (!address || typeof address === "string") {
      throw new Error("failed to get broker test server address");
    }

    let bridgeStdout = "";
    let bridgeStderr = "";
    let bridgeExit = null;

    const bridge = spawn("node", [bridgePath], {
      cwd: bridgeCwd,
      env: {
        ...cleanEnv(),
        SLACK_BROKER_URL: `http://127.0.0.1:${address.port}`,
        SLACK_BROKER_WORKSPACE_ID: testWorkspaceId,
        SLACK_BROKER_SERVER_PRIVATE_KEY: toBase64(serverBox.privateKey),
        SLACK_BROKER_SERVER_PUBLIC_KEY: toBase64(serverBox.publicKey),
        SLACK_BROKER_SERVER_SIGNING_PRIVATE_KEY: toBase64(serverSignSeed),
        SLACK_BROKER_PUBLIC_KEY: toBase64(brokerBox.publicKey),
        SLACK_BROKER_SIGNING_PUBLIC_KEY: toBase64(brokerSign.publicKey),
        SLACK_BROKER_ACCESS_TOKEN: "test-broker-token",
        SLACK_ALLOWED_USERS: "U_ALLOWED",
        SLACK_BROKER_POLL_INTERVAL_MS: "50",
        BRIDGE_API_PORT: "0",
      },
      stdio: ["ignore", "pipe", "pipe"],
    });

    bridge.stdout.on("data", (chunk) => { bridgeStdout += chunk.toString(); });
    bridge.stderr.on("data", (chunk) => { bridgeStderr += chunk.toString(); });

    const bridgeExited = new Promise((_, reject) => {
      bridge.on("error", (err) => {
        if (ackPayload !== null) return;
        reject(new Error(`bridge spawn error: ${err.message}; stdout=${bridgeStdout}; stderr=${bridgeStderr}`));
      });
      bridge.on("exit", (code, signal) => {
        bridgeExit = { code, signal };
        if (ackPayload !== null) return;
        reject(new Error(`bridge exited early: code=${code} signal=${signal}; stdout=${bridgeStdout}; stderr=${bridgeStderr}`));
      });
    });

    children.push(bridge);

    const ackWait = waitFor(
      () => ackPayload !== null,
      12_000,
      50,
      `timeout waiting for dashboard envelope ack; pullCount=${pullCount}; exit=${JSON.stringify(bridgeExit)}; stdout=${bridgeStdout}; stderr=${bridgeStderr}`,
    );

    await Promise.race([ackWait, bridgeExited]);

    expect(ackPayload.message_ids).toContain("m-dashboard-1");
    expect(bridgeStdout).toContain("generic envelope");
    expect(bridgeStdout).toContain("source: dashboard");
    expect(bridgeStdout).toContain("dashboard event: config.updated");
  });

  it("acks generic envelope with unknown source to avoid blocking queue", async () => {
    await sodium.ready;

    const testFileDir = path.dirname(fileURLToPath(import.meta.url));
    const repoRoot = path.dirname(testFileDir);
    const bridgePath = path.join(repoRoot, "slack-bridge", "broker-bridge.mjs");
    const bridgeCwd = path.join(repoRoot, "slack-bridge");

    const serverBox = sodium.crypto_box_keypair();
    const brokerBox = sodium.crypto_box_keypair();
    const brokerSign = sodium.crypto_sign_keypair();
    const serverSignSeed = sodium.randombytes_buf(sodium.crypto_sign_SEEDBYTES);

    const testWorkspaceId = "T123BROKER";

    const unknownEnvelope = {
      source: "future_service",
      type: "something.happened",
      broker_timestamp: Math.floor(Date.now() / 1000),
      payload: { detail: "some data" },
    };

    const encrypted = sodium.crypto_box_seal(
      Buffer.from(JSON.stringify(unknownEnvelope)),
      serverBox.publicKey,
    );
    const brokerTimestamp = Math.floor(Date.now() / 1000);
    const encryptedB64 = toBase64(encrypted);
    const brokerSignature = toBase64(
      sodium.crypto_sign_detached(
        canonicalizeEnvelope(testWorkspaceId, brokerTimestamp, encryptedB64),
        brokerSign.privateKey,
      ),
    );

    let pullCount = 0;
    let ackPayload = null;

    const broker = createServer(async (req, res) => {
      if (req.method === "POST" && req.url === "/api/inbox/pull") {
        pullCount += 1;
        const messages = pullCount === 1
          ? [{
              message_id: "m-unknown-src-1",
              workspace_id: testWorkspaceId,
              encrypted: encryptedB64,
              broker_timestamp: brokerTimestamp,
              broker_signature: brokerSignature,
            }]
          : [];
        res.writeHead(200, { "Content-Type": "application/json" });
        res.end(JSON.stringify({ ok: true, messages }));
        return;
      }

      if (req.method === "POST" && req.url === "/api/inbox/ack") {
        let raw = "";
        for await (const chunk of req) raw += chunk;
        ackPayload = JSON.parse(raw);
        res.writeHead(200, { "Content-Type": "application/json" });
        res.end(JSON.stringify({ ok: true, acked: ackPayload.message_ids?.length ?? 0 }));
        return;
      }

      if (req.method === "POST" && req.url === "/api/send") {
        res.writeHead(200, { "Content-Type": "application/json" });
        res.end(JSON.stringify({ ok: true, ts: "1234.5678" }));
        return;
      }

      res.writeHead(404, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ ok: false, error: "not found" }));
    });

    await new Promise((resolve) => broker.listen(0, "127.0.0.1", resolve));
    servers.push(broker);

    const address = broker.address();
    if (!address || typeof address === "string") {
      throw new Error("failed to get broker test server address");
    }

    let bridgeStdout = "";
    let bridgeStderr = "";
    let bridgeExit = null;

    const bridge = spawn("node", [bridgePath], {
      cwd: bridgeCwd,
      env: {
        ...cleanEnv(),
        SLACK_BROKER_URL: `http://127.0.0.1:${address.port}`,
        SLACK_BROKER_WORKSPACE_ID: testWorkspaceId,
        SLACK_BROKER_SERVER_PRIVATE_KEY: toBase64(serverBox.privateKey),
        SLACK_BROKER_SERVER_PUBLIC_KEY: toBase64(serverBox.publicKey),
        SLACK_BROKER_SERVER_SIGNING_PRIVATE_KEY: toBase64(serverSignSeed),
        SLACK_BROKER_PUBLIC_KEY: toBase64(brokerBox.publicKey),
        SLACK_BROKER_SIGNING_PUBLIC_KEY: toBase64(brokerSign.publicKey),
        SLACK_BROKER_ACCESS_TOKEN: "test-broker-token",
        SLACK_ALLOWED_USERS: "U_ALLOWED",
        SLACK_BROKER_POLL_INTERVAL_MS: "50",
        BRIDGE_API_PORT: "0",
      },
      stdio: ["ignore", "pipe", "pipe"],
    });

    bridge.stdout.on("data", (chunk) => { bridgeStdout += chunk.toString(); });
    bridge.stderr.on("data", (chunk) => { bridgeStderr += chunk.toString(); });

    const bridgeExited = new Promise((_, reject) => {
      bridge.on("error", (err) => {
        if (ackPayload !== null) return;
        reject(new Error(`bridge spawn error: ${err.message}; stdout=${bridgeStdout}; stderr=${bridgeStderr}`));
      });
      bridge.on("exit", (code, signal) => {
        bridgeExit = { code, signal };
        if (ackPayload !== null) return;
        reject(new Error(`bridge exited early: code=${code} signal=${signal}; stdout=${bridgeStdout}; stderr=${bridgeStderr}`));
      });
    });

    children.push(bridge);

    const ackWait = waitFor(
      () => ackPayload !== null,
      12_000,
      50,
      `timeout waiting for unknown source ack; pullCount=${pullCount}; exit=${JSON.stringify(bridgeExit)}; stdout=${bridgeStdout}; stderr=${bridgeStderr}`,
    );

    await Promise.race([ackWait, bridgeExited]);

    expect(ackPayload.message_ids).toContain("m-unknown-src-1");
    expect(bridgeStdout + bridgeStderr).toContain("unknown event source: future_service");
  });
});
