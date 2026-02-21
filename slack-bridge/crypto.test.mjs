/**
 * Tests for crypto.mjs — canonicalization and deterministic serialization.
 *
 * Run: node --test crypto.test.mjs
 */

import { describe, it } from "node:test";
import assert from "node:assert/strict";
import {
  stableStringify,
  canonicalizeEnvelope,
  canonicalizeOutbound,
  canonicalizeSendRequest,
} from "./crypto.mjs";

const decode = (bytes) => new TextDecoder().decode(bytes);

// ── stableStringify ─────────────────────────────────────────────────────────

describe("stableStringify", () => {
  it("serializes primitives like JSON.stringify", () => {
    assert.equal(stableStringify(null), "null");
    assert.equal(stableStringify(true), "true");
    assert.equal(stableStringify(false), "false");
    assert.equal(stableStringify(42), "42");
    assert.equal(stableStringify(3.14), "3.14");
    assert.equal(stableStringify("hello"), '"hello"');
    assert.equal(stableStringify(""), '""');
  });

  it("sorts object keys alphabetically", () => {
    assert.equal(stableStringify({ z: 1, a: 2, m: 3 }), '{"a":2,"m":3,"z":1}');
  });

  it("sorts nested object keys recursively", () => {
    const obj = { b: { z: 1, a: 2 }, a: { y: 3, x: 4 } };
    assert.equal(stableStringify(obj), '{"a":{"x":4,"y":3},"b":{"a":2,"z":1}}');
  });

  it("preserves array order", () => {
    assert.equal(stableStringify([3, 1, 2]), "[3,1,2]");
  });

  it("handles arrays of objects with sorted keys", () => {
    assert.equal(stableStringify([{ b: 1, a: 2 }]), '[{"a":2,"b":1}]');
  });

  it("handles empty objects and arrays", () => {
    assert.equal(stableStringify({}), "{}");
    assert.equal(stableStringify([]), "[]");
  });

  it("handles deeply nested structures", () => {
    const obj = { c: { b: { a: 1 } } };
    assert.equal(stableStringify(obj), '{"c":{"b":{"a":1}}}');
  });

  it("omits undefined object values (matches JSON.stringify)", () => {
    assert.equal(stableStringify({ a: 1, b: undefined, c: "hi" }), '{"a":1,"c":"hi"}');
    assert.equal(
      stableStringify({ a: 1, b: undefined, c: "hi" }),
      JSON.stringify({ a: 1, c: "hi" }),
    );
  });

  it("converts undefined array elements to null (matches JSON.stringify)", () => {
    assert.equal(stableStringify([1, undefined, 3]), "[1,null,3]");
    assert.equal(
      stableStringify([1, undefined, 3]),
      JSON.stringify([1, undefined, 3]),
    );
  });

  it("handles mixed nested undefined values", () => {
    const obj = { a: [1, undefined], b: { c: undefined, d: 2 } };
    assert.equal(stableStringify(obj), '{"a":[1,null],"b":{"d":2}}');
  });

  it("returns undefined for top-level undefined (matches JSON.stringify)", () => {
    assert.equal(stableStringify(undefined), undefined);
    assert.equal(stableStringify(undefined), JSON.stringify(undefined));
  });

  it("handles strings with special characters", () => {
    assert.equal(stableStringify({ a: 'he said "hi"' }), '{"a":"he said \\"hi\\""}');
    assert.equal(stableStringify({ a: "line\nnewline" }), '{"a":"line\\nnewline"}');
  });

  it("produces identical output regardless of insertion order", () => {
    const a = { workspace_id: "T123", action: "chat.postMessage", timestamp: 1000 };
    const b = { timestamp: 1000, action: "chat.postMessage", workspace_id: "T123" };
    assert.equal(stableStringify(a), stableStringify(b));
  });

  it("matches expected canonical form for send request shape", () => {
    const obj = {
      workspace_id: "T09192W1Z34",
      action: "chat.postMessage",
      timestamp: 1234567890,
      encrypted_body: "abc123==",
      nonce: "xyz789==",
      routing: {
        channel: "C0A2G6TSDL6",
        thread_ts: "1771464783.614839",
        timestamp: "",
        emoji: "",
      },
    };
    const result = stableStringify(obj);
    // Keys must be sorted at every level
    assert.ok(result.indexOf('"action"') < result.indexOf('"encrypted_body"'));
    assert.ok(result.indexOf('"encrypted_body"') < result.indexOf('"nonce"'));
    assert.ok(result.indexOf('"nonce"') < result.indexOf('"routing"'));
    assert.ok(result.indexOf('"routing"') < result.indexOf('"timestamp"'));
    assert.ok(result.indexOf('"timestamp"') < result.indexOf('"workspace_id"'));
    // Nested routing keys sorted
    assert.ok(result.indexOf('"channel"') < result.indexOf('"emoji"'));
  });
});

// ── canonicalizeEnvelope ────────────────────────────────────────────────────

describe("canonicalizeEnvelope", () => {
  it("produces pipe-delimited format", () => {
    const result = decode(canonicalizeEnvelope("T123", 1700000000, "encryptedBase64=="));
    assert.equal(result, "T123|1700000000|encryptedBase64==");
  });

  it("returns Uint8Array", () => {
    const result = canonicalizeEnvelope("T123", 1700000000, "enc");
    assert.ok(result instanceof Uint8Array);
  });
});

