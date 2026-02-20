# Slack Broker — Detailed Architecture

This document provides technical details for Baudbot's broker-based Slack integration. For a high-level overview, see the [README](../README.md#slack-broker-architecture).

## Architecture Overview

The broker is a Cloudflare Worker that handles **both inbound and outbound** message delivery between Slack and your agent. In the canonical broker deployment, the agent does NOT have direct access to the Slack bot token.

### Canonical Broker-Only Model

**Key principle**: The broker stores the Slack bot token (encrypted at rest). The agent only has cryptographic keys for secure communication with the broker.

**OAuth Flow**:
1. Admin completes Slack OAuth workflow
2. Broker receives and stores bot token encrypted in Cloudflare KV
3. Agent receives only the cryptographic keys needed to communicate with broker
4. Agent has NO direct Slack API access

### Message Flow Patterns

**Inbound (Slack → Agent)**:
1. Slack webhook → Broker
2. Broker encrypts event with agent's public key (sealed box)
3. Agent polls broker, decrypts locally

**Outbound (Agent → Slack)**:
1. Agent encrypts message and sends to broker `/api/send`
2. Broker decrypts transiently and posts to Slack using stored bot token
3. Broker zeros plaintext immediately after posting

## Cryptographic Design

**Inbound encryption (Slack → Agent) — TRUE E2E:**
- Messages encrypted with **libsodium sealed boxes** (crypto_box_seal)
- Uses X25519 elliptic curve Diffie-Hellman + XSalsa20-Poly1305
- Ephemeral keypair per message + BLAKE2B nonce derivation
- **Only the agent's private key can decrypt — broker cannot read content**

**Outbound encryption (Agent → Broker → Slack) — TRANSIENT DECRYPTION:**
- Messages encrypted with **NaCl crypto_box** (authenticated encryption)
- Uses X25519 + XSalsa20-Poly1305 with shared secret
- **Broker decrypts transiently to post to Slack, then zeros plaintext**
- Provides sender authentication via shared secret

**Bot Token Storage:**
- Slack bot token stored encrypted at rest in Cloudflare KV
- Encrypted with broker's private key
- Agent never receives the bot token

**Authentication:**
- All requests signed with **Ed25519** detached signatures
- Broker signs message envelopes; agents verify broker authenticity
- Agents sign API requests; broker verifies sender identity
- 5-minute timestamp replay protection on all signed requests

## Message Flow Details

### Complete Flow (9 steps)
1. **Slack sends event** → Broker receives webhook
2. **Broker encrypts** event with agent's public key (sealed box)
3. **Broker enqueues** encrypted envelope in Durable Object inbox
4. **Agent polls** `/api/inbox/pull` with signed request
5. **Broker returns** encrypted messages (max 10 per poll)
6. **Agent decrypts** locally and processes events
7. **Agent acknowledges** processed messages via `/api/inbox/ack`
8. **Agent sends replies** via `/api/send` (crypto_box encrypted to broker)
9. **Broker decrypts, posts to Slack, zeros plaintext**

### Security Properties

**Inbound Security (Slack → Agent)**:
- True end-to-end encryption
- Broker cannot read message content
- Agent-only decryption

**Outbound Security (Agent → Slack)**:
- Encrypted in transit to broker
- Broker has transient access to plaintext (required to post to Slack)
- Immediate zeroing after Slack API call
- No persistent plaintext storage

## Polling and Reliability

- **Default polling**: Every 3 seconds when active
- **Exponential backoff**: Up to 30 seconds on errors
- **Message leasing**: 30-second exclusive leases with automatic requeue
- **Retry handling**: Up to 10 attempts before dead letter queue
- **Deduplication**: 20-minute client-side cache prevents double-processing
- **Poison message handling**: Invalid signatures/decrypt failures are auto-acked

## Why This Design

**Security benefits:**
- **Inbound messages are truly end-to-end encrypted** — broker cannot read them
- Agent never stores or accesses Slack bot token directly
- Bot token stored encrypted at rest on broker infrastructure
- Minimized plaintext exposure (immediate zeroing after Slack posts)

