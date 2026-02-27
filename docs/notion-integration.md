# Notion Integration

The Notion extension provides read-only access to your Notion workspace via the Notion REST API. This allows Baudbot agents to search for documentation, retrieve specifications, and query project databases during development work.

## Setup

### 1. Create a Notion Integration

1. Go to [Notion → My integrations](https://www.notion.so/my-integrations)
2. Click **"+ New integration"**
3. Give it a name (e.g., "Baudbot Agent")
4. Select the workspace where your documentation lives
5. Set capabilities to **Read content** only (no write access needed)
6. Submit and copy the **Internal Integration Token** (starts with `secret_`)

### 2. Share Pages with the Integration

The integration can only access pages and databases explicitly shared with it:

1. Navigate to the page or database you want the agent to access
2. Click **"•••"** (top right) → **Add connections**
3. Select your integration from the list
4. The integration now has read access to that page and all its child pages

Tip: Share a top-level workspace page to give access to all nested documentation.

### 3. Configure Baudbot

Add the integration token to `~/.config/.env`:

```bash
NOTION_API_KEY=secret_abc123...
```

Restart the control-agent to load the extension:

```bash
sudo baudbot stop
sudo baudbot start
```

## Usage

The `notion` tool provides four actions:

### Search for pages and databases

Find content by text query or filter by type:

```typescript
notion({
  action: "search",
  query: "deployment",  // optional search text
  filter: "page",       // optional: "page" or "database"
  limit: 20             // optional, default 20, max 100
})
```

Returns a list of matching pages/databases with titles, URLs, and last-edited dates.

**Example output:**
```
Found 3 result(s):

📄 How to deploy a new service
  URL: https://notion.so/How-to-deploy-...
  Last edited: 2026-02-15

🗂️ Deployment Tracker
  URL: https://notion.so/Deployment-Tracker-...
  Last edited: 2026-02-20

📄 CI/CD Pipeline Overview
  URL: https://notion.so/CI-CD-Pipeline-...
  Last edited: 2026-01-10
```

### Get full page content

Retrieve complete page content with all blocks formatted as markdown:

```typescript
notion({
  action: "get",
  page_id: "303d77b00f4480f9973fdcdd869caa94"  // from URL or search results
})
```

**Page ID extraction:**  
- URL: `https://notion.so/Page-Title-303d77b00f4480f9973fdcdd869caa94`
- Page ID: `303d77b00f4480f9973fdcdd869caa94` (last 32 hex characters)

The tool accepts IDs with or without hyphens.

**Supported block types:**
- Text blocks: paragraphs, headings (H1-H3), quotes
- Lists: bulleted, numbered, to-do (with checkboxes)
- Code blocks with syntax highlighting
- Callouts with emoji icons
- Toggles, dividers, breadcrumbs
- Child pages and databases (linked)
- Media: images, videos, files, PDFs, bookmarks, embeds
- Nested content (fetched up to 1 level deep)

**Example output:**
```
# API Authentication Guide
URL: https://notion.so/...
Last edited: 2026-02-20T15:30:00.000Z

## Overview

Our API uses JWT bearer tokens for authentication.

## Getting a Token

1. Log in to the dashboard
2. Navigate to Settings → API Keys
3. Click "Generate New Key"

⚠️ Keep your API key secret. Never commit it to version control.

## Making Requests

```bash
curl -H "Authorization: Bearer YOUR_TOKEN" \
     https://api.example.com/v1/resource
```

## Rate Limits

- 1000 requests per hour per token
- 10 requests per second burst limit
```

### Query database entries

List database rows with filtering and sorting:

```typescript
notion({
  action: "list",
  database_id: "abc123...",
  filter: '{"property": "Status", "status": {"equals": "In Progress"}}',  // optional JSON
  sorts: '[{"property": "Created", "direction": "descending"}]',           // optional JSON
  limit: 20
})
```

The filter and sorts parameters accept JSON strings matching [Notion's database query format](https://developers.notion.com/reference/post-database-query).

**Example output:**
```
5 entries:

📄 Fix login timeout bug
  Status: In Progress | Priority: High | Assignee: Alice
  URL: https://notion.so/...

📄 Add export feature
  Status: In Progress | Priority: Medium | Assignee: Bob
  URL: https://notion.so/...

📄 Update documentation
  Status: In Progress | Priority: Low | Assignee: Carol
  URL: https://notion.so/...
```

### Get database schema

Inspect database structure and property types:

```typescript
notion({
  action: "database",
  database_id: "abc123..."
})
```

**Example output:**
```
🗂️ Project Tasks
URL: https://notion.so/...

Properties:
  - Name (title)
  - Status (status)
  - Priority (select)
  - Assignee (people)
  - Due Date (date)
  - Tags (multi_select)
  - Completed (checkbox)
```

## Use Cases

### Documentation Lookup

Control-agent can retrieve setup guides, API references, and runbooks during task execution:

```typescript
// Agent searches for deployment docs
notion({ action: "search", query: "kubernetes deployment" })

// Retrieves the specific guide
notion({ action: "get", page_id: "..." })
```

### Project Context

Dev-agents can read specifications and architecture decision records:

```typescript
// Find the PRD for the feature being worked on
notion({ action: "search", query: "user authentication PRD" })

// Read the full specification
notion({ action: "get", page_id: "..." })
```

### Task Tracking

Query project databases for context on work items:

```typescript
// Check current sprint tasks
notion({
  action: "list",
  database_id: "...",
  filter: '{"property": "Sprint", "select": {"equals": "Sprint 23"}}'
})

// Get database structure for custom queries
notion({ action: "database", database_id: "..." })
```

## Limitations

### Read-Only Access

The integration provides read access only. The agent cannot:
- Create new pages or databases
- Update existing content
- Delete pages
- Add comments or mentions

This is intentional — documentation changes should go through human review.

### API Rate Limits

Notion's API has rate limits:
- 3 requests per second per integration
- Burst allowance for occasional spikes

The extension does not implement request throttling. If you hit rate limits, the tool will return an error. Control-agent should wait and retry.

### Pagination

Query results are limited to 100 items per request. The extension does not handle pagination automatically. For large databases:
- Use filters to narrow results
- Or make multiple queries with different filter criteria

### Block Nesting Depth

Child blocks are fetched only 1 level deep. If your pages have deeply nested content (e.g., toggles within toggles within toggles), the deepest levels won't be included.

To retrieve deep content:
- Flatten your documentation structure
- Or make multiple `get` calls for child pages

### Content Shared with Integration

The integration can only see pages and databases explicitly shared with it. If the agent can't find a page:
1. Verify the page exists and isn't archived
2. Check that the integration has been added to the page via **Add connections**
3. Check parent page permissions (child pages inherit access)

## Security

### Token Storage

The `NOTION_API_KEY` is stored in `~/.config/.env` with `600` permissions (readable only by the `baudbot_agent` user and root).

### Principle of Least Privilege

Only share the minimum necessary documentation with the integration:
- Don't share your entire workspace unless needed
- Share specific docs or a dedicated "Engineering Docs" section
- Review shared pages periodically

### Audit Log

Notion's workspace settings include an audit log showing all integration access. Review this regularly to ensure the agent is only accessing expected pages.

## Troubleshooting

### "NOTION_API_KEY not set"

The environment variable is missing or empty. Verify:
1. Token is in `~/.config/.env`
2. No typos in the variable name
3. Agent was restarted after adding the token

### "Notion API 401: Unauthorized"

The token is invalid or expired. Generate a new integration token and update `.env`.

### "Notion API 404: Not Found"

The page or database ID is incorrect, or the integration doesn't have access. Verify:
1. Page ID is correct (32 hex characters from the URL)
2. Page isn't archived
3. Integration has been added to the page

### "Notion API 429: Rate Limited"

Too many requests in a short period. The agent should wait 60 seconds before retrying.

### Empty search results

The integration can't see the pages. Make sure:
1. Pages are shared with the integration
2. Pages aren't in the trash
3. Search query matches page titles or content

## API Reference

For advanced use cases, refer to [Notion's official API documentation](https://developers.notion.com/reference/intro).

## Examples

### Load API documentation during a task

**Scenario:** Dev-agent needs to understand authentication before implementing a feature.

```typescript
// Search for auth docs
notion({ action: "search", query: "API authentication" })

// Read the guide
notion({ action: "get", page_id: "abc123..." })
```

### Check if a feature is already documented

**Scenario:** Before implementing, verify the feature isn't already described elsewhere.

```typescript
// Search for existing work
notion({ action: "search", query: "payment processing" })

// Review each result
notion({ action: "get", page_id: "..." })
```

### Query project roadmap database

**Scenario:** Control-agent checks upcoming priorities before allocating work.

```typescript
// Get all high-priority items
notion({
  action: "list",
  database_id: "...",
  filter: '{"property": "Priority", "select": {"equals": "High"}}',
  sorts: '[{"property": "Due Date", "direction": "ascending"}]'
})
```

## Contributing

If you add capabilities to the Notion extension (e.g., write operations, pagination, deeper nesting), update this documentation and submit a PR.

See [CONTRIBUTING.md](../CONTRIBUTING.md) for guidelines.
