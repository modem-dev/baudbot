/**
 * Baudbot Dashboard Extension
 *
 * Renders a persistent status widget above the editor showing:
 *   • System health: versions, bridge, sessions, todos, worktrees, heartbeat
 *   • Control-agent activity feed: live stream of what the control-agent is doing
 *
 * The activity feed tails the control-agent's JSONL session file and shows
 * recent assistant text, tool calls, and incoming messages. If this IS the
 * control-agent session, it hooks events directly instead of file-watching.
 *
 * Refreshes health metrics every 30 seconds with zero LLM token cost.
 * Use /dashboard to force an immediate refresh.
 */

import type { ExtensionAPI, ExtensionContext } from "@mariozechner/pi-coding-agent";
import { truncateToWidth, visibleWidth } from "@mariozechner/pi-tui";
import {
  existsSync, readdirSync, readFileSync, readlinkSync, statSync,
  watch as fsWatch, openSync, readSync, fstatSync, closeSync,
} from "node:fs";
import { homedir } from "node:os";
import { join, basename } from "node:path";
import { execSync } from "node:child_process";

const REFRESH_INTERVAL_MS = 30_000;
const SOCKET_DIR = join(homedir(), ".pi", "session-control");
const SESSION_DIR = join(homedir(), ".pi", "agent", "sessions");
const WORKTREES_DIR = join(homedir(), "workspace", "worktrees");
const TODOS_DIR = join(homedir(), ".pi", "todos");
const BRIDGE_URL = "http://127.0.0.1:7890/send";
const BAUDBOT_DEPLOY = "/opt/baudbot";

const ACTIVITY_BUFFER_SIZE = 8; // max lines in activity feed

// ── Data types ──────────────────────────────────────────────────────────────

interface LastEvent {
  source: string;
  summary: string;
  time: Date;
}

interface HeartbeatInfo {
  enabled: boolean;
  lastRunAt: number | null;
  totalRuns: number;
  healthy: boolean;
}

interface ActivityLine {
  time: Date;
  icon: string;     // "💬" "🔧" "📥" "📝" "🤔" etc (for themed rendering)
  type: "text" | "tool" | "incoming" | "thinking" | "compaction";
  text: string;
}

interface DashboardData {
  piVersion: string;
  piLatest: string | null;
  baudbotVersion: string | null;
  baudbotSha: string | null;
  bridgeUp: boolean;
  bridgeType: string | null;
  sessions: { name: string; alive: boolean }[];
  devAgentCount: number;
  devAgentNames: string[];
  todosInProgress: number;
  todosDone: number;
  todosTotal: number;
  worktreeCount: number;
  uptimeMs: number;
  lastRefresh: Date;
  heartbeat: HeartbeatInfo;
  lastEvent: LastEvent | null;
}

// ── Data collectors ─────────────────────────────────────────────────────────

function getBaudbotVersion(): { version: string | null; sha: string | null } {
  try {
    const currentLink = join(BAUDBOT_DEPLOY, "current");
    const target = readlinkSync(currentLink);
    const sha = target.split("/").pop() ?? null;
    let version: string | null = null;
    try {
      const pkg = JSON.parse(readFileSync(join(currentLink, "package.json"), "utf-8"));
      version = pkg.version ?? null;
    } catch {}
    return { version, sha: sha ? sha.substring(0, 7) : null };
  } catch {
    return { version: null, sha: null };
  }
}

function getPiVersion(): string {
  try {
    const prefix = join(process.execPath, "..", "..");
    const piPkg = join(prefix, "lib", "node_modules", "@mariozechner", "pi-coding-agent", "package.json");
    const pkg = JSON.parse(readFileSync(piPkg, "utf-8"));
    return pkg.version ?? "?";
  } catch {
    return "?";
  }
}

let cachedLatestVersion: string | null = null;
let lastVersionCheck = 0;
const VERSION_CHECK_INTERVAL = 3600_000;

async function getPiLatestVersion(): Promise<string | null> {
  const now = Date.now();
  if (cachedLatestVersion && now - lastVersionCheck < VERSION_CHECK_INTERVAL) {
    return cachedLatestVersion;
  }
  try {
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 5000);
    const res = await fetch("https://registry.npmjs.org/@mariozechner/pi-coding-agent/latest", {
      signal: controller.signal,
    });
    clearTimeout(timeout);
    if (res.ok) {
      const data = (await res.json()) as { version?: string };
      cachedLatestVersion = data.version ?? null;
      lastVersionCheck = now;
    }
  } catch {}
  return cachedLatestVersion;
}

