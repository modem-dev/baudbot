import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";
import { Type } from "@sinclair/typebox";
import { StringEnum } from "@mariozechner/pi-ai";

/**
 * Linear Extension
 *
 * Provides a `linear` tool for interacting with the Linear issue tracker
 * via their GraphQL API. Supports searching, listing, creating, updating
 * issues and adding comments.
 *
 * Requires:
 *   LINEAR_API_KEY — Linear API key (personal or OAuth token)
 */

// ── Config ────────────────────────────────────────────────────────────────────

const LINEAR_API_KEY = process.env.LINEAR_API_KEY || "";
const LINEAR_API_URL = "https://api.linear.app/graphql";

// ── GraphQL helper ────────────────────────────────────────────────────────────

async function linearQuery(query: string, variables: Record<string, any> = {}): Promise<any> {
  if (!LINEAR_API_KEY) {
    throw new Error("LINEAR_API_KEY not set. Add it to ~/.config/.env and restart.");
  }

  const res = await fetch(LINEAR_API_URL, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: LINEAR_API_KEY,
    },
    body: JSON.stringify({ query, variables }),
  });

  if (!res.ok) {
    const text = await res.text();
    throw new Error(`Linear API ${res.status}: ${text}`);
  }

  const json = await res.json();
  if (json.errors?.length) {
    throw new Error(`Linear GraphQL error: ${json.errors.map((e: any) => e.message).join("; ")}`);
  }
  return json.data;
}

// ── Formatters ────────────────────────────────────────────────────────────────

function priorityLabel(p: number | null | undefined): string {
  switch (p) {
    case 0: return "None";
    case 1: return "Urgent";
    case 2: return "High";
    case 3: return "Medium";
    case 4: return "Low";
    default: return "—";
  }
}

function formatIssueCompact(issue: any): string {
  const assignee = issue.assignee?.name || issue.assignee?.displayName || "unassigned";
  const status = issue.state?.name || "unknown";
  const prio = priorityLabel(issue.priority);
  return `${issue.identifier}  ${issue.title}\n  Status: ${status} | Priority: ${prio} | Assignee: ${assignee}`;
}

function formatIssueDetail(issue: any, comments?: any[]): string {
  const assignee = issue.assignee?.name || issue.assignee?.displayName || "unassigned";
  const status = issue.state?.name || "unknown";
  const prio = priorityLabel(issue.priority);
  const labels = (issue.labels?.nodes || []).map((l: any) => l.name).join(", ") || "none";
  const team = issue.team?.name || "—";

  let desc = issue.description || "(no description)";
  if (desc.length > 500) desc = desc.slice(0, 500) + "…";

  const lines: string[] = [
    `**${issue.identifier}**: ${issue.title}`,
    `Status: ${status} | Priority: ${prio} | Assignee: ${assignee}`,
    `Team: ${team} | Labels: ${labels}`,
    `URL: ${issue.url}`,
    `Created: ${issue.createdAt} | Updated: ${issue.updatedAt}`,
    "",
    `Description:\n${desc}`,
  ];

  if (comments && comments.length > 0) {
    lines.push("", `Last ${comments.length} comment(s):`);
    for (const c of comments) {
      const author = c.user?.name || c.user?.displayName || "unknown";
      const body = c.body?.length > 200 ? c.body.slice(0, 200) + "…" : (c.body || "");
      lines.push(`  [${c.createdAt}] ${author}: ${body}`);
    }
  }

  return lines.join("\n");
}

// ── Action handlers ───────────────────────────────────────────────────────────

async function handleSearch(params: any): Promise<string> {
  if (!params.query) return "❌ query is required for search action.";

  const limit = params.limit || 20;

  // Build filter for status if provided
  let filterClause = "";
  if (params.status) {
    filterClause = `, filter: { state: { name: { eqCaseInsensitive: "${params.status}" } } }`;
  }

  const data = await linearQuery(`
    query SearchIssues($query: String!, $first: Int!) {
      issueSearch(query: $query, first: $first${filterClause}) {
        nodes {
          identifier
          title
          priority
          state { name }
          assignee { name displayName }
        }
      }
    }
  `, { query: params.query, first: limit });

  const issues = data.issueSearch?.nodes || [];
  if (issues.length === 0) return `No issues found for query: "${params.query}"`;

  const lines = issues.map(formatIssueCompact);
  return `Found ${issues.length} issue(s):\n\n${lines.join("\n\n")}`;
}

