import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";
import { Type } from "@sinclair/typebox";
import { StringEnum } from "@mariozechner/pi-ai";

/**
 * Sentry Monitor Extension
 *
 * Polls the #bots-sentry Slack channel for new Sentry alert messages, then uses
 * the Sentry API to fetch detailed issue info (stack traces, event counts, etc.)
 * for triage.
 *
 * Trigger: Slack channel polling (Sentry already posts alerts there)
 * Investigation: Sentry API for deep-dive on flagged issues
 *
 * Requires:
 *   SLACK_BOT_TOKEN    — Slack bot OAuth token
 *   SENTRY_AUTH_TOKEN  — Sentry API bearer token
 *   SENTRY_ORG         — Sentry organization slug
 *   SENTRY_CHANNEL_ID  — Slack channel ID for #bots-sentry
 */

// ── Config ────────────────────────────────────────────────────────────────────

const SENTRY_ORG = process.env.SENTRY_ORG || "";
const SENTRY_AUTH_TOKEN = process.env.SENTRY_AUTH_TOKEN || "";
const SLACK_BOT_TOKEN = process.env.SLACK_BOT_TOKEN || "";
let SENTRY_CHANNEL_ID = process.env.SENTRY_CHANNEL_ID || "";

// ── Types ─────────────────────────────────────────────────────────────────────

interface SlackMessage {
  type: string;
  ts: string;
  text?: string;
  bot_id?: string;
  attachments?: SlackAttachment[];
  blocks?: any[];
}

interface SlackAttachment {
  title?: string;
  title_link?: string;
  text?: string;
  fallback?: string;
  color?: string;
  fields?: { title: string; value: string; short: boolean }[];
}

interface ParsedAlert {
  title: string;
  project: string;
  link: string;
  level: "critical" | "error" | "warning" | "info";
  eventCount?: number;
  issueId?: string;
  isNew?: boolean;
  isRegression?: boolean;
  raw: SlackMessage;
}

interface MonitorState {
  polling: boolean;
  intervalMs: number;
  lastPollTs: string | null; // Slack message timestamp (for oldest= param)
  seenTs: Set<string>; // Deduplicate messages
  baselineComplete: boolean;
}

// ── Extension ─────────────────────────────────────────────────────────────────

