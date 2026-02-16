/**
 * Kernel Browser Extension
 *
 * Provides tools for cloud browser automation via Kernel (kernel.sh).
 * Requires KERNEL_API_KEY environment variable.
 *
 * Tools:
 *   kernel_browser     - Create, list, and delete cloud browser sessions
 *   kernel_playwright  - Execute Playwright code against a browser
 *   kernel_screenshot  - Capture a screenshot of the browser
 *   kernel_computer    - Low-level mouse/keyboard/scroll actions
 *
 * Commands:
 *   /kernel            - List active browser sessions and manage them
 */

import type { ExtensionAPI, ExtensionContext } from "@mariozechner/pi-coding-agent";
import { Type, } from "@sinclair/typebox";
import { StringEnum } from "@mariozechner/pi-ai";
import Kernel from "@onkernel/sdk";

// ---------------------------------------------------------------------------
// Client
// ---------------------------------------------------------------------------

function getClient(): Kernel {
	const apiKey = process.env.KERNEL_API_KEY;
	if (!apiKey) {
		throw new Error(
			"KERNEL_API_KEY environment variable is not set. Get one at https://app.onkernel.com",
		);
	}
	return new Kernel({ apiKey });
}

// ---------------------------------------------------------------------------
// State — track the "active" browser so tools default to it
// ---------------------------------------------------------------------------

let activeBrowserId: string | undefined;
let _activeLiveViewUrl: string | undefined;

function formatBrowser(b: {
	session_id: string;
	stealth?: boolean;
	headless?: boolean;
	browser_live_view_url?: string;
	created_at?: string;
	timeout_seconds?: number;
	profile?: { name?: string } | null;
}): string {
	const parts = [`id: ${b.session_id}`];
	if (b.stealth) parts.push("stealth");
	if (b.headless) parts.push("headless");
	if (b.profile?.name) parts.push(`profile: ${b.profile.name}`);
	if (b.browser_live_view_url) parts.push(`live: ${b.browser_live_view_url}`);
	if (b.timeout_seconds) parts.push(`timeout: ${b.timeout_seconds}s`);
	if (b.created_at) parts.push(`created: ${b.created_at}`);
	return parts.join(" | ");
}

// ---------------------------------------------------------------------------
// Extension
// ---------------------------------------------------------------------------

