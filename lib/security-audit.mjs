/**
 * Structured security audit module.
 *
 * Complements bin/security-audit.sh with structured, typed findings
 * that can be consumed programmatically (JSON output, CI checks).
 *
 * Focuses on checks that work without root access:
 * - File permission verification
 * - Deploy integrity (manifest hash checking)
 * - Secret exposure scanning
 * - Extension/skill safety scanning
 * - Configuration validation
 *
 * Pure functions where possible — filesystem access is explicit and injectable.
 */

import fs from "node:fs/promises";
import path from "node:path";
import { createHash } from "node:crypto";

// ── Types ───────────────────────────────────────────────────────────────────

/**
 * @typedef {"critical" | "warn" | "info"} Severity
 *
 * @typedef {{
 *   checkId: string,
 *   severity: Severity,
 *   title: string,
 *   detail: string,
 *   remediation?: string,
 *   fixable?: boolean,
 * }} Finding
 *
 * @typedef {{
 *   critical: number,
 *   warn: number,
 *   info: number,
 *   pass: number,
 *   fixed: number,
 * }} AuditSummary
 *
 * @typedef {{
 *   timestamp: string,
 *   summary: AuditSummary,
 *   findings: Finding[],
 * }} AuditReport
 */

// ── Helpers ─────────────────────────────────────────────────────────────────

/**
 * Get file permissions as octal string. Returns null if file doesn't exist.
 * @param {string} filePath
 * @returns {Promise<string | null>}
 */
export async function getFilePerms(filePath) {
  try {
    const stat = await fs.stat(filePath);
    return (stat.mode & 0o777).toString(8);
  } catch {
    return null;
  }
}

/**
 * Check if a path is a symlink.
 * @param {string} filePath
 * @returns {Promise<boolean>}
 */
export async function isSymlink(filePath) {
  try {
    const stat = await fs.lstat(filePath);
    return stat.isSymbolicLink();
  } catch {
    return false;
  }
}

/**
 * SHA256 hash a file.
 * @param {string} filePath
 * @returns {Promise<string | null>}
 */
export async function hashFile(filePath) {
  try {
    const data = await fs.readFile(filePath);
    return createHash("sha256").update(data).digest("hex");
  } catch {
    return null;
  }
}

// ── Individual Checks ───────────────────────────────────────────────────────

/**
 * Check file permissions against expected values.
 * @param {string} filePath
 * @param {string} expectedPerms - Octal string like "600"
 * @param {string} description
 * @returns {Promise<Finding | null>} Finding if mismatch, null if OK
 */
export async function checkFilePerms(filePath, expectedPerms, description) {
  const perms = await getFilePerms(filePath);
  if (perms === null) return null; // File doesn't exist, skip

  if (perms === expectedPerms) return null; // OK

  // Group/world readable secrets = critical
  const isSensitive = expectedPerms === "600" || expectedPerms === "700";
  const isGroupWorldReadable = (parseInt(perms, 8) & 0o044) !== 0;
  const severity = isSensitive && isGroupWorldReadable ? "critical" : "warn";

  return {
    checkId: "perms-" + path.basename(filePath),
    severity,
    title: `${description} has permissions ${perms} (expected ${expectedPerms})`,
    detail: filePath,
    remediation: `chmod ${expectedPerms} ${filePath}`,
    fixable: true,
  };
}

/**
 * Check that a directory is not a symlink (should be a real dir for security).
 * @param {string} dirPath
 * @param {string} description
 * @returns {Promise<Finding | null>}
 */
export async function checkNotSymlink(dirPath, description) {
  if (await isSymlink(dirPath)) {
    return {
      checkId: "symlink-" + path.basename(dirPath),
      severity: "critical",
      title: `${description} is a symlink (should be a real directory)`,
      detail: dirPath,
      remediation: `rm ${dirPath} && mkdir ${dirPath} && run deploy.sh`,
      fixable: false,
    };
  }
  return null;
}

/**
 * Check deploy manifest integrity for critical files.
 * @param {string} homeDir - Agent home directory
 * @returns {Promise<Finding[]>}
 */
