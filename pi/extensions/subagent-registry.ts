import { existsSync, mkdirSync, readdirSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, isAbsolute, join, relative, resolve } from "node:path";

export const SUBAGENTS_DIR_ENV = "BAUDBOT_SUBAGENTS_DIR";
export const SUBAGENTS_STATE_FILE_ENV = "BAUDBOT_SUBAGENTS_STATE_FILE";

const SUBAGENT_ID_RE = /^[a-z0-9][a-z0-9-]{1,63}$/;
const SAFE_NAME_RE = /^[a-zA-Z0-9._-]+$/;

const MIN_READY_TIMEOUT_SEC = 1;
const MAX_READY_TIMEOUT_SEC = 60;
const DEFAULT_READY_TIMEOUT_SEC = 10;

export type SubagentModelProfile = "top_tier" | "cheap_tier" | "explicit";

export type SubagentUtility = {
  name: string;
  description: string;
  entrypoint: string;
  timeout_sec: number;
  max_output_bytes: number;
};

export type SubagentManifest = {
  id: string;
  name: string;
  description: string;
  version?: string;
  session_name: string;
  cwd: string;
  skill_path: string;
  model_profile: SubagentModelProfile;
  model?: string;
  ready_alias: string;
  ready_timeout_sec: number;
  installed_by_default: boolean;
  enabled_by_default: boolean;
  autostart: boolean;
  startup_message?: string;
  utilities: SubagentUtility[];
};

export type SubagentPackage = {
  id: string;
  root_dir: string;
  manifest_path: string;
  manifest: SubagentManifest;
};

export type SubagentStateEntry = {
  installed?: boolean;
  enabled?: boolean;
  autostart?: boolean;
};

export type SubagentState = {
  version: number;
  agents: Record<string, SubagentStateEntry>;
};

export type SubagentEffectiveState = {
  id: string;
  installed: boolean;
  enabled: boolean;
  autostart: boolean;
};

export type SubagentDiscoveryResult = {
  packages: SubagentPackage[];
  diagnostics: string[];
};

function isRecord(value: unknown): value is Record<string, unknown> {
  return !!value && typeof value === "object" && !Array.isArray(value);
}

function isSafeSessionName(value: string): boolean {
  return SAFE_NAME_RE.test(value);
}

function clampReadyTimeout(value: unknown): number {
  if (typeof value !== "number" || !Number.isFinite(value)) return DEFAULT_READY_TIMEOUT_SEC;
  return Math.min(MAX_READY_TIMEOUT_SEC, Math.max(MIN_READY_TIMEOUT_SEC, Math.round(value)));
}

function boolOrDefault(value: unknown, fallback: boolean): boolean {
  return typeof value === "boolean" ? value : fallback;
}

function numberOrDefault(value: unknown, fallback: number): number {
  return typeof value === "number" && Number.isFinite(value) ? value : fallback;
}

function parseUtilityList(value: unknown): SubagentUtility[] {
  if (!Array.isArray(value)) return [];
  const utilities: SubagentUtility[] = [];

  for (const entry of value) {
    if (!isRecord(entry)) continue;
    const name = typeof entry.name === "string" ? entry.name.trim() : "";
    const description = typeof entry.description === "string" ? entry.description.trim() : "";
    const entrypoint = typeof entry.entrypoint === "string" ? entry.entrypoint.trim() : "";

    if (!name || !description || !entrypoint) continue;

    utilities.push({
      name,
      description,
      entrypoint,
      timeout_sec: Math.max(1, Math.round(numberOrDefault(entry.timeout_sec, 30))),
      max_output_bytes: Math.max(1024, Math.round(numberOrDefault(entry.max_output_bytes, 32_768))),
    });
  }

  return utilities;
}

