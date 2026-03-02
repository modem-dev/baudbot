import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";
import { StringEnum } from "@mariozechner/pi-ai";
import { Type } from "@sinclair/typebox";
import { existsSync } from "node:fs";
import {
  discoverSubagentPackages,
  readSubagentState,
  resolveEffectiveState,
  resolvePathInPackage,
  type SubagentPackage,
  type SubagentUtility,
} from "./subagent-registry.ts";

const ACTIONS = ["list", "run"] as const;
type Action = (typeof ACTIONS)[number];

function shellQuote(value: string): string {
  return `'${value.replace(/'/g, `"'"'`)}'`;
}

function truncateText(value: string, maxBytes: number): string {
  const buffer = Buffer.from(value, "utf-8");
  if (buffer.length <= maxBytes) return value;
  const prefix = buffer.subarray(0, maxBytes).toString("utf-8");
  return `${prefix}\n… [truncated to ${maxBytes} bytes]`;
}

function summarizeUtilities(pkg: SubagentPackage) {
  return pkg.manifest.utilities.map((utility) => ({
    name: utility.name,
    description: utility.description,
    timeout_sec: utility.timeout_sec,
    max_output_bytes: utility.max_output_bytes,
  }));
}

function resolvePackageFromSessionName(packages: SubagentPackage[], sessionName: string | null): SubagentPackage | null {
  if (!sessionName) return null;
  const matched = packages.find((pkg) => pkg.manifest.session_name === sessionName.trim());
  return matched ?? null;
}

function resolveUtility(pkg: SubagentPackage, utilityName: string): SubagentUtility | null {
  const normalized = utilityName.trim().toLowerCase();
  if (!normalized) return null;
  const match = pkg.manifest.utilities.find((utility) => utility.name.toLowerCase() === normalized);
  return match ?? null;
}

export default function subagentUtilExtension(pi: ExtensionAPI): void {
  pi.registerTool({
    name: "subagent_util",
    label: "Subagent Utility",
    description: "List or run manifest-declared utilities for a subagent package.",
    parameters: Type.Object({
      action: StringEnum(ACTIONS),
      id: Type.Optional(Type.String({ description: "Subagent id (optional when called from that subagent session)" })),
      utility: Type.Optional(Type.String({ description: "Utility name for action=run" })),
      args: Type.Optional(Type.Record(Type.String(), Type.Unknown(), { description: "Utility arguments JSON object" })),
    }),
    async execute(_toolCallId, params, _signal, _onUpdate, ctx) {
      const action = params.action as Action;
      const requestedId = typeof params.id === "string" ? params.id.trim() : "";
      const utilityName = typeof params.utility === "string" ? params.utility.trim() : "";
      const utilityArgs = params.args && typeof params.args === "object" ? params.args : {};

      const discovery = discoverSubagentPackages();
      const state = readSubagentState();
      const packages = discovery.packages;

      if (action === "list" && !requestedId) {
        const items = packages.map((pkg) => {
          const effective = resolveEffectiveState(pkg, state);
          return {
            id: pkg.id,
            enabled: effective.enabled,
            installed: effective.installed,
            utilities: summarizeUtilities(pkg),
          };
        });
        return {
          content: [{ type: "text", text: `Listed utilities for ${items.length} package(s).` }],
          details: {
            packages: items,
            diagnostics: discovery.diagnostics,
          },
        };
      }

      let pkg: SubagentPackage | null = null;
      if (requestedId) {
        pkg = packages.find((entry) => entry.id === requestedId) ?? null;
      } else {
        const sessionName = ctx?.sessionManager?.getSessionName?.() ?? null;
        pkg = resolvePackageFromSessionName(packages, sessionName);
      }

      if (!pkg) {
        return {
          content: [{ type: "text", text: requestedId ? `Unknown subagent id: ${requestedId}` : "Could not infer subagent id from this session. Pass id explicitly." }],
          isError: true,
          details: {
            error: "unknown_subagent",
            requested_id: requestedId || null,
            available: packages.map((entry) => entry.id),
          },
        };
      }

      const effective = resolveEffectiveState(pkg, state);

      if (action === "list") {
        return {
          content: [{ type: "text", text: `Listed ${pkg.manifest.utilities.length} utilit${pkg.manifest.utilities.length === 1 ? "y" : "ies"} for ${pkg.id}.` }],
          details: {
            id: pkg.id,
            enabled: effective.enabled,
            installed: effective.installed,
            utilities: summarizeUtilities(pkg),
            diagnostics: discovery.diagnostics,
          },
        };
      }

      if (!utilityName) {
        return {
          content: [{ type: "text", text: "action=run requires utility." }],
          isError: true,
          details: { error: "missing_utility", id: pkg.id },
        };
      }

      if (!effective.installed || !effective.enabled) {
        return {
          content: [{ type: "text", text: `Subagent ${pkg.id} is not enabled.` }],
          isError: true,
          details: {
            error: "subagent_not_enabled",
            id: pkg.id,
            installed: effective.installed,
            enabled: effective.enabled,
          },
        };
      }

      const utility = resolveUtility(pkg, utilityName);
      if (!utility) {
        return {
          content: [{ type: "text", text: `Unknown utility ${utilityName} for ${pkg.id}.` }],
          isError: true,
          details: {
            error: "unknown_utility",
            id: pkg.id,
            utility: utilityName,
            available: pkg.manifest.utilities.map((entry) => entry.name),
          },
        };
      }

      const utilityPath = resolvePathInPackage(pkg.root_dir, utility.entrypoint);
      if (!utilityPath || !existsSync(utilityPath)) {
        return {
          content: [{ type: "text", text: `Utility entrypoint not found: ${utility.entrypoint}` }],
          isError: true,
          details: {
            error: "utility_not_found",
            id: pkg.id,
            utility: utility.name,
            entrypoint: utility.entrypoint,
          },
        };
      }

      const argsJson = JSON.stringify(utilityArgs ?? {});
      const argsB64 = Buffer.from(argsJson, "utf-8").toString("base64");

      const command = [
        "set -euo pipefail",
        `cd ${shellQuote(pkg.root_dir)}`,
        `export SUBAGENT_UTIL_ARGS_B64=${shellQuote(argsB64)}`,
        `if [ ! -x ${shellQuote(utilityPath)} ]; then chmod u+x ${shellQuote(utilityPath)} 2>/dev/null || true; fi`,
        `${shellQuote(utilityPath)}`,
      ].join(" && ");

      const execResult = await pi.exec("bash", ["-lc", command], {
        timeout: utility.timeout_sec * 1000,
      });

      const maxBytes = utility.max_output_bytes;
      const stdout = truncateText(execResult.stdout ?? "", maxBytes);
      const stderr = truncateText(execResult.stderr ?? "", maxBytes);

      const ok = execResult.code === 0;
      return {
        content: [
          {
            type: "text",
            text: ok
              ? `Utility ${utility.name} completed for ${pkg.id}.`
              : `Utility ${utility.name} failed for ${pkg.id} (exit ${execResult.code}).`,
          },
        ],
        isError: !ok,
        details: {
          id: pkg.id,
          utility: utility.name,
          entrypoint: utility.entrypoint,
          exit_code: execResult.code,
          stdout,
          stderr,
        },
      };
    },
  });
}
