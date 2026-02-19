/**
 * Slack OAuth install flow.
 *
 * Two endpoints:
 *   1. GET /slack/oauth/install — redirect user to Slack's authorization page
 *   2. GET /slack/oauth/callback — handle the OAuth callback, store bot token
 *
 * After OAuth completes, the workspace is in "pending" status until a
 * baudbot server registers via the /api/register endpoint.
 *
 * The auth_code is generated during OAuth and must be presented during
 * server registration to prove workspace ownership.
 */

import { createPendingWorkspace, hashAuthCode } from "../routing/registry.js";
import type { Env } from "../index.js";

/** Required OAuth scopes for the Prime app. */
const BOT_SCOPES = [
  "app_mentions:read",
  "channels:history",
  "chat:write",
  "groups:history",
  "im:history",
  "reactions:write",
  "users:read",
].join(",");

/**
 * Generate a cryptographically random string for OAuth state and auth codes.
 */
function generateRandomString(length: number): string {
  const bytes = crypto.getRandomValues(new Uint8Array(length));
  return Array.from(bytes)
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

/**
 * Redirect to Slack's OAuth authorization page.
 */
export async function handleOAuthInstall(
  request: Request,
  env: Env,
): Promise<Response> {
  const state = generateRandomString(32);

  // Store state with 10-minute expiry
  await env.OAUTH_STATE.put(`oauth_state:${state}`, "valid", {
    expirationTtl: 600,
  });

  const url = new URL("https://slack.com/oauth/v2/authorize");
  url.searchParams.set("client_id", env.SLACK_CLIENT_ID);
  url.searchParams.set("scope", BOT_SCOPES);
  url.searchParams.set("state", state);

  // Derive redirect URI from the current request's origin
  const requestUrl = new URL(request.url);
  const redirectUri = `${requestUrl.origin}/slack/oauth/callback`;
  url.searchParams.set("redirect_uri", redirectUri);

  return Response.redirect(url.toString(), 302);
}

interface SlackOAuthResponse {
  ok: boolean;
  access_token?: string;
  token_type?: string;
  team?: { id: string; name: string };
  bot_user_id?: string;
  error?: string;
}

/**
 * Handle the OAuth callback from Slack.
 *
 * Exchanges the code for a bot token, creates a pending workspace record,
 * and returns the auth_code that the user needs for server registration.
 */
export async function handleOAuthCallback(
  request: Request,
  env: Env,
): Promise<Response> {
  const url = new URL(request.url);
  const code = url.searchParams.get("code");
  const state = url.searchParams.get("state");
  const error = url.searchParams.get("error");

  // User denied access
  if (error) {
    return new Response(
      `<html><body><h1>Installation cancelled</h1><p>${escapeHtml(error)}</p></body></html>`,
      { status: 200, headers: { "Content-Type": "text/html" } },
    );
  }

  if (!code || !state) {
    return new Response("missing code or state", { status: 400 });
  }

  // Verify state parameter
  const storedState = await env.OAUTH_STATE.get(`oauth_state:${state}`);
  if (!storedState) {
    return new Response("invalid or expired state", { status: 400 });
  }
  // Delete state to prevent reuse
  await env.OAUTH_STATE.delete(`oauth_state:${state}`);

  // Exchange code for token
  const redirectUri = `${url.origin}/slack/oauth/callback`;
  const tokenResponse = await fetch("https://slack.com/api/oauth.v2.access", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      client_id: env.SLACK_CLIENT_ID,
      client_secret: env.SLACK_CLIENT_SECRET,
      code,
      redirect_uri: redirectUri,
    }),
  });

  const tokenData = (await tokenResponse.json()) as SlackOAuthResponse;

  if (!tokenData.ok || !tokenData.access_token || !tokenData.team) {
    return new Response(
      `<html><body><h1>Installation failed</h1><p>${escapeHtml(tokenData.error ?? "unknown error")}</p></body></html>`,
      { status: 200, headers: { "Content-Type": "text/html" } },
    );
  }

  // Generate auth code for server registration
  const authCode = generateRandomString(32);
  const authCodeHashed = await hashAuthCode(authCode);

  // Store workspace with pending status
  await createPendingWorkspace(
    env.WORKSPACE_ROUTING,
    tokenData.team.id,
    tokenData.team.name,
    tokenData.access_token,
    authCodeHashed,
  );

  // Return success page with auth code
  return new Response(
    `<html>
<body>
  <h1>✅ Baudbot installed in ${escapeHtml(tokenData.team.name)}</h1>
  <p>Your workspace ID: <code>${escapeHtml(tokenData.team.id)}</code></p>
  <p>Your auth code (save this — you'll need it during server setup):</p>
  <pre>${escapeHtml(authCode)}</pre>
  <p>Run <code>baudbot setup --slack-broker</code> on your server and enter this code when prompted.</p>
</body>
</html>`,
    { status: 200, headers: { "Content-Type": "text/html" } },
  );
}

/** Minimal HTML escaping. */
function escapeHtml(str: string): string {
  return str
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}