function parseManifest(raw: unknown, manifestPath: string): { manifest?: SubagentManifest; error?: string } {
  if (!isRecord(raw)) {
    return { error: `manifest must be an object (${manifestPath})` };
  }

  const id = typeof raw.id === "string" ? raw.id.trim() : "";
  if (!id || !SUBAGENT_ID_RE.test(id)) {
    return { error: `invalid id in ${manifestPath}` };
  }

  const name = typeof raw.name === "string" ? raw.name.trim() : "";
  if (!name) {
    return { error: `missing name in ${manifestPath}` };
  }

  const description = typeof raw.description === "string" ? raw.description.trim() : "";
  if (!description) {
    return { error: `missing description in ${manifestPath}` };
  }

  const sessionName = typeof raw.session_name === "string" ? raw.session_name.trim() : "";
  if (!sessionName || !isSafeSessionName(sessionName)) {
    return { error: `invalid session_name in ${manifestPath}` };
  }

  const modelProfileRaw = typeof raw.model_profile === "string" ? raw.model_profile.trim() : "";
  const modelProfile =
    modelProfileRaw === "top_tier" || modelProfileRaw === "cheap_tier" || modelProfileRaw === "explicit"
      ? (modelProfileRaw as SubagentModelProfile)
      : null;

  if (!modelProfile) {
    return { error: `invalid model_profile in ${manifestPath}` };
  }

  const explicitModel = typeof raw.model === "string" ? raw.model.trim() : undefined;
  if (modelProfile === "explicit" && !explicitModel) {
    return { error: `model_profile=explicit requires model in ${manifestPath}` };
  }

  const readyAliasRaw = typeof raw.ready_alias === "string" ? raw.ready_alias.trim() : "";
  const readyAlias = readyAliasRaw || sessionName;
  if (!isSafeSessionName(readyAlias)) {
    return { error: `invalid ready_alias in ${manifestPath}` };
  }

  const manifest: SubagentManifest = {
    id,
    name,
    description,
    version: typeof raw.version === "string" ? raw.version.trim() || undefined : undefined,
    session_name: sessionName,
    cwd: typeof raw.cwd === "string" && raw.cwd.trim() ? raw.cwd.trim() : "~",
    skill_path: typeof raw.skill_path === "string" && raw.skill_path.trim() ? raw.skill_path.trim() : "SKILL.md",
    model_profile: modelProfile,
    model: explicitModel,
    ready_alias: readyAlias,
    ready_timeout_sec: clampReadyTimeout(raw.ready_timeout_sec),
    installed_by_default: boolOrDefault(raw.installed_by_default, true),
    enabled_by_default: boolOrDefault(raw.enabled_by_default, true),
    autostart: boolOrDefault(raw.autostart, false),
    startup_message: typeof raw.startup_message === "string" ? raw.startup_message.trim() || undefined : undefined,
    utilities: parseUtilityList(raw.utilities),
  };

  return { manifest };
}

export function expandHomePath(value: string): string {
  const trimmed = value.trim();
  if (trimmed === "~") return homedir();
  if (trimmed.startsWith("~/")) return join(homedir(), trimmed.slice(2));
  return trimmed;
}

export function absolutePath(value: string): string {
  return resolve(expandHomePath(value));
}

export function resolveSubagentsDir(): string {
  const configured = process.env[SUBAGENTS_DIR_ENV]?.trim();
  if (configured) return absolutePath(configured);
  return join(homedir(), ".pi", "agent", "subagents");
}

export function resolveSubagentsStateFilePath(): string {
  const configured = process.env[SUBAGENTS_STATE_FILE_ENV]?.trim();
  if (configured) return absolutePath(configured);
  return join(homedir(), ".pi", "agent", "subagents-state.json");
}

export function resolvePathInPackage(rootDir: string, relativePath: string): string | null {
  const trimmed = relativePath.trim();
  if (!trimmed) return null;
  const resolved = resolve(rootDir, trimmed);
  const rel = relative(rootDir, resolved);
  if (rel.startsWith("..") || isAbsolute(rel)) return null;
  return resolved;
}

export function discoverSubagentPackages(): SubagentDiscoveryResult {
  const rootDir = resolveSubagentsDir();
  const diagnostics: string[] = [];
  const packages: SubagentPackage[] = [];

  if (!existsSync(rootDir)) {
    return { packages, diagnostics };
  }

  let entries: string[] = [];
  try {
    entries = readdirSync(rootDir);
  } catch (error) {
    diagnostics.push(`failed to read subagents dir ${rootDir}: ${error instanceof Error ? error.message : String(error)}`);
    return { packages, diagnostics };
  }

  const seen = new Set<string>();
  for (const entry of entries.sort()) {
    const packageDir = join(rootDir, entry);
    let isDirectory = false;
    try {
      isDirectory = statSync(packageDir).isDirectory();
    } catch {
      continue;
    }
    if (!isDirectory) continue;

    const manifestPath = join(packageDir, "subagent.json");
    if (!existsSync(manifestPath)) continue;

    let raw: unknown;
    try {
      raw = JSON.parse(readFileSync(manifestPath, "utf-8")) as unknown;
    } catch (error) {
      diagnostics.push(`failed parsing ${manifestPath}: ${error instanceof Error ? error.message : String(error)}`);
      continue;
    }

    const parsed = parseManifest(raw, manifestPath);
    if (!parsed.manifest) {
      diagnostics.push(parsed.error ?? `invalid manifest at ${manifestPath}`);
      continue;
    }

    if (seen.has(parsed.manifest.id)) {
      diagnostics.push(`duplicate subagent id ${parsed.manifest.id} at ${manifestPath}`);
      continue;
    }
    seen.add(parsed.manifest.id);

    packages.push({
      id: parsed.manifest.id,
      root_dir: packageDir,
      manifest_path: manifestPath,
      manifest: parsed.manifest,
    });
  }

  return { packages, diagnostics };
}

