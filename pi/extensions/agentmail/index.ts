/**
 * AgentMail Extension
 *
 * Provides email tools for sending, receiving, and managing emails via AgentMail.
 * Requires AGENTMAIL_API_KEY environment variable.
 *
 * Tools:
 *   agentmail_inbox    - Create, list, get, and delete inboxes
 *   agentmail_send     - Send an email, reply, reply-all, or forward
 *   agentmail_messages - List and read messages in an inbox
 *   agentmail_threads  - List and read email threads
 *   agentmail_search   - Search messages by label, date range, or sender
 *
 * Commands:
 *   /mail              - Check inbox and browse recent messages
 */

import type { ExtensionAPI, ExtensionContext } from "@mariozechner/pi-coding-agent";
import { Type } from "@sinclair/typebox";
import { StringEnum } from "@mariozechner/pi-ai";
import { AgentMailClient } from "agentmail";

// ---------------------------------------------------------------------------
// Client
// ---------------------------------------------------------------------------

function getClient(): AgentMailClient {
	const apiKey = process.env.AGENTMAIL_API_KEY;
	if (!apiKey) {
		throw new Error(
			"AGENTMAIL_API_KEY environment variable is not set. Get one at https://app.agentmail.to",
		);
	}
	return new AgentMailClient({ apiKey });
}

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

let activeInboxId: string | undefined;
let _activeInboxAddress: string | undefined;

function formatInbox(inbox: any): string {
	const parts = [`id: ${inbox.inboxId}`];
	if (inbox.displayName) parts.push(`name: ${inbox.displayName}`);
	// Derive address from inboxId (it's the email address)
	parts.push(`address: ${inbox.inboxId}`);
	if (inbox.createdAt) parts.push(`created: ${new Date(inbox.createdAt).toISOString()}`);
	return parts.join(" | ");
}

function formatMessage(msg: any): string {
	const parts: string[] = [];
	parts.push(`id: ${msg.messageId}`);
	if (msg.from) parts.push(`from: ${msg.from}`);
	if (msg.to?.length) parts.push(`to: ${msg.to.join(", ")}`);
	if (msg.subject) parts.push(`subject: ${msg.subject}`);
	if (msg.timestamp) parts.push(`date: ${new Date(msg.timestamp).toISOString()}`);
	if (msg.preview) parts.push(`preview: ${msg.preview.slice(0, 120)}`);
	return parts.join(" | ");
}

function formatThread(thread: any): string {
	const parts: string[] = [];
	parts.push(`id: ${thread.threadId}`);
	if (thread.subject) parts.push(`subject: ${thread.subject}`);
	if (thread.senders?.length) parts.push(`from: ${thread.senders.join(", ")}`);
	parts.push(`messages: ${thread.messageCount ?? "?"}`);
	if (thread.timestamp) parts.push(`date: ${new Date(thread.timestamp).toISOString()}`);
	if (thread.preview) parts.push(`preview: ${thread.preview.slice(0, 120)}`);
	return parts.join(" | ");
}

// ---------------------------------------------------------------------------
// Extension
// ---------------------------------------------------------------------------

