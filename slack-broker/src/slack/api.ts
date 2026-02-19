/**
 * Slack Web API helpers.
 *
 * Used by the broker to post messages, add reactions, and update messages.
 * These are the minimum API calls needed for the outbound path.
 *
 * SECURITY: Message content is only held transiently in memory.
 * After calling Slack's API, callers should zero any plaintext buffers.
 */

export interface SlackApiResult {
  ok: boolean;
  ts?: string;
  error?: string;
}

/**
 * Post a message to a Slack channel.
 */
export async function postMessage(
  botToken: string,
  channel: string,
  text: string,
  options?: {
    thread_ts?: string;
    blocks?: unknown[];
  },
): Promise<SlackApiResult> {
  const body: Record<string, unknown> = {
    channel,
    text,
  };

  if (options?.thread_ts) body.thread_ts = options.thread_ts;
  if (options?.blocks) body.blocks = options.blocks;

  return callSlackApi(botToken, "chat.postMessage", body);
}

/**
 * Add a reaction to a message.
 */
export async function addReaction(
  botToken: string,
  channel: string,
  timestamp: string,
  emoji: string,
): Promise<SlackApiResult> {
  return callSlackApi(botToken, "reactions.add", {
    channel,
    timestamp,
    name: emoji,
  });
}

/**
 * Update an existing message.
 */
export async function updateMessage(
  botToken: string,
  channel: string,
  timestamp: string,
  text: string,
  options?: {
    blocks?: unknown[];
  },
): Promise<SlackApiResult> {
  const body: Record<string, unknown> = {
    channel,
    ts: timestamp,
    text,
  };

  if (options?.blocks) body.blocks = options.blocks;

  return callSlackApi(botToken, "chat.update", body);
}

/**
 * Generic Slack Web API caller.
 */
async function callSlackApi(
  botToken: string,
  method: string,
  body: Record<string, unknown>,
): Promise<SlackApiResult> {
  try {
    const response = await fetch(`https://slack.com/api/${method}`, {
      method: "POST",
      headers: {
        "Authorization": `Bearer ${botToken}`,
        "Content-Type": "application/json; charset=utf-8",
      },
      body: JSON.stringify(body),
    });

    const data = (await response.json()) as SlackApiResult;
    return data;
  } catch (err) {
    const message = err instanceof Error ? err.message : "unknown error";
    return { ok: false, error: `slack api call failed: ${message}` };
  }
}
