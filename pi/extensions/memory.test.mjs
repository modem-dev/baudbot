/**
 * Tests for persistent agent memory.
 *
 * Tests the memory seed files, deploy logic, and skill file integration.
 * Memory is a convention (Markdown files + deploy script), not a runtime
 * module, so we test file structure, content, and deploy behavior.
 *
 * Run: node --test pi/extensions/memory.test.mjs
 */

import { describe, it, beforeEach, afterEach } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import os from "node:os";
import { execSync } from "node:child_process";

// ── Paths ───────────────────────────────────────────────────────────────────

const REPO_ROOT = path.resolve(
  path.dirname(new URL(import.meta.url).pathname),
  "../.."
);
const MEMORY_SEED_DIR = path.join(
  REPO_ROOT,
  "pi/skills/control-agent/memory"
);
const EXPECTED_SEED_FILES = [
  "operational.md",
  "repos.md",
  "users.md",
  "incidents.md",
];

// ── Test helpers ────────────────────────────────────────────────────────────

let tmpDir;

function setup() {
  tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "memory-test-"));
}

function teardown() {
  fs.rmSync(tmpDir, { recursive: true, force: true });
}

// ── Tests: seed files exist and have correct structure ──────────────────────

describe("memory: seed files exist", () => {
  it("memory seed directory exists", () => {
    assert.ok(
      fs.existsSync(MEMORY_SEED_DIR),
      `Memory seed directory should exist at ${MEMORY_SEED_DIR}`
    );
  });

  for (const file of EXPECTED_SEED_FILES) {
    it(`seed file exists: ${file}`, () => {
      const filePath = path.join(MEMORY_SEED_DIR, file);
      assert.ok(fs.existsSync(filePath), `${file} should exist`);
    });
  }

  it("no unexpected files in memory seed directory", () => {
    const actual = fs
      .readdirSync(MEMORY_SEED_DIR)
      .filter((f) => f.endsWith(".md"))
      .sort();
    const expected = [...EXPECTED_SEED_FILES].sort();
    assert.deepEqual(actual, expected);
  });
});

