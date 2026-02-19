# Baudbot Slack Broker — Architecture Spec

## Problem

Setting up a Slack app is hard and irritating. Every baudbot user currently needs to:
1. Create a Slack app in their workspace
2. Configure OAuth scopes, event subscriptions, socket mode
3. Generate and manage bot tokens
4. Deal with Slack's app review process (if distributing)

This is the #1 friction point for new baudbot users.

## Solution

Two modes, user's choice:

**Direct mode (existing)** — Bring your own Slack app. Full control, zero dependency on external infra. For security-conscious users who want complete ownership of their Slack integration.

**Broker mode (new)** — A shared "Prime" Baudbot Slack app + an open-source message broker on Cloudflare Workers. Users install the Prime app with one click. The broker routes messages between Slack workspaces and individual baudbot servers. All messages are end-to-end encrypted. The broker cannot read message content after the initial Slack plaintext receipt.

Both modes use the same bridge interface internally — the agent code is identical. The transport layer is swappable via config.

## Architecture Overview

```
┌─────────────────────┐
│  User's Slack        │
│  Workspace           │
│                      │
│  @baudbot do X ──────┼──► Slack Platform
└─────────────────────┘         │
                                │ Socket Mode / Events API
                                ▼
                    ┌───────────────────────┐
                    │   Cloudflare Worker    │
                    │   "Slack Broker"       │
                    │                        │
                    │  ┌──────────────────┐  │
                    │  │ Routing Table    │  │
                    │  │ (KV Store)       │  │
                    │  │                  │  │
                    │  │ workspace_id →   │  │
                    │  │   server_url     │  │
                    │  │   server_pubkey  │  │
                    │  │   workspace_token│  │
                    │  └──────────────────┘  │
                    │                        │
                    │  Encrypt → Forward     │
                    │  Receive ← Decrypt     │
                    └──────────┬────────────┘
                               │
              ┌────────────────┼────────────────┐
              │                │                │
              ▼                ▼                ▼
     ┌──────────────┐ ┌──────────────┐ ┌──────────────┐
     │ Baudbot       │ │ Baudbot       │ │ Baudbot       │
     │ Server A      │ │ Server B      │ │ Server C      │
     │ (alice)       │ │ (bob)         │ │ (carol)       │
     │               │ │               │ │               │
     │ Private Key A │ │ Private Key B │ │ Private Key C │
     └──────────────┘ └──────────────┘ └──────────────┘
```

## Encryption Design

### Key Management

**Broker keypair:**
- Broker generates an X25519 keypair on first deployment
- Public key is published and hardcoded in the baudbot client SDK
- Private key stored in Cloudflare Workers secrets (not KV — never readable via API)

**Server keypair (per baudbot installation):**
- Generated during `baudbot setup` on the user's server
- Public key registered with the broker during setup
- Private key never leaves the server — stored in `~/.config/baudbot/broker-key.pem`

### Crypto Primitives

All encryption uses **libsodium** (via `tweetnacl` or `libsodium.js`):
- **Key exchange**: X25519 (Curve25519 ECDH)
- **Symmetric encryption**: XChaCha20-Poly1305 (AEAD)
- **Pattern**: `crypto_box_seal` (anonymous sealed boxes) for one-way, `crypto_box` for authenticated encryption

### Message Flow: Inbound (Slack → Baudbot Server)

```
1. Slack sends event to broker (plaintext — unavoidable)
2. Broker looks up workspace_id → server_pubkey
3. Broker encrypts payload:
   - sealed_box = crypto_box_seal(payload, server_pubkey)
   - Only the server's private key can decrypt
4. Broker POSTs to server:
   {
     "workspace_id": "T09192W1Z34",
     "encrypted": "<base64 sealed box>",
     "nonce": "<if using crypto_box>",
     "timestamp": 1771465000,
     "signature": "<broker signs the envelope>"
   }
5. Server decrypts:
   - payload = crypto_box_seal_open(sealed_box, server_keypair)
   - Verifies broker signature on envelope
   - Processes the Slack event
```

### Message Flow: Outbound (Baudbot Server → Slack)

This is the harder direction. The broker needs to call Slack's API, so it must see the *Slack API call parameters* (channel, text, thread_ts). But we can still protect the message content.

**Option A: Structured Encryption (recommended)**

```
1. Server constructs the Slack API call
2. Server encrypts the message BODY but leaves routing metadata in cleartext:
   {
     "workspace_id": "T09192W1Z34",
     "action": "chat.postMessage",
     "routing": {
       "channel": "C0A2G6TSDL6",
       "thread_ts": "1771464783.614839"
     },
     "encrypted_body": crypto_box(
       { "text": "Here's your answer...", "blocks": [...] },
       nonce, server_privkey, broker_pubkey
     ),
     "nonce": "<nonce>",
     "timestamp": 1771465000
   }
3. Broker decrypts the body using crypto_box_open
4. Broker assembles the full Slack API call and posts it
5. Broker zeroes the plaintext from memory immediately after posting
```