export async function checkManifestIntegrity(homeDir) {
  const manifestPath = path.join(homeDir, ".pi/agent/baudbot-manifest.json");
  const findings = [];

  let manifest;
  try {
    manifest = JSON.parse(await fs.readFile(manifestPath, "utf8"));
  } catch {
    findings.push({
      checkId: "manifest-missing",
      severity: "warn",
      title: "No deploy manifest found — cannot verify integrity",
      detail: manifestPath,
      remediation: "Run deploy.sh to generate",
      fixable: false,
    });
    return findings;
  }

  const criticalFiles = [
    ".pi/agent/extensions/tool-guard.ts",
    ".pi/agent/extensions/tool-guard.test.mjs",
    "runtime/slack-bridge/security.mjs",
    "runtime/slack-bridge/security.test.mjs",
  ];

  for (const relPath of criticalFiles) {
    const fullPath = path.join(homeDir, relPath);
    const expectedHash = manifest[relPath];

    if (!expectedHash) {
      findings.push({
        checkId: `manifest-missing-entry-${path.basename(relPath)}`,
        severity: "warn",
        title: `${relPath} not in manifest`,
        detail: "Run deploy.sh to regenerate",
        fixable: false,
      });
      continue;
    }

    const actualHash = await hashFile(fullPath);
    if (actualHash === null) {
      findings.push({
        checkId: `file-missing-${path.basename(relPath)}`,
        severity: "warn",
        title: `Missing critical file: ${relPath}`,
        detail: fullPath,
        remediation: "Run deploy.sh",
        fixable: false,
      });
      continue;
    }

    if (actualHash !== expectedHash) {
      findings.push({
        checkId: `integrity-${path.basename(relPath)}`,
        severity: "critical",
        title: `${relPath}: HASH MISMATCH (possibly tampered)`,
        detail: `Expected: ${expectedHash.slice(0, 16)}… Got: ${actualHash.slice(0, 16)}…`,
        remediation: "Re-deploy: deploy.sh",
        fixable: false,
      });
    }
  }

  return findings;
}

/**
 * Check for secrets in group/world-readable files.
 * @param {string} homeDir
 * @returns {Promise<Finding[]>}
 */
export async function checkSecretExposure(homeDir) {
  const findings = [];

  // Check .env permissions
  const envPath = path.join(homeDir, ".config/.env");
  const envPerms = await getFilePerms(envPath);
  if (envPerms !== null && envPerms !== "600") {
    const isWorldReadable = (parseInt(envPerms, 8) & 0o044) !== 0;
    findings.push({
      checkId: "secret-env-perms",
      severity: isWorldReadable ? "critical" : "warn",
      title: `Secrets file has permissions ${envPerms} (expected 600)`,
      detail: envPath,
      remediation: `chmod 600 ${envPath}`,
      fixable: true,
    });
  }

  // Check for stale .env copies outside .config
  try {
    const entries = await fs.readdir(homeDir, { withFileTypes: true });
    for (const entry of entries) {
      if (entry.name === ".config" || entry.name === "node_modules" || entry.name === ".git") continue;
      const childPath = path.join(homeDir, entry.name);
      if (entry.isDirectory()) {
        try {
          const subEntries = await fs.readdir(childPath);
          for (const sub of subEntries) {
            if (sub === ".env") {
              findings.push({
                checkId: "stale-env-" + entry.name,
                severity: "warn",
                title: `Found .env file outside ~/.config: ${entry.name}/.env`,
                detail: path.join(childPath, sub),
                remediation: `Remove or move to ~/.config/: rm ${path.join(childPath, sub)}`,
                fixable: false,
              });
            }
          }
        } catch { /* skip unreadable dirs */ }
      }
    }
  } catch { /* skip if home not readable */ }

  return findings;
}

/**
 * Check configuration in .env file.
 * @param {string} homeDir
 * @returns {Promise<Finding[]>}
 */
export async function checkConfiguration(homeDir) {
  const findings = [];
  const envPath = path.join(homeDir, ".config/.env");

  let envContent;
  try {
    envContent = await fs.readFile(envPath, "utf8");
  } catch {
    findings.push({
      checkId: "config-env-missing",
      severity: "warn",
      title: "No .env file found",
      detail: envPath,
      remediation: "Create .config/.env with required environment variables",
      fixable: false,
    });
    return findings;
  }

  // Check SLACK_ALLOWED_USERS
  const allowedMatch = envContent.match(/^SLACK_ALLOWED_USERS=(.*)$/m);
  if (!allowedMatch) {
    findings.push({
      checkId: "config-no-allowed-users",
      severity: "critical",
      title: "SLACK_ALLOWED_USERS not set in .env",
      detail: "Bridge will refuse to start without an allowlist",
      remediation: "Add SLACK_ALLOWED_USERS=U... to .config/.env",
      fixable: false,
    });
  } else {
    const users = allowedMatch[1].split(",").filter(Boolean);
    if (users.length === 0) {
      findings.push({
        checkId: "config-empty-allowed-users",
        severity: "critical",
        title: "SLACK_ALLOWED_USERS is empty",
        detail: "Bridge will refuse to start — add at least one user ID",
        remediation: "Set SLACK_ALLOWED_USERS=U... in .config/.env",
        fixable: false,
      });
    }
  }

  return findings;
}

// ── Main Audit Runner ───────────────────────────────────────────────────────

/**
 * Run all security checks and return a structured report.
 * @param {object} options
 * @param {string} options.homeDir - Agent home directory
 * @param {boolean} [options.fix=false] - Attempt auto-remediation
 * @returns {Promise<AuditReport>}
 */
