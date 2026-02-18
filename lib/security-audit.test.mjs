/**
 * Tests for lib/security-audit.mjs — structured security audit module.
 *
 * Run: node --test lib/security-audit.test.mjs
 */

import { describe, it, beforeEach, afterEach } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs/promises";
import path from "node:path";
import os from "node:os";
import {
  getFilePerms,
  isSymlink,
  hashFile,
  checkFilePerms,
  checkNotSymlink,
  checkManifestIntegrity,
  checkSecretExposure,
  checkConfiguration,
  runAudit,
  formatReport,
} from "./security-audit.mjs";

let tmpDir;

beforeEach(async () => {
  tmpDir = await fs.mkdtemp(path.join(os.tmpdir(), "baudbot-audit-test-"));
});

afterEach(async () => {
  await fs.rm(tmpDir, { recursive: true, force: true });
});

// ── getFilePerms ────────────────────────────────────────────────────────────

describe("getFilePerms", () => {
  it("returns octal permissions for existing file", async () => {
    const f = path.join(tmpDir, "test.txt");
    await fs.writeFile(f, "hello");
    await fs.chmod(f, 0o644);
    const perms = await getFilePerms(f);
    assert.equal(perms, "644");
  });

  it("returns null for non-existent file", async () => {
    const perms = await getFilePerms(path.join(tmpDir, "nope.txt"));
    assert.equal(perms, null);
  });

  it("returns restricted permissions", async () => {
    const f = path.join(tmpDir, "secret.txt");
    await fs.writeFile(f, "secret");
    await fs.chmod(f, 0o600);
    assert.equal(await getFilePerms(f), "600");
  });
});

// ── isSymlink ───────────────────────────────────────────────────────────────

describe("isSymlink", () => {
  it("returns false for regular file", async () => {
    const f = path.join(tmpDir, "regular.txt");
    await fs.writeFile(f, "hello");
    assert.equal(await isSymlink(f), false);
  });

  it("returns false for directory", async () => {
    const d = path.join(tmpDir, "dir");
    await fs.mkdir(d);
    assert.equal(await isSymlink(d), false);
  });

  it("returns true for symlink", async () => {
    const target = path.join(tmpDir, "target");
    const link = path.join(tmpDir, "link");
    await fs.writeFile(target, "hello");
    await fs.symlink(target, link);
    assert.equal(await isSymlink(link), true);
  });

  it("returns false for non-existent path", async () => {
    assert.equal(await isSymlink(path.join(tmpDir, "nope")), false);
  });
});

// ── hashFile ────────────────────────────────────────────────────────────────

describe("hashFile", () => {
  it("returns consistent hash for same content", async () => {
    const f = path.join(tmpDir, "hashme.txt");
    await fs.writeFile(f, "hello world");
    const hash1 = await hashFile(f);
    const hash2 = await hashFile(f);
    assert.equal(hash1, hash2);
    assert.equal(typeof hash1, "string");
    assert.equal(hash1.length, 64); // SHA256 hex
  });

  it("returns different hash for different content", async () => {
    const f1 = path.join(tmpDir, "a.txt");
    const f2 = path.join(tmpDir, "b.txt");
    await fs.writeFile(f1, "hello");
    await fs.writeFile(f2, "world");
    assert.notEqual(await hashFile(f1), await hashFile(f2));
  });

  it("returns null for non-existent file", async () => {
    assert.equal(await hashFile(path.join(tmpDir, "nope")), null);
  });
});

// ── checkFilePerms ──────────────────────────────────────────────────────────

describe("checkFilePerms", () => {
  it("returns null when permissions match", async () => {
    const f = path.join(tmpDir, "ok.txt");
    await fs.writeFile(f, "hello");
    await fs.chmod(f, 0o600);
    const finding = await checkFilePerms(f, "600", "Test file");
    assert.equal(finding, null);
  });

  it("returns null for non-existent file", async () => {
    const finding = await checkFilePerms(path.join(tmpDir, "nope"), "600", "Missing");
    assert.equal(finding, null);
  });

  it("returns critical finding for world-readable secret", async () => {
    const f = path.join(tmpDir, "secret.txt");
    await fs.writeFile(f, "secret");
    await fs.chmod(f, 0o644);
    const finding = await checkFilePerms(f, "600", "Secrets file");
    assert.ok(finding);
    assert.equal(finding.severity, "critical");
    assert.ok(finding.title.includes("644"));
    assert.ok(finding.title.includes("600"));
    assert.equal(finding.fixable, true);
  });

  it("returns warn finding for non-sensitive permission mismatch", async () => {
    const f = path.join(tmpDir, "config.txt");
    await fs.writeFile(f, "config");
    await fs.chmod(f, 0o644);
    const finding = await checkFilePerms(f, "755", "Config file");
    assert.ok(finding);
    assert.equal(finding.severity, "warn");
  });
});

