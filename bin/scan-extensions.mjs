#!/usr/bin/env node
/**
 * Extension & skill static analysis scanner.
 *
 * Scans .js/.ts/.mjs/.mts files for suspicious patterns including:
 * - Shell command execution (child_process)
 * - Dynamic code execution (eval, new Function)
 * - Data exfiltration (file read + network send)
 * - Credential harvesting (process.env + network send)
 * - Obfuscated code (hex sequences, large base64)
 * - Crypto-mining references
 * - Filesystem writes outside agent home
 * - Privilege escalation patterns
 * - Network listeners (potential backdoors)
 *
 * Ported from OpenClaw's skill-scanner.ts.
 *
 * Usage: node scan-extensions.mjs [dir1] [dir2] ...
 *        Defaults to ~/baudbot/pi/extensions ~/baudbot/pi/skills
 */

import { readdir, readFile, stat } from "node:fs/promises";
import { join, extname, resolve, relative } from "node:path";
import { homedir } from "node:os";

// ── Config ──────────────────────────────────────────────────────────────────

const SCANNABLE_EXTENSIONS = new Set([".js", ".ts", ".mjs", ".cjs", ".mts", ".cts", ".jsx", ".tsx"]);
const MAX_FILES = 500;
const MAX_FILE_BYTES = 1024 * 1024; // 1MB

// ── Rule definitions ────────────────────────────────────────────────────────

