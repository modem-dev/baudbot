#!/usr/bin/env node

import { execFile } from "node:child_process";
import { promises as fs } from "node:fs";
import * as net from "node:net";
import * as os from "node:os";
import * as path from "node:path";

const SENDER_INFO_PATTERN = /<sender_info>[\s\S]*?<\/sender_info>/g;
const SOCKET_SUFFIX = ".sock";

function parseArgs(argv) {
  const parsed = {};

  for (let i = 0; i < argv.length; i += 1) {
    const raw = argv[i];
    if (!raw) continue;

    if (raw === "--help" || raw === "-h") {
      parsed.help = true;
      continue;
    }

    if (!raw.startsWith("--")) continue;

    const withoutPrefix = raw.slice(2);
    const eqIndex = withoutPrefix.indexOf("=");

    if (eqIndex !== -1) {
      const key = withoutPrefix.slice(0, eqIndex);
      const value = withoutPrefix.slice(eqIndex + 1);
      parsed[key] = value;
      continue;
    }

    const key = withoutPrefix;
    const value = argv[i + 1];
    if (value && !value.startsWith("--")) {
      parsed[key] = value;
      i += 1;
      continue;
    }

    parsed[key] = "true";
  }

  return parsed;
}

function usage() {
  return `Usage: node cli-session-shim.mjs \\
  --session-id <uuid> \\
  --session-name <alias> \\
  --tmux-session <name> \\
  [--control-dir <path>] \\
  [--capture-lines <n>] \\
  [--turn-end-delay-ms <n>] \\
  [--abort-hard-kill-ms <n>] \\
  [--tmux-bin <path>]`;
}

function toInt(value, fallback, min = 0) {
  const parsed = Number.parseInt(String(value ?? ""), 10);
  if (!Number.isFinite(parsed) || parsed < min) return fallback;
  return parsed;
}

function isErrnoException(error) {
  return typeof error === "object" && error !== null && "code" in error;
}

async function safeUnlink(targetPath) {
  try {
    await fs.unlink(targetPath);
  } catch (error) {
    if (isErrnoException(error) && error.code !== "ENOENT") {
      throw error;
    }
  }
}

function stripSenderInfo(text) {
  return String(text).replace(SENDER_INFO_PATTERN, "").trim();
}

function compactLines(text, maxLines) {
  const lines = String(text)
    .split("\n")
    .map((line) => line.replace(/\s+$/g, ""))
    .filter((line) => line.trim().length > 0);

  if (lines.length === 0) return "";
  return lines.slice(-maxLines).join("\n");
}

function buildSummary(paneText) {
  const compact = compactLines(paneText, 30);
  if (!compact) {
    return "No CLI output captured yet.";
  }

  return `CLI output snapshot (most recent lines):\n\n${compact}`;
}

function createExtractedMessage(content) {
  return {
    role: "assistant",
    content,
    timestamp: Date.now(),
  };
}

function execFileAsync(file, args) {
  return new Promise((resolve, reject) => {
    execFile(file, args, { encoding: "utf8", maxBuffer: 1024 * 1024 }, (error, stdout, stderr) => {
      if (error) {
        const err = new Error(`${file} ${args.join(" ")} failed: ${stderr || error.message}`);
        err.cause = error;
        reject(err);
        return;
      }

      resolve({ stdout, stderr });
    });
  });
}

