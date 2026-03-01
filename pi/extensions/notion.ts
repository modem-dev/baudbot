import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";
import { Type } from "@sinclair/typebox";
import { StringEnum } from "@mariozechner/pi-ai";

/**
 * Notion Extension
 *
 * Provides a `notion` tool for reading from Notion workspace via REST API.
 * Supports searching pages, getting page content, querying databases, and
 * inspecting database schemas.
 *
 * Requires:
 *   NOTION_API_KEY — Notion integration secret (internal integration token)
 */

// ── Config ────────────────────────────────────────────────────────────────────

const NOTION_API_KEY = process.env.NOTION_API_KEY || "";
const NOTION_API_URL = "https://api.notion.com/v1";
const NOTION_VERSION = "2022-06-28";

// ── API helper ────────────────────────────────────────────────────────────────

async function notionRequest(endpoint: string, options: RequestInit = {}): Promise<any> {
	if (!NOTION_API_KEY) {
		throw new Error("NOTION_API_KEY not set. Add it to ~/.config/.env and restart.");
	}

	const url = `${NOTION_API_URL}${endpoint}`;
	const res = await fetch(url, {
		...options,
		headers: {
			Authorization: `Bearer ${NOTION_API_KEY}`,
			"Notion-Version": NOTION_VERSION,
			"Content-Type": "application/json",
			...options.headers,
		},
	});

	if (!res.ok) {
		const text = await res.text();
		throw new Error(`Notion API ${res.status}: ${text}`);
	}

	return await res.json();
}

// ── Content extractors ────────────────────────────────────────────────────────

function extractPlainText(richText: any[]): string {
	if (!richText || !Array.isArray(richText)) return "";
	return richText.map((rt: any) => rt.plain_text || "").join("");
}

function extractPageTitle(page: any): string {
	const props = page.properties || {};
	const titleProp = Object.values(props).find((p: any) => p.type === "title") as any;
	if (!titleProp?.title) return "(untitled)";
	return extractPlainText(titleProp.title);
}

function formatBlockContent(block: any, indent = 0): string {
	const prefix = "  ".repeat(indent);
	const type = block.type;
	const content = block[type];

	if (!content) return "";

	// Extract text from rich_text array
	let text = "";
	if (content.rich_text) {
		text = extractPlainText(content.rich_text);
	}

	switch (type) {
		case "paragraph":
			return text ? `${prefix}${text}` : "";
		case "heading_1":
			return `${prefix}# ${text}`;
		case "heading_2":
			return `${prefix}## ${text}`;
		case "heading_3":
			return `${prefix}### ${text}`;
		case "bulleted_list_item":
			return `${prefix}- ${text}`;
		case "numbered_list_item":
			return `${prefix}1. ${text}`;
		case "to_do": {
			const checked = content.checked ? "x" : " ";
			return `${prefix}- [${checked}] ${text}`;
		}
		case "toggle":
			return `${prefix}▸ ${text}`;
		case "quote":
			return `${prefix}> ${text}`;
		case "code": {
			const lang = content.language || "";
			return `${prefix}\`\`\`${lang}\n${text}\n${prefix}\`\`\``;
		}
		case "callout": {
			const emoji = content.icon?.emoji || "ℹ️";
			return `${prefix}${emoji} ${text}`;
		}
		case "divider":
			return `${prefix}---`;
		case "table_of_contents":
			return `${prefix}[Table of Contents]`;
		case "breadcrumb":
			return `${prefix}[Breadcrumb]`;
		case "column_list":
		case "column":
			return ""; // Handled by child blocks
		case "child_page":
			return `${prefix}📄 ${content.title}`;
		case "child_database":
			return `${prefix}🗂️ ${content.title}`;
		case "embed":
		case "image":
		case "video":
		case "file":
		case "pdf": {
			const url = content.url || content.file?.url || content.external?.url || "";
			return `${prefix}[${type}: ${url}]`;
		}
		case "bookmark":
			return `${prefix}🔖 ${content.url}`;
		case "equation":
			return `${prefix}[equation: ${content.expression}]`;
		case "link_preview":
			return `${prefix}🔗 ${content.url}`;
		default:
			return `${prefix}[${type}]`;
	}
}