async function handleGet(params: any): Promise<string> {
  if (!params.issue_id) return "❌ issue_id is required for get action (e.g. \"MOD-123\").";

  // Linear's issueSearch can find by identifier; use it to resolve
  const searchData = await linearQuery(`
    query GetByIdentifier($query: String!) {
      issueSearch(query: $query, first: 1) {
        nodes {
          id
          identifier
          title
          description
          priority
          url
          createdAt
          updatedAt
          state { name }
          assignee { name displayName }
          team { name }
          labels { nodes { name } }
          comments(first: 5, orderBy: createdAt) {
            nodes {
              id
              body
              createdAt
              user { name displayName }
            }
          }
        }
      }
    }
  `, { query: params.issue_id });

  const issues = searchData.issueSearch?.nodes || [];
  if (issues.length === 0) return `❌ Issue not found: ${params.issue_id}`;

  const issue = issues[0];
  const comments = issue.comments?.nodes || [];
  return formatIssueDetail(issue, comments);
}

async function handleList(params: any): Promise<string> {
  const limit = params.limit || 20;
  const filters: string[] = [];

  if (params.status) {
    filters.push(`state: { name: { eqCaseInsensitive: "${params.status}" } }`);
  }
  if (params.assignee) {
    filters.push(`assignee: { name: { eqCaseInsensitive: "${params.assignee}" } }`);
  }
  if (params.team) {
    filters.push(`team: { name: { eqCaseInsensitive: "${params.team}" } }`);
  }
  if (params.label) {
    filters.push(`labels: { name: { eqCaseInsensitive: "${params.label}" } }`);
  }

  const filterArg = filters.length > 0 ? `, filter: { ${filters.join(", ")} }` : "";

  const data = await linearQuery(`
    query ListIssues($first: Int!) {
      issues(first: $first${filterArg}, orderBy: updatedAt) {
        nodes {
          identifier
          title
          priority
          state { name }
          assignee { name displayName }
        }
      }
    }
  `, { first: limit });

  const issues = data.issues?.nodes || [];
  if (issues.length === 0) return "No issues found matching the given filters.";

  const lines = issues.map(formatIssueCompact);
  return `${issues.length} issue(s):\n\n${lines.join("\n\n")}`;
}

async function handleCreate(params: any): Promise<string> {
  if (!params.title) return "❌ title is required for create action.";
  if (!params.team_id) return "❌ team_id is required for create action.";

  const input: Record<string, any> = {
    title: params.title,
    teamId: params.team_id,
  };
  if (params.description) input.description = params.description;
  if (params.priority !== undefined && params.priority !== null) input.priority = params.priority;
  if (params.label_ids) input.labelIds = params.label_ids;

  const data = await linearQuery(`
    mutation CreateIssue($input: IssueCreateInput!) {
      issueCreate(input: $input) {
        success
        issue {
          identifier
          title
          url
          state { name }
        }
      }
    }
  `, { input });

  const result = data.issueCreate;
  if (!result?.success) return "❌ Failed to create issue.";

  const issue = result.issue;
  return `✅ Created ${issue.identifier}: ${issue.title}\nStatus: ${issue.state?.name || "—"}\nURL: ${issue.url}`;
}

