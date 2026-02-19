import test from "node:test";
import assert from "node:assert/strict";
import { createServer } from "node:http";
import {
  parseArgs,
  normalizeBrokerUrl,
  validateWorkspaceId,
  validateCallbackUrl,
  mapRegisterError,
  registerWithBroker,
  upsertEnvContent,
  runRegistration,
} from "./broker-register.mjs";

const FIXTURE_SERVER_KEYS = {
  server_pubkey: Buffer.alloc(32, 1).toString("base64"),
  server_private_key: Buffer.alloc(32, 2).toString("base64"),
  server_signing_pubkey: Buffer.alloc(32, 3).toString("base64"),
  server_signing_private_key: Buffer.alloc(32, 4).toString("base64"),
};

function jsonResponse(data, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

test("parseArgs parses long-form options", () => {
  const parsed = parseArgs([
    "--broker-url",
    "https://broker.example.com/",
    "--workspace-id",
    "T123ABC",
    "--auth-code",
    "secret-code",
    "--callback-url",
    "https://server.example.com/slack/callback",
  ]);

  assert.deepEqual(parsed, {
    brokerUrl: "https://broker.example.com/",
    workspaceId: "T123ABC",
    authCode: "secret-code",
    callbackUrl: "https://server.example.com/slack/callback",
    help: false,
  });
});

test("parseArgs rejects unknown arguments", () => {
  assert.throws(() => parseArgs(["--wat"]), /unknown argument/);
});

test("validation helpers normalize and enforce broker/workspace/callback formats", () => {
  assert.equal(normalizeBrokerUrl("https://broker.example.com/"), "https://broker.example.com");
  assert.equal(validateWorkspaceId("T0ABC123"), true);
  assert.equal(validateWorkspaceId("workspace-123"), false);
  assert.equal(validateCallbackUrl("https://server.example.com/callback"), "https://server.example.com/callback");

  assert.throws(() => normalizeBrokerUrl("ftp://broker.example.com"), /http:\/\/ or https:\/\//);
  assert.throws(() => validateCallbackUrl("http://server.example.com/callback"), /must use https:\/\//);
});

test("mapRegisterError returns actionable messages", () => {
  assert.match(mapRegisterError(403, "invalid auth code"), /invalid auth code/);
  assert.match(mapRegisterError(409, "workspace already active"), /already active/);
  assert.match(mapRegisterError(500, "oops"), /broker server error/);
});

test("registerWithBroker fetches pubkeys then posts registration payload", async () => {
  const calls = [];
  const fetchImpl = async (url, init = {}) => {
    calls.push({ url: String(url), init });

    if (String(url).endsWith("/api/broker-pubkey")) {
      return jsonResponse({
        ok: true,
        broker_pubkey: Buffer.alloc(32, 9).toString("base64"),
        broker_signing_pubkey: Buffer.alloc(32, 8).toString("base64"),
      });
    }

    if (String(url).endsWith("/api/register")) {
      const payload = JSON.parse(init.body);
      assert.equal(payload.workspace_id, "TTEST123");
      assert.equal(payload.server_callback_url, "https://server.example.com/callback");
      assert.equal(payload.server_pubkey, FIXTURE_SERVER_KEYS.server_pubkey);
      assert.equal(payload.server_signing_pubkey, FIXTURE_SERVER_KEYS.server_signing_pubkey);
      assert.equal(payload.auth_code, "one-time-code");

      return jsonResponse({
        ok: true,
        broker_pubkey: Buffer.alloc(32, 9).toString("base64"),
        broker_signing_pubkey: Buffer.alloc(32, 8).toString("base64"),
      });
    }

    return jsonResponse({ ok: false, error: "unexpected endpoint" }, 404);
  };

  const result = await registerWithBroker({
    brokerUrl: "https://broker.example.com",
    workspaceId: "TTEST123",
    authCode: "one-time-code",
    callbackUrl: "https://server.example.com/callback",
    serverKeys: FIXTURE_SERVER_KEYS,
    fetchImpl,
  });

  assert.equal(calls.length, 2);
  assert.match(calls[0].url, /\/api\/broker-pubkey$/);
  assert.match(calls[1].url, /\/api\/register$/);
  assert.equal(result.broker_pubkey, Buffer.alloc(32, 9).toString("base64"));
  assert.equal(result.broker_signing_pubkey, Buffer.alloc(32, 8).toString("base64"));
});

test("runRegistration integration path succeeds against live local HTTP server", async () => {
  const brokerPubkey = Buffer.alloc(32, 5).toString("base64");
  const brokerSigningPubkey = Buffer.alloc(32, 6).toString("base64");

  let receivedRegisterPayload = null;

  const server = createServer(async (req, res) => {
    if (req.method === "GET" && req.url === "/api/broker-pubkey") {
      res.writeHead(200, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ ok: true, broker_pubkey: brokerPubkey, broker_signing_pubkey: brokerSigningPubkey }));
      return;
    }

    if (req.method === "POST" && req.url === "/api/register") {
      let raw = "";
      for await (const chunk of req) raw += chunk;
      receivedRegisterPayload = JSON.parse(raw);
      res.writeHead(200, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ ok: true, broker_pubkey: brokerPubkey, broker_signing_pubkey: brokerSigningPubkey }));
      return;
    }

    res.writeHead(404, { "Content-Type": "application/json" });
    res.end(JSON.stringify({ ok: false, error: "not found" }));
  });

  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const address = server.address();
  const brokerUrl = `http://127.0.0.1:${address.port}`;

  try {
    const result = await runRegistration({
      brokerUrl,
      workspaceId: "TABC12345",
      callbackUrl: "https://server.example.com/broker/inbound",
      authCode: "auth-code-from-oauth",
    });

    assert.ok(receivedRegisterPayload);
    assert.equal(receivedRegisterPayload.workspace_id, "TABC12345");
    assert.equal(receivedRegisterPayload.server_callback_url, "https://server.example.com/broker/inbound");
    assert.ok(result.updates.SLACK_BROKER_SERVER_PRIVATE_KEY);
    assert.ok(result.updates.SLACK_BROKER_SERVER_SIGNING_PRIVATE_KEY);
    assert.equal(result.updates.SLACK_BROKER_PUBLIC_KEY, brokerPubkey);
    assert.equal(result.updates.SLACK_BROKER_SIGNING_PUBLIC_KEY, brokerSigningPubkey);
  } finally {
    await new Promise((resolve, reject) => server.close((err) => (err ? reject(err) : resolve())));
  }
});

test("upsertEnvContent updates existing values and appends new ones", () => {
  const existing = [
    "SLACK_BOT_TOKEN=xoxb-old",
    "SLACK_ALLOWED_USERS=U1,U2",
    "",
  ].join("\n");

  const next = upsertEnvContent(existing, {
    SLACK_ALLOWED_USERS: "U3,U4",
    SLACK_BROKER_URL: "https://broker.example.com",
  });

  assert.match(next, /SLACK_ALLOWED_USERS=U3,U4/);
  assert.match(next, /SLACK_BROKER_URL=https:\/\/broker\.example\.com/);
  assert.match(next, /SLACK_BOT_TOKEN=xoxb-old/);
});