// ── checkNotSymlink ─────────────────────────────────────────────────────────

describe("checkNotSymlink", () => {
  it("returns null for real directory", async () => {
    const d = path.join(tmpDir, "real");
    await fs.mkdir(d);
    assert.equal(await checkNotSymlink(d, "Test dir"), null);
  });

  it("returns critical finding for symlink", async () => {
    const target = path.join(tmpDir, "target");
    const link = path.join(tmpDir, "link");
    await fs.mkdir(target);
    await fs.symlink(target, link);
    const finding = await checkNotSymlink(link, "Test dir");
    assert.ok(finding);
    assert.equal(finding.severity, "critical");
    assert.ok(finding.title.includes("symlink"));
  });
});

// ── checkManifestIntegrity ──────────────────────────────────────────────────

describe("checkManifestIntegrity", () => {
  it("returns warn finding when manifest is missing", async () => {
    const findings = await checkManifestIntegrity(tmpDir);
    assert.equal(findings.length, 1);
    assert.equal(findings[0].checkId, "manifest-missing");
    assert.equal(findings[0].severity, "warn");
  });

  it("reports critical finding for hash mismatch", async () => {
    // Set up a fake agent home with manifest and a tampered file
    const agentDir = path.join(tmpDir, ".pi/agent");
    const extDir = path.join(agentDir, "extensions");
    await fs.mkdir(extDir, { recursive: true });

    const toolGuardPath = path.join(extDir, "tool-guard.ts");
    await fs.writeFile(toolGuardPath, "original content");
    const originalHash = await hashFile(toolGuardPath);

    // Write manifest with the original hash
    const manifest = { ".pi/agent/extensions/tool-guard.ts": originalHash };
    await fs.writeFile(path.join(agentDir, "baudbot-manifest.json"), JSON.stringify(manifest));

    // Tamper with the file
    await fs.writeFile(toolGuardPath, "tampered content");

    const findings = await checkManifestIntegrity(tmpDir);
    const tamperFinding = findings.find((f) => f.checkId === "integrity-tool-guard.ts");
    assert.ok(tamperFinding, "expected integrity finding for tool-guard.ts");
    assert.equal(tamperFinding.severity, "critical");
    assert.ok(tamperFinding.title.includes("HASH MISMATCH"));
  });

  it("returns no findings when files match manifest", async () => {
    const agentDir = path.join(tmpDir, ".pi/agent");
    const extDir = path.join(agentDir, "extensions");
    const bridgeDir = path.join(tmpDir, "runtime/slack-bridge");
    await fs.mkdir(extDir, { recursive: true });
    await fs.mkdir(bridgeDir, { recursive: true });

    const files = {
      ".pi/agent/extensions/tool-guard.ts": "guard content",
      ".pi/agent/extensions/tool-guard.test.mjs": "guard tests",
      "runtime/slack-bridge/security.mjs": "security module",
      "runtime/slack-bridge/security.test.mjs": "security tests",
    };

    const manifest = {};
    for (const [rel, content] of Object.entries(files)) {
      const fullPath = path.join(tmpDir, rel);
      await fs.writeFile(fullPath, content);
      manifest[rel] = await hashFile(fullPath);
    }

    await fs.writeFile(path.join(agentDir, "baudbot-manifest.json"), JSON.stringify(manifest));

    const findings = await checkManifestIntegrity(tmpDir);
    assert.equal(findings.length, 0);
  });
});

// ── checkSecretExposure ─────────────────────────────────────────────────────

describe("checkSecretExposure", () => {
  it("reports finding for .env with wrong permissions", async () => {
    const configDir = path.join(tmpDir, ".config");
    await fs.mkdir(configDir, { recursive: true });
    const envPath = path.join(configDir, ".env");
    await fs.writeFile(envPath, "SECRET=value");
    await fs.chmod(envPath, 0o644);

    const findings = await checkSecretExposure(tmpDir);
    const envFinding = findings.find((f) => f.checkId === "secret-env-perms");
    assert.ok(envFinding);
    assert.equal(envFinding.severity, "critical");
  });

  it("finds stale .env copies", async () => {
    await fs.mkdir(path.join(tmpDir, ".config"), { recursive: true });
    await fs.writeFile(path.join(tmpDir, ".config/.env"), "ok");
    await fs.chmod(path.join(tmpDir, ".config/.env"), 0o600);

    const subDir = path.join(tmpDir, "slack-bridge");
    await fs.mkdir(subDir);
    await fs.writeFile(path.join(subDir, ".env"), "stale");

    const findings = await checkSecretExposure(tmpDir);
    const staleFinding = findings.find((f) => f.checkId === "stale-env-slack-bridge");
    assert.ok(staleFinding);
    assert.equal(staleFinding.severity, "warn");
  });

  it("returns no findings when clean", async () => {
    const configDir = path.join(tmpDir, ".config");
    await fs.mkdir(configDir, { recursive: true });
    await fs.writeFile(path.join(configDir, ".env"), "ok");
    await fs.chmod(path.join(configDir, ".env"), 0o600);

    const findings = await checkSecretExposure(tmpDir);
    assert.equal(findings.length, 0);
  });
});

