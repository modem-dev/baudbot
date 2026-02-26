/**
 * GitHub webhook event formatting and filtering for the broker bridge.
 *
 * Pure functions — no side effects, no env vars, no I/O.
 * The bridge imports these and wires them into the message pipeline.
 */

import { wrapExternalContent } from "./security.mjs";

// ── Security Boundary Wrapping ──────────────────────────────────────────────

/**
 * Wrap a GitHub event message with security boundaries.
 *
 * Uses shared security wrapping (notice + marker sanitization + boundaries)
 * with GitHub-specific metadata (Repo, Event, Ref, Actor).
 */
export function wrapGitHubContent({ body, repo, event, action, actor, ref }) {
  const metadataLines = [
    `Repo: ${repo}`,
    `Event: ${event}${action ? ` (${action})` : ""}`,
    ...(ref ? [`Ref: ${ref}`] : []),
    ...(actor ? [`Actor: ${actor}`] : []),
  ];

  return wrapExternalContent({
    text: body,
    source: "GitHub",
    metadataLines,
  });
}

// ── Filtering ───────────────────────────────────────────────────────────────

const DEFAULT_IGNORED_USERS = ["baudbot-agent"];

/**
 * Parse GITHUB_IGNORED_USERS env var into a Set of login names.
 * Always includes "baudbot-agent" to prevent loops.
 */
export function parseIgnoredUsers(envValue) {
  const extra = (envValue || "")
    .split(",")
    .map((s) => s.trim().toLowerCase())
    .filter(Boolean);
  return new Set([...DEFAULT_IGNORED_USERS.map((u) => u.toLowerCase()), ...extra]);
}

/**
 * Extract the actor login from a GitHub webhook payload.
 * Different event types store the actor in different fields.
 */
export function extractActor(type, payload) {
  if (!payload || typeof payload !== "object") return null;

  // Most events have a top-level sender
  if (payload.sender?.login) return payload.sender.login;

  // push events use pusher.name
  if (type === "push" && payload.pusher?.name) return payload.pusher.name;

  return null;
}

/**
 * Determine if a GitHub event should be skipped (filtered out).
 * Returns a reason string if skipped, or null if the event should be processed.
 */
export function shouldSkipEvent(type, payload, ignoredUsers) {
  const actor = extractActor(type, payload);

  // Skip events from ignored users (bot loop prevention)
  if (actor && ignoredUsers.has(actor.toLowerCase())) {
    return `ignored user: ${actor}`;
  }

  const action = payload?.action;

  // Skip noisy check_suite lifecycle events (only care about completed)
  if (type === "check_suite" && (action === "requested" || action === "created" || action === "rerequested")) {
    return `check_suite action: ${action}`;
  }

  // Skip noisy check_run lifecycle events (only care about completed)
  if (type === "check_run" && (action === "requested" || action === "created" || action === "rerequested")) {
    return `check_run action: ${action}`;
  }

  // Skip pull_request synchronize (force-push noise)
  if (type === "pull_request" && action === "synchronize") {
    return "pull_request action: synchronize";
  }

  return null;
}

// ── Event Formatting ────────────────────────────────────────────────────────

function repoName(payload) {
  return payload?.repository?.full_name || "unknown/repo";
}

function truncate(text, maxLen = 200) {
  if (!text || typeof text !== "string") return "";
  const oneLine = text.replace(/\r?\n/g, " ").trim();
  if (oneLine.length <= maxLen) return oneLine;
  return `${oneLine.slice(0, maxLen)}…`;
}

function formatPullRequest(payload) {
  const pr = payload.pull_request;
  if (!pr) return null;

  const repo = repoName(payload);
  const action = payload.action;
  const merged = action === "closed" && pr.merged;
  const displayAction = merged ? "merged" : action;
  const actor = pr.user?.login || extractActor("pull_request", payload) || "unknown";

  const lines = [
    `PR #${pr.number}: ${truncate(pr.title, 120)}`,
    `Action: ${displayAction}`,
    `Author: ${actor}`,
    pr.html_url ? `URL: ${pr.html_url}` : null,
  ].filter(Boolean);

  return wrapGitHubContent({
    body: lines.join("\n"),
    repo,
    event: "pull_request",
    action: displayAction,
    actor,
    ref: pr.head?.ref,
  });
}

function formatPullRequestReview(payload) {
  const review = payload.review;
  const pr = payload.pull_request;
  if (!review || !pr) return null;

  const repo = repoName(payload);
  const actor = review.user?.login || extractActor("pull_request_review", payload) || "unknown";
  const state = review.state || "unknown"; // approved, changes_requested, commented

  const lines = [
    `PR #${pr.number}: ${truncate(pr.title, 120)}`,
    `Review: ${state}`,
    `Reviewer: ${actor}`,
    review.body ? `Comment: ${truncate(review.body, 300)}` : null,
    review.html_url ? `URL: ${review.html_url}` : null,
  ].filter(Boolean);

  return wrapGitHubContent({
    body: lines.join("\n"),
    repo,
    event: "pull_request_review",
    action: state,
    actor,
    ref: `#${pr.number}`,
  });
}