// ── canonicalizeOutbound ────────────────────────────────────────────────────

describe("canonicalizeOutbound", () => {
  it("produces pipe-delimited format with action", () => {
    const result = decode(canonicalizeOutbound("T123", "inbox.pull", 1700000000, "10"));
    assert.equal(result, "T123|inbox.pull|1700000000|10");
  });

  it("works for inbox.ack with comma-separated IDs", () => {
    const result = decode(canonicalizeOutbound("T123", "inbox.ack", 1700000000, "id1,id2,id3"));
    assert.equal(result, "T123|inbox.ack|1700000000|id1,id2,id3");
  });

  it("returns Uint8Array", () => {
    const result = canonicalizeOutbound("T123", "inbox.pull", 1700000000, "10");
    assert.ok(result instanceof Uint8Array);
  });
});

// ── canonicalizeSendRequest ─────────────────────────────────────────────────

describe("canonicalizeSendRequest", () => {
  const ws = "T09192W1Z34";
  const action = "chat.postMessage";
  const ts = 1234567890;
  const encBody = "ciphertext_base64==";
  const nonce = "nonce_base64==";

  it("returns Uint8Array", () => {
    const routing = { channel: "C123" };
    const result = canonicalizeSendRequest(ws, action, ts, encBody, nonce, routing);
    assert.ok(result instanceof Uint8Array);
  });

  it("produces valid JSON when decoded", () => {
    const routing = { channel: "C123", thread_ts: "1234.5678" };
    const result = decode(canonicalizeSendRequest(ws, action, ts, encBody, nonce, routing));
    const parsed = JSON.parse(result);
    assert.equal(parsed.workspace_id, ws);
    assert.equal(parsed.action, action);
    assert.equal(parsed.timestamp, ts);
    assert.equal(parsed.encrypted_body, encBody);
    assert.equal(parsed.nonce, nonce);
    assert.equal(parsed.routing.channel, "C123");
    assert.equal(parsed.routing.thread_ts, "1234.5678");
  });

  it("defaults missing routing fields to empty string", () => {
    const routing = { channel: "C123" };
    const result = decode(canonicalizeSendRequest(ws, action, ts, encBody, nonce, routing));
    const parsed = JSON.parse(result);
    assert.equal(parsed.routing.thread_ts, "");
    assert.equal(parsed.routing.timestamp, "");
    assert.equal(parsed.routing.emoji, "");
  });

  it("preserves provided routing fields", () => {
    const routing = {
      channel: "C123",
      thread_ts: "1234.5678",
      timestamp: "1234.5678",
      emoji: "white_check_mark",
    };
    const result = decode(canonicalizeSendRequest(ws, action, ts, encBody, nonce, routing));
    const parsed = JSON.parse(result);
    assert.equal(parsed.routing.thread_ts, "1234.5678");
    assert.equal(parsed.routing.timestamp, "1234.5678");
    assert.equal(parsed.routing.emoji, "white_check_mark");
  });

  it("produces deterministic output regardless of routing key order", () => {
    const r1 = { channel: "C1", emoji: "x", thread_ts: "t", timestamp: "s" };
    const r2 = { timestamp: "s", channel: "C1", thread_ts: "t", emoji: "x" };
    const a = decode(canonicalizeSendRequest(ws, action, ts, encBody, nonce, r1));
    const b = decode(canonicalizeSendRequest(ws, action, ts, encBody, nonce, r2));
    assert.equal(a, b);
  });

  it("has keys sorted alphabetically in output", () => {
    const routing = { channel: "C123" };
    const result = decode(canonicalizeSendRequest(ws, action, ts, encBody, nonce, routing));
    // Top-level keys should be: action, encrypted_body, nonce, routing, timestamp, workspace_id
    const parsed = JSON.parse(result);
    const keys = Object.keys(parsed);
    assert.deepEqual(keys, ["action", "encrypted_body", "nonce", "routing", "timestamp", "workspace_id"]);
    // Routing keys should be: channel, emoji, thread_ts, timestamp
    const routingKeys = Object.keys(parsed.routing);
    assert.deepEqual(routingKeys, ["channel", "emoji", "thread_ts", "timestamp"]);
  });

  it("produces different output for different routing values", () => {
    const r1 = { channel: "C123", thread_ts: "111.222" };
    const r2 = { channel: "C123", thread_ts: "333.444" };
    const a = canonicalizeSendRequest(ws, action, ts, encBody, nonce, r1);
    const b = canonicalizeSendRequest(ws, action, ts, encBody, nonce, r2);
    assert.notDeepEqual(a, b);
  });

  it("produces different output for different nonces", () => {
    const routing = { channel: "C123" };
    const a = canonicalizeSendRequest(ws, action, ts, encBody, "nonce1", routing);
    const b = canonicalizeSendRequest(ws, action, ts, encBody, "nonce2", routing);
    assert.notDeepEqual(a, b);
  });

  it("matches broker format for reactions.add", () => {
    const routing = { channel: "C123", timestamp: "1234.5678", emoji: "thumbsup" };
    const result = decode(canonicalizeSendRequest(ws, "reactions.add", ts, encBody, nonce, routing));
    const parsed = JSON.parse(result);
    assert.equal(parsed.action, "reactions.add");
    assert.equal(parsed.routing.emoji, "thumbsup");
    assert.equal(parsed.routing.timestamp, "1234.5678");
  });
});
