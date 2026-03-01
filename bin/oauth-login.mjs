#!/usr/bin/env node
/**
 * OAuth subscription login for baudbot.
 *
 * Authenticates with an LLM provider using OAuth (subscription-based access)
 * and writes credentials to pi's auth.json format.
 *
 * Supported providers:
 *   - openai-codex    ChatGPT Plus/Pro (Codex Subscription)
 *   - anthropic       Anthropic (Claude Pro/Max)
 *
 * Usage:
 *   node oauth-login.mjs --provider openai-codex --auth-path /path/to/auth.json
 *   node oauth-login.mjs                          # interactive provider picker
 *
 * Exit codes:
 *   0  Login successful
 *   1  Login failed or cancelled
 *
 * On success, prints the provider ID to stdout (e.g. "openai-codex").
 * All prompts and status messages go to stderr so stdout stays clean for callers.
 */

import { createInterface } from "node:readline";
import { webcrypto } from "node:crypto";
import { randomBytes } from "node:crypto";
import http from "node:http";
import fs from "node:fs";
import path from "node:path";

const { subtle } = webcrypto;

// ── Provider definitions ────────────────────────────────────────────────────

const PROVIDERS = {
  "openai-codex": {
    id: "openai-codex",
    name: "ChatGPT Plus/Pro (Codex Subscription)",
    authorizeUrl: "https://auth.openai.com/oauth/authorize",
    tokenUrl: "https://auth.openai.com/oauth/token",
    clientId: "app_EMoamEEZ73f0CkXaXp7hrann",
    redirectUri: "http://localhost:1455/auth/callback",
    scope: "openid profile email offline_access",
    usesCallbackServer: true,
  },
  anthropic: {
    id: "anthropic",
    name: "Anthropic (Claude Pro/Max)",
    authorizeUrl: "https://claude.ai/oauth/authorize",
    tokenUrl: "https://console.anthropic.com/v1/oauth/token",
    clientId: atob("OWQxYzI1MGEtZTYxYi00NGQ5LTg4ZWQtNTk0NGQxOTYyZjVl"),
    redirectUri: "https://console.anthropic.com/oauth/code/callback",
    scope: "org:create_api_key user:profile user:inference",
    usesCallbackServer: false,
  },
};

// ── PKCE ────────────────────────────────────────────────────────────────────

function base64urlEncode(bytes) {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=/g, "");
}

async function generatePKCE() {
  const verifierBytes = new Uint8Array(32);
  webcrypto.getRandomValues(verifierBytes);
  const verifier = base64urlEncode(verifierBytes);
  const data = new TextEncoder().encode(verifier);
  const hashBuffer = await subtle.digest("SHA-256", data);
  const challenge = base64urlEncode(new Uint8Array(hashBuffer));
  return { verifier, challenge };
}

// ── Readline helpers ────────────────────────────────────────────────────────

function createRL() {
  return createInterface({ input: process.stdin, output: process.stderr });
}

function ask(rl, question) {
  return new Promise((resolve) => rl.question(question, resolve));
}

function info(msg) {
  process.stderr.write(`${msg}\n`);
}

// ── OAuth: OpenAI Codex ─────────────────────────────────────────────────────

function decodeJwt(token) {
  try {
    const parts = token.split(".");
    if (parts.length !== 3) return null;
    return JSON.parse(atob(parts[1]));
  } catch {
    return null;
  }
}

function parseAuthorizationInput(input) {
  const value = input.trim();
  if (!value) return {};
  try {
    const url = new URL(value);
    return {
      code: url.searchParams.get("code") ?? undefined,
      state: url.searchParams.get("state") ?? undefined,
    };
  } catch { /* not a URL */ }
  if (value.includes("#")) {
    const [code, state] = value.split("#", 2);
    return { code, state };
  }
  if (value.includes("code=")) {
    const params = new URLSearchParams(value);
    return {
      code: params.get("code") ?? undefined,
      state: params.get("state") ?? undefined,
    };
  }
  return { code: value };
}

