import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { createServer } from "node:http";
import { pathToFileURL } from "node:url";
import {
  parseArgs,
  normalizeBrokerUrl,
  validateWorkspaceId,
  mapRegisterError,
  registerWithBroker,
  upsertEnvContent,
  runRegistration,
  isMainModule,
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
    "--registration-token",
    "token-xyz",
  ]);

  assert.deepEqual(parsed, {
    brokerUrl: "https://broker.example.com/",
    workspaceId: "T123ABC",
    registrationToken: "token-xyz",
    verbose: false,
    help: false,
  });
});

test("parseArgs sets verbose=true for -v and --verbose", () => {
  const short = parseArgs(["-v"]);
  assert.equal(short.verbose, true);

  const long = parseArgs(["--verbose"]);
  assert.equal(long.verbose, true);
});

test("isMainModule handles symlink argv path", () => {
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "broker-register-main-"));
  const realFile = path.join(tempDir, "real.mjs");
  const symlinkFile = path.join(tempDir, "link.mjs");

  try {
    fs.writeFileSync(realFile, "export default 1;\n", "utf8");
    fs.symlinkSync(realFile, symlinkFile);

    const moduleUrl = pathToFileURL(fs.realpathSync(realFile)).href;
    assert.equal(isMainModule(moduleUrl, symlinkFile), true);
  } finally {
    try { fs.unlinkSync(symlinkFile); } catch {}
    try { fs.unlinkSync(realFile); } catch {}
    try { fs.rmdirSync(tempDir); } catch {}
  }
});

test("parseArgs accepts registration token", () => {
  const parsed = parseArgs(["--registration-token", "token-123"]);
  assert.equal(parsed.registrationToken, "token-123");
});

test("parseArgs rejects unknown arguments", () => {
  assert.throws(() => parseArgs(["--wat"]), /unknown argument/);
});

test("parseArgs rejects legacy auth-code argument", () => {
  assert.throws(() => parseArgs(["--auth-code", "legacy"]), /unknown argument/);
});

test("validation helpers normalize and enforce broker/workspace formats", () => {
  assert.equal(normalizeBrokerUrl("https://broker.example.com/"), "https://broker.example.com");
  assert.equal(validateWorkspaceId("T0ABC123"), true);
  assert.equal(validateWorkspaceId("workspace-123"), false);

  assert.throws(() => normalizeBrokerUrl("ftp://broker.example.com"), /http:\/\/ or https:\/\//);
});

test("mapRegisterError returns actionable messages", () => {
  assert.match(mapRegisterError(400, "missing registration proof"), /registration token is required/);
  assert.match(mapRegisterError(403, "invalid registration token"), /invalid registration token/);
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
      assert.equal(payload.server_pubkey, FIXTURE_SERVER_KEYS.server_pubkey);
      assert.equal(payload.server_signing_pubkey, FIXTURE_SERVER_KEYS.server_signing_pubkey);
      assert.equal(payload.registration_token, "token-abc");
      assert.equal(payload.auth_code, undefined);
      assert.equal(payload.server_callback_url, undefined);

      return jsonResponse({
        ok: true,
        broker_pubkey: Buffer.alloc(32, 9).toString("base64"),
        broker_signing_pubkey: Buffer.alloc(32, 8).toString("base64"),
        broker_access_token: "tok-abc",
        broker_access_token_expires_at: "2026-02-22T22:00:00.000Z",
        broker_access_token_scopes: ["slack.send", "inbox.pull"],
      });
    }

    return jsonResponse({ ok: false, error: "unexpected endpoint" }, 404);
  };

  const result = await registerWithBroker({
    brokerUrl: "https://broker.example.com",
    workspaceId: "TTEST123",
    registrationToken: "token-abc",
    serverKeys: FIXTURE_SERVER_KEYS,
    fetchImpl,
  });

  assert.equal(calls.length, 2);
  assert.match(calls[0].url, /\/api\/broker-pubkey$/);
  assert.match(calls[1].url, /\/api\/register$/);
  assert.equal(result.broker_pubkey, Buffer.alloc(32, 9).toString("base64"));
  assert.equal(result.broker_signing_pubkey, Buffer.alloc(32, 8).toString("base64"));
  assert.equal(result.broker_access_token, "tok-abc");
  assert.equal(result.broker_access_token_expires_at, "2026-02-22T22:00:00.000Z");
  assert.deepEqual(result.broker_access_token_scopes, ["slack.send", "inbox.pull"]);
});

test("registerWithBroker sends registration_token when provided", async () => {
  const fetchImpl = async (url, init = {}) => {
    if (String(url).endsWith("/api/broker-pubkey")) {
      return jsonResponse({
        ok: true,
        broker_pubkey: Buffer.alloc(32, 9).toString("base64"),
        broker_signing_pubkey: Buffer.alloc(32, 8).toString("base64"),
      });
    }

    if (String(url).endsWith("/api/register")) {
      const payload = JSON.parse(init.body);
      assert.equal(payload.registration_token, "token-abc");
      assert.equal(payload.auth_code, undefined);
      return jsonResponse({
        ok: true,
        broker_pubkey: Buffer.alloc(32, 9).toString("base64"),
        broker_signing_pubkey: Buffer.alloc(32, 8).toString("base64"),
      });
    }

    return jsonResponse({ ok: false, error: "unexpected endpoint" }, 404);
  };

  await registerWithBroker({
    brokerUrl: "https://broker.example.com",
    workspaceId: "TTEST123",
    registrationToken: "token-abc",
    serverKeys: FIXTURE_SERVER_KEYS,
    fetchImpl,
  });
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
      res.end(JSON.stringify({
        ok: true,
        broker_pubkey: brokerPubkey,
        broker_signing_pubkey: brokerSigningPubkey,
        broker_access_token: "tok-live",
        broker_access_token_expires_at: "2026-02-22T22:00:00.000Z",
        broker_access_token_scopes: ["slack.send"],
      }));
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
      registrationToken: "token-from-dashboard",
    });

    assert.ok(receivedRegisterPayload);
    assert.equal(receivedRegisterPayload.workspace_id, "TABC12345");
    assert.equal(receivedRegisterPayload.registration_token, "token-from-dashboard");
    assert.equal(receivedRegisterPayload.server_callback_url, undefined);
    assert.ok(result.updates.SLACK_BROKER_SERVER_PRIVATE_KEY);
    assert.ok(result.updates.SLACK_BROKER_SERVER_SIGNING_PRIVATE_KEY);
    assert.equal(result.updates.SLACK_BROKER_PUBLIC_KEY, brokerPubkey);
    assert.equal(result.updates.SLACK_BROKER_SIGNING_PUBLIC_KEY, brokerSigningPubkey);
    assert.equal(result.updates.SLACK_BROKER_ACCESS_TOKEN, "tok-live");
    assert.equal(result.updates.SLACK_BROKER_ACCESS_TOKEN_EXPIRES_AT, "2026-02-22T22:00:00.000Z");
    assert.equal(result.updates.SLACK_BROKER_ACCESS_TOKEN_SCOPES, "slack.send");
  } finally {
    await new Promise((resolve, reject) => server.close((err) => (err ? reject(err) : resolve())));
  }
});

test("runRegistration requires registration token", async () => {
  await assert.rejects(
    runRegistration({
      brokerUrl: "https://broker.example.com",
      workspaceId: "TABC12345",
    }),
    /registration token is required/,
  );
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