function formatIssueComment(payload) {
  const comment = payload.comment;
  if (!comment) return null;

  const repo = repoName(payload);
  const actor = comment.user?.login || extractActor("issue_comment", payload) || "unknown";
  // issue_comment fires for both issues and PRs; the payload has .issue
  const issue = payload.issue;
  const number = issue?.number || "?";
  const isPR = Boolean(issue?.pull_request);

  const lines = [
    `${isPR ? "PR" : "Issue"} #${number}: ${truncate(issue?.title, 120)}`,
    `Commenter: ${actor}`,
    comment.body ? `Body: ${truncate(comment.body, 300)}` : null,
    comment.html_url ? `URL: ${comment.html_url}` : null,
  ].filter(Boolean);

  return wrapGitHubContent({
    body: lines.join("\n"),
    repo,
    event: "issue_comment",
    action: payload.action || "created",
    actor,
    ref: `#${number}`,
  });
}

function formatCheckSuite(payload) {
  const suite = payload.check_suite;
  if (!suite) return null;

  const repo = repoName(payload);
  const conclusion = suite.conclusion || suite.status || "unknown";
  const branch = suite.head_branch || "unknown";
  const actor = extractActor("check_suite", payload) || "unknown";

  const prInfo = suite.pull_requests?.[0];
  const lines = [
    `Conclusion: ${conclusion}`,
    `Branch: ${branch}`,
    prInfo ? `PR: #${prInfo.number}` : null,
    prInfo?.url ? `PR URL: ${prInfo.url}` : null,
  ].filter(Boolean);

  return wrapGitHubContent({
    body: lines.join("\n"),
    repo,
    event: "check_suite",
    action: conclusion,
    actor,
    ref: branch,
  });
}

function formatCheckRun(payload) {
  const run = payload.check_run;
  if (!run) return null;

  const repo = repoName(payload);
  const conclusion = run.conclusion || run.status || "unknown";
  const name = run.name || "unknown";
  const actor = extractActor("check_run", payload) || "unknown";

  const prInfo = run.pull_requests?.[0];
  const lines = [
    `Check: ${name}`,
    `Conclusion: ${conclusion}`,
    prInfo ? `PR: #${prInfo.number}` : null,
    run.html_url ? `URL: ${run.html_url}` : null,
  ].filter(Boolean);

  return wrapGitHubContent({
    body: lines.join("\n"),
    repo,
    event: "check_run",
    action: conclusion,
    actor,
    ref: prInfo ? `#${prInfo.number}` : undefined,
  });
}

function formatPush(payload) {
  const repo = repoName(payload);
  const ref = payload.ref || "unknown";
  const branch = ref.replace(/^refs\/heads\//, "");
  const actor = payload.pusher?.name || extractActor("push", payload) || "unknown";
  const commits = Array.isArray(payload.commits) ? payload.commits : [];

  const commitSummaries = commits
    .slice(0, 5)
    .map((c) => `• ${c.id?.slice(0, 7) || "?"} ${truncate(c.message, 80)}`)
    .join("\n");

  const lines = [
    `Branch: ${branch}`,
    `Pusher: ${actor}`,
    `Commits: ${commits.length}`,
    commitSummaries || null,
    commits.length > 5 ? `  … and ${commits.length - 5} more` : null,
    payload.compare ? `Compare: ${payload.compare}` : null,
  ].filter(Boolean);

  return wrapGitHubContent({
    body: lines.join("\n"),
    repo,
    event: "push",
    action: null,
    actor,
    ref: branch,
  });
}

/**
 * Format a GitHub webhook event into a security-wrapped message for the agent.
 *
 * Returns { message, isPing, isUnknown } where:
 * - message: the formatted string to send (null for ping events)
 * - isPing: true if this was a ping event (no message needed)
 * - isUnknown: true if the event type is not explicitly handled
 */
export function formatGitHubEvent(type, payload) {
  if (type === "ping") {
    return { message: null, isPing: true, isUnknown: false };
  }

  const formatters = {
    pull_request: formatPullRequest,
    pull_request_review: formatPullRequestReview,
    issue_comment: formatIssueComment,
    check_suite: formatCheckSuite,
    check_run: formatCheckRun,
    push: formatPush,
  };

  const formatter = formatters[type];
  if (formatter) {
    const message = formatter(payload);
    return { message, isPing: false, isUnknown: false };
  }

  // Unknown event type — build a minimal summary
  const repo = repoName(payload);
  const actor = extractActor(type, payload) || "unknown";
  const preview = truncate(JSON.stringify(payload), 200);

  const message = wrapGitHubContent({
    body: `Unhandled event type. Payload preview:\n${preview}`,
    repo,
    event: type,
    action: payload?.action || null,
    actor,
  });

  return { message, isPing: false, isUnknown: true };
}