export default function (pi: ExtensionAPI) {
	// -------------------------------------------------------------------
	// kernel_browser — create / list / get / delete
	// -------------------------------------------------------------------

	pi.registerTool({
		name: "kernel_browser",
		label: "Kernel Browser",
		description:
			"Manage Kernel cloud browsers. Actions: create (launch a new browser), list (show active sessions), get (get session info), delete (terminate a session). After creating a browser, use kernel_playwright to automate it.",
		parameters: Type.Object({
			action: StringEnum(["create", "list", "get", "delete"] as const, {
				description: "Action to perform",
			}),
			session_id: Type.Optional(
				Type.String({ description: "Browser session ID (for get/delete). Omit to use the active browser." }),
			),
			stealth: Type.Optional(
				Type.Boolean({ description: "Enable stealth mode (default true)" }),
			),
			headless: Type.Optional(
				Type.Boolean({ description: "Headless mode — no live view (default false)" }),
			),
			timeout_seconds: Type.Optional(
				Type.Number({ description: "Inactivity timeout in seconds (default 300)" }),
			),
			profile: Type.Optional(
				Type.String({ description: "Profile name to load (for create)" }),
			),
		}),
		async execute(_id, params, signal) {
			const client = getClient();

			switch (params.action) {
				case "create": {
					const createParams: Record<string, unknown> = {
						stealth: params.stealth ?? true,
						headless: params.headless ?? false,
					};
					if (params.timeout_seconds) createParams.timeout_seconds = params.timeout_seconds;
					if (params.profile) createParams.profile = { name: params.profile };

					const browser = await client.browsers.create(createParams as any);
					activeBrowserId = browser.session_id;
					_activeLiveViewUrl = browser.browser_live_view_url ?? undefined;

					return {
						content: [
							{
								type: "text",
								text: `Browser created and set as active.\n${formatBrowser(browser)}`,
							},
						],
						details: { browser },
					};
				}

				case "list": {
					const browsers: any[] = [];
					for await (const b of client.browsers.list()) {
						browsers.push(b);
					}
					if (browsers.length === 0) {
						return { content: [{ type: "text", text: "No active browser sessions." }] };
					}
					const lines = browsers.map(
						(b, i) =>
							`${b.session_id === activeBrowserId ? "→ " : "  "}${i + 1}. ${formatBrowser(b)}`,
					);
					return {
						content: [
							{
								type: "text",
								text: `${browsers.length} browser session(s):\n${lines.join("\n")}`,
							},
						],
						details: { browsers },
					};
				}

				case "get": {
					const sid = params.session_id ?? activeBrowserId;
					if (!sid) {
						return {
							content: [{ type: "text", text: "No session_id provided and no active browser." }],
							isError: true,
						};
					}
					const browser = await client.browsers.retrieve(sid);
					return {
						content: [{ type: "text", text: formatBrowser(browser) }],
						details: { browser },
					};
				}

				case "delete": {
					const sid = params.session_id ?? activeBrowserId;
					if (!sid) {
						return {
							content: [{ type: "text", text: "No session_id provided and no active browser." }],
							isError: true,
						};
					}
					await client.browsers.deleteByID(sid);
					if (sid === activeBrowserId) {
						activeBrowserId = undefined;
						_activeLiveViewUrl = undefined;
					}
					return {
						content: [{ type: "text", text: `Browser ${sid} deleted.` }],
					};
				}

				default:
					return { content: [{ type: "text", text: `Unknown action: ${params.action}` }], isError: true };
			}
		},
	});

	// -------------------------------------------------------------------
	// kernel_playwright — execute Playwright code
	// -------------------------------------------------------------------

	pi.registerTool({
		name: "kernel_playwright",
		label: "Kernel Playwright",
		description:
			'Execute Playwright TypeScript code against a Kernel browser. The code runs server-side with access to `page`, `context`, and `browser` variables. Use `return` to send a value back. Example: `await page.goto("https://example.com"); return await page.title();`',
		parameters: Type.Object({
			code: Type.String({ description: "Playwright TypeScript code to execute" }),
			session_id: Type.Optional(
				Type.String({ description: "Browser session ID. Omit to use the active browser." }),
			),
			timeout_sec: Type.Optional(
				Type.Number({ description: "Execution timeout in seconds (default 60)" }),
			),
		}),
		async execute(_id, params, signal) {
			const client = getClient();
			const sid = params.session_id ?? activeBrowserId;
			if (!sid) {
				return {
					content: [
						{
							type: "text",
							text: "No browser session. Create one first with kernel_browser (action: create).",
						},
					],
					isError: true,
				};
			}

			const execParams: any = { code: params.code };
			if (params.timeout_sec) execParams.timeout_sec = params.timeout_sec;

			const result = await client.browsers.playwright.execute(sid, execParams);

			if (!result.success) {
				const errMsg = [result.error, result.stderr].filter(Boolean).join("\n");
				return {
					content: [{ type: "text", text: `Playwright execution failed:\n${errMsg}` }],
					details: { result },
					isError: true,
				};
			}

			const parts: string[] = [];
			if (result.result !== undefined && result.result !== null) {
				parts.push(
					typeof result.result === "string"
						? result.result
						: JSON.stringify(result.result, null, 2),
				);
			}
			if (result.stdout) parts.push(`stdout:\n${result.stdout}`);
			if (result.stderr) parts.push(`stderr:\n${result.stderr}`);

			return {
				content: [{ type: "text", text: parts.join("\n\n") || "Executed successfully (no output)." }],
				details: { result },
			};
		},
	});

	// -------------------------------------------------------------------
	// kernel_screenshot — capture screenshot
	// -------------------------------------------------------------------

	pi.registerTool({
		name: "kernel_screenshot",
		label: "Kernel Screenshot",
		description:
			"Capture a screenshot of the current browser page. Returns the image for visual inspection.",
		parameters: Type.Object({
			session_id: Type.Optional(
				Type.String({ description: "Browser session ID. Omit to use the active browser." }),
			),
		}),
		async execute(_id, params, signal) {
			const client = getClient();
			const sid = params.session_id ?? activeBrowserId;
			if (!sid) {
				return {
					content: [{ type: "text", text: "No browser session. Create one first." }],
					isError: true,
				};
			}

			const response = await client.browsers.computer.captureScreenshot(sid);
			const arrayBuf = await response.arrayBuffer();
			const base64 = Buffer.from(arrayBuf).toString("base64");

			return {
				content: [
					{
						type: "image",
						mimeType: "image/png",
						data: base64,
					} as any,
					{ type: "text", text: "Screenshot captured." },
				],
				details: { session_id: sid, size: arrayBuf.byteLength },
			};
		},
	});

	// -------------------------------------------------------------------
	// kernel_computer — low-level mouse/keyboard
	// -------------------------------------------------------------------

	pi.registerTool({
		name: "kernel_computer",
		label: "Kernel Computer",
		description:
			"Perform low-level computer actions on a Kernel browser: click, type, press key, scroll, move mouse, drag, or get mouse position. Use kernel_screenshot to see the result.",
		parameters: Type.Object({
			action: StringEnum(
				["click", "type", "press_key", "scroll", "move_mouse", "drag", "get_mouse_position"] as const,
				{ description: "Computer action to perform" },
			),
			session_id: Type.Optional(
				Type.String({ description: "Browser session ID. Omit to use the active browser." }),
			),
			x: Type.Optional(Type.Number({ description: "X coordinate (for click, move, drag start)" })),
			y: Type.Optional(Type.Number({ description: "Y coordinate (for click, move, drag start)" })),
			end_x: Type.Optional(Type.Number({ description: "End X coordinate (for drag)" })),
			end_y: Type.Optional(Type.Number({ description: "End Y coordinate (for drag)" })),
			text: Type.Optional(Type.String({ description: "Text to type" })),
			key: Type.Optional(
				Type.String({ description: 'Key to press (e.g. "Enter", "Tab", "Escape", "a")' }),
			),
			button: Type.Optional(
				StringEnum(["left", "right", "middle"] as const, { description: "Mouse button (default left)" }),
			),
			scroll_x: Type.Optional(Type.Number({ description: "Horizontal scroll amount" })),
			scroll_y: Type.Optional(Type.Number({ description: "Vertical scroll amount" })),
		}),
		async execute(_id, params, signal) {
			const client = getClient();
			const sid = params.session_id ?? activeBrowserId;
			if (!sid) {
				return {
					content: [{ type: "text", text: "No browser session. Create one first." }],
					isError: true,
				};
			}

			switch (params.action) {
				case "click": {
					if (params.x == null || params.y == null) {
						return { content: [{ type: "text", text: "click requires x and y" }], isError: true };
					}
					await client.browsers.computer.clickMouse(sid, {
						x: params.x,
						y: params.y,
						button: params.button ?? "left",
					});
					return { content: [{ type: "text", text: `Clicked at (${params.x}, ${params.y})` }] };
				}

				case "type": {
					if (!params.text) {
						return { content: [{ type: "text", text: "type requires text" }], isError: true };
					}
					await client.browsers.computer.typeText(sid, { text: params.text });
					return { content: [{ type: "text", text: `Typed: "${params.text}"` }] };
				}

				case "press_key": {
					if (!params.key) {
						return { content: [{ type: "text", text: "press_key requires key" }], isError: true };
					}
					await client.browsers.computer.pressKey(sid, { key: params.key });
					return { content: [{ type: "text", text: `Pressed key: ${params.key}` }] };
				}

				case "scroll": {
					await client.browsers.computer.scroll(sid, {
						x: params.x ?? 0,
						y: params.y ?? 0,
						scroll_x: params.scroll_x ?? 0,
						scroll_y: params.scroll_y ?? 0,
					});
					return {
						content: [
							{
								type: "text",
								text: `Scrolled (${params.scroll_x ?? 0}, ${params.scroll_y ?? 0}) at (${params.x ?? 0}, ${params.y ?? 0})`,
							},
						],
					};
				}

				case "move_mouse": {
					if (params.x == null || params.y == null) {
						return { content: [{ type: "text", text: "move_mouse requires x and y" }], isError: true };
					}
					await client.browsers.computer.moveMouse(sid, { x: params.x, y: params.y });
					return { content: [{ type: "text", text: `Moved mouse to (${params.x}, ${params.y})` }] };
				}

				case "drag": {
					if (params.x == null || params.y == null || params.end_x == null || params.end_y == null) {
						return {
							content: [{ type: "text", text: "drag requires x, y, end_x, end_y" }],
							isError: true,
						};
					}
					await client.browsers.computer.dragMouse(sid, {
						start_x: params.x,
						start_y: params.y,
						end_x: params.end_x,
						end_y: params.end_y,
					});
					return {
						content: [
							{
								type: "text",
								text: `Dragged from (${params.x}, ${params.y}) to (${params.end_x}, ${params.end_y})`,
							},
						],
					};
				}

				case "get_mouse_position": {
					const pos = await client.browsers.computer.getMousePosition(sid);
					return { content: [{ type: "text", text: `Mouse at (${pos.x}, ${pos.y})` }] };
				}

				default:
					return { content: [{ type: "text", text: `Unknown action: ${params.action}` }], isError: true };
			}
		},
	});

	// -------------------------------------------------------------------
	// /kernel command — interactive session management
	// -------------------------------------------------------------------

	pi.registerCommand("kernel", {
		description: "List and manage Kernel browser sessions",
		handler: async (args, ctx) => {
			if (!process.env.KERNEL_API_KEY) {
				ctx.ui.notify("KERNEL_API_KEY not set", "error");
				return;
			}

			const client = getClient();

			try {
				const browsers: any[] = [];
				for await (const b of client.browsers.list()) {
					browsers.push(b);
				}

				if (browsers.length === 0) {
					ctx.ui.notify("No active Kernel browser sessions", "info");
					return;
				}

				const items = browsers.map((b) => ({
					value: b.session_id,
					label: `${b.session_id === activeBrowserId ? "● " : "  "}${b.session_id}`,
					description: [
						b.stealth ? "stealth" : "",
						b.headless ? "headless" : "gui",
						b.profile?.name ? `profile:${b.profile.name}` : "",
					]
						.filter(Boolean)
						.join(", "),
				}));

				const selected = await ctx.ui.select("Kernel Browsers (select to set active):", items);
				if (selected) {
					activeBrowserId = selected;
					const match = browsers.find((b: any) => b.session_id === selected);
					_activeLiveViewUrl = match?.browser_live_view_url ?? undefined;
					ctx.ui.notify(`Active browser: ${selected}`, "info");
				}
			} catch (err: any) {
				ctx.ui.notify(`Kernel error: ${err.message}`, "error");
			}
		},
	});

	// -------------------------------------------------------------------
	// Status widget — show active browser
	// -------------------------------------------------------------------

	function updateWidget(ctx: ExtensionContext) {
		if (!ctx.hasUI) return;
		if (activeBrowserId) {
			const text = `Kernel: ${activeBrowserId.slice(0, 12)}…`;
			ctx.ui.setStatus("kernel", ctx.ui.theme.fg("accent", text));
		} else {
			ctx.ui.setStatus("kernel", undefined);
		}
	}

	// -------------------------------------------------------------------
	// Cleanup on shutdown
	// -------------------------------------------------------------------

	pi.on("session_shutdown", async () => {
		// Don't auto-delete browsers on shutdown — they may be long-lived
		// Just clear local state
		activeBrowserId = undefined;
		_activeLiveViewUrl = undefined;
	});

	// -------------------------------------------------------------------
	// Restore state on session start (from tool results in history)
	// -------------------------------------------------------------------

	pi.on("session_start", async (_event, ctx) => {
		for (const entry of ctx.sessionManager.getEntries()) {
			const e = entry as any;
			if (e.type === "message" && e.message?.role === "toolResult") {
				if (e.message.toolName === "kernel_browser" && e.message.details?.browser?.session_id) {
					activeBrowserId = e.message.details.browser.session_id;
					_activeLiveViewUrl = e.message.details.browser.browser_live_view_url ?? undefined;
				}
			}
		}
		updateWidget(ctx);
	});
}