function startLocalCallbackServer(expectedState) {
  let lastCode = null;
  let cancelled = false;

  const server = http.createServer((req, res) => {
    try {
      const url = new URL(req.url || "", "http://localhost");
      if (url.pathname !== "/auth/callback") {
        res.statusCode = 404;
        res.end("Not found");
        return;
      }
      if (url.searchParams.get("state") !== expectedState) {
        res.statusCode = 400;
        res.end("State mismatch");
        return;
      }
      const code = url.searchParams.get("code");
      if (!code) {
        res.statusCode = 400;
        res.end("Missing authorization code");
        return;
      }
      res.statusCode = 200;
      res.setHeader("Content-Type", "text/html; charset=utf-8");
      res.end("<p>Authentication successful. Return to your terminal to continue.</p>");
      lastCode = code;
    } catch {
      res.statusCode = 500;
      res.end("Internal error");
    }
  });

  return new Promise((resolve) => {
    server
      .listen(1455, "127.0.0.1", () => {
        resolve({
          close: () => server.close(),
          cancel: () => { cancelled = true; },
          waitForCode: async () => {
            for (let i = 0; i < 600; i++) {
              if (lastCode) return lastCode;
              if (cancelled) return null;
              await new Promise((r) => setTimeout(r, 100));
            }
            return null;
          },
        });
      })
      .on("error", () => {
        resolve({
          close: () => { try { server.close(); } catch { /* ignore */ } },
          cancel: () => {},
          waitForCode: async () => null,
        });
      });
  });
}

async function loginOpenAICodex(rl) {
  const provider = PROVIDERS["openai-codex"];
  const { verifier, challenge } = await generatePKCE();
  const state = randomBytes(16).toString("hex");

  const url = new URL(provider.authorizeUrl);
  url.searchParams.set("response_type", "code");
  url.searchParams.set("client_id", provider.clientId);
  url.searchParams.set("redirect_uri", provider.redirectUri);
  url.searchParams.set("scope", provider.scope);
  url.searchParams.set("code_challenge", challenge);
  url.searchParams.set("code_challenge_method", "S256");
  url.searchParams.set("state", state);
  url.searchParams.set("id_token_add_organizations", "true");
  url.searchParams.set("codex_cli_simplified_flow", "true");
  url.searchParams.set("originator", "baudbot");

  const server = await startLocalCallbackServer(state);

  info("");
  info("  Open this URL in your browser to authenticate:");
  info(`  ${url.toString()}`);
  info("");
  info("  If your browser can reach this machine on port 1455, login will");
  info("  complete automatically. Otherwise, paste the redirect URL below.");
  info("");

  // Race: callback server vs manual paste
  let code;
  const manualPromise = ask(rl, "  Paste redirect URL (or press Enter to wait for browser): ");

  const serverCode = await Promise.race([
    server.waitForCode(),
    manualPromise.then((input) => {
      if (input.trim()) {
        server.cancel();
        return "manual:" + input;
      }
      return null;
    }),
  ]);

  if (typeof serverCode === "string" && serverCode.startsWith("manual:")) {
    const parsed = parseAuthorizationInput(serverCode.slice(7));
    if (parsed.state && parsed.state !== state) throw new Error("State mismatch");
    code = parsed.code;
  } else if (serverCode) {
    code = serverCode;
  }

  if (!code) {
    // Wait for the remaining promise
    const remaining = await (typeof serverCode === "string" ? server.waitForCode() : manualPromise);
    if (typeof remaining === "string" && remaining.trim()) {
      const parsed = parseAuthorizationInput(remaining);
      if (parsed.state && parsed.state !== state) throw new Error("State mismatch");
      code = parsed.code;
    } else if (remaining) {
      code = remaining;
    }
  }

  if (!code) {
    // Final fallback prompt
    const input = await ask(rl, "  Paste the authorization code (or full redirect URL): ");
    const parsed = parseAuthorizationInput(input);
    if (parsed.state && parsed.state !== state) throw new Error("State mismatch");
    code = parsed.code;
  }

  server.close();

  if (!code) throw new Error("No authorization code received");

  // Exchange code for tokens
  const tokenResp = await fetch(provider.tokenUrl, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "authorization_code",
      client_id: provider.clientId,
      code,
      code_verifier: verifier,
      redirect_uri: provider.redirectUri,
    }),
  });

  if (!tokenResp.ok) {
    const text = await tokenResp.text().catch(() => "");
    throw new Error(`Token exchange failed: ${tokenResp.status} ${text}`);
  }

  const tokens = await tokenResp.json();
  if (!tokens.access_token || !tokens.refresh_token || typeof tokens.expires_in !== "number") {
    throw new Error("Token response missing required fields");
  }

  const payload = decodeJwt(tokens.access_token);
  const auth = payload?.["https://api.openai.com/auth"];
  const accountId = auth?.chatgpt_account_id;
  if (!accountId) throw new Error("Failed to extract accountId from token");

  return {
    access: tokens.access_token,
    refresh: tokens.refresh_token,
    expires: Date.now() + tokens.expires_in * 1000,
    accountId,
  };
}

// ── OAuth: Anthropic ────────────────────────────────────────────────────────