function parseNotionId(rawId: string, fieldName: "page_id" | "database_id") {
	const normalizedId = rawId.replace(/-/g, "").trim();
	if (!/^[a-f0-9]{32}$/i.test(normalizedId)) {
		return { error: `❌ ${fieldName} must be a valid Notion ID (32 hex characters).` };
	}
	return { value: normalizedId };
}

// ── Action handlers ───────────────────────────────────────────────────────────

async function handleSearch(params: any): Promise<string> {
	const query = params.query || "";
	const limit = Math.min(params.limit || 20, 100);

	const body: any = {
		page_size: limit,
	};

	if (query) {
		body.query = query;
	}

	if (params.filter) {
		body.filter = { property: "object", value: params.filter };
	}

	const data = await notionRequest("/search", {
		method: "POST",
		body: JSON.stringify(body),
	});

	const results = data.results || [];
	if (results.length === 0) {
		return query ? `No results found for query: "${query}"` : "No pages found in workspace.";
	}

	const lines = results.map((item: any) => {
		const type = item.object;
		const title =
			type === "page" ? extractPageTitle(item) : item.title?.[0]?.plain_text || "(untitled)";
		const url = item.url;
		const lastEdited = item.last_edited_time?.split("T")[0] || "unknown";
		const icon = type === "database" ? "🗂️" : "📄";
		return `${icon} ${title}\n  URL: ${url}\n  Last edited: ${lastEdited}`;
	});

	return `Found ${results.length} result(s):\n\n${lines.join("\n\n")}`;
}

async function handleGet(params: any): Promise<string> {
	if (!params.page_id) return "❌ page_id is required for get action.";

	const parsedPageId = parseNotionId(params.page_id, "page_id");
	if (parsedPageId.error) return parsedPageId.error;
	const pageId = parsedPageId.value;

	// Get page metadata
	const page = await notionRequest(`/pages/${pageId}`);
	const title = extractPageTitle(page);
	const url = page.url;
	const lastEdited = page.last_edited_time;

	// Get page content (blocks)
	const blocksData = await notionRequest(`/blocks/${pageId}/children?page_size=100`);
	const blocks = blocksData.results || [];

	const contentLines: string[] = [];

	for (const block of blocks) {
		const line = formatBlockContent(block);
		if (line) contentLines.push(line);

		// If block has children, fetch them (up to 1 level deep for now)
		if (block.has_children && block.type !== "child_page" && block.type !== "child_database") {
			try {
				const childData = await notionRequest(`/blocks/${block.id}/children?page_size=100`);
				const children = childData.results || [];
				for (const child of children) {
					const childLine = formatBlockContent(child, 1);
					if (childLine) contentLines.push(childLine);
				}
			} catch (_e) {
				// Skip if we can't fetch children
			}
		}
	}

	const content = contentLines.length > 0 ? contentLines.join("\n") : "(empty page)";

	const output = [`# ${title}`, `URL: ${url}`, `Last edited: ${lastEdited}`, "", content].join(
		"\n",
	);

	return output;
}