The broker sees routing info (channel, thread) but only decrypts message content transiently to post to Slack. This is the minimum required — Slack needs plaintext to display messages.

**Option B: Full Proxy (simpler, less encrypted)**

Server sends the complete Slack API payload encrypted, broker decrypts everything, posts to Slack. Simpler but broker sees all content.

**Recommendation: Option A.** The structured approach lets us log/debug routing issues without ever persisting message content.

### Message Flow: Outbound (Alternative — Direct Bot Token)

A more aggressive E2E approach: during OAuth, the workspace's bot token is encrypted with the *server's* public key and stored in KV. The broker can't read it. The server gets the encrypted token during setup, decrypts it locally, and posts directly to Slack.

```
Pros: True E2E — broker never sees outbound messages
Cons: Server needs outbound HTTPS to Slack (most do), 
      token rotation is harder, broker can't help with rate limiting
```

This could be a v2 enhancement for security-conscious users.

## Registration & Setup Flow

### 1. User Installs Prime App

```
1. User visits baudbot.dev/slack/install
2. OAuth flow → user authorizes Prime app in their workspace
3. Broker stores:
   - workspace_id
   - bot_token (encrypted at rest in KV)
   - team_name (for display)
   - Status: "pending" (no server linked yet)
```

### 2. User Sets Up Baudbot Server

```
1. User runs: baudbot setup --slack-broker
2. CLI generates X25519 keypair, stores private key locally
3. CLI calls broker API:
   POST /api/register
   {
     "workspace_id": "T09192W1Z34",
     "server_pubkey": "<base64>",
     "server_callback_url": "https://my-server.example.com/broker/inbound",
     "auth_code": "<from OAuth flow or email verification>"
   }
4. Broker stores the mapping, returns its own public key
5. CLI stores broker pubkey locally
6. Broker status → "active"
```

### 3. Verification

The `auth_code` ensures only the workspace admin can link a server. Options:
- **OAuth state parameter**: Carried through from step 1
- **Email verification**: Broker sends a code to the workspace admin's email
- **Slack verification**: Broker sends a DM in the workspace with a code

## Broker API Surface

### Public Endpoints (Cloudflare Worker)

```
POST /slack/events          — Slack event webhook (or Socket Mode handler)
POST /slack/oauth/callback  — OAuth callback from Slack app install
POST /api/register          — Register a baudbot server for a workspace
POST /api/heartbeat         — Server health check (keepalive)
DELETE /api/register         — Unlink a server
GET  /api/broker-pubkey     — Get broker's public key
```

### Server-to-Broker (authenticated with server's signature)

```
POST /api/send              — Send a message to Slack (encrypted body)
POST /api/react             — Add a reaction
POST /api/update            — Update a message
```

### Broker-to-Server (authenticated with broker's signature)

```
POST {server_callback_url}  — Deliver encrypted Slack event
```

## Cloudflare Architecture

```
Cloudflare Workers
├── slack-broker-worker/
│   ├── src/
│   │   ├── index.ts              — Request router
│   │   ├── slack/
│   │   │   ├── events.ts         — Handle Slack events
│   │   │   ├── oauth.ts          — OAuth install flow
│   │   │   └── api.ts            — Post messages to Slack
│   │   ├── crypto/
│   │   │   ├── seal.ts           — Sealed box encrypt/decrypt
│   │   │   ├── box.ts            — Authenticated encryption
│   │   │   └── verify.ts         — Signature verification
│   │   ├── routing/
│   │   │   ├── registry.ts       — Workspace → server mapping
│   │   │   └── forward.ts        — Encrypt & forward to server
│   │   └── api/
│   │       ├── register.ts       — Server registration
│   │       └── send.ts           — Outbound message handling
│   ├── wrangler.toml
│   └── package.json
│
├── KV Namespaces:
│   ├── WORKSPACE_ROUTING         — workspace_id → {server_url, server_pubkey, status}
│   └── OAUTH_STATE               — Temporary OAuth state tokens
│
└── Secrets:
    ├── BROKER_PRIVATE_KEY        — X25519 private key
    ├── SLACK_CLIENT_ID           — Prime app client ID
    ├── SLACK_CLIENT_SECRET       — Prime app client secret
    └── SLACK_SIGNING_SECRET      — Slack request verification
```

## Baudbot Server Side

New module in baudbot: `src/broker/`

```
src/broker/
├── client.ts          — Broker API client (register, send, receive)
├── crypto.ts          — Encrypt/decrypt using libsodium
├── keys.ts            — Keypair generation and storage
├── server.ts          — HTTP handler for broker→server callbacks
└── setup.ts           — Interactive setup flow (baudbot setup --slack-broker)
```

The existing Slack bridge (`slack-bridge/`) gains an alternative transport:

```
┌─────────────────────────────────────────────────┐
│              Slack Bridge (unchanged API)         │
│                                                   │
│   bridge.on('message', handler)                   │
│   bridge.send(channel, text, thread_ts)           │
│                                                   │
├────────────────────┬──────────────────────────────┤
│   Direct Transport │     Broker Transport         │
│   (Socket Mode)    │     (HTTP ↔ Broker)          │
│                    │                              │
│   User's own app   │   Shared Prime app           │
│   User's bot token │   E2E encrypted              │
│   Zero dependency  │   One-click setup            │
└────────────────────┴──────────────────────────────┘
```

Config determines which transport is active:
```env
# Direct mode (existing)
SLACK_BOT_TOKEN=xoxb-...
SLACK_APP_TOKEN=xapp-...
SLACK_MODE=direct

# Broker mode (new)
SLACK_BROKER_URL=https://broker.baudbot.dev
SLACK_BROKER_AUTH_CODE=abc123
SLACK_MODE=broker
```

The agent doesn't know or care which transport is used.

## Security Properties

| Property | Status | Notes |
|----------|--------|-------|
| Inbound messages encrypted in transit | ✅ | Sealed box, only server can decrypt |
| Outbound message body encrypted in transit | ✅ | crypto_box, broker decrypts transiently to post to Slack |
| Broker cannot persist message content | ✅ | By design + auditable (open source) |
| Broker cannot read inbound messages | ✅ | Sealed box — no broker private key involved |
| Broker cannot read outbound messages at rest | ✅ | Only decrypted in memory, zeroed after Slack API call |
| Server authenticates broker | ✅ | Broker signs envelopes with its key |
| Broker authenticates server | ✅ | Server signs outbound requests with its key |
| Perfect forward secrecy | ❌ | Would need session keys — v2 enhancement |
| Replay protection | ✅ | Timestamps + nonces on all messages |
| Bot token exposure | ⚠️ | Broker holds workspace bot tokens — mitigated by Cloudflare Secrets |

### Unavoidable Plaintext Exposure

1. **Slack → Broker**: Slack sends events in plaintext. This is a Slack platform constraint — no way around it.
2. **Broker → Slack**: Slack needs plaintext to display messages. The broker must decrypt outbound messages to post them.

The broker is a **trust minimization** layer, not a zero-trust layer. The security model is:
- Broker is open source and auditable
- Broker runs on Cloudflare (no persistent storage of message content)
- Broker minimizes plaintext residence time
- Compromise of the broker exposes routing metadata and transient message content, but NOT historical messages (nothing is stored)

## Implementation Plan

### Phase 1: Core Broker (MVP)
1. **Cloudflare Worker skeleton** — Request routing, KV setup, wrangler config
2. **Crypto module** — libsodium sealed boxes + authenticated encryption
3. **OAuth install flow** — Prime app install, workspace registration
4. **Inbound path** — Slack events → encrypt → forward to server
5. **Server registration API** — Keypair exchange, callback URL registration
6. **Baudbot broker client** — Receive + decrypt inbound events
7. **Tests** — Unit tests for crypto, integration tests for message flow

### Phase 2: Outbound + Bridge Integration
8. **Outbound path** — Server encrypts reply → broker decrypts → posts to Slack
9. **Slack bridge integration** — Add broker transport mode alongside direct Socket Mode
10. **Setup CLI** — `baudbot setup --slack-broker` interactive flow
11. **Health/heartbeat** — Server keepalive, broker marks servers offline if silent

### Phase 3: Hardening
12. **Rate limiting** — Per-workspace rate limiting at broker level
13. **Monitoring** — Cloudflare analytics, error tracking
14. **Documentation** — User-facing setup guide, security whitepaper
15. **Audit** — Security review of crypto implementation

### Phase 4: Enhanced Security (v2)
16. **Direct bot token mode** — Encrypted token delivery for true E2E outbound
17. **Session keys** — Ephemeral keys for perfect forward secrecy
18. **Multi-server** — One workspace routing to multiple baudbot instances

## Open Questions

1. **Socket Mode vs Events API?** Socket Mode is simpler (no public URL needed for Slack→broker) but requires a persistent WebSocket connection from the Worker. Events API needs a public endpoint but is more natural for Workers. *Recommendation: Events API for the broker, since Workers handle HTTP natively.*

2. **What if a server goes offline?** Queue messages in KV with TTL? Drop them? Notify the workspace? *Recommendation: Short TTL queue (5 min) + Slack DM to workspace admin if server is unreachable.*

3. **Multi-workspace per server?** Some users might want one baudbot handling multiple Slack workspaces. The routing table supports this (multiple workspace_ids → same server_url). Worth designing for from the start.

4. **Pricing model?** Free tier with rate limits? Usage-based? This affects the broker's KV/Worker usage costs. *Not a technical decision but affects architecture (metering, quotas).*

5. **Slack app distribution?** The Prime app needs to be listed in the Slack App Directory for easy install. This requires Slack's review process. Start with "Install from link" for beta, then submit for directory listing.