async function loginAnthropic(rl) {
  const provider = PROVIDERS.anthropic;
  const { verifier, challenge } = await generatePKCE();

  const url = new URL(provider.authorizeUrl);
  url.searchParams.set("code", "true");
  url.searchParams.set("client_id", provider.clientId);
  url.searchParams.set("response_type", "code");
  url.searchParams.set("redirect_uri", provider.redirectUri);
  url.searchParams.set("scope", provider.scope);
  url.searchParams.set("code_challenge", challenge);
  url.searchParams.set("code_challenge_method", "S256");
  url.searchParams.set("state", verifier);

  info("");
  info("  Open this URL in your browser to authenticate:");
  info(`  ${url.toString()}`);
  info("");
  info("  After logging in, you'll see an authorization code.");
  info("  Copy it and paste it below (format: code#state).");
  info("");

  const input = await ask(rl, "  Paste the authorization code: ");
  if (!input.trim()) throw new Error("No authorization code provided");

  const splits = input.trim().split("#");
  const code = splits[0];
  const state = splits[1];

  // Exchange code for tokens
  const tokenResp = await fetch(provider.tokenUrl, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      grant_type: "authorization_code",
      client_id: provider.clientId,
      code,
      state,
      redirect_uri: provider.redirectUri,
      code_verifier: verifier,
    }),
  });

  if (!tokenResp.ok) {
    const text = await tokenResp.text().catch(() => "");
    throw new Error(`Token exchange failed: ${tokenResp.status} ${text}`);
  }

  const tokens = await tokenResp.json();
  if (!tokens.access_token || !tokens.refresh_token || typeof tokens.expires_in !== "number") {
    throw new Error("Token response missing required fields");
  }

  return {
    access: tokens.access_token,
    refresh: tokens.refresh_token,
    expires: Date.now() + tokens.expires_in * 1000 - 5 * 60 * 1000,
  };
}

// ── Auth storage ────────────────────────────────────────────────────────────

function readAuthJson(authPath) {
  try {
    if (fs.existsSync(authPath)) {
      return JSON.parse(fs.readFileSync(authPath, "utf-8"));
    }
  } catch { /* ignore */ }
  return {};
}

function writeAuthJson(authPath, data) {
  const dir = path.dirname(authPath);
  if (!fs.existsSync(dir)) {
    fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
  }
  fs.writeFileSync(authPath, JSON.stringify(data, null, 2), "utf-8");
  fs.chmodSync(authPath, 0o600);
}

// ── Main ────────────────────────────────────────────────────────────────────

async function main() {
  const args = process.argv.slice(2);
  let providerId = null;
  let authPath = path.join(
    process.env.HOME || "/home/baudbot_agent",
    ".pi/agent/auth.json",
  );

  for (let i = 0; i < args.length; i++) {
    if (args[i] === "--provider" && args[i + 1]) {
      providerId = args[++i];
    } else if (args[i] === "--auth-path" && args[i + 1]) {
      authPath = args[++i];
    } else if (args[i] === "--help" || args[i] === "-h") {
      info("Usage: oauth-login.mjs [--provider openai-codex|anthropic] [--auth-path <path>]");
      info("");
      info("Providers:");
      for (const p of Object.values(PROVIDERS)) {
        info(`  ${p.id.padEnd(16)} ${p.name}`);
      }
      process.exit(0);
    }
  }

  const rl = createRL();

  try {
    // Provider selection
    if (!providerId) {
      info("");
      info("Choose subscription provider:");
      const providerList = Object.values(PROVIDERS);
      providerList.forEach((p, i) => info(`  ${i + 1}) ${p.name}`));
      info("");
      const choice = await ask(rl, "Enter choice [1-" + providerList.length + "]: ");
      const idx = parseInt(choice, 10) - 1;
      if (idx < 0 || idx >= providerList.length) {
        throw new Error("Invalid choice");
      }
      providerId = providerList[idx].id;
    }

    if (!PROVIDERS[providerId]) {
      throw new Error(`Unknown provider: ${providerId}. Supported: ${Object.keys(PROVIDERS).join(", ")}`);
    }

    info(`\n  Logging in with ${PROVIDERS[providerId].name}...`);

    // Run the login flow
    let credentials;
    if (providerId === "openai-codex") {
      credentials = await loginOpenAICodex(rl);
    } else if (providerId === "anthropic") {
      credentials = await loginAnthropic(rl);
    } else {
      throw new Error(`Login not implemented for ${providerId}`);
    }

    // Merge into existing auth.json
    const existing = readAuthJson(authPath);
    existing[providerId] = { type: "oauth", ...credentials };
    writeAuthJson(authPath, existing);

    info(`\n  ✓ Logged in with ${PROVIDERS[providerId].name}`);
    info(`  Credentials saved to ${authPath}`);

    // Print provider ID to stdout for callers
    process.stdout.write(providerId + "\n");
  } finally {
    rl.close();
  }
}

main().catch((err) => {
  info(`\n  ✗ Login failed: ${err.message}`);
  process.exit(1);
});