function emptyState(): SubagentState {
  return { version: 1, agents: {} };
}

export function readSubagentState(): SubagentState {
  const statePath = resolveSubagentsStateFilePath();
  if (!existsSync(statePath)) return emptyState();

  try {
    const parsed = JSON.parse(readFileSync(statePath, "utf-8")) as unknown;
    if (!isRecord(parsed)) return emptyState();

    const version = typeof parsed.version === "number" && Number.isFinite(parsed.version) ? parsed.version : 1;
    const agentsRaw = isRecord(parsed.agents) ? parsed.agents : {};
    const agents: Record<string, SubagentStateEntry> = {};

    for (const [id, value] of Object.entries(agentsRaw)) {
      if (!SUBAGENT_ID_RE.test(id) || !isRecord(value)) continue;
      const entry: SubagentStateEntry = {};
      if (typeof value.installed === "boolean") entry.installed = value.installed;
      if (typeof value.enabled === "boolean") entry.enabled = value.enabled;
      if (typeof value.autostart === "boolean") entry.autostart = value.autostart;
      agents[id] = entry;
    }

    return { version, agents };
  } catch {
    return emptyState();
  }
}

export function writeSubagentState(state: SubagentState): void {
  const statePath = resolveSubagentsStateFilePath();
  mkdirSync(dirname(statePath), { recursive: true });
  writeFileSync(statePath, `${JSON.stringify(state, null, 2)}\n`, "utf-8");
}

export function ensureSubagentStateEntry(state: SubagentState, id: string): SubagentStateEntry {
  const existing = state.agents[id];
  if (existing) return existing;
  const created: SubagentStateEntry = {};
  state.agents[id] = created;
  return created;
}

export function resolveEffectiveState(pkg: SubagentPackage, state: SubagentState): SubagentEffectiveState {
  const override = state.agents[pkg.id] ?? {};

  const installed = override.installed ?? pkg.manifest.installed_by_default;
  const enabled = installed && (override.enabled ?? pkg.manifest.enabled_by_default);
  const autostart = enabled && (override.autostart ?? pkg.manifest.autostart);

  return {
    id: pkg.id,
    installed,
    enabled,
    autostart,
  };
}

export function resolveModelForProfile(manifest: SubagentManifest): { model?: string; error?: string } {
  if (manifest.model_profile === "explicit") {
    if (!manifest.model) {
      return { error: `subagent ${manifest.id} is explicit model profile but model is missing` };
    }
    return { model: manifest.model };
  }

  if (manifest.model_profile === "top_tier") {
    if (process.env.ANTHROPIC_API_KEY) return { model: "anthropic/claude-opus-4-6" };
    if (process.env.OPENAI_API_KEY) return { model: "openai/gpt-5.2-codex" };
    if (process.env.GEMINI_API_KEY) return { model: "google/gemini-3-pro-preview" };
    if (process.env.OPENCODE_ZEN_API_KEY) return { model: "opencode-zen/claude-opus-4-6" };
    return { error: "no API key available for top_tier model profile" };
  }

  if (process.env.ANTHROPIC_API_KEY) return { model: "anthropic/claude-haiku-4-5" };
  if (process.env.OPENAI_API_KEY) return { model: "openai/gpt-5-mini" };
  if (process.env.GEMINI_API_KEY) return { model: "google/gemini-3-flash-preview" };
  if (process.env.OPENCODE_ZEN_API_KEY) return { model: "opencode-zen/claude-haiku-4-5" };
  return { error: "no API key available for cheap_tier model profile" };
}
