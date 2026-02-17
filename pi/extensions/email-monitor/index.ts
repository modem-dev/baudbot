import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";
import { Type } from "@sinclair/typebox";
import { StringEnum } from "@mariozechner/pi-ai";

export default function (pi: ExtensionAPI) {
  let polling = false;
  let pollInterval: ReturnType<typeof setInterval> | null = null;
  let monitoredInboxId: string | null = null;
  let lastSeenMessageIds = new Set<string>();
  let pollIntervalMs = 60_000;
  let actionInstructions = "Read and summarize the email, then decide if any action is needed.";
  let useSubAgent = true;
  const activeSubAgents = new Set<string>();
  const allowedSenders = new Set<string>(
    (process.env.BAUDBOT_ALLOWED_EMAILS || "").split(",").map(s => s.trim()).filter(Boolean)
  );
  const SHARED_SECRET = process.env.BAUDBOT_SECRET || "changeme";

  // Restore state from session
  pi.on("session_start", async (_event, ctx) => {
    for (const entry of ctx.sessionManager.getEntries()) {
      if (entry.type === "custom" && entry.customType === "email-monitor-state") {
        const data = entry.data as any;
        if (data?.inboxId) monitoredInboxId = data.inboxId;
        if (data?.seenIds) lastSeenMessageIds = new Set(data.seenIds);
        if (data?.intervalMs) pollIntervalMs = data.intervalMs;
        if (data?.instructions) actionInstructions = data.instructions;
        if (data?.useSubAgent !== undefined) useSubAgent = data.useSubAgent;
        if (data?.polling) startPolling(ctx);
      }
    }
  });

  pi.on("session_shutdown", async () => {
    stopPolling();
  });

  function saveState() {
    pi.appendEntry("email-monitor-state", {
      inboxId: monitoredInboxId,
      seenIds: Array.from(lastSeenMessageIds),
      intervalMs: pollIntervalMs,
      instructions: actionInstructions,
      polling,
      useSubAgent,
    });
  }

  function startPolling(ctx?: any) {
    if (pollInterval) clearInterval(pollInterval);
    polling = true;
    pollInterval = setInterval(() => checkForNewEmails(ctx), pollIntervalMs);
  }

  function stopPolling() {
    polling = false;
    if (pollInterval) {
      clearInterval(pollInterval);
      pollInterval = null;
    }
  }

  async function fetchMessages(inboxId: string, limit = 10) {
    const apiKey = process.env.AGENTMAIL_API_KEY;
    if (!apiKey) return [];
    const res = await fetch(
      `https://api.agentmail.to/v0/inboxes/${inboxId}/messages?limit=${limit}`,
      { headers: { Authorization: `Bearer ${apiKey}`, "Content-Type": "application/json" } }
    );
    if (!res.ok) return [];
    const data = (await res.json()) as any;
    return data.messages || [];
  }

  async function fetchMessageBody(inboxId: string, messageId: string) {
    const apiKey = process.env.AGENTMAIL_API_KEY;
    if (!apiKey) return "(could not fetch body)";
    const res = await fetch(
      `https://api.agentmail.to/v0/inboxes/${inboxId}/messages/${messageId}`,
      { headers: { Authorization: `Bearer ${apiKey}`, "Content-Type": "application/json" } }
    );
    if (!res.ok) return "(could not fetch body)";
    const msg = (await res.json()) as any;
    return msg.text || msg.html || "(empty body)";
  }

  async function spawnSubAgent(emailSummary: string) {
    const subAgentId = `email-${Date.now()}`;
    activeSubAgents.add(subAgentId);

    try {
      // Spawn a pi subprocess in print mode to handle the email
      // It gets full tool access (agentmail, bash, read, etc.)
      const prompt = [
        `You are handling an incoming email. Here are your instructions:`,
        ``,
        actionInstructions,
        ``,
        `--- EMAIL ---`,
        emailSummary,
        `--- END EMAIL ---`,
        ``,
        `The monitored inbox ID is: ${monitoredInboxId}`,
        `Use the agentmail tools to reply if needed.`,
        `Be concise and take action directly.`,
      ].join("\n");

      const result = await pi.exec(
        "pi",
        ["-p", "--no-session", prompt],
        { timeout: 120_000 }
      );

      return {
        subAgentId,
        stdout: result.stdout,
        stderr: result.stderr,
        exitCode: result.code,
      };
    } catch (e: any) {
      return { subAgentId, error: e.message };
    } finally {
      activeSubAgents.delete(subAgentId);
    }
  }

  async function checkForNewEmails(ctx?: any) {
    if (!monitoredInboxId) return;

    try {
      const messages = await fetchMessages(monitoredInboxId);
      const newMessages = messages.filter((m: any) => {
        if (lastSeenMessageIds.has(m.message_id)) return false;
        const fromAddr = (m.from || "").toLowerCase();
        // Skip our own outgoing messages to avoid loops
        if (monitoredInboxId && fromAddr.includes(monitoredInboxId.toLowerCase())) return false;
        // Only accept emails from allowed senders
        const senderEmail = fromAddr.match(/<([^>]+)>/)?.[1] || fromAddr.trim();
        if (!allowedSenders.has(senderEmail)) {
          // Silently ignore unauthorized senders
          return false;
        }
        return true;
      });

      if (newMessages.length === 0) return;

      // Mark as seen immediately
      for (const msg of newMessages) {
        lastSeenMessageIds.add(msg.message_id);
      }
      saveState();

      for (const msg of newMessages) {
        const body = await fetchMessageBody(monitoredInboxId, msg.message_id);

        // Verify shared secret is present in the email body
        if (!body.includes(SHARED_SECRET)) {
          // Silently ignore — don't reveal that a secret is required
          continue;
        }

        // Strip the secret from the body before processing
        const cleanBody = body.replace(SHARED_SECRET, "[verified]");

        const emailSummary = [
          `From: ${msg.from || "unknown"}`,
          `Subject: ${msg.subject || "(no subject)"}`,
          `Date: ${msg.created_at || "unknown"}`,
          `Message ID: ${msg.message_id}`,
          ``,
          cleanBody,
        ].join("\n");

        if (useSubAgent) {
          // Fire off a sub-agent — don't block the poll loop
          spawnSubAgent(emailSummary).then((result) => {
            // Report back to main agent
            const report = result.error
              ? `⚠️ Sub-agent failed for email "${msg.subject}": ${result.error}`
              : `✅ Sub-agent handled email "${msg.subject}" (exit ${result.exitCode}):\n${(result.stdout || "").slice(0, 500)}`;

            pi.sendMessage(
              {
                customType: "email-monitor-result",
                content: report,
                display: true,
              },
              { deliverAs: "followUp", triggerTurn: false }
            );
          });
        } else {
          // Handle in main agent
          pi.sendUserMessage(
            `📬 New email received:\n\n${emailSummary}\n\n---\nInstructions: ${actionInstructions}\nInbox ID: ${monitoredInboxId}`,
            { deliverAs: "followUp" }
          );
        }
      }
    } catch (_e) {
      // Silently fail — will retry next interval
    }
  }

  pi.registerTool({
    name: "email_monitor",
    label: "Email Monitor",
    description:
      "Monitor an AgentMail inbox for new emails and take action when they arrive. " +
      "Uses background sub-agents by default so the main session stays responsive. " +
      "Actions: start (begin monitoring), stop (stop monitoring), status (check state), " +
      "check (manually poll now).",
    parameters: Type.Object({
      action: StringEnum(["start", "stop", "status", "check"] as const),
      inbox_id: Type.Optional(
        Type.String({ description: "AgentMail inbox ID to monitor. Required for 'start'." })
      ),
      interval_seconds: Type.Optional(
        Type.Number({ description: "Polling interval in seconds (default 60)." })
      ),
      instructions: Type.Optional(
        Type.String({
          description:
            "Instructions for the sub-agent when an email arrives (e.g. 'summarize and reply', 'forward to user@example.com').",
        })
      ),
      use_sub_agent: Type.Optional(
        Type.Boolean({
          description:
            "If true (default), spawn a separate pi agent to handle each email. If false, deliver to main agent.",
        })
      ),
    }),
    async execute(toolCallId, params, signal, onUpdate, ctx) {
      switch (params.action) {
        case "start": {
          if (!params.inbox_id) {
            return {
              content: [
                {
                  type: "text",
                  text: "Error: inbox_id is required. Create an inbox first with agentmail_inbox.",
                },
              ],
            };
          }

          monitoredInboxId = params.inbox_id;
          if (params.interval_seconds) pollIntervalMs = params.interval_seconds * 1000;
          if (params.instructions) actionInstructions = params.instructions;
          if (params.use_sub_agent !== undefined) useSubAgent = params.use_sub_agent;

          // Seed seen messages so we don't re-process old ones
          try {
            const existing = await fetchMessages(monitoredInboxId, 50);
            for (const msg of existing) lastSeenMessageIds.add(msg.message_id);
          } catch {}

          startPolling(ctx);
          saveState();

          return {
            content: [
              {
                type: "text",
                text: [
                  `✅ Now monitoring inbox ${monitoredInboxId} every ${pollIntervalMs / 1000}s`,
                  `Mode: ${useSubAgent ? "sub-agent (background)" : "main agent (inline)"}`,
                  `Instructions: ${actionInstructions}`,
                  `Seeded ${lastSeenMessageIds.size} existing messages`,
                ].join("\n"),
              },
            ],
            details: { inboxId: monitoredInboxId, intervalMs: pollIntervalMs, useSubAgent },
          };
        }

        case "stop": {
          stopPolling();
          saveState();
          return { content: [{ type: "text", text: "⏹ Email monitoring stopped." }] };
        }

        case "status": {
          return {
            content: [
              {
                type: "text",
                text: [
                  `Email Monitor Status:`,
                  `  Polling: ${polling ? "✅ active" : "⏹ stopped"}`,
                  `  Inbox: ${monitoredInboxId || "none"}`,
                  `  Interval: ${pollIntervalMs / 1000}s`,
                  `  Mode: ${useSubAgent ? "sub-agent" : "main agent"}`,
                  `  Seen messages: ${lastSeenMessageIds.size}`,
                  `  Active sub-agents: ${activeSubAgents.size}`,
                  `  Instructions: ${actionInstructions}`,
                ].join("\n"),
              },
            ],
          };
        }

        case "check": {
          if (!monitoredInboxId) {
            return {
              content: [{ type: "text", text: "No inbox configured. Use 'start' first." }],
            };
          }
          await checkForNewEmails(ctx);
          return {
            content: [
              {
                type: "text",
                text: `🔍 Checked inbox ${monitoredInboxId}. New emails will be handled by ${useSubAgent ? "sub-agents" : "this session"}.`,
              },
            ],
          };
        }

        default:
          return { content: [{ type: "text", text: `Unknown action: ${params.action}` }] };
      }
    },
  });

  pi.registerCommand("email-monitor", {
    description: "Check email monitor status",
    handler: async (_args, ctx) => {
      const status = polling ? "✅ active" : "⏹ stopped";
      const mode = useSubAgent ? "sub-agent" : "inline";
      ctx.ui.notify(
        `Email monitor: ${status} | ${monitoredInboxId || "no inbox"} | ${pollIntervalMs / 1000}s | ${mode} | ${activeSubAgents.size} running`,
        "info"
      );
    },
  });
}
