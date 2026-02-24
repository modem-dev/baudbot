#!/usr/bin/env node

import fs from "node:fs";

const envPath = process.argv[2] || "";

function countUsers(rawValue) {
  if (!rawValue) return 0;
  return rawValue
    .split(",")
    .filter((entry) => entry.length > 0).length;
}

if (!envPath) {
  process.stdout.write(
    JSON.stringify({
      ok: "0",
      exists: "0",
      defined: "0",
      raw_non_empty: "0",
      count: "0",
      error: "missing_path_argument",
    }),
  );
  process.exit(0);
}

if (!fs.existsSync(envPath)) {
  process.stdout.write(
    JSON.stringify({
      ok: "1",
      exists: "0",
      defined: "0",
      raw_non_empty: "0",
      count: "0",
      error: "",
    }),
  );
  process.exit(0);
}

try {
  const lines = fs.readFileSync(envPath, "utf8").split(/\r?\n/);
  let value = "";
  let defined = false;

  for (const line of lines) {
    if (!line.startsWith("SLACK_ALLOWED_USERS=")) continue;
    value = line.slice("SLACK_ALLOWED_USERS=".length);
    defined = true;
  }

  const count = defined ? countUsers(value) : 0;

  process.stdout.write(
    JSON.stringify({
      ok: "1",
      exists: "1",
      defined: defined ? "1" : "0",
      raw_non_empty: defined && value.length > 0 ? "1" : "0",
      count: String(count),
      error: "",
    }),
  );
} catch {
  process.stdout.write(
    JSON.stringify({
      ok: "0",
      exists: "1",
      defined: "0",
      raw_non_empty: "0",
      count: "0",
      error: "parse_error",
    }),
  );
}