export default function (pi: ExtensionAPI) {
  const state: MonitorState = {
    polling: false,
    intervalMs: 3 * 60_000, // 3 minutes
    lastPollTs: null,
    seenTs: new Set(),
    baselineComplete: false,
  };
  let pollTimer: ReturnType<typeof setInterval> | null = null;

  // ── State persistence ───────────────────────────────────────────────────

  pi.on("session_start", async (_event, ctx) => {
    for (const entry of ctx.sessionManager.getEntries()) {
      if (entry.type === "custom" && entry.customType === "sentry-monitor-state") {
        const data = entry.data as any;
        if (data) {
          state.polling = data.polling ?? false;
          state.intervalMs = data.intervalMs ?? 3 * 60_000;
          state.lastPollTs = data.lastPollTs ?? null;
          state.seenTs = new Set(data.seenTs ?? []);
          state.baselineComplete = data.baselineComplete ?? false;
          if (state.polling) startPolling();
        }
      }
    }
  });

  pi.on("session_shutdown", async () => {
    stopPolling();
  });

  function saveState() {
    pi.appendEntry("sentry-monitor-state", {
      polling: state.polling,
      intervalMs: state.intervalMs,
      lastPollTs: state.lastPollTs,
      seenTs: Array.from(state.seenTs).slice(-200), // cap persisted set
      baselineComplete: state.baselineComplete,
    });
  }

  // ── Slack API ───────────────────────────────────────────────────────────

  async function slackGet(method: string, params: Record<string, string> = {}): Promise<any> {
    if (!SLACK_BOT_TOKEN) throw new Error("SLACK_BOT_TOKEN not set");
    const qs = new URLSearchParams(params).toString();
    const url = `https://slack.com/api/${method}${qs ? `?${qs}` : ""}`;
    const res = await fetch(url, {
      headers: { Authorization: `Bearer ${SLACK_BOT_TOKEN}` },
    });
    const json = await res.json();
    if (!json.ok) throw new Error(`Slack API ${method}: ${json.error}`);
    return json;
  }

  async function slackPost(method: string, body: Record<string, any>): Promise<any> {
    if (!SLACK_BOT_TOKEN) throw new Error("SLACK_BOT_TOKEN not set");
    const res = await fetch(`https://slack.com/api/${method}`, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${SLACK_BOT_TOKEN}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify(body),
    });
    const json = await res.json();
    if (!json.ok) throw new Error(`Slack API ${method}: ${json.error}`);
    return json;
  }

  async function resolveChannelId(): Promise<string> {
    if (SENTRY_CHANNEL_ID) return SENTRY_CHANNEL_ID;

    // Look up #bots-sentry channel
    const data = await slackGet("conversations.list", {
      types: "public_channel",
      limit: "200",
    });
    for (const ch of data.channels || []) {
      if (ch.name === "bots-sentry") {
        SENTRY_CHANNEL_ID = ch.id;
        return ch.id;
      }
    }
    throw new Error("Could not find #bots-sentry channel");
  }

  async function ensureInChannel(channelId: string): Promise<void> {
    try {
      await slackPost("conversations.join", { channel: channelId });
    } catch {
      // Already in channel, or can't join — either way, continue
    }
  }

  async function fetchChannelMessages(limit = 20, oldest?: string): Promise<SlackMessage[]> {
    const channelId = await resolveChannelId();
    await ensureInChannel(channelId);

    const params: Record<string, string> = {
      channel: channelId,
      limit: String(limit),
    };
    if (oldest) params.oldest = oldest;

    const data = await slackGet("conversations.history", params);
    return (data.messages || []) as SlackMessage[];
  }

  // ── Alert parsing ───────────────────────────────────────────────────────

  function parseAlert(msg: SlackMessage): ParsedAlert | null {
    // Sentry alerts come as bot messages with attachments
    const att = msg.attachments?.[0];
    const text = msg.text || att?.fallback || att?.text || "";
    const title = att?.title || text.split("\n")[0] || "(untitled)";

    // Try to extract Sentry issue link and ID
    const link = att?.title_link || "";
    let issueId: string | undefined;
    const idMatch = link.match(/issues\/(\d+)/);
    if (idMatch) issueId = idMatch[1];

    // Try to extract project from link or text
    let project = "unknown";
    const projMatch = link.match(/organizations\/[^/]+\/issues\//) 
      ? (text.match(/\b(dashboard|ingest|slack|workflows|github|linear|media-proxy|usage|x)\b/i)?.[1] || "unknown")
      : "unknown";
    if (projMatch !== "unknown") project = projMatch.toLowerCase();

    // Determine severity
    const color = att?.color || "";
    let level: ParsedAlert["level"] = "info";
    if (color === "danger" || color === "#e03e2f" || /critical/i.test(text)) level = "critical";
    else if (color === "warning" || color === "#f2c744" || /warning/i.test(text)) level = "warning";
    else if (/error/i.test(text) || color === "#e03e2f") level = "error";

    // Check for new/regression markers
    const isNew = /first seen|new issue/i.test(text);
    const isRegression = /regression/i.test(text);

    // Extract event count if present
    let eventCount: number | undefined;
    const countMatch = text.match(/(\d+)\s*events?/i);
    if (countMatch) eventCount = parseInt(countMatch[1], 10);

    if (!title && !link) return null;

    return { title, project, link, level, eventCount, issueId, isNew, isRegression, raw: msg };
  }

  // ── Sentry API (for deep-dive) ──────────────────────────────────────────

  async function sentryGet(path: string): Promise<any> {
    if (!SENTRY_AUTH_TOKEN) throw new Error("SENTRY_AUTH_TOKEN not set — add it to ~/.config/.env");
    if (!SENTRY_ORG) throw new Error("SENTRY_ORG not set — add it to ~/.config/.env (your Sentry organization slug)");
    const url = `https://sentry.io/api/0/${path}`;
    const res = await fetch(url, {
      headers: { Authorization: `Bearer ${SENTRY_AUTH_TOKEN}` },
    });
    if (!res.ok) {
      const text = await res.text();
      throw new Error(`Sentry API ${res.status}: ${text}`);
    }
    return res.json();
  }

  async function fetchIssueDetails(issueId: string): Promise<any> {
    return sentryGet(`issues/${issueId}/`);
  }

  async function fetchLatestEvent(issueId: string): Promise<any> {
    return sentryGet(`issues/${issueId}/events/latest/`);
  }

  function formatIssueDetails(issue: any, event?: any): string {
    let out = [
      `**${issue.shortId}**: ${issue.title}`,
      `Project: ${issue.project?.slug} | Level: ${issue.level} | Status: ${issue.status}`,
      `Events: ${issue.count} | Users: ${issue.userCount}`,
      `First: ${issue.firstSeen} | Last: ${issue.lastSeen}`,
      `Culprit: ${issue.culprit || "unknown"}`,
      `Link: ${issue.permalink}`,
    ].join("\n");

    if (event?.entries) {
      for (const entry of event.entries) {
        if (entry.type === "exception") {
          for (const exc of entry.data?.values || []) {
            out += `\n\n**Exception**: ${exc.type}: ${exc.value}`;
            if (exc.stacktrace?.frames) {
              const frames = exc.stacktrace.frames.slice(-10).reverse();
              out += "\n```";
              for (const f of frames) {
                const loc = f.lineNo ? `:${f.lineNo}` : "";
                out += `\n  ${f.filename || "?"}${loc} in ${f.function || "?"}`;
              }
              out += "\n```";
            }
          }
        }
      }
    }

    return out;
  }

  // ── Polling ─────────────────────────────────────────────────────────────

  function startPolling() {
    if (pollTimer) clearInterval(pollTimer);
    state.polling = true;
    saveState();

    pollTimer = setInterval(async () => {
      try {
        const result = await pollOnce();
        if (result.alerts.length > 0) {
          pi.sendUserMessage(
            `🚨 **Sentry**: ${result.alerts.length} new alert(s) from #bots-sentry:\n\n${result.summary}\n\n` +
              `Triage these according to your guidelines. Use \`sentry_monitor get <issue_id>\` for stack traces on critical ones.`
          );
        }
      } catch {
        // Don't crash on poll errors
      }
    }, state.intervalMs);
  }

  function stopPolling() {
    if (pollTimer) {
      clearInterval(pollTimer);
      pollTimer = null;
    }
    state.polling = false;
    saveState();
  }

  async function pollOnce(): Promise<{ alerts: ParsedAlert[]; summary: string }> {
    const messages = await fetchChannelMessages(20, state.lastPollTs || undefined);

    // Messages come newest-first; we want oldest-first for processing
    messages.reverse();

    const newAlerts: ParsedAlert[] = [];

    for (const msg of messages) {
      if (state.seenTs.has(msg.ts)) continue;
      state.seenTs.add(msg.ts);

      // Update high-water mark
      if (!state.lastPollTs || msg.ts > state.lastPollTs) {
        state.lastPollTs = msg.ts;
      }

      // On first poll, just record baseline — don't alert
      if (!state.baselineComplete) continue;

      const alert = parseAlert(msg);
      if (alert) newAlerts.push(alert);
    }

    if (!state.baselineComplete) {
      state.baselineComplete = true;
    }

    // Cap seen set
    if (state.seenTs.size > 500) {
      const arr = Array.from(state.seenTs);
      state.seenTs = new Set(arr.slice(-300));
    }

    saveState();

    const summary = newAlerts.length > 0 ? formatAlertSummary(newAlerts) : "No new alerts.";
    return { alerts: newAlerts, summary };
  }

  function formatAlertSummary(alerts: ParsedAlert[]): string {
    const lines: string[] = [];
    for (const alert of alerts) {
      const icon = alert.level === "critical" ? "🔴" : alert.level === "error" ? "🟠" : alert.level === "warning" ? "🟡" : "⚪";
      const tags: string[] = [];
      if (alert.isNew) tags.push("NEW");
      if (alert.isRegression) tags.push("REGRESSION");
      if (alert.eventCount && alert.eventCount > 100) tags.push("🔥 HIGH FREQ");
      const tagStr = tags.length > 0 ? ` [${tags.join(", ")}]` : "";

      lines.push(`${icon} **${alert.project}** — ${alert.title}${tagStr}`);
      if (alert.eventCount) lines.push(`   Events: ${alert.eventCount}`);
      if (alert.issueId) lines.push(`   Issue ID: ${alert.issueId}`);
      if (alert.link) lines.push(`   ${alert.link}`);
      lines.push("");
    }
    return lines.join("\n");
  }

  // ── Tool ────────────────────────────────────────────────────────────────

  pi.registerTool({
    name: "sentry_monitor",
    label: "Sentry Monitor",
    description:
      "Monitor #bots-sentry Slack channel for Sentry alerts and investigate issues via Sentry API. " +
      "Actions: start (begin polling), stop, status, check (poll now), get (issue details + stack trace), list (recent channel messages).",
    parameters: Type.Object({
      action: StringEnum(["start", "stop", "status", "check", "get", "list"] as const),
      interval_minutes: Type.Optional(
        Type.Number({ description: "Polling interval in minutes (default 3)" })
      ),
      issue_id: Type.Optional(Type.String({ description: "Sentry issue ID (for get action — fetches details + stack trace from Sentry API)" })),
      count: Type.Optional(Type.Number({ description: "Number of messages to fetch (for list, default 20)" })),
    }),

    async execute(_toolCallId, params, _signal, _onUpdate, _ctx) {
      let text: string;

      switch (params.action) {
        case "start": {
          if (!SLACK_BOT_TOKEN) {
            text = "❌ SLACK_BOT_TOKEN not set. Add it to ~/.config/.env and restart.";
            break;
          }
          if (params.interval_minutes) {
            state.intervalMs = params.interval_minutes * 60_000;
          }
          try {
            const channelId = await resolveChannelId();
            startPolling();
            text = `✅ Sentry monitor started.\n  Channel: #bots-sentry (${channelId})\n  Polling: every ${state.intervalMs / 60_000}min\n  Baseline: ${state.baselineComplete ? "complete" : "will establish on first poll"}`;
          } catch (e: any) {
            text = `❌ Failed to start: ${e.message}`;
          }
          break;
        }

        case "stop": {
          stopPolling();
          text = "⏹️ Sentry monitor stopped.";
          break;
        }

        case "status": {
          text = [
            `Sentry Monitor Status:`,
            `  Polling: ${state.polling ? "✅ active" : "⏹️ stopped"}`,
            `  Interval: ${state.intervalMs / 60_000}min`,
            `  Last poll: ${state.lastPollTs ? new Date(parseFloat(state.lastPollTs) * 1000).toISOString() : "never"}`,
            `  Baseline: ${state.baselineComplete ? "complete" : "pending"}`,
            `  Tracked messages: ${state.seenTs.size}`,
            `  Channel ID: ${SENTRY_CHANNEL_ID || "(will resolve on start)"}`,
            `  Slack token: ${SLACK_BOT_TOKEN ? "✅ set" : "❌ missing"}`,
            `  Sentry token: ${SENTRY_AUTH_TOKEN ? "✅ set" : "❌ missing"}`,
            `  Org: ${SENTRY_ORG}`,
          ].join("\n");
          break;
        }

        case "check": {
          if (!SLACK_BOT_TOKEN) {
            text = "❌ SLACK_BOT_TOKEN not set.";
            break;
          }
          try {
            const result = await pollOnce();
            text = result.summary;
          } catch (e: any) {
            text = `❌ Poll failed: ${e.message}`;
          }
          break;
        }

        case "get": {
          if (!params.issue_id) {
            text = "❌ issue_id required";
            break;
          }
          if (!SENTRY_AUTH_TOKEN) {
            text = "❌ SENTRY_AUTH_TOKEN not set.";
            break;
          }
          try {
            const issue = await fetchIssueDetails(params.issue_id);
            let event: any;
            try {
              event = await fetchLatestEvent(params.issue_id);
            } catch {
              // event fetch is optional
            }
            text = formatIssueDetails(issue, event);
          } catch (e: any) {
            text = `❌ Failed to fetch issue: ${e.message}`;
          }
          break;
        }

        case "list": {
          if (!SLACK_BOT_TOKEN) {
            text = "❌ SLACK_BOT_TOKEN not set.";
            break;
          }
          try {
            const limit = params.count || 20;
            const messages = await fetchChannelMessages(limit);
            if (messages.length === 0) {
              text = "No messages in #bots-sentry.";
            } else {
              const alerts = messages
                .map(parseAlert)
                .filter((a): a is ParsedAlert => a !== null);
              if (alerts.length === 0) {
                text = `${messages.length} messages found but none parsed as Sentry alerts.`;
              } else {
                text = `Recent alerts (${alerts.length}):\n\n${formatAlertSummary(alerts)}`;
              }
            }
          } catch (e: any) {
            text = `❌ Failed to list: ${e.message}`;
          }
          break;
        }

        default:
          text = `Unknown action: ${(params as any).action}`;
      }

      return { content: [{ type: "text" as const, text }], details: undefined };
    },
  });
}