// ── checkConfiguration ──────────────────────────────────────────────────────

describe("checkConfiguration", () => {
  it("reports missing .env", async () => {
    const findings = await checkConfiguration(tmpDir);
    assert.equal(findings.length, 1);
    assert.equal(findings[0].checkId, "config-env-missing");
  });

  it("reports missing SLACK_ALLOWED_USERS", async () => {
    const configDir = path.join(tmpDir, ".config");
    await fs.mkdir(configDir, { recursive: true });
    await fs.writeFile(path.join(configDir, ".env"), "OTHER_VAR=value");

    const findings = await checkConfiguration(tmpDir);
    const finding = findings.find((f) => f.checkId === "config-no-allowed-users");
    assert.ok(finding);
    assert.equal(finding.severity, "critical");
  });

  it("reports empty SLACK_ALLOWED_USERS", async () => {
    const configDir = path.join(tmpDir, ".config");
    await fs.mkdir(configDir, { recursive: true });
    await fs.writeFile(path.join(configDir, ".env"), "SLACK_ALLOWED_USERS=");

    const findings = await checkConfiguration(tmpDir);
    const finding = findings.find((f) => f.checkId === "config-empty-allowed-users");
    assert.ok(finding);
    assert.equal(finding.severity, "critical");
  });

  it("returns no findings when properly configured", async () => {
    const configDir = path.join(tmpDir, ".config");
    await fs.mkdir(configDir, { recursive: true });
    await fs.writeFile(path.join(configDir, ".env"), "SLACK_ALLOWED_USERS=U12345,U67890");

    const findings = await checkConfiguration(tmpDir);
    assert.equal(findings.length, 0);
  });
});

// ── runAudit ────────────────────────────────────────────────────────────────

describe("runAudit", () => {
  it("returns structured report", async () => {
    const report = await runAudit({ homeDir: tmpDir });
    assert.ok(report.timestamp);
    assert.ok(report.summary);
    assert.ok(Array.isArray(report.findings));
    assert.equal(typeof report.summary.critical, "number");
    assert.equal(typeof report.summary.warn, "number");
    assert.equal(typeof report.summary.info, "number");
    assert.equal(typeof report.summary.pass, "number");
  });

  it("fixes permissions when fix=true", async () => {
    // Create a secret file with wrong permissions
    const configDir = path.join(tmpDir, ".config");
    await fs.mkdir(configDir, { recursive: true });
    const envPath = path.join(configDir, ".env");
    await fs.writeFile(envPath, "SLACK_ALLOWED_USERS=U123");
    await fs.chmod(envPath, 0o644);

    const report = await runAudit({ homeDir: tmpDir, fix: true });
    assert.ok(report.summary.fixed > 0, "expected at least one fix");

    // Verify file was actually fixed
    const perms = await getFilePerms(envPath);
    assert.equal(perms, "600");
  });
});

// ── formatReport ────────────────────────────────────────────────────────────

describe("formatReport", () => {
  it("formats clean report", () => {
    const report = {
      timestamp: new Date().toISOString(),
      summary: { critical: 0, warn: 0, info: 0, pass: 5, fixed: 0 },
      findings: [],
    };
    const output = formatReport(report);
    assert.ok(output.includes("All checks passed"));
    assert.ok(output.includes("Pass:     5"));
  });

  it("formats report with findings", () => {
    const report = {
      timestamp: new Date().toISOString(),
      summary: { critical: 1, warn: 1, info: 0, pass: 3, fixed: 0 },
      findings: [
        { checkId: "test-crit", severity: "critical", title: "Bad thing", detail: "/some/path", remediation: "Fix it" },
        { checkId: "test-warn", severity: "warn", title: "Meh thing", detail: "/other/path" },
      ],
    };
    const output = formatReport(report);
    assert.ok(output.includes("Bad thing"));
    assert.ok(output.includes("Meh thing"));
    assert.ok(output.includes("Critical: 1"));
    assert.ok(output.includes("Warn:     1"));
    assert.ok(output.includes("Fix: Fix it"));
  });

  it("shows fixed count when non-zero", () => {
    const report = {
      timestamp: new Date().toISOString(),
      summary: { critical: 0, warn: 0, info: 0, pass: 5, fixed: 2 },
      findings: [],
    };
    const output = formatReport(report);
    assert.ok(output.includes("Fixed:    2"));
  });
});