async function handleUpdate(params: any): Promise<string> {
  if (!params.issue_id) return "❌ issue_id is required for update action.";

  // Resolve identifier to UUID via search
  const searchData = await linearQuery(`
    query Resolve($query: String!) {
      issueSearch(query: $query, first: 1) {
        nodes { id identifier }
      }
    }
  `, { query: params.issue_id });

  const found = searchData.issueSearch?.nodes?.[0];
  if (!found) return `❌ Issue not found: ${params.issue_id}`;

  const input: Record<string, any> = {};
  if (params.status) input.stateId = params.status; // caller provides state UUID
  if (params.priority !== undefined && params.priority !== null) input.priority = params.priority;
  if (params.assignee_id) input.assigneeId = params.assignee_id;

  if (Object.keys(input).length === 0) return "❌ Nothing to update. Provide status, priority, or assignee_id.";

  const data = await linearQuery(`
    mutation UpdateIssue($id: String!, $input: IssueUpdateInput!) {
      issueUpdate(id: $id, input: $input) {
        success
        issue {
          identifier
          title
          state { name }
          priority
          assignee { name displayName }
        }
      }
    }
  `, { id: found.id, input });

  const result = data.issueUpdate;
  if (!result?.success) return "❌ Failed to update issue.";

  const issue = result.issue;
  return `✅ Updated ${issue.identifier}: ${issue.title}\nStatus: ${issue.state?.name || "—"} | Priority: ${priorityLabel(issue.priority)} | Assignee: ${issue.assignee?.name || "unassigned"}`;
}

async function handleComment(params: any): Promise<string> {
  if (!params.issue_id) return "❌ issue_id is required for comment action.";
  if (!params.body) return "❌ body is required for comment action.";

  // Resolve identifier to UUID via search
  const searchData = await linearQuery(`
    query Resolve($query: String!) {
      issueSearch(query: $query, first: 1) {
        nodes { id identifier }
      }
    }
  `, { query: params.issue_id });

  const found = searchData.issueSearch?.nodes?.[0];
  if (!found) return `❌ Issue not found: ${params.issue_id}`;

  const data = await linearQuery(`
    mutation CreateComment($input: CommentCreateInput!) {
      commentCreate(input: $input) {
        success
        comment {
          id
          createdAt
        }
      }
    }
  `, { input: { issueId: found.id, body: params.body } });

  const result = data.commentCreate;
  if (!result?.success) return "❌ Failed to create comment.";

  return `✅ Comment added to ${found.identifier} (comment ID: ${result.comment.id})`;
}

// ── Extension ─────────────────────────────────────────────────────────────────

export default function (pi: ExtensionAPI) {
  pi.registerTool({
    name: "linear",
    label: "Linear",
    description:
      "Interact with Linear issue tracker. " +
      "Actions: search (text search), get (issue details by identifier like MOD-123), " +
      "list (filter by status/assignee/team/label), create (new issue), " +
      "update (change status/priority/assignee), comment (add comment to issue).",
    parameters: Type.Object({
      action: StringEnum(["search", "get", "list", "create", "update", "comment"] as const),
      query: Type.Optional(Type.String({ description: "Search query text (for search)" })),
      issue_id: Type.Optional(
        Type.String({ description: "Issue identifier, e.g. 'MOD-123' (for get/update/comment)" })
      ),
      status: Type.Optional(
        Type.String({ description: "Filter by status name, e.g. 'In Progress' (for search/list), or state ID (for update)" })
      ),
      assignee: Type.Optional(
        Type.String({ description: "Filter by assignee name (for list)" })
      ),
      assignee_id: Type.Optional(
        Type.String({ description: "Assignee user ID (for update)" })
      ),
      team: Type.Optional(
        Type.String({ description: "Filter by team name (for list)" })
      ),
      team_id: Type.Optional(
        Type.String({ description: "Team ID (required for create)" })
      ),
      label: Type.Optional(
        Type.String({ description: "Filter by label name (for list)" })
      ),
      label_ids: Type.Optional(
        Type.Array(Type.String(), { description: "Label IDs to apply (for create)" })
      ),
      title: Type.Optional(
        Type.String({ description: "Issue title (required for create)" })
      ),
      description: Type.Optional(
        Type.String({ description: "Issue description (for create)" })
      ),
      body: Type.Optional(
        Type.String({ description: "Comment body text (required for comment)" })
      ),
      priority: Type.Optional(
        Type.Number({ description: "Priority: 0=None, 1=Urgent, 2=High, 3=Medium, 4=Low (for create/update)" })
      ),
      limit: Type.Optional(
        Type.Number({ description: "Max results to return (default 20, for search/list)" })
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
          case "create":
            text = await handleCreate(params);
            break;
          case "update":
            text = await handleUpdate(params);
            break;
          case "comment":
            text = await handleComment(params);
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