export async function runAudit({ homeDir, fix = false }) {
  const findings = [];
  let fixedCount = 0;

  // ── Permission checks ──────────────────────────────────────────────────
  const permChecks = [
    [path.join(homeDir, ".ssh"), "700", "SSH directory"],
    [path.join(homeDir, ".pi"), "700", "Pi state directory"],
    [path.join(homeDir, ".pi/agent"), "700", "Pi agent directory"],
    [path.join(homeDir, ".pi/session-control"), "700", "Pi session-control directory"],
    [path.join(homeDir, ".pi/agent/settings.json"), "600", "Pi settings"],
  ];

  for (const [filePath, expected, desc] of permChecks) {
    const finding = await checkFilePerms(filePath, expected, desc);
    if (finding) {
      if (fix && finding.fixable) {
        try {
          await fs.chmod(filePath, parseInt(expected, 8));
          fixedCount++;
          continue; // Fixed — don't report
        } catch { /* fall through to report */ }
      }
      findings.push(finding);
    }
  }

  // ── Symlink checks ─────────────────────────────────────────────────────
  const symlinkChecks = [
    [path.join(homeDir, ".pi/agent/extensions"), "Extensions directory"],
    [path.join(homeDir, ".pi/agent/skills"), "Skills directory"],
  ];

  for (const [dirPath, desc] of symlinkChecks) {
    const finding = await checkNotSymlink(dirPath, desc);
    if (finding) findings.push(finding);
  }

  // ── Integrity checks ──────────────────────────────────────────────────
  const integrityFindings = await checkManifestIntegrity(homeDir);
  findings.push(...integrityFindings);

  // ── Secret exposure ────────────────────────────────────────────────────
  const secretFindings = await checkSecretExposure(homeDir);
  for (const finding of secretFindings) {
    if (fix && finding.fixable) {
      try {
        const mode = finding.remediation?.match(/chmod (\d+)/)?.[1];
        if (mode) {
          await fs.chmod(finding.detail, parseInt(mode, 8));
          fixedCount++;
          continue;
        }
      } catch { /* fall through */ }
    }
    findings.push(finding);
  }

  // ── Configuration ──────────────────────────────────────────────────────
  const configFindings = await checkConfiguration(homeDir);
  findings.push(...configFindings);

  // ── Build report ───────────────────────────────────────────────────────
  const permSymlinkFindings = findings.filter(
    (f) => f.checkId.startsWith("perms-") || f.checkId.startsWith("symlink-"),
  ).length;
  const summary = {
    critical: findings.filter((f) => f.severity === "critical").length,
    warn: findings.filter((f) => f.severity === "warn").length,
    info: findings.filter((f) => f.severity === "info").length,
    pass: Math.max(0, permChecks.length + symlinkChecks.length - permSymlinkFindings + fixedCount),
    fixed: fixedCount,
  };

  return {
    timestamp: new Date().toISOString(),
    summary,
    findings,
  };
}

// ── CLI ─────────────────────────────────────────────────────────────────────

/**
 * Format a report for human-readable terminal output.
 * @param {AuditReport} report
 * @returns {string}
 */
export function formatReport(report) {
  const lines = [];
  lines.push("");
  lines.push("🔒 Baudbot Security Audit (structured)");
  lines.push("======================================");
  lines.push("");

  if (report.findings.length === 0) {
    lines.push("  ✅ All checks passed.");
  } else {
    for (const f of report.findings) {
      const icon = f.severity === "critical" ? "❌" : f.severity === "warn" ? "⚠️ " : "ℹ️ ";
      const sev = f.severity.toUpperCase().padEnd(8);
      lines.push(`  ${icon} ${sev} ${f.title}`);
      if (f.detail) lines.push(`              ${f.detail}`);
      if (f.remediation) lines.push(`              Fix: ${f.remediation}`);
    }
  }

  lines.push("");
  lines.push("Summary");
  lines.push("───────");
  lines.push(`  ✅ Pass:     ${report.summary.pass}`);
  lines.push(`  ❌ Critical: ${report.summary.critical}`);
  lines.push(`  ⚠️  Warn:     ${report.summary.warn}`);
  lines.push(`  ℹ️  Info:     ${report.summary.info}`);
  if (report.summary.fixed > 0) {
    lines.push(`  🔧 Fixed:    ${report.summary.fixed}`);
  }
  lines.push("");

  return lines.join("\n");
}

// ── CLI entry point ─────────────────────────────────────────────────────────

const isMain = process.argv[1] &&
  path.basename(process.argv[1]) === "security-audit.mjs";

if (isMain) {
  const args = process.argv.slice(2);
  const json = args.includes("--json");
  const fix = args.includes("--fix");
  const homeDir = args.find((a) => !a.startsWith("--")) || process.env.BAUDBOT_HOME || "/home/baudbot_agent";

  const report = await runAudit({ homeDir, fix });

  if (json) {
    process.stdout.write(JSON.stringify(report, null, 2) + "\n");
  } else {
    process.stdout.write(formatReport(report));
  }

  if (report.summary.critical > 0) process.exit(2);
  if (report.summary.warn > 0) process.exit(1);
  process.exit(0);
}