**Operational benefits:**
- No inbound ports or reverse proxy setup required
- Works behind firewalls, NAT, or restrictive networks
- Cloudflare's global edge provides reliability and performance
- Automatic retry and queue semantics for reliable delivery
- Centralized credential management (bot token on broker only)

**Scalability:**
- Broker is stateless — scales automatically with Cloudflare
- Durable Objects provide strong consistency for message ordering
- Multiple agents can register to the same broker instance

## Implementation Details

The broker implementation uses Cloudflare Workers and Durable Objects:

- **Worker**: Stateless handler for webhooks and API endpoints
- **Durable Object**: Per-workspace inbox for reliable message queuing
- **KV Storage**: Encrypted workspace registration data and bot tokens
- **Edge deployment**: Global distribution with low latency

Key crypto operations:
- `crypto_box_seal` for inbound encryption (agent-only decryption)
- `crypto_box` for outbound encryption (broker transient decryption)
- `ed25519` signatures for all request authentication
- Memory zeroing (`zeroBytes()`) to minimize plaintext residence time

## Configuration

### Broker Mode (Canonical)

Agent only needs broker communication keys:

```bash
# Broker connection
SLACK_BROKER_URL=https://your-broker.example.com
SLACK_BROKER_WORKSPACE_ID=T0123ABCD

# Server cryptographic keys (base64-encoded, generated during registration)
SLACK_BROKER_SERVER_PRIVATE_KEY=<server_private_key>
SLACK_BROKER_SERVER_PUBLIC_KEY=<server_public_key>
SLACK_BROKER_SERVER_SIGNING_PRIVATE_KEY=<server_signing_private_key>

# Broker public keys (received during registration)
SLACK_BROKER_PUBLIC_KEY=<broker_public_key>
SLACK_BROKER_SIGNING_PUBLIC_KEY=<broker_signing_pubkey>

# NO SLACK_BOT_TOKEN — stored on broker only
```

### Socket Mode (Alternative)

For simpler single-server setups that can accept inbound websocket connections:

```bash
SLACK_BOT_TOKEN=<bot_token>
SLACK_APP_TOKEN=<app_token>
SLACK_ALLOWED_USERS=<user_ids>
```

## Registration Flow

1. Admin initiates OAuth: Visit broker's `/oauth/install` endpoint
2. Slack redirects to broker with authorization code
3. Broker exchanges code for bot token and stores it encrypted
4. Admin runs registration command with auth code:
   ```bash
   sudo baudbot broker register \
     --broker-url https://your-broker.example.com \
     --workspace-id T0123ABCD \
     --auth-code <auth-code-from-oauth>
   ```
5. Agent receives cryptographic keys (NOT the bot token)
6. Restart to load new configuration: `sudo baudbot restart`

## Message Sending (Agent Perspective)

In broker mode, the agent sends all outbound messages through the broker's local API:

```bash
# Send message
curl -s -X POST http://127.0.0.1:7890/send \
  -H 'Content-Type: application/json' \
  -d '{"channel":"CHANNEL_ID","text":"your message","thread_ts":"optional"}'

# Add reaction
curl -s -X POST http://127.0.0.1:7890/react \
  -H 'Content-Type: application/json' \
  -d '{"channel":"CHANNEL_ID","timestamp":"msg_ts","emoji":"white_check_mark"}'
```

The bridge encrypts these requests and forwards them to the broker, which handles the actual Slack API calls.

## Comparison: Broker vs Socket Mode

| Aspect | Broker Mode | Socket Mode |
|--------|-------------|-------------|
| **Inbound ports** | None required | Websocket connection to Slack |
| **Bot token location** | Encrypted on broker | Local env var |
| **Inbound encryption** | E2E encrypted | TLS only |
| **Outbound encryption** | Encrypted to broker, transient decryption | Direct HTTPS to Slack |
| **Firewall complexity** | Outbound HTTPS only | Outbound + websocket |
| **Setup complexity** | OAuth + registration | Token configuration |
| **Recommended for** | Production, multi-agent | Development, simple setups |
