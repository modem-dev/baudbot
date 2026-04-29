# Future: Async Message Visibility in Debug-Agent

## Current Limitation

The debug-agent (and any pi session) operates in a **synchronous turn-based model**:
- When processing a user prompt, the LLM generates a response
- During this generation, incoming `send_to_session` messages are queued
- These queued messages are **invisible** until the current turn completes
- Only then does pi process the queue and present them as new user prompts

This creates confusion in debug/observability scenarios where admins expect real-time interaction.

## Short-term Mitigation (this PR)

- Document the limitation clearly
- Add `/ready` command to signal completion
- Advise keeping responses short
- Provide socket checking workarounds

## Long-term Solutions

### Option 1: Pi Core Enhancement - Message Queue API

Extend pi's `ExtensionAPI` to expose pending message count:

```typescript
interface ExtensionAPI {
  // ... existing methods
  
  /**
   * Get count of pending send_to_session messages in queue
   * Returns 0 if no messages pending, N if messages queued
   */
  getPendingMessageCount(): number;
  
  /**
   * Get preview of pending messages (if available)
   * Useful for dashboard indicators
   */
  getPendingMessagePreviews(): Array<{
    from: string; // sender session ID or name
    preview: string; // first 50 chars
    timestamp: Date;
  }>;
}
```

Then the dashboard could show:
```
┌─────────────────────────────────────────────────────┐
│ 📬 3 messages queued (complete turn to process)     │
│   • control-agent: "can you check..."              │
│   • user: "status update?"                          │
└─────────────────────────────────────────────────────┘
```

**Implementation**: Requires changes to pi's session control layer (WebSocket/message routing)

### Option 2: Streaming Response with Message Interruption

More ambitious - allow interrupting mid-generation:

```typescript
pi.on("message_received_during_turn", async (event, ctx) => {
  // Opportunity to abort current generation
  // Present queued message immediately
  // Or queue for "after this sentence"
});
```

**Challenges**:
- Requires streaming/incremental generation support
- Complex state management (partial responses)
- May confuse conversation context

### Option 3: Parallel Session Mode

Create a "monitor" mode for debug-agent that spawns a parallel session:

```typescript
// Main session: normal turn-based interaction
// Monitor session: async-only, polls for messages every 2s

pi.registerExtension("async-monitor", {
  async init(ctx) {
    if (ctx.sessionRole === "debug-observer") {
      setInterval(() => {
        // Poll session control for pending messages
        // Display in dashboard without blocking main turn
      }, 2000);
    }
  }
});
```

**Pros**: No pi core changes needed
**Cons**: Complex dual-session architecture, more resources

### Option 4: Event-Driven Dashboard Widget

The dashboard widget already runs outside the LLM turn. Enhance it to:
1. Listen on the session socket directly (bypassing pi's queue)
2. Display pending messages in the widget itself (not as user prompts)
3. Use `/accept-message <id>` command to pull from queue into conversation

**Pros**: Clean separation of monitoring vs. conversation
**Cons**: Two different interaction modes (in-chat vs. dashboard commands)

## Recommendation

**Phase 1** (this PR): Documentation + workarounds
**Phase 2**: Implement Option 1 (message queue API in pi core)
**Phase 3**: Consider Option 4 if Option 1 proves insufficient

Option 1 is the cleanest long-term solution as it:
- Preserves pi's turn-based model
- Adds visibility without changing core behavior
- Minimal API surface area
- Useful for all session types, not just debug-agent

## Related Pi Issues

- (TODO: check if @mariozechner/pi-coding-agent has issue tracker)
- Consider proposing this enhancement upstream
