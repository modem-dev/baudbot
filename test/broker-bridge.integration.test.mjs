import { afterEach, describe, expect, it } from "vitest";
import { createServer } from "node:http";
import { spawn } from "node:child_process";
import path from "node:path";
import { fileURLToPath } from "node:url";

function b64(bytes = 32, fill = 1) {
  return Buffer.alloc(bytes, fill).toString("base64");
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

describe("broker pull bridge semi-integration", () => {
  const children = [];
  const servers = [];

  afterEach(async () => {
    for (const child of children) {
      if (!child.killed) child.kill("SIGTERM");
    }
    for (const server of servers) {
      await new Promise((resolve) => server.close(() => resolve(undefined)));
    }
    children.length = 0;
    servers.length = 0;
  });

  it("acks poison messages from broker to avoid infinite retry loops", async () => {
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
        ...process.env,
        SLACK_BROKER_URL: brokerUrl,
        SLACK_BROKER_WORKSPACE_ID: "T123BROKER",
        SLACK_BROKER_SERVER_PRIVATE_KEY: b64(32, 11),
        SLACK_BROKER_SERVER_PUBLIC_KEY: b64(32, 12),
        SLACK_BROKER_SERVER_SIGNING_PRIVATE_KEY: b64(32, 13),
        SLACK_BROKER_PUBLIC_KEY: b64(32, 14),
        SLACK_BROKER_SIGNING_PUBLIC_KEY: b64(32, 15),
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
    expect(ackPayload.message_ids).toContain("m-poison-1");
  });
});
