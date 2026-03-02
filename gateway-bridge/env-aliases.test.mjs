import test from "node:test";
import assert from "node:assert/strict";
import { applyGatewayEnvAliases, resolveGatewayEnvAliases } from "./env-aliases.mjs";

test("falls back to legacy SLACK_* var and emits deprecation warning", () => {
  const env = {
    SLACK_BOT_TOKEN: "xoxb-legacy-token",
  };

  const result = resolveGatewayEnvAliases(env);

  assert.equal(result.resolved.SLACK_BOT_TOKEN, "xoxb-legacy-token");
  assert.equal(result.warnings.length, 1);
  assert.match(result.warnings[0], /Using legacy SLACK_\* env vars/);
  assert.match(result.warnings[0], /SLACK_BOT_TOKEN→GATEWAY_BOT_TOKEN/);
});

test("prefers GATEWAY_* when both gateway and legacy vars are set", () => {
  const env = {
    GATEWAY_BOT_TOKEN: "xoxb-gateway-token",
    SLACK_BOT_TOKEN: "xoxb-legacy-token",
  };

  const result = resolveGatewayEnvAliases(env);

  assert.equal(result.resolved.SLACK_BOT_TOKEN, "xoxb-gateway-token");
  assert.equal(result.warnings.length, 1);
  assert.match(result.warnings[0], /Both GATEWAY_BOT_TOKEN and SLACK_BOT_TOKEN are set/);
  assert.match(result.warnings[0], /using GATEWAY_BOT_TOKEN/);
});

test("does not emit conflict warning when both aliases are set to the same value", () => {
  const env = {
    GATEWAY_ALLOWED_USERS: "U1,U2",
    SLACK_ALLOWED_USERS: "U1,U2",
  };

  const result = resolveGatewayEnvAliases(env);

  assert.equal(result.resolved.SLACK_ALLOWED_USERS, "U1,U2");
  assert.equal(result.warnings.length, 0);
});

test("empty gateway value falls back to legacy slack value", () => {
  const env = {
    GATEWAY_CHANNEL_ID: "",
    SLACK_CHANNEL_ID: "C123",
  };

  const result = resolveGatewayEnvAliases(env);

  assert.equal(result.resolved.SLACK_CHANNEL_ID, "C123");
  assert.equal(result.warnings.length, 1);
  assert.match(result.warnings[0], /SLACK_CHANNEL_ID→GATEWAY_CHANNEL_ID/);
});

test("applyGatewayEnvAliases mutates env with resolved canonical legacy keys", () => {
  const env = {
    GATEWAY_BROKER_URL: "https://broker.gateway.example",
  };

  const result = applyGatewayEnvAliases(env);

  assert.equal(env.SLACK_BROKER_URL, "https://broker.gateway.example");
  assert.equal(result.warnings.length, 0);
});

test("maps GATEWAY_BROKER_ORG_ID to SLACK_BROKER_ORG_ID and legacy workspace key", () => {
  const env = {
    GATEWAY_BROKER_ORG_ID: "org_abc123",
  };

  const result = applyGatewayEnvAliases(env);

  assert.equal(env.SLACK_BROKER_ORG_ID, "org_abc123");
  assert.equal(env.SLACK_BROKER_WORKSPACE_ID, "org_abc123");
  assert.equal(result.warnings.length, 0);
});

test("falls back from deprecated workspace id when org id is absent", () => {
  const env = {
    SLACK_BROKER_WORKSPACE_ID: "T123LEGACY",
  };

  const result = resolveGatewayEnvAliases(env);

  assert.equal(result.resolved.SLACK_BROKER_ORG_ID, "T123LEGACY");
  assert.equal(result.resolved.SLACK_BROKER_WORKSPACE_ID, "T123LEGACY");
  assert.ok(result.warnings.some((warning) => warning.includes("SLACK_BROKER_WORKSPACE_ID is deprecated")));
});

test("prefers org id over workspace id when both are set", () => {
  const env = {
    GATEWAY_BROKER_ORG_ID: "org_preferred",
    GATEWAY_BROKER_WORKSPACE_ID: "Tlegacy_should_not_win",
  };

  const result = resolveGatewayEnvAliases(env);

  assert.equal(result.resolved.SLACK_BROKER_ORG_ID, "org_preferred");
  assert.equal(result.resolved.SLACK_BROKER_WORKSPACE_ID, "org_preferred");
  assert.ok(result.warnings.some((warning) => warning.includes("using GATEWAY_BROKER_ORG_ID")));
});