function detectBridgeType(): string | null {
  try {
    const out = execSync("ps -eo args", {
      encoding: "utf-8", timeout: 3000,
    }).trim();
    if (out.includes("broker-bridge")) return "broker";
    if (out.includes("bridge.mjs")) return "socket";
    return null;
  } catch {
    return null;
  }
}

async function checkBridge(): Promise<boolean> {
  try {
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 3000);
    const res = await fetch(BRIDGE_URL, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: "{}",
      signal: controller.signal,
    });
    clearTimeout(timeout);
    return res.status === 400;
  } catch {
    return false;
  }
}

function getSessions(): { name: string; alive: boolean }[] {
  const results: { name: string; alive: boolean }[] = [];
  const expected = ["control-agent", "sentry-agent"];
  try {
    const files = readdirSync(SOCKET_DIR);
    const aliases = files.filter((f) => f.endsWith(".alias"));
    for (const alias of expected) {
      const aliasFile = `${alias}.alias`;
      if (!aliases.includes(aliasFile)) {
        results.push({ name: alias, alive: false });
        continue;
      }
      try {
        const target = readlinkSync(join(SOCKET_DIR, aliasFile));
        const sockPath = join(SOCKET_DIR, target);
        results.push({ name: alias, alive: existsSync(sockPath) });
      } catch {
        results.push({ name: alias, alive: false });
      }
    }
  } catch {
    for (const alias of expected) {
      results.push({ name: alias, alive: false });
    }
  }
  return results;
}

function getDevAgents(): { count: number; names: string[] } {
  try {
    const files = readdirSync(SOCKET_DIR);
    const agents = files
      .filter((f) => f.endsWith(".alias") && f.startsWith("dev-agent-"))
      .map((f) => f.replace(".alias", ""));
    return { count: agents.length, names: agents };
  } catch {
    return { count: 0, names: [] };
  }
}

function getTodoStats(): { inProgress: number; done: number; total: number } {
  let inProgress = 0;
  let done = 0;
  let total = 0;
  if (!existsSync(TODOS_DIR)) return { inProgress, done, total };
  try {
    const files = readdirSync(TODOS_DIR).filter((f) => f.endsWith(".md"));
    total = files.length;
    for (const file of files) {
      try {
        const content = readFileSync(join(TODOS_DIR, file), "utf-8");
        if (content.includes('"status": "in-progress"')) inProgress++;
        else if (content.includes('"status": "done"')) done++;
      } catch { continue; }
    }
  } catch {}
  return { inProgress, done, total };
}

function getWorktreeCount(): number {
  if (!existsSync(WORKTREES_DIR)) return 0;
  try {
    return readdirSync(WORKTREES_DIR).filter((entry) => {
      try { return statSync(join(WORKTREES_DIR, entry)).isDirectory(); }
      catch { return false; }
    }).length;
  } catch {
    return 0;
  }
}

function readHeartbeatState(ctx: ExtensionContext): HeartbeatInfo {
  const info: HeartbeatInfo = { enabled: true, lastRunAt: null, totalRuns: 0, healthy: true };
  for (const entry of ctx.sessionManager.getEntries()) {
    const e = entry as { type: string; customType?: string; data?: any };
    if (e.type === "custom" && e.customType === "heartbeat-state" && e.data) {
      if (typeof e.data.lastRunAt === "number") info.lastRunAt = e.data.lastRunAt;
      if (typeof e.data.totalRuns === "number") info.totalRuns = e.data.totalRuns;
      if (Array.isArray(e.data.lastFailures)) info.healthy = e.data.lastFailures.length === 0;
    }
  }
  const env = process.env.HEARTBEAT_ENABLED?.trim().toLowerCase();
  info.enabled = !(env === "0" || env === "false" || env === "no");
  return info;
}

// ── Activity feed: JSONL file tailer ────────────────────────────────────────

/**
 * Find the control-agent's session UUID from its socket alias.
 */
function getControlAgentSessionId(): string | null {
  try {
    const aliasPath = join(SOCKET_DIR, "control-agent.alias");
    const target = readlinkSync(aliasPath);      // "UUID.sock"
    return basename(target, ".sock");
  } catch {
    return null;
  }
}

/**
 * Find the session JSONL file for a given session UUID.
 * Session files are named: <timestamp>_<uuid>.jsonl
 */