async function handleList(params: any): Promise<string> {
	if (!params.database_id) return "❌ database_id is required for list action.";

	const parsedDatabaseId = parseNotionId(params.database_id, "database_id");
	if (parsedDatabaseId.error) return parsedDatabaseId.error;
	const databaseId = parsedDatabaseId.value;
	const limit = Math.min(params.limit || 20, 100);

	const body: any = {
		page_size: limit,
	};

	if (params.filter) {
		try {
			body.filter = JSON.parse(params.filter);
		} catch (_e) {
			return "❌ filter must be valid JSON (Notion filter object)";
		}
	}

	if (params.sorts) {
		try {
			body.sorts = JSON.parse(params.sorts);
		} catch (_e) {
			return "❌ sorts must be valid JSON array";
		}
	}

	const data = await notionRequest(`/databases/${databaseId}/query`, {
		method: "POST",
		body: JSON.stringify(body),
	});

	const results = data.results || [];
	if (results.length === 0) return "No entries found in database.";

	const lines = results.map((page: any) => {
		const title = extractPageTitle(page);
		const url = page.url;

		// Extract a few key properties
		const props = page.properties || {};
		const propLines: string[] = [];

		for (const [name, prop] of Object.entries(props) as [string, any][]) {
			if (prop.type === "title") continue; // Already shown

			let value = "";
			switch (prop.type) {
				case "rich_text":
					value = extractPlainText(prop.rich_text);
					break;
				case "number":
					value = String(prop.number || "");
					break;
				case "select":
					value = prop.select?.name || "";
					break;
				case "multi_select":
					value = (prop.multi_select || []).map((s: any) => s.name).join(", ");
					break;
				case "date":
					value = prop.date?.start || "";
					break;
				case "checkbox":
					value = prop.checkbox ? "✓" : "✗";
					break;
				case "url":
					value = prop.url || "";
					break;
				case "email":
					value = prop.email || "";
					break;
				case "phone_number":
					value = prop.phone_number || "";
					break;
				case "status":
					value = prop.status?.name || "";
					break;
			}

			if (value && propLines.length < 3) {
				// Limit to 3 properties for brevity
				propLines.push(`${name}: ${value}`);
			}
		}

		return `📄 ${title}\n  ${propLines.join(" | ")}\n  URL: ${url}`;
	});

	return `${results.length} entries:\n\n${lines.join("\n\n")}`;
}

async function handleDatabase(params: any): Promise<string> {
	if (!params.database_id) return "❌ database_id is required for database action.";

	const parsedDatabaseId = parseNotionId(params.database_id, "database_id");
	if (parsedDatabaseId.error) return parsedDatabaseId.error;
	const databaseId = parsedDatabaseId.value;

	const db = await notionRequest(`/databases/${databaseId}`);

	const title = db.title?.[0]?.plain_text || "(untitled database)";
	const url = db.url;
	const props = db.properties || {};

	const propLines = Object.entries(props).map(([name, prop]: [string, any]) => {
		return `  - ${name} (${prop.type})`;
	});

	const output = [`🗂️ ${title}`, `URL: ${url}`, "", "Properties:", ...propLines].join("\n");

	return output;
}

// ── Extension ─────────────────────────────────────────────────────────────────

export default function (pi: ExtensionAPI) {
	pi.registerTool({
		name: "notion",
		label: "Notion",
		description:
			"Read from Notion workspace. " +
			"Actions: search (find pages/databases by query), get (read page content by ID), " +
			"list (query database entries), database (get database schema).",
		parameters: Type.Object({
			action: StringEnum(["search", "get", "list", "database"] as const),
			query: Type.Optional(Type.String({ description: "Search query text (for search)" })),
			page_id: Type.Optional(
				Type.String({
					description: "Page ID (UUID from URL, with or without hyphens) (for get)",
				}),
			),
			database_id: Type.Optional(
				Type.String({ description: "Database ID (UUID from URL) (for list/database)" }),
			),
			filter: Type.Optional(
				Type.String({
					description:
						"Filter: 'page' or 'database' (for search), or JSON filter object (for list)",
				}),
			),
			sorts: Type.Optional(Type.String({ description: "JSON array of sort objects (for list)" })),
			limit: Type.Optional(
				Type.Number({ description: "Max results to return (default 20, max 100)" }),
			),
		}),

		async execute(_toolCallId, params, _signal, _onUpdate, _ctx) {
			let text: string;

			try {
				switch (params.action) {
					case "search":
						text = await handleSearch(params);
						break;
					case "get":
						text = await handleGet(params);
						break;
					case "list":
						text = await handleList(params);
						break;
					case "database":
						text = await handleDatabase(params);
						break;
					default:
						text = `Unknown action: ${(params as any).action}`;
				}
			} catch (e: any) {
				text = `❌ ${e.message}`;
			}

			return { content: [{ type: "text" as const, text }], details: undefined };
		},
	});
}