/** Line rules — tested per-line, fire once per file. */
const LINE_RULES = [
  {
    id: "dangerous-exec",
    severity: "critical",
    message: "Shell command execution detected (child_process)",
    pattern: /\b(exec|execSync|spawn|spawnSync|execFile|execFileSync)\s*\(/,
    requiresContext: /child_process/,
  },
  {
    id: "dynamic-code-execution",
    severity: "critical",
    message: "Dynamic code execution detected (eval/new Function)",
    pattern: /\beval\s*\(|new\s+Function\s*\(/,
  },
  {
    id: "crypto-mining",
    severity: "critical",
    message: "Possible crypto-mining reference detected",
    pattern: /stratum\+tcp|stratum\+ssl|coinhive|cryptonight|xmrig/i,
  },
  {
    id: "suspicious-network",
    severity: "warn",
    message: "WebSocket connection to non-standard port",
    pattern: /new\s+WebSocket\s*\(\s*["']wss?:\/\/[^"']*:(\d+)/,
  },
  {
    id: "fs-write-outside-home",
    severity: "critical",
    message: "Filesystem write to system path detected",
    pattern: /writeFileSync?\s*\(\s*["'`](\/etc\/|\/usr\/|\/var\/|\/root\/)/,
  },
  {
    id: "privilege-escalation",
    severity: "critical",
    message: "Privilege escalation pattern detected (sudo/chmod/chown)",
    pattern: /\bsudo\b|chmod\s+[0-7]{3,4}\s+\/|chown\s+root/,
    requiresContext: /child_process|execSync|spawn/,
  },
  {
    id: "network-listener",
    severity: "warn",
    message: "Network server/listener detected (potential backdoor)",
    pattern: /\.listen\s*\(\s*\d+|createServer\s*\(/,
    requiresContext: /\bnet\b|\bhttp\b|\bhttps\b|\bexpress\b/,
  },
  {
    id: "prototype-pollution",
    severity: "warn",
    message: "Potential prototype pollution pattern",
    pattern: /__proto__|Object\.setPrototypeOf|constructor\s*\[/,
  },
  {
    id: "unsafe-deserialization",
    severity: "warn",
    message: "Unsafe deserialization (JSON.parse on external input without validation)",
    pattern: /JSON\.parse\s*\(\s*(req\.|request\.|body|input|external|untrusted)/,
  },
];

const STANDARD_PORTS = new Set([80, 443, 8080, 8443, 3000]);

/** Source rules — tested against full file content. */
const SOURCE_RULES = [
  {
    id: "potential-exfiltration",
    severity: "warn",
    message: "File read combined with network send — possible data exfiltration",
    pattern: /readFileSync|readFile/,
    requiresContext: /\bfetch\b|\bpost\b|http\.request/i,
  },
  {
    id: "obfuscated-hex",
    severity: "warn",
    message: "Hex-encoded string sequence detected (possible obfuscation)",
    pattern: /(\\x[0-9a-fA-F]{2}){6,}/,
  },
  {
    id: "obfuscated-base64",
    severity: "warn",
    message: "Large base64 payload with decode call detected (possible obfuscation)",
    pattern: /(?:atob|Buffer\.from)\s*\(\s*["'][A-Za-z0-9+/=]{200,}["']/,
  },
  {
    id: "env-harvesting",
    severity: "critical",
    message: "Environment variable access combined with network send — possible credential harvesting",
    pattern: /process\.env/,
    requiresContext: /\bfetch\b|\bpost\b|http\.request/i,
  },
  {
    id: "credential-logging",
    severity: "warn",
    message: "Possible credential logging (process.env written to log/console)",
    pattern: /process\.env/,
    // Uses [\s\S]*? to match across newlines in full-source context check
    requiresContext: /console\.(log|info|warn|error|debug)\s*\([\s\S]*?process\.env/,
  },
  {
    id: "dynamic-require",
    severity: "info",
    message: "Dynamic require/import — may load untrusted modules",
    pattern: /require\s*\(\s*[^"'`]|import\s*\(\s*[^"'`]/,
  },
];

// ── Scanner ─────────────────────────────────────────────────────────────────

function truncateEvidence(evidence, maxLen = 120) {
  if (evidence.length <= maxLen) return evidence;
  return evidence.slice(0, maxLen) + "…";
}

function scanSource(source, filePath) {
  const findings = [];
  const lines = source.split("\n");
  const matchedLineRules = new Set();

  // Line rules
  for (const rule of LINE_RULES) {
    if (matchedLineRules.has(rule.id)) continue;
    if (rule.requiresContext && !rule.requiresContext.test(source)) continue;

    for (let i = 0; i < lines.length; i++) {
      const line = lines[i];
      const match = rule.pattern.exec(line);
      if (!match) continue;

      // Special: skip standard ports for suspicious-network
      if (rule.id === "suspicious-network") {
        const port = parseInt(match[1], 10);
        if (STANDARD_PORTS.has(port)) continue;
      }

      findings.push({
        ruleId: rule.id,
        severity: rule.severity,
        file: filePath,
        line: i + 1,
        message: rule.message,
        evidence: truncateEvidence(line.trim()),
      });
      matchedLineRules.add(rule.id);
      break;
    }
  }

  // Source rules
  const matchedSourceRules = new Set();
  for (const rule of SOURCE_RULES) {
    const ruleKey = `${rule.id}::${rule.message}`;
    if (matchedSourceRules.has(ruleKey)) continue;
    if (!rule.pattern.test(source)) continue;
    if (rule.requiresContext && !rule.requiresContext.test(source)) continue;

    let matchLine = 0;
    let matchEvidence = "";
    for (let i = 0; i < lines.length; i++) {
      if (rule.pattern.test(lines[i])) {
        matchLine = i + 1;
        matchEvidence = lines[i].trim();
        break;
      }
    }
    if (matchLine === 0) {
      matchLine = 1;
      matchEvidence = source.slice(0, 120);
    }

    findings.push({
      ruleId: rule.id,
      severity: rule.severity,
      file: filePath,
      line: matchLine,
      message: rule.message,
      evidence: truncateEvidence(matchEvidence),
    });
    matchedSourceRules.add(ruleKey);
  }

  return findings;
}

async function walkDir(dirPath, maxFiles) {
  const files = [];
  const stack = [dirPath];

  while (stack.length > 0 && files.length < maxFiles) {
    const dir = stack.pop();
    let entries;
    try {
      entries = await readdir(dir, { withFileTypes: true });
    } catch {
      continue;
    }

    for (const entry of entries) {
      if (files.length >= maxFiles) break;
      if (entry.name.startsWith(".") || entry.name === "node_modules") continue;

      const fullPath = join(dir, entry.name);
      if (entry.isDirectory()) {
        stack.push(fullPath);
      } else if (SCANNABLE_EXTENSIONS.has(extname(entry.name).toLowerCase())) {
        files.push(fullPath);
      }
    }
  }
  return files;
}

async function scanDirectory(dirPath) {
  const files = await walkDir(dirPath, MAX_FILES);
  const allFindings = [];
  let scanned = 0;

  for (const file of files) {
    try {
      const st = await stat(file);
      if (!st.isFile() || st.size > MAX_FILE_BYTES) continue;
      const source = await readFile(file, "utf-8");
      scanned++;
      const findings = scanSource(source, file);
      allFindings.push(...findings);
    } catch {
    }
  }

  return { scanned, findings: allFindings };
}

// ── CLI ─────────────────────────────────────────────────────────────────────

const SEVERITY_ICONS = {
  critical: "❌",
  warn: "⚠️ ",
  info: "ℹ️ ",
};

const SEVERITY_ORDER = { critical: 0, warn: 1, info: 2 };

async function main() {
  const home = homedir();
  const dirs = process.argv.slice(2);
  if (dirs.length === 0) {
    dirs.push(join(home, "baudbot/pi/extensions"), join(home, "baudbot/pi/skills"));
  }

  let totalScanned = 0;
  let totalCritical = 0;
  let totalWarn = 0;
  const allFindings = [];

  console.log("");
  console.log("🔍 Extension & Skill Scanner");
  console.log("============================");

  for (const dir of dirs) {
    const resolved = resolve(dir);
    console.log(`\nScanning: ${resolved}`);

    try {
      await stat(resolved);
    } catch {
      console.log("  (directory not found, skipping)");
      continue;
    }

    const { scanned, findings } = await scanDirectory(resolved);
    totalScanned += scanned;
    allFindings.push(...findings);

    if (findings.length === 0) {
      console.log(`  ✅ ${scanned} files scanned, no findings`);
    } else {
      console.log(`  ${scanned} files scanned, ${findings.length} finding(s):`);
      // Sort by severity
      findings.sort((a, b) => (SEVERITY_ORDER[a.severity] ?? 2) - (SEVERITY_ORDER[b.severity] ?? 2));
      for (const f of findings) {
        const icon = SEVERITY_ICONS[f.severity] ?? "?";
        const relPath = relative(resolved, f.file);
        console.log(`  ${icon} ${f.severity.toUpperCase()}: ${f.message}`);
        console.log(`     ${relPath}:${f.line}`);
        console.log(`     ${f.evidence}`);
        if (f.severity === "critical") totalCritical++;
        if (f.severity === "warn") totalWarn++;
      }
    }
  }

  const totalInfo = allFindings.filter((f) => f.severity === "info").length;

  console.log("");
  console.log("Summary");
  console.log("───────");
  console.log(`  Files scanned: ${totalScanned}`);
  console.log(`  ❌ Critical:   ${totalCritical}`);
  console.log(`  ⚠️  Warn:       ${totalWarn}`);
  if (totalInfo > 0) console.log(`  ℹ️  Info:       ${totalInfo}`);
  console.log("");

  if (totalCritical > 0) {
    console.log(`🚨 ${totalCritical} critical finding(s) — review immediately!`);
    process.exit(2);
  } else if (totalWarn > 0) {
    console.log(`⚠️  ${totalWarn} warning(s) — review recommended.`);
    process.exit(1);
  } else {
    if (totalInfo > 0) console.log(`ℹ️  ${totalInfo} info finding(s) — no action required.`);
    else console.log("✅ All clean.");
    process.exit(0);
  }
}

main().catch((err) => {
  console.error("Scanner error:", err);
  process.exit(3);
});
