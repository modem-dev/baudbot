/**
 * Gateway bridge environment alias helpers.
 *
 * Migration rule:
 *   - Prefer GATEWAY_* variables when present.
 *   - Fall back to legacy SLACK_* variables.
 *   - Emit non-breaking deprecation warnings when legacy vars are used.
 */

export const GATEWAY_ENV_ALIAS_PAIRS = [
  ["GATEWAY_BOT_TOKEN", "SLACK_BOT_TOKEN"],
  ["GATEWAY_APP_TOKEN", "SLACK_APP_TOKEN"],
  ["GATEWAY_ALLOWED_USERS", "SLACK_ALLOWED_USERS"],
  ["GATEWAY_CHANNEL_ID", "SLACK_CHANNEL_ID"],
  ["GATEWAY_BROKER_URL", "SLACK_BROKER_URL"],
  ["GATEWAY_BROKER_ORG_ID", "SLACK_BROKER_ORG_ID"],
  ["GATEWAY_BROKER_WORKSPACE_ID", "SLACK_BROKER_WORKSPACE_ID"],
  ["GATEWAY_BROKER_SERVER_PRIVATE_KEY", "SLACK_BROKER_SERVER_PRIVATE_KEY"],
  ["GATEWAY_BROKER_SERVER_PUBLIC_KEY", "SLACK_BROKER_SERVER_PUBLIC_KEY"],
  ["GATEWAY_BROKER_SERVER_SIGNING_PRIVATE_KEY", "SLACK_BROKER_SERVER_SIGNING_PRIVATE_KEY"],
  ["GATEWAY_BROKER_SERVER_SIGNING_PUBLIC_KEY", "SLACK_BROKER_SERVER_SIGNING_PUBLIC_KEY"],
  ["GATEWAY_BROKER_PUBLIC_KEY", "SLACK_BROKER_PUBLIC_KEY"],
  ["GATEWAY_BROKER_SIGNING_PUBLIC_KEY", "SLACK_BROKER_SIGNING_PUBLIC_KEY"],
  ["GATEWAY_BROKER_ACCESS_TOKEN", "SLACK_BROKER_ACCESS_TOKEN"],
  ["GATEWAY_BROKER_ACCESS_TOKEN_EXPIRES_AT", "SLACK_BROKER_ACCESS_TOKEN_EXPIRES_AT"],
  ["GATEWAY_BROKER_ACCESS_TOKEN_SCOPES", "SLACK_BROKER_ACCESS_TOKEN_SCOPES"],
  ["GATEWAY_BROKER_POLL_INTERVAL_MS", "SLACK_BROKER_POLL_INTERVAL_MS"],
  ["GATEWAY_BROKER_MAX_MESSAGES", "SLACK_BROKER_MAX_MESSAGES"],
  ["GATEWAY_BROKER_WAIT_SECONDS", "SLACK_BROKER_WAIT_SECONDS"],
  ["GATEWAY_BROKER_DEDUPE_TTL_MS", "SLACK_BROKER_DEDUPE_TTL_MS"],
];

function hasConfiguredValue(value) {
  return value !== undefined && value !== null && value !== "";
}

export function resolveGatewayEnvAliases(env = process.env) {
  const resolved = {};
  const warnings = [];
  const legacyFallbackKeys = [];

  for (const [gatewayKey, legacySlackKey] of GATEWAY_ENV_ALIAS_PAIRS) {
    const gatewayValue = env[gatewayKey];
    const legacySlackValue = env[legacySlackKey];
    const hasGateway = hasConfiguredValue(gatewayValue);
    const hasLegacySlack = hasConfiguredValue(legacySlackValue);

    if (hasGateway) {
      resolved[legacySlackKey] = String(gatewayValue);
      if (hasLegacySlack && String(gatewayValue) !== String(legacySlackValue)) {
        warnings.push(
          `⚠️  Both ${gatewayKey} and ${legacySlackKey} are set; using ${gatewayKey} and ignoring ${legacySlackKey}.`,
        );
      }
      continue;
    }

    if (hasLegacySlack) {
      resolved[legacySlackKey] = String(legacySlackValue);
      legacyFallbackKeys.push(`${legacySlackKey}→${gatewayKey}`);
    }
  }

  if (legacyFallbackKeys.length > 0) {
    warnings.push(
      `⚠️  Using legacy SLACK_* env vars (${legacyFallbackKeys.join(", ")}); set GATEWAY_* aliases instead (legacy fallback still supported).`,
    );
  }

  const gatewayOrgId = env.GATEWAY_BROKER_ORG_ID;
  const slackOrgId = env.SLACK_BROKER_ORG_ID;
  const gatewayWorkspaceId = env.GATEWAY_BROKER_WORKSPACE_ID;
  const slackWorkspaceId = env.SLACK_BROKER_WORKSPACE_ID;

  const hasGatewayOrgId = hasConfiguredValue(gatewayOrgId);
  const hasSlackOrgId = hasConfiguredValue(slackOrgId);
  const hasGatewayWorkspaceId = hasConfiguredValue(gatewayWorkspaceId);
  const hasSlackWorkspaceId = hasConfiguredValue(slackWorkspaceId);

  if (hasGatewayOrgId && hasGatewayWorkspaceId && String(gatewayOrgId) !== String(gatewayWorkspaceId)) {
    warnings.push(
      "⚠️  Both GATEWAY_BROKER_ORG_ID and GATEWAY_BROKER_WORKSPACE_ID are set; using GATEWAY_BROKER_ORG_ID.",
    );
  }
  if (hasSlackOrgId && hasSlackWorkspaceId && String(slackOrgId) !== String(slackWorkspaceId)) {
    warnings.push(
      "⚠️  Both SLACK_BROKER_ORG_ID and SLACK_BROKER_WORKSPACE_ID are set; using SLACK_BROKER_ORG_ID.",
    );
  }

  let brokerOrgId = "";
  if (hasGatewayOrgId) {
    brokerOrgId = String(gatewayOrgId);
  } else if (hasSlackOrgId) {
    brokerOrgId = String(slackOrgId);
  } else if (hasGatewayWorkspaceId) {
    brokerOrgId = String(gatewayWorkspaceId);
    warnings.push("⚠️  GATEWAY_BROKER_WORKSPACE_ID is deprecated; use GATEWAY_BROKER_ORG_ID.");
  } else if (hasSlackWorkspaceId) {
    brokerOrgId = String(slackWorkspaceId);
    warnings.push("⚠️  SLACK_BROKER_WORKSPACE_ID is deprecated; use GATEWAY_BROKER_ORG_ID/SLACK_BROKER_ORG_ID.");
  }

  if (brokerOrgId) {
    // Canonical runtime value for broker identity.
    resolved.SLACK_BROKER_ORG_ID = brokerOrgId;
    // Keep legacy workspace key populated for older runtime paths still expecting it.
    resolved.SLACK_BROKER_WORKSPACE_ID = brokerOrgId;
  }

  return { resolved, warnings };
}

export function applyGatewayEnvAliases(env = process.env) {
  const { resolved, warnings } = resolveGatewayEnvAliases(env);

  for (const [legacySlackKey, value] of Object.entries(resolved)) {
    env[legacySlackKey] = value;
  }

  return { warnings };
}