function writeLine(socket, payload) {
  try {
    socket.write(`${JSON.stringify(payload)}\n`);
  } catch {
    // Ignore closed/broken sockets.
  }
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.help) {
    console.log(usage());
    process.exit(0);
  }

  const sessionId = String(args["session-id"] || "").trim();
  const sessionName = String(args["session-name"] || "").trim();
  const tmuxSession = String(args["tmux-session"] || "").trim();

  if (!sessionId || !sessionName || !tmuxSession) {
    console.error(usage());
    process.exit(2);
  }

  const controlDir =
    String(args["control-dir"] || "").trim() ||
    path.join(os.homedir(), ".pi", "session-control");
  const captureLines = toInt(args["capture-lines"], 120, 20);
  const turnEndDelayMs = toInt(args["turn-end-delay-ms"], 700, 0);
  const defaultAbortHardKillMs = toInt(
    args["abort-hard-kill-ms"] || process.env.CLI_SHIM_ABORT_HARD_KILL_MS,
    0,
    0,
  );
  const tmuxBin = String(args["tmux-bin"] || process.env.CLI_SHIM_TMUX_BIN || "tmux").trim();

  const socketPath = path.join(controlDir, `${sessionId}${SOCKET_SUFFIX}`);
  const aliasPath = path.join(controlDir, `${sessionName}.alias`);
  let server = null;
  let shuttingDown = false;
  let turnIndex = 0;
  let lastMessage = createExtractedMessage("No CLI output captured yet.");
  let sendQueue = Promise.resolve();
  const subscriptions = [];

  const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

  async function runTmux(commandArgs) {
    return await execFileAsync(tmuxBin, commandArgs);
  }

  async function capturePaneText() {
    const result = await runTmux([
      "capture-pane",
      "-t",
      tmuxSession,
      "-p",
      "-S",
      `-${captureLines}`,
    ]);
    return result.stdout || "";
  }

  function upsertLastMessageFromPane(paneText) {
    const compact = compactLines(paneText, 40);
    if (!compact) return lastMessage;
    lastMessage = createExtractedMessage(compact);
    return lastMessage;
  }

  function cleanupSubscriptionSocket(socket) {
    for (let i = subscriptions.length - 1; i >= 0; i -= 1) {
      if (subscriptions[i]?.socket === socket) {
        subscriptions.splice(i, 1);
      }
    }
  }

  function emitTurnEnd(data) {
    if (subscriptions.length === 0) return;

    const pending = [...subscriptions];
    subscriptions.length = 0;

    for (const sub of pending) {
      writeLine(sub.socket, {
        type: "event",
        event: "turn_end",
        data,
        subscriptionId: sub.subscriptionId,
      });
    }
  }

  function respond(socket, commandName, success, data, error, id) {
    writeLine(socket, {
      type: "response",
      command: commandName,
      success,
      data,
      error,
      id,
    });
  }

  async function handleCommand(socket, command) {
    const id = typeof command.id === "string" ? command.id : undefined;

    if (!command || typeof command !== "object" || typeof command.type !== "string") {
      respond(socket, "parse", false, undefined, "Invalid command", id);
      return;
    }

    if (command.type === "subscribe") {
      if (command.event !== "turn_end") {
        respond(socket, "subscribe", false, undefined, `Unknown event type: ${command.event}`, id);
        return;
      }

      const subscriptionId = id || `sub_${Date.now()}_${Math.random().toString(36).slice(2, 8)}`;
      subscriptions.push({ socket, subscriptionId });
      socket.once("close", () => cleanupSubscriptionSocket(socket));
      socket.once("error", () => cleanupSubscriptionSocket(socket));

      respond(socket, "subscribe", true, { subscriptionId, event: "turn_end" }, undefined, id);
      return;
    }

    if (command.type === "get_message") {
      try {
        const paneText = await capturePaneText();
        const message = upsertLastMessageFromPane(paneText);
        respond(socket, "get_message", true, { message }, undefined, id);
      } catch (error) {
        const message = error instanceof Error ? error.message : "Failed to capture tmux output";
        respond(socket, "get_message", false, undefined, message, id);
      }
      return;
    }

    if (command.type === "get_summary") {
      try {
        const paneText = await capturePaneText();
        upsertLastMessageFromPane(paneText);
        const summary = buildSummary(paneText);
        respond(socket, "get_summary", true, { summary, model: "tmux-capture" }, undefined, id);
      } catch (error) {
        const message = error instanceof Error ? error.message : "Failed to summarize tmux output";
        respond(socket, "get_summary", false, undefined, message, id);
      }
      return;
    }

    if (command.type === "abort") {
      try {
        await runTmux(["send-keys", "-t", tmuxSession, "C-c"]);
        const requestedDelayMs = command.hardKillAfterMs ?? command.hard_kill_after_ms;
        const hardKillDelayMs = toInt(
          requestedDelayMs,
          command.hard === true && defaultAbortHardKillMs === 0 ? 1500 : defaultAbortHardKillMs,
          0,
        );
        if (hardKillDelayMs > 0) {
          setTimeout(() => {
            void runTmux(["kill-session", "-t", tmuxSession]).catch(() => {
              // Ignore failed escalation; session may already be gone.
            });
          }, hardKillDelayMs);
        }
        respond(
          socket,
          "abort",
          true,
          { delivered: true, hardKillScheduledMs: hardKillDelayMs > 0 ? hardKillDelayMs : undefined },
          undefined,
          id,
        );
      } catch (error) {
        const message = error instanceof Error ? error.message : "Failed to abort session";
        respond(socket, "abort", false, undefined, message, id);
      }
      return;
    }

    if (command.type === "clear") {
      respond(
        socket,
        "clear",
        false,
        undefined,
        "Clear is not supported for CLI-backed sessions",
        id,
      );
      return;
    }

    if (command.type === "send") {
      const rawMessage = typeof command.message === "string" ? command.message : "";
      const message = stripSenderInfo(rawMessage);

      if (!message) {
        respond(socket, "send", false, undefined, "Missing message", id);
        return;
      }

      turnIndex += 1;
      const nextTurn = turnIndex;
      sendQueue = sendQueue
        .then(async () => {
          await runTmux(["send-keys", "-t", tmuxSession, "-l", message]);
          await runTmux(["send-keys", "-t", tmuxSession, "Enter"]);
          if (turnEndDelayMs > 0) {
            await sleep(turnEndDelayMs);
          }

          const paneText = await capturePaneText();
          const extracted = upsertLastMessageFromPane(paneText);
          emitTurnEnd({ message: extracted, turnIndex: nextTurn });
        })
        .catch((error) => {
          const errorMessage = error instanceof Error ? error.message : "send queue failed";
          emitTurnEnd({ message: lastMessage, turnIndex: nextTurn, error: errorMessage });
        });

      respond(socket, "send", true, { delivered: true, mode: command.mode || "steer" }, undefined, id);
      return;
    }

    respond(socket, command.type, false, undefined, `Unsupported command: ${command.type}`, id);
  }

  async function startServer() {
    await fs.mkdir(controlDir, { recursive: true });
    await safeUnlink(socketPath);
    await safeUnlink(aliasPath);

    server = net.createServer((socket) => {
      socket.setEncoding("utf8");
      let buffer = "";

      socket.on("data", (chunk) => {
        buffer += chunk;
        let newlineIndex = buffer.indexOf("\n");

        while (newlineIndex !== -1) {
          const line = buffer.slice(0, newlineIndex).trim();
          buffer = buffer.slice(newlineIndex + 1);
          newlineIndex = buffer.indexOf("\n");
          if (!line) continue;

          let command;
          try {
            command = JSON.parse(line);
          } catch (error) {
            const message = error instanceof Error ? error.message : "Failed to parse command";
            respond(socket, "parse", false, undefined, message, undefined);
            continue;
          }

          void handleCommand(socket, command);
        }
      });

      socket.on("close", () => cleanupSubscriptionSocket(socket));
      socket.on("error", () => cleanupSubscriptionSocket(socket));
    });

    await new Promise((resolve, reject) => {
      if (!server) {
        reject(new Error("server is not initialized"));
        return;
      }

      server.once("error", reject);
      server.listen(socketPath, async () => {
        try {
          await fs.symlink(`${sessionId}${SOCKET_SUFFIX}`, aliasPath);
          resolve();
        } catch (error) {
          reject(error);
        }
      });
    });
  }

  async function shutdown(exitCode = 0) {
    if (shuttingDown) return;
    shuttingDown = true;

    try {
      if (server) {
        await new Promise((resolve) => {
          server.close(() => resolve(undefined));
        });
      }
    } catch {
      // Ignore shutdown errors.
    }

    try {
      await safeUnlink(aliasPath);
      await safeUnlink(socketPath);
    } finally {
      process.exit(exitCode);
    }
  }

  process.on("SIGINT", () => {
    void shutdown(130);
  });
  process.on("SIGTERM", () => {
    void shutdown(143);
  });

  try {
    await startServer();
  } catch (error) {
    const message = error instanceof Error ? error.message : "Unknown startup error";
    console.error(`cli-session-shim failed to start: ${message}`);
    await shutdown(1);
    return;
  }

  console.log(`cli-session-shim ready: ${sessionName} (${sessionId}) at ${socketPath}`);
}

void main();