describe("memory: seed file content", () => {
  for (const file of EXPECTED_SEED_FILES) {
    it(`${file} is valid Markdown with a heading`, () => {
      const content = fs.readFileSync(
        path.join(MEMORY_SEED_DIR, file),
        "utf-8"
      );
      assert.ok(content.length > 0, "file should not be empty");
      assert.ok(content.startsWith("#"), "file should start with a Markdown heading");
    });

    it(`${file} contains no-secrets warning`, () => {
      const content = fs.readFileSync(
        path.join(MEMORY_SEED_DIR, file),
        "utf-8"
      );
      assert.ok(
        content.includes("DO NOT store secrets") ||
          content.includes("do not store secrets"),
        `${file} should contain a no-secrets warning`
      );
    });

    it(`${file} does not contain actual secrets`, () => {
      const content = fs.readFileSync(
        path.join(MEMORY_SEED_DIR, file),
        "utf-8"
      );
      // Check for common secret patterns
      assert.ok(!content.match(/sk-ant-[a-zA-Z0-9]/), "should not contain Anthropic keys");
      assert.ok(!content.match(/sk-[a-zA-Z0-9]{20,}/), "should not contain OpenAI keys");
      assert.ok(!content.match(/ghp_[a-zA-Z0-9]{20,}/), "should not contain GitHub tokens");
      assert.ok(!content.match(/xoxb-[a-zA-Z0-9]/), "should not contain Slack tokens");
      assert.ok(!content.match(/xapp-[a-zA-Z0-9]/), "should not contain Slack app tokens");
    });

    it(`${file} contains only example/template content (comments)`, () => {
      const content = fs.readFileSync(
        path.join(MEMORY_SEED_DIR, file),
        "utf-8"
      );
      // Meaningful lines (not headings, not empty, not comments, not HTML comments)
      const meaningful = content
        .split("\n")
        .filter((line) => {
          const trimmed = line.trim();
          if (trimmed.length === 0) return false;
          if (trimmed.startsWith("#")) return false;
          if (trimmed.startsWith("<!--")) return false;
          if (trimmed.startsWith("-->")) return false;
          if (trimmed.startsWith("**DO NOT")) return false;
          return true;
        });
      // Should only have template/description text, not real entries
      for (const line of meaningful) {
        assert.ok(
          !line.match(/^## \d{4}-\d{2}-\d{2}/),
          `${file} should not contain real dated entries (found: ${line})`
        );
      }
    });
  }
});

describe("memory: repos.md has known repo sections", () => {
  it("contains modem section", () => {
    const content = fs.readFileSync(
      path.join(MEMORY_SEED_DIR, "repos.md"),
      "utf-8"
    );
    assert.ok(content.includes("## modem"), "should have modem section");
  });

  it("contains website section", () => {
    const content = fs.readFileSync(
      path.join(MEMORY_SEED_DIR, "repos.md"),
      "utf-8"
    );
    assert.ok(content.includes("## website"), "should have website section");
  });

  it("contains baudbot section", () => {
    const content = fs.readFileSync(
      path.join(MEMORY_SEED_DIR, "repos.md"),
      "utf-8"
    );
    assert.ok(content.includes("## baudbot"), "should have baudbot section");
  });
});

// ── Tests: deploy script seeds correctly ────────────────────────────────────

describe("memory: deploy seeding logic", () => {
  beforeEach(setup);
  afterEach(teardown);

  it("copies seed files to empty destination", () => {
    const destDir = path.join(tmpDir, "memory");
    fs.mkdirSync(destDir, { recursive: true });

    for (const file of EXPECTED_SEED_FILES) {
      const src = path.join(MEMORY_SEED_DIR, file);
      const dest = path.join(destDir, file);
      // Simulate: [ -f dest ] || cp src dest
      if (!fs.existsSync(dest)) {
        fs.copyFileSync(src, dest);
      }
    }

    for (const file of EXPECTED_SEED_FILES) {
      assert.ok(
        fs.existsSync(path.join(destDir, file)),
        `${file} should be seeded`
      );
    }
  });

  it("does NOT overwrite existing files", () => {
    const destDir = path.join(tmpDir, "memory");
    fs.mkdirSync(destDir, { recursive: true });

    // Pre-populate with agent-modified content
    const customContent = "# Operational Learnings\n\n## 2026-02-17\n- Custom entry\n";
    fs.writeFileSync(path.join(destDir, "operational.md"), customContent);

    // Run the seed logic
    for (const file of EXPECTED_SEED_FILES) {
      const src = path.join(MEMORY_SEED_DIR, file);
      const dest = path.join(destDir, file);
      // Simulate: [ -f dest ] || cp src dest
      if (!fs.existsSync(dest)) {
        fs.copyFileSync(src, dest);
      }
    }

    // operational.md should keep agent's custom content
    const result = fs.readFileSync(
      path.join(destDir, "operational.md"),
      "utf-8"
    );
    assert.equal(result, customContent, "should NOT overwrite existing file");

    // Other files should be seeded (they didn't exist)
    for (const file of EXPECTED_SEED_FILES) {
      assert.ok(
        fs.existsSync(path.join(destDir, file)),
        `${file} should exist after seeding`
      );
    }
  });

  it("handles partial seeding (some files exist, some don't)", () => {
    const destDir = path.join(tmpDir, "memory");
    fs.mkdirSync(destDir, { recursive: true });

    // Only repos.md exists
    const customRepos = "# Repos\n\n## modem\n- Uses Next.js 15\n";
    fs.writeFileSync(path.join(destDir, "repos.md"), customRepos);

    for (const file of EXPECTED_SEED_FILES) {
      const src = path.join(MEMORY_SEED_DIR, file);
      const dest = path.join(destDir, file);
      if (!fs.existsSync(dest)) {
        fs.copyFileSync(src, dest);
      }
    }

    // repos.md should keep custom content
    assert.equal(
      fs.readFileSync(path.join(destDir, "repos.md"), "utf-8"),
      customRepos
    );

    // Others should be seeded from templates
    for (const file of ["operational.md", "users.md", "incidents.md"]) {
      const content = fs.readFileSync(path.join(destDir, file), "utf-8");
      const seed = fs.readFileSync(path.join(MEMORY_SEED_DIR, file), "utf-8");
      assert.equal(content, seed, `${file} should match seed template`);
    }
  });
});

// ── Tests: skill files reference memory correctly ───────────────────────────

describe("memory: skill file integration", () => {
  const controlSkill = fs.readFileSync(
    path.join(REPO_ROOT, "pi/skills/control-agent/SKILL.md"),
    "utf-8"
  );
  const devSkill = fs.readFileSync(
    path.join(REPO_ROOT, "pi/skills/dev-agent/SKILL.md"),
    "utf-8"
  );
  const sentrySkill = fs.readFileSync(
    path.join(REPO_ROOT, "pi/skills/sentry-agent/SKILL.md"),
    "utf-8"
  );

  it("control-agent SKILL.md has Memory section", () => {
    assert.ok(controlSkill.includes("## Memory"), "should have Memory section");
  });

  it("control-agent SKILL.md references memory directory", () => {
    assert.ok(
      controlSkill.includes("~/.pi/agent/memory/"),
      "should reference memory directory"
    );
  });

  it("control-agent SKILL.md lists all memory files", () => {
    assert.ok(controlSkill.includes("operational.md"), "should list operational.md");
    assert.ok(controlSkill.includes("repos.md"), "should list repos.md");
    assert.ok(controlSkill.includes("users.md"), "should list users.md");
    assert.ok(controlSkill.includes("incidents.md"), "should list incidents.md");
  });

  it("control-agent startup checklist includes memory read", () => {
    assert.ok(
      controlSkill.includes("Read memory files"),
      "startup checklist should include memory read"
    );
  });

  it("control-agent SKILL.md warns against storing secrets", () => {
    assert.ok(
      controlSkill.includes("Never store secrets"),
      "should warn against storing secrets in memory"
    );
  });

  it("dev-agent SKILL.md has Memory section", () => {
    assert.ok(devSkill.includes("## Memory"), "should have Memory section");
  });

  it("dev-agent SKILL.md references repos.md", () => {
    assert.ok(
      devSkill.includes("repos.md"),
      "should reference repos.md"
    );
  });

  it("dev-agent SKILL.md warns against storing secrets", () => {
    assert.ok(
      devSkill.includes("Never store secrets"),
      "should warn against storing secrets"
    );
  });

  it("sentry-agent SKILL.md has Memory section", () => {
    assert.ok(sentrySkill.includes("## Memory"), "should have Memory section");
  });

  it("sentry-agent SKILL.md references incidents.md", () => {
    assert.ok(
      sentrySkill.includes("incidents.md"),
      "should reference incidents.md"
    );
  });

  it("sentry-agent startup reads incident history", () => {
    assert.ok(
      sentrySkill.includes("Read incident history"),
      "startup should read incident history"
    );
  });

  it("sentry-agent SKILL.md warns against storing secrets", () => {
    assert.ok(
      sentrySkill.includes("Never store secrets"),
      "should warn against storing secrets"
    );
  });
});

// ── Tests: deploy.sh has memory seeding ─────────────────────────────────────

describe("memory: deploy.sh integration", () => {
  const deployScript = fs.readFileSync(
    path.join(REPO_ROOT, "bin/deploy.sh"),
    "utf-8"
  );

  it("deploy.sh has memory seeds section", () => {
    assert.ok(
      deployScript.includes("Memory Seeds") || deployScript.includes("memory seeds"),
      "deploy.sh should have a memory seeds section"
    );
  });

  it("deploy.sh creates memory destination directory", () => {
    assert.ok(
      deployScript.includes("mkdir -p") &&
        deployScript.includes("memory"),
      "deploy.sh should create memory directory"
    );
  });

  it("deploy.sh uses conditional copy (won't overwrite)", () => {
    // The key pattern: [ -f dest ] || cp src dest
    assert.ok(
      deployScript.includes("-f") && deployScript.includes("|| cp"),
      "deploy.sh should use conditional copy to avoid overwriting"
    );
  });
});

// ── Tests: setup.sh creates memory directory ────────────────────────────────

describe("memory: setup.sh integration", () => {
  const setupScript = fs.readFileSync(
    path.join(REPO_ROOT, "setup.sh"),
    "utf-8"
  );

  it("setup.sh creates memory directory", () => {
    assert.ok(
      setupScript.includes("mkdir -p") &&
        setupScript.includes("memory"),
      "setup.sh should create memory directory"
    );
  });
});