function findSessionFile(sessionId: string): string | null {
  try {
    // Walk all session subdirs
    const subdirs = readdirSync(SESSION_DIR);
    for (const subdir of subdirs) {
      const dirPath = join(SESSION_DIR, subdir);
      try {
        const files = readdirSync(dirPath);
        const match = files.find((f) => f.includes(sessionId) && f.endsWith(".jsonl"));
        if (match) return join(dirPath, match);
      } catch { continue; }
    }
  } catch {}
  return null;
}

/**
 * Parse a JSONL entry into an ActivityLine (or null if not interesting).
 */
function parseActivityEntry(line: string): ActivityLine | null {
  try {
    const entry = JSON.parse(line);
    const ts = entry.timestamp ? new Date(entry.timestamp) : new Date();

    if (entry.type === "summary") {
      return { time: ts, icon: "📋", type: "compaction", text: "context compacted" };
    }

    if (entry.type !== "message") return null;

    const msg = entry.message;
    if (!msg) return null;

    const content = msg.content;

    if (msg.role === "assistant") {
      if (!Array.isArray(content)) return null;

      // Show tool calls
      for (const c of content) {
        if (c.type === "toolCall") {
          const name = c.name ?? "?";
          const args = c.arguments ?? {};
          let detail = "";
          if (name === "bash" && args.command) {
            // Show the command, strip comments
            detail = String(args.command).split("\n")[0].replace(/^#.*/, "").trim().substring(0, 60);
          } else if (name === "read" && args.path) {
            detail = String(args.path).split("/").slice(-2).join("/");
          } else if (name === "edit" && args.path) {
            detail = String(args.path).split("/").slice(-2).join("/");
          } else if (name === "write" && args.path) {
            detail = String(args.path).split("/").slice(-2).join("/");
          } else {
            detail = Object.keys(args).slice(0, 2).join(",");
          }
          return { time: ts, icon: "⚡", type: "tool", text: `${name} ${detail}` };
        }
      }

      // Show text (abbreviated)
      for (const c of content) {
        if (c.type === "text" && c.text) {
          const text = c.text.replace(/\n/g, " ").substring(0, 80);
          return { time: ts, icon: "💬", type: "text", text };
        }
      }

      // Show thinking
      for (const c of content) {
        if (c.type === "thinking" && c.thinking) {
          const text = c.thinking.replace(/\n/g, " ").substring(0, 60);
          return { time: ts, icon: "🧠", type: "thinking", text };
        }
      }
    }

    if (msg.role === "user") {
      const text = typeof content === "string" ? content : "";
      if (text.includes("EXTERNAL_UNTRUSTED_CONTENT")) {
        const fromMatch = text.match(/From:\s*(<@[^>]+>|[^\n]+)/);
        const from = fromMatch ? fromMatch[1].trim() : "user";
        return { time: ts, icon: "📩", type: "incoming", text: `slack: ${from}` };
      }
      if (text.includes("Heartbeat")) {
        return { time: ts, icon: "♥", type: "incoming", text: "heartbeat check" };
      }
      // Skip other user messages (tool results fill the feed otherwise)
      if (text.length > 0 && text.length < 200) {
        return { time: ts, icon: "📝", type: "incoming", text: text.replace(/\n/g, " ").substring(0, 60) };
      }
    }

    return null;
  } catch {
    return null;
  }
}

/**
 * Activity feed manager — tails a JSONL file and maintains a ring buffer.
 */
class ActivityFeed {
  private buffer: ActivityLine[] = [];
  private fileOffset = 0;
  private sessionFile: string | null = null;
  private watcher: ReturnType<typeof fsWatch> | null = null;
  private pollTimer: ReturnType<typeof setInterval> | null = null;

  /** Start tailing a session file */
  start(sessionFile: string) {
    this.sessionFile = sessionFile;

    // Seed with last N entries from the existing file
    this.seedFromFile(sessionFile);

    // Watch for changes via fs.watch + fallback poll
    try {
      this.watcher = fsWatch(sessionFile, { persistent: false }, () => {
        this.readNewEntries();
      });
    } catch {
      // fs.watch may not work on all systems
    }

    // Poll every 2 seconds as fallback (fs.watch can miss events)
    this.pollTimer = setInterval(() => this.readNewEntries(), 2000);
  }

  /** Seed buffer from end of existing file */
  private seedFromFile(filePath: string) {
    try {
      const content = readFileSync(filePath, "utf-8");
      const lines = content.split("\n").filter((l) => l.trim().length > 0);
      this.fileOffset = Buffer.byteLength(content, "utf-8");

      // Parse last ~50 entries to find interesting ones
      const tail = lines.slice(-50);
      for (const line of tail) {
        const activity = parseActivityEntry(line);
        if (activity) this.push(activity);
      }
    } catch {}
  }

  /** Read new bytes appended to the file */
  private readNewEntries() {
    if (!this.sessionFile) return;
    try {
      const fd = openSync(this.sessionFile, "r");
      try {
        const stat = fstatSync(fd);
        if (stat.size <= this.fileOffset) return;

        const newSize = stat.size - this.fileOffset;
        const buf = Buffer.alloc(newSize);
        readSync(fd, buf, 0, newSize, this.fileOffset);
        this.fileOffset = stat.size;

        const text = buf.toString("utf-8");
        const lines = text.split("\n").filter((l) => l.trim().length > 0);
        for (const line of lines) {
          const activity = parseActivityEntry(line);
          if (activity) this.push(activity);
        }
      } finally {
        closeSync(fd);
      }
    } catch {}
  }

  /** Push to ring buffer */
  private push(item: ActivityLine) {
    this.buffer.push(item);
    if (this.buffer.length > ACTIVITY_BUFFER_SIZE) {
      this.buffer.shift();
    }
  }

  /** Add an activity line directly (for same-session events) */
  addDirect(item: ActivityLine) {
    this.push(item);
  }

  /** Get current buffer */
  getLines(): readonly ActivityLine[] {
    return this.buffer;
  }

  /** Stop watching */
  stop() {
    if (this.watcher) { this.watcher.close(); this.watcher = null; }
    if (this.pollTimer) { clearInterval(this.pollTimer); this.pollTimer = null; }
  }
}

// ── Rendering ───────────────────────────────────────────────────────────────

function formatAgo(date: Date): string {
  const ms = Date.now() - date.getTime();
  const s = Math.floor(ms / 1000);
  const m = Math.floor(s / 60);
  const h = Math.floor(m / 60);
  if (h > 0) return `${h}h ${m % 60}m ago`;
  if (m > 0) return `${m}m ago`;
  if (s > 10) return `${s}s ago`;
  return "just now";
}

function formatUptime(ms: number): string {
  const s = Math.floor(ms / 1000);
  const m = Math.floor(s / 60);
  const h = Math.floor(m / 60);
  const d = Math.floor(h / 24);
  if (d > 0) return `${d}d ${h % 24}h ${m % 60}m`;
  if (h > 0) return `${h}h ${m % 60}m`;
  if (m > 0) return `${m}m`;
  return `${s}s`;
}

function formatTime(date: Date): string {
  return date.toLocaleTimeString("en-US", {
    hour: "2-digit", minute: "2-digit", second: "2-digit", hour12: false,
  });
}

function pad(left: string, right: string, width: number, indent: number = 2): string {
  const gap = Math.max(1, width - visibleWidth(left) - visibleWidth(right) - indent);
  return truncateToWidth(`${left}${" ".repeat(gap)}${right}${"".padEnd(indent)}`, width);
}

function renderDashboard(
  data: DashboardData,
  activity: readonly ActivityLine[],
  theme: ExtensionContext["ui"]["theme"],
  width: number,
): string[] {
  const lines: string[] = [];
  const dim = (s: string) => theme.fg("dim", s);
  const bar = "─";

  // ── Top border with title ──
  const title = " baudbot ";
  const titleStyled = theme.fg("accent", theme.bold(title));
  const titleLen = visibleWidth(title);
  const sideL = Math.max(1, Math.floor((width - titleLen) / 2));
  const sideR = Math.max(1, width - sideL - titleLen);
  lines.push(truncateToWidth(dim(bar.repeat(sideL)) + titleStyled + dim(bar.repeat(sideR)), width));

  // ── Row 1: baudbot version │ pi version │ bridge │ uptime ──
  let bbDisplay: string;
  if (data.baudbotVersion && data.baudbotSha) {
    bbDisplay = dim(`v${data.baudbotVersion}`) + dim(`@${data.baudbotSha}`);
  } else if (data.baudbotSha) {
    bbDisplay = dim(`@${data.baudbotSha}`);
  } else {
    bbDisplay = dim("?");
  }

  let piDisplay: string;
  if (data.piLatest && data.piLatest !== data.piVersion) {
    piDisplay = theme.fg("warning", `v${data.piVersion}*`);
  } else if (data.piLatest) {
    piDisplay = theme.fg("success", `v${data.piVersion}`);
  } else {
    piDisplay = dim(`v${data.piVersion}`);
  }

  const bridgeIcon = data.bridgeUp ? theme.fg("success", "●") : theme.fg("error", "●");
  const bridgeLabel = data.bridgeUp ? "up" : theme.fg("error", "DOWN");
  const bridgeTypeStr = data.bridgeType ? dim(` ${data.bridgeType}`) : "";

  const row1Left = `  baudbot ${bbDisplay}  ${dim("│")}  pi ${piDisplay}  ${dim("│")}  ${bridgeIcon} bridge ${bridgeLabel}${bridgeTypeStr}`;
  const row1Right = dim(`up ${formatUptime(data.uptimeMs)}`);
  lines.push(pad(row1Left, row1Right, width));

  // ── Row 2: sessions ──
  const parts: string[] = [];
  for (const s of data.sessions) {
    const icon = s.alive ? theme.fg("success", "●") : theme.fg("error", "●");
    const label = s.alive ? dim(s.name) : theme.fg("error", s.name);
    parts.push(`${icon} ${label}`);
  }
  if (data.devAgentCount > 0) {
    parts.push(
      theme.fg("accent", `● ${data.devAgentCount} dev-agent${data.devAgentCount > 1 ? "s" : ""}`)
    );
  }
  lines.push(pad(`  ${parts.join("  ")}`, "", width));

  // ── Row 3: todos │ worktrees │ heartbeat ──
  const todoParts: string[] = [];
  if (data.todosInProgress > 0) {
    todoParts.push(theme.fg("accent", `${data.todosInProgress} active`));
  }
  todoParts.push(dim(`${data.todosDone} done`));
  todoParts.push(dim(`${data.todosTotal} total`));
  const todoStr = `todos ${todoParts.join(dim(" / "))}`;

  const wtIcon = data.worktreeCount > 0 ? theme.fg("accent", "●") : dim("○");
  const wtLabel = data.worktreeCount > 0
    ? theme.fg("accent", `${data.worktreeCount}`)
    : dim("0");
  const wtStr = `${wtIcon} ${wtLabel} wt`;

  let hbStr: string;
  if (!data.heartbeat.enabled) {
    hbStr = `${theme.fg("warning", "♥")} ${theme.fg("warning", "paused")}`;
  } else if (data.heartbeat.lastRunAt) {
    const ago = formatAgo(new Date(data.heartbeat.lastRunAt));
    const icon = data.heartbeat.healthy ? theme.fg("success", "♥") : theme.fg("error", "♥");
    const label = data.heartbeat.healthy ? dim(ago) : theme.fg("error", ago);
    hbStr = `${icon} ${label}`;
  } else {
    hbStr = `${dim("♥")} ${dim("pending")}`;
  }

  const refreshTime = data.lastRefresh.toLocaleTimeString("en-US", {
    hour: "2-digit", minute: "2-digit", second: "2-digit", hour12: false,
  });

  const row3Left = `  ${todoStr}  ${dim("│")}  ${wtStr}  ${dim("│")}  ${hbStr}`;
  const row3Right = dim(`⟳ ${refreshTime}`);
  lines.push(pad(row3Left, row3Right, width));

  // ── Activity feed ──
  if (activity.length > 0) {
    // Thin separator
    const actLabel = " activity ";
    const actLabelStyled = dim(actLabel);
    const actLabelLen = visibleWidth(actLabel);
    const actSideL = 2;
    const actSideR = Math.max(1, width - actSideL - actLabelLen);
    lines.push(truncateToWidth(dim(bar.repeat(actSideL)) + actLabelStyled + dim(bar.repeat(actSideR)), width));

    for (const item of activity) {
      const time = dim(formatTime(item.time));
      let icon: string;
      let text: string;
      switch (item.type) {
        case "tool":
          icon = theme.fg("accent", "⚡");
          text = dim(item.text);
          break;
        case "incoming":
          icon = theme.fg("success", "→");
          text = theme.fg("success", item.text);
          break;
        case "thinking":
          icon = dim("…");
          text = dim(item.text);
          break;
        case "compaction":
          icon = dim("◇");
          text = dim(item.text);
          break;
        case "text":
        default:
          icon = dim("│");
          text = item.text;
          break;
      }
      const lineText = `  ${time} ${icon} ${text}`;
      lines.push(truncateToWidth(lineText, width));
    }
  }

  // ── Bottom border ──
  lines.push(truncateToWidth(dim(bar.repeat(width)), width));

  return lines;
}

// ── Extension ───────────────────────────────────────────────────────────────

export default function dashboardExtension(pi: ExtensionAPI): void {
  let timer: ReturnType<typeof setInterval> | null = null;
  const startTime = Date.now();
  const piVersion = getPiVersion();

  let data: DashboardData | null = null;
  let savedCtx: ExtensionContext | null = null;
  let lastEvent: LastEvent | null = null;
  const activityFeed = new ActivityFeed();

  async function refresh() {
    const [bridgeUp, piLatest] = await Promise.all([
      checkBridge(),
      getPiLatestVersion(),
    ]);

    const sessions = getSessions();
    const devAgents = getDevAgents();
    const todoStats = getTodoStats();
    const worktreeCount = getWorktreeCount();
    const baudbot = getBaudbotVersion();
    const bridgeType = detectBridgeType();
    const heartbeat = savedCtx ? readHeartbeatState(savedCtx) : { enabled: true, lastRunAt: null, totalRuns: 0, healthy: true };

    data = {
      piVersion,
      piLatest,
      baudbotVersion: baudbot.version,
      baudbotSha: baudbot.sha,
      bridgeUp,
      bridgeType,
      sessions,
      devAgentCount: devAgents.count,
      devAgentNames: devAgents.names,
      todosInProgress: todoStats.inProgress,
      todosDone: todoStats.done,
      todosTotal: todoStats.total,
      worktreeCount,
      uptimeMs: Date.now() - startTime,
      lastRefresh: new Date(),
      heartbeat,
      lastEvent,
    };
  }

  function installWidget(ctx: ExtensionContext) {
    if (!ctx.hasUI) return;

    ctx.ui.setWidget("baudbot-dashboard", (_tui, theme) => ({
      render(width: number): string[] {
        if (!data) {
          return [
            theme.fg("dim", "─".repeat(width)),
            theme.fg("dim", "  baudbot dashboard loading…"),
            theme.fg("dim", "─".repeat(width)),
          ];
        }
        data.uptimeMs = Date.now() - startTime;
        return renderDashboard(data, activityFeed.getLines(), theme, width);
      },
      invalidate() {},
    }));
  }

  function startActivityFeed() {
    const sessionId = getControlAgentSessionId();
    if (!sessionId) return;

    const sessionFile = findSessionFile(sessionId);
    if (!sessionFile) return;

    activityFeed.start(sessionFile);
  }

  // /dashboard command — force immediate refresh
  pi.registerCommand("dashboard", {
    description: "Refresh the baudbot status dashboard",
    handler: async (_args, ctx) => {
      await refresh();
      if (ctx.hasUI) ctx.ui.notify("Dashboard refreshed", "info");
    },
  });

  pi.on("session_start", async (_event, ctx) => {
    savedCtx = ctx;
    await refresh();
    installWidget(ctx);
    startActivityFeed();

    timer = setInterval(async () => {
      try { await refresh(); }
      catch (err) { console.error("Dashboard refresh failed:", err); }
    }, REFRESH_INTERVAL_MS);
  });

  // Track last event + feed activity from our own session's inbound messages
  pi.on("before_agent_start", async (event) => {
    const prompt = event.prompt ?? "";

    if (prompt.includes("EXTERNAL_UNTRUSTED_CONTENT")) {
      const fromMatch = prompt.match(/From:\s*(<@[^>]+>|[^\n]+)/);
      const from = fromMatch ? fromMatch[1].trim() : "user";
      const bodyMatch = prompt.match(/---\n([\s\S]*?)<<<END_EXTERNAL_UNTRUSTED_CONTENT>>>/);
      const body = bodyMatch ? bodyMatch[1].trim().substring(0, 40).replace(/\n/g, " ") : "";
      const summary = body ? `${from}: ${body}` : from;
      lastEvent = { source: "slack", summary, time: new Date() };
    } else if (prompt.includes("Heartbeat")) {
      lastEvent = { source: "heartbeat", summary: "health check fired", time: new Date() };
    } else if (prompt.includes("#bots-sentry") || prompt.includes("Sentry")) {
      const preview = prompt.substring(0, 50).replace(/\n/g, " ");
      lastEvent = { source: "sentry", summary: preview, time: new Date() };
    } else if (prompt.length > 0) {
      const preview = prompt.substring(0, 50).replace(/\n/g, " ");
      lastEvent = { source: "chat", summary: preview, time: new Date() };
    }

    if (data && lastEvent) {
      data.lastEvent = lastEvent;
    }
  });

  pi.on("session_shutdown", async () => {
    if (timer) { clearInterval(timer); timer = null; }
    activityFeed.stop();
  });
}
