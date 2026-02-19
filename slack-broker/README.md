# Slack Broker

A Cloudflare Worker that routes messages between Slack workspaces and individual baudbot servers. All messages are end-to-end encrypted — the broker cannot read inbound messages and only decrypts outbound messages transiently to post them to Slack.

## Architecture

```
Slack Workspace ──Events API──► Cloudflare Worker ──sealed box──► Baudbot Server
                                  (Slack Broker)
Slack Workspace ◄──Slack API──── Cloudflare Worker ◄──crypto_box── Baudbot Server
```

**Inbound (Slack → Server):** Slack sends events to the broker in plaintext (unavoidable Slack constraint). The broker encrypts the payload using `crypto_box_seal` (sealed box) with the server's public key, then forwards it. The broker **cannot decrypt** sealed boxes — only the server's private key can.

**Outbound (Server → Slack):** The server encrypts the message body with `crypto_box` (authenticated encryption) using the broker's public key. Routing metadata (channel, thread_ts) stays in cleartext so the broker can route without decrypting. The broker decrypts the body, posts to Slack, and immediately zeroes the plaintext from memory.

## Setup

### Prerequisites

- [Node.js](https://nodejs.org/) 18+
- [Wrangler CLI](https://developers.cloudflare.com/workers/wrangler/) (`npm i -g wrangler`)
- A Cloudflare account

### 1. Create KV Namespaces

```bash
wrangler kv namespace create WORKSPACE_ROUTING
wrangler kv namespace create OAUTH_STATE
```

Update the namespace IDs in `wrangler.toml`.

### 2. Set Secrets

```bash
# Generate a 32-byte seed for the broker's keypair
openssl rand -base64 32 | wrangler secret put BROKER_PRIVATE_KEY

# From your Slack app configuration
wrangler secret put SLACK_CLIENT_ID
wrangler secret put SLACK_CLIENT_SECRET
wrangler secret put SLACK_SIGNING_SECRET
```

### 3. Deploy

```bash
cd slack-broker
npm install
npm run deploy
```

### 4. Configure Slack App

Point your Slack app's Event Subscriptions request URL to:
```
https://<your-worker>.workers.dev/slack/events
```

Set the OAuth redirect URL to:
```
https://<your-worker>.workers.dev/slack/oauth/callback
```

## API Reference

### Public Endpoints

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/health` | Health check |
| `GET` | `/api/broker-pubkey` | Get broker's public keys |
| `POST` | `/slack/events` | Slack Events API webhook |
| `GET` | `/slack/oauth/install` | Start OAuth install flow |
| `GET` | `/slack/oauth/callback` | Handle OAuth callback |

### Server-to-Broker (authenticated)

| Method | Path | Description |
|--------|------|-------------|
| `POST` | `/api/register` | Register a baudbot server for a workspace |
| `DELETE` | `/api/register` | Unlink a server (requires signature) |
| `POST` | `/api/send` | Send an encrypted message to Slack |

### Registration Flow

1. User visits `/slack/oauth/install` → redirected to Slack → authorizes app
2. Callback stores workspace with "pending" status, returns an auth code
3. Server calls `POST /api/register` with the auth code to link itself
4. Workspace status becomes "active" — events start flowing

### Outbound Message Format

```json
{
  "workspace_id": "T09192W1Z34",
  "action": "chat.postMessage",
  "routing": {
    "channel": "C0A2G6TSDL6",
    "thread_ts": "1771464783.614839"
  },
  "encrypted_body": "<base64 crypto_box ciphertext>",
  "nonce": "<base64 nonce>",
  "timestamp": 1771465000,
  "signature": "<base64 Ed25519 signature>"
}
```

Supported actions: `chat.postMessage`, `reactions.add`, `chat.update`.

## Encryption Details

| Primitive | Use | Library |
|-----------|-----|---------|
| `crypto_box_seal` (X25519 + XSalsa20-Poly1305) | Inbound: Slack → server | tweetnacl |
| `crypto_box` (X25519 + XSalsa20-Poly1305) | Outbound: server → Slack | tweetnacl |
| Ed25519 | Envelope signatures | tweetnacl |
| HMAC-SHA256 | Slack request verification | Web Crypto API |

### Key Types

- **X25519 keypair** — encryption/decryption (sealed boxes + authenticated encryption)
- **Ed25519 keypair** — signing/verification (envelope authentication)
- Both derived from the same 32-byte seed (`BROKER_PRIVATE_KEY`)

## Security Properties

- ✅ Inbound messages encrypted in transit (sealed box, only server can decrypt)
- ✅ Outbound message body encrypted in transit (authenticated, broker decrypts transiently)
- ✅ Broker cannot persist message content (by design)
- ✅ Broker cannot read inbound messages (sealed box — no broker private key involved)
- ✅ Server authenticates broker (broker signs envelopes)
- ✅ Broker authenticates server (server signs outbound requests)
- ✅ Replay protection (timestamps + nonces on all messages)
- ✅ Auth code verification for server registration
- ❌ Perfect forward secrecy (would need session keys — future enhancement)

### What the Broker Can See

- Routing metadata: workspace_id, channel, thread_ts, timestamps
- Outbound message content: **transiently** (decrypted in memory to post to Slack, then zeroed)

### What the Broker Cannot See

- Inbound message content (sealed box encryption)
- Historical messages (nothing is stored)

## Development

```bash
npm install
npm test          # Run tests
npm run dev       # Start local dev server
npm run typecheck # TypeScript type checking
```

## Testing

54 tests across 3 suites:

- **crypto.test.ts** — Sealed boxes, authenticated encryption, signatures, encoding
- **routing.test.ts** — KV registry CRUD, auth code hashing, event forwarding
- **integration.test.ts** — End-to-end flows, Slack signature verification, replay protection