export default function (pi: ExtensionAPI) {
	// -------------------------------------------------------------------
	// agentmail_inbox — create / list / get / delete
	// -------------------------------------------------------------------

	pi.registerTool({
		name: "agentmail_inbox",
		label: "AgentMail Inbox",
		description:
			"Manage AgentMail inboxes. Actions: create (create a new inbox with an email address), list (list all inboxes), get (get inbox details), delete (delete an inbox). After creating an inbox, use agentmail_send to send emails and agentmail_messages to read them.",
		parameters: Type.Object({
			action: StringEnum(["create", "list", "get", "delete"] as const, {
				description: "Action to perform",
			}),
			inbox_id: Type.Optional(
				Type.String({
					description: "Inbox ID (for get/delete). Omit to use the active inbox.",
				}),
			),
			username: Type.Optional(
				Type.String({
					description: "Username for the email address (for create). Randomly generated if not specified.",
				}),
			),
			domain: Type.Optional(
				Type.String({
					description: "Domain for the email address (for create). Defaults to agentmail.to.",
				}),
			),
			display_name: Type.Optional(
				Type.String({
					description: "Display name for the inbox (for create).",
				}),
			),
		}),
		async execute(_id, params, _signal) {
			const client = getClient();

			switch (params.action) {
				case "create": {
					const createParams: any = {};
					if (params.username) createParams.username = params.username;
					if (params.domain) createParams.domain = params.domain;
					if (params.display_name) createParams.displayName = params.display_name;

					const inbox = await client.inboxes.create(createParams);
					activeInboxId = inbox.inboxId;

					return {
						content: [
							{
								type: "text",
								text: `Inbox created and set as active.\n${formatInbox(inbox)}`,
							},
						],
						details: { inbox },
					};
				}

				case "list": {
					const response = await client.inboxes.list();
					const inboxes = response.inboxes ?? [];
					if (inboxes.length === 0) {
						return { content: [{ type: "text", text: "No inboxes found." }] };
					}
					const lines = inboxes.map(
						(inbox: any, i: number) =>
							`${inbox.inboxId === activeInboxId ? "→ " : "  "}${i + 1}. ${formatInbox(inbox)}`,
					);
					return {
						content: [
							{
								type: "text",
								text: `${inboxes.length} inbox(es):\n${lines.join("\n")}`,
							},
						],
						details: { inboxes },
					};
				}

				case "get": {
					const id = params.inbox_id ?? activeInboxId;
					if (!id) {
						return {
							content: [{ type: "text", text: "No inbox_id provided and no active inbox." }],
							isError: true,
						};
					}
					const inbox = await client.inboxes.get(id);
					return {
						content: [{ type: "text", text: formatInbox(inbox) }],
						details: { inbox },
					};
				}

				case "delete": {
					const id = params.inbox_id ?? activeInboxId;
					if (!id) {
						return {
							content: [{ type: "text", text: "No inbox_id provided and no active inbox." }],
							isError: true,
						};
					}
					await client.inboxes.delete(id);
					if (id === activeInboxId) {
						activeInboxId = undefined;
						_activeInboxAddress = undefined;
					}
					return {
						content: [{ type: "text", text: `Inbox ${id} deleted.` }],
					};
				}

				default:
					return { content: [{ type: "text", text: `Unknown action: ${params.action}` }], isError: true };
			}
		},
	});

	// -------------------------------------------------------------------
	// agentmail_send — send / reply / reply-all / forward
	// -------------------------------------------------------------------

	pi.registerTool({
		name: "agentmail_send",
		label: "AgentMail Send",
		description:
			"Send an email from an AgentMail inbox. Actions: send (compose new email), reply (reply to a message), reply_all (reply to all recipients), forward (forward a message). Requires an active inbox or explicit inbox_id.",
		parameters: Type.Object({
			action: StringEnum(["send", "reply", "reply_all", "forward"] as const, {
				description: "Action to perform",
			}),
			inbox_id: Type.Optional(
				Type.String({ description: "Inbox ID to send from. Omit to use the active inbox." }),
			),
			message_id: Type.Optional(
				Type.String({ description: "Message ID to reply to or forward (required for reply/reply_all/forward)." }),
			),
			to: Type.Optional(
				Type.Array(Type.String(), {
					description: 'Recipients in format "email@example.com" or "Name <email@example.com>".',
				}),
			),
			cc: Type.Optional(
				Type.Array(Type.String(), { description: "CC recipients." }),
			),
			bcc: Type.Optional(
				Type.Array(Type.String(), { description: "BCC recipients." }),
			),
			subject: Type.Optional(
				Type.String({ description: "Email subject (for send/forward)." }),
			),
			text: Type.Optional(
				Type.String({ description: "Plain text body." }),
			),
			html: Type.Optional(
				Type.String({ description: "HTML body." }),
			),
		}),
		async execute(_id, params, _signal) {
			const client = getClient();
			const inboxId = params.inbox_id ?? activeInboxId;
			if (!inboxId) {
				return {
					content: [
						{
							type: "text",
							text: "No inbox. Create one first with agentmail_inbox (action: create).",
						},
					],
					isError: true,
				};
			}

			switch (params.action) {
				case "send": {
					const sendParams: any = {};
					if (params.to) sendParams.to = params.to;
					if (params.cc) sendParams.cc = params.cc;
					if (params.bcc) sendParams.bcc = params.bcc;
					if (params.subject) sendParams.subject = params.subject;
					if (params.text) sendParams.text = params.text;
					if (params.html) sendParams.html = params.html;

					const result = await client.inboxes.messages.send(inboxId, sendParams);
					return {
						content: [
							{
								type: "text",
								text: `Email sent. Message ID: ${result.messageId}, Thread ID: ${result.threadId}`,
							},
						],
						details: { result },
					};
				}

				case "reply": {
					if (!params.message_id) {
						return {
							content: [{ type: "text", text: "reply requires message_id" }],
							isError: true,
						};
					}
					const replyParams: any = {};
					if (params.to) replyParams.to = params.to;
					if (params.cc) replyParams.cc = params.cc;
					if (params.bcc) replyParams.bcc = params.bcc;
					if (params.text) replyParams.text = params.text;
					if (params.html) replyParams.html = params.html;

					const result = await client.inboxes.messages.reply(inboxId, params.message_id, replyParams);
					return {
						content: [
							{
								type: "text",
								text: `Reply sent. Message ID: ${result.messageId}, Thread ID: ${result.threadId}`,
							},
						],
						details: { result },
					};
				}

				case "reply_all": {
					if (!params.message_id) {
						return {
							content: [{ type: "text", text: "reply_all requires message_id" }],
							isError: true,
						};
					}
					const replyAllParams: any = {};
					if (params.text) replyAllParams.text = params.text;
					if (params.html) replyAllParams.html = params.html;

					const result = await client.inboxes.messages.replyAll(inboxId, params.message_id, replyAllParams);
					return {
						content: [
							{
								type: "text",
								text: `Reply-all sent. Message ID: ${result.messageId}, Thread ID: ${result.threadId}`,
							},
						],
						details: { result },
					};
				}

				case "forward": {
					if (!params.message_id) {
						return {
							content: [{ type: "text", text: "forward requires message_id" }],
							isError: true,
						};
					}
					const fwdParams: any = {};
					if (params.to) fwdParams.to = params.to;
					if (params.cc) fwdParams.cc = params.cc;
					if (params.bcc) fwdParams.bcc = params.bcc;
					if (params.subject) fwdParams.subject = params.subject;
					if (params.text) fwdParams.text = params.text;
					if (params.html) fwdParams.html = params.html;

					const result = await client.inboxes.messages.forward(inboxId, params.message_id, fwdParams);
					return {
						content: [
							{
								type: "text",
								text: `Forwarded. Message ID: ${result.messageId}, Thread ID: ${result.threadId}`,
							},
						],
						details: { result },
					};
				}

				default:
					return { content: [{ type: "text", text: `Unknown action: ${params.action}` }], isError: true };
			}
		},
	});

	// -------------------------------------------------------------------
	// agentmail_messages — list / get messages
	// -------------------------------------------------------------------

	pi.registerTool({
		name: "agentmail_messages",
		label: "AgentMail Messages",
		description:
			"Read emails from an AgentMail inbox. Actions: list (list recent messages), get (get full message content including body). Use get to read the actual email text/html content.",
		parameters: Type.Object({
			action: StringEnum(["list", "get"] as const, {
				description: "Action to perform",
			}),
			inbox_id: Type.Optional(
				Type.String({ description: "Inbox ID. Omit to use the active inbox." }),
			),
			message_id: Type.Optional(
				Type.String({ description: "Message ID (required for get)." }),
			),
			limit: Type.Optional(
				Type.Number({ description: "Max messages to return (for list, default 20)." }),
			),
			labels: Type.Optional(
				Type.Array(Type.String(), {
					description: 'Filter by labels, e.g. ["inbox", "unread"] (for list).',
				}),
			),
		}),
		async execute(_id, params, _signal) {
			const client = getClient();
			const inboxId = params.inbox_id ?? activeInboxId;
			if (!inboxId) {
				return {
					content: [{ type: "text", text: "No inbox. Create or select one first." }],
					isError: true,
				};
			}

			switch (params.action) {
				case "list": {
					const listParams: any = {};
					if (params.limit) listParams.limit = params.limit;
					if (params.labels) listParams.labels = params.labels;

					const response = await client.inboxes.messages.list(inboxId, listParams);
					const messages = response.messages ?? [];
					if (messages.length === 0) {
						return { content: [{ type: "text", text: "No messages." }] };
					}
					const lines = messages.map(
						(msg: any, i: number) => `${i + 1}. ${formatMessage(msg)}`,
					);
					return {
						content: [
							{
								type: "text",
								text: `${messages.length} message(s) (of ${response.count} total):\n${lines.join("\n")}`,
							},
						],
						details: { messages, count: response.count },
					};
				}

				case "get": {
					if (!params.message_id) {
						return {
							content: [{ type: "text", text: "get requires message_id" }],
							isError: true,
						};
					}
					const msg = await client.inboxes.messages.get(inboxId, params.message_id);
					const parts: string[] = [];
					parts.push(`From: ${msg.from}`);
					if (msg.to?.length) parts.push(`To: ${msg.to.join(", ")}`);
					if (msg.cc?.length) parts.push(`CC: ${msg.cc.join(", ")}`);
					if (msg.subject) parts.push(`Subject: ${msg.subject}`);
					parts.push(`Date: ${new Date(msg.timestamp).toISOString()}`);
					if (msg.labels?.length) parts.push(`Labels: ${msg.labels.join(", ")}`);
					parts.push("---");

					// Prefer extracted text (just the new content), fall back to full text, then html
					if (msg.extractedText) {
						parts.push(msg.extractedText);
					} else if (msg.text) {
						parts.push(msg.text);
					} else if (msg.extractedHtml) {
						parts.push(msg.extractedHtml);
					} else if (msg.html) {
						parts.push(msg.html);
					} else {
						parts.push("(no body)");
					}

					if (msg.attachments?.length) {
						parts.push("---");
						parts.push(`Attachments (${msg.attachments.length}):`);
						for (const att of msg.attachments) {
							parts.push(`  - ${att.filename ?? att.attachmentId} (${att.contentType ?? "unknown"}, ${att.size} bytes)`);
						}
					}

					return {
						content: [{ type: "text", text: parts.join("\n") }],
						details: { message: msg },
					};
				}

				default:
					return { content: [{ type: "text", text: `Unknown action: ${params.action}` }], isError: true };
			}
		},
	});

	// -------------------------------------------------------------------
	// agentmail_threads — list / get threads
	// -------------------------------------------------------------------

	pi.registerTool({
		name: "agentmail_threads",
		label: "AgentMail Threads",
		description:
			"View email threads (conversations) in an AgentMail inbox. Actions: list (list recent threads), get (get full thread with all messages).",
		parameters: Type.Object({
			action: StringEnum(["list", "get"] as const, {
				description: "Action to perform",
			}),
			inbox_id: Type.Optional(
				Type.String({ description: "Inbox ID. Omit to use the active inbox." }),
			),
			thread_id: Type.Optional(
				Type.String({ description: "Thread ID (required for get)." }),
			),
			limit: Type.Optional(
				Type.Number({ description: "Max threads to return (for list, default 20)." }),
			),
		}),
		async execute(_id, params, _signal) {
			const client = getClient();
			const inboxId = params.inbox_id ?? activeInboxId;
			if (!inboxId) {
				return {
					content: [{ type: "text", text: "No inbox. Create or select one first." }],
					isError: true,
				};
			}

			switch (params.action) {
				case "list": {
					const listParams: any = {};
					if (params.limit) listParams.limit = params.limit;

					const response = await client.inboxes.threads.list(inboxId, listParams);
					const threads = response.threads ?? [];
					if (threads.length === 0) {
						return { content: [{ type: "text", text: "No threads." }] };
					}
					const lines = threads.map(
						(thread: any, i: number) => `${i + 1}. ${formatThread(thread)}`,
					);
					return {
						content: [
							{
								type: "text",
								text: `${threads.length} thread(s) (of ${response.count} total):\n${lines.join("\n")}`,
							},
						],
						details: { threads, count: response.count },
					};
				}

				case "get": {
					if (!params.thread_id) {
						return {
							content: [{ type: "text", text: "get requires thread_id" }],
							isError: true,
						};
					}
					const thread = await client.inboxes.threads.get(inboxId, params.thread_id);
					const parts: string[] = [];
					parts.push(`Thread: ${thread.threadId}`);
					if (thread.subject) parts.push(`Subject: ${thread.subject}`);
					parts.push(`Messages: ${thread.messageCount}`);
					parts.push("");

					for (const msg of thread.messages ?? []) {
						parts.push(`--- Message ${msg.messageId} ---`);
						parts.push(`From: ${msg.from}`);
						if (msg.to?.length) parts.push(`To: ${msg.to.join(", ")}`);
						parts.push(`Date: ${new Date(msg.timestamp).toISOString()}`);
						parts.push("");
						if (msg.extractedText) {
							parts.push(msg.extractedText);
						} else if (msg.text) {
							parts.push(msg.text);
						} else if (msg.html) {
							parts.push(msg.html);
						}
						parts.push("");
					}

					return {
						content: [{ type: "text", text: parts.join("\n") }],
						details: { thread },
					};
				}

				default:
					return { content: [{ type: "text", text: `Unknown action: ${params.action}` }], isError: true };
			}
		},
	});

	// -------------------------------------------------------------------
	// /mail command — interactive inbox browser
	// -------------------------------------------------------------------

	pi.registerCommand("mail", {
		description: "Check inbox and browse recent messages",
		handler: async (args, ctx) => {
			if (!process.env.AGENTMAIL_API_KEY) {
				ctx.ui.notify("AGENTMAIL_API_KEY not set", "error");
				return;
			}

			const client = getClient();

			try {
				// List inboxes
				const inboxResponse = await client.inboxes.list();
				const inboxes = inboxResponse.inboxes ?? [];

				if (inboxes.length === 0) {
					ctx.ui.notify("No inboxes. Use agentmail_inbox to create one.", "info");
					return;
				}

				// Select inbox
				let selectedInboxId: string | undefined;
				if (inboxes.length === 1) {
					selectedInboxId = inboxes[0].inboxId;
				} else {
					const items = inboxes.map((inbox: any) => ({
						value: inbox.inboxId,
						label: `${inbox.inboxId === activeInboxId ? "● " : "  "}${inbox.inboxId}`,
						description: inbox.displayName ?? "",
					}));

					selectedInboxId = await ctx.ui.select("Select inbox:", items) ?? undefined;
				}

				if (!selectedInboxId) return;
				activeInboxId = selectedInboxId;

				// List recent messages
				const msgResponse = await client.inboxes.messages.list(selectedInboxId, { limit: 10 });
				const messages = msgResponse.messages ?? [];

				if (messages.length === 0) {
					ctx.ui.notify(`Inbox ${selectedInboxId}: no messages`, "info");
					return;
				}

				const items = messages.map((msg: any) => ({
					value: msg.messageId,
					label: `${msg.from ?? "unknown"} — ${msg.subject ?? "(no subject)"}`,
					description: msg.preview?.slice(0, 80) ?? "",
				}));

				const selectedMsgId = await ctx.ui.select(
					`${messages.length} message(s) in ${selectedInboxId}:`,
					items,
				);

				if (selectedMsgId) {
					// Show the message
					const msg = await client.inboxes.messages.get(selectedInboxId, selectedMsgId);
					const body = msg.extractedText ?? msg.text ?? msg.html ?? "(no body)";
					ctx.ui.notify(
						`From: ${msg.from}\nSubject: ${msg.subject ?? "(none)"}\n\n${body.slice(0, 500)}`,
						"info",
					);
				}
			} catch (err: any) {
				ctx.ui.notify(`AgentMail error: ${err.message}`, "error");
			}
		},
	});

	// -------------------------------------------------------------------
	// Status widget
	// -------------------------------------------------------------------

	function updateWidget(ctx: ExtensionContext) {
		if (!ctx.hasUI) return;
		if (activeInboxId) {
			const text = `✉ ${activeInboxId}`;
			ctx.ui.setStatus("agentmail", ctx.ui.theme.fg("accent", text));
		} else {
			ctx.ui.setStatus("agentmail", undefined);
		}
	}

	// -------------------------------------------------------------------
	// Restore state on session start
	// -------------------------------------------------------------------

	pi.on("session_start", async (_event, ctx) => {
		for (const entry of ctx.sessionManager.getEntries()) {
			const e = entry as any;
			if (e.type === "message" && e.message?.role === "toolResult") {
				if (e.message.toolName === "agentmail_inbox" && e.message.details?.inbox?.inboxId) {
					activeInboxId = e.message.details.inbox.inboxId;
				}
			}
		}
		updateWidget(ctx);
	});

	// -------------------------------------------------------------------
	// Cleanup on shutdown
	// -------------------------------------------------------------------

	pi.on("session_shutdown", async () => {
		activeInboxId = undefined;
		_activeInboxAddress = undefined;
	});
}
