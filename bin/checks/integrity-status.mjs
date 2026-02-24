#!/usr/bin/env node

import fs from "node:fs";

function asString(value, fallback) {
  return typeof value === "string" && value.length > 0 ? value : fallback;
}

function asCountString(value) {
  if (typeof value === "number" && Number.isFinite(value) && value >= 0) {
    return String(Math.trunc(value));
  }
  if (typeof value === "string" && /^\d+$/.test(value)) {
    return value;
  }
  return "0";
}

const statusPath = process.argv[2] || "";

if (!statusPath) {
  process.stdout.write(
    JSON.stringify({
      ok: "0",
      exists: "0",
      status: "unknown",
      checked_at: "unknown",
      missing_files: "0",
      hash_mismatches: "0",
      error: "missing_path_argument",
    }),
  );
  process.exit(0);
}

if (!fs.existsSync(statusPath)) {
  process.stdout.write(
    JSON.stringify({
      ok: "1",
      exists: "0",
      status: "missing",
      checked_at: "unknown",
      missing_files: "0",
      hash_mismatches: "0",
      error: "",
    }),
  );
  process.exit(0);
}

try {
  const raw = fs.readFileSync(statusPath, "utf8");
  const parsed = JSON.parse(raw);

  process.stdout.write(
    JSON.stringify({
      ok: "1",
      exists: "1",
      status: asString(parsed?.status, "unknown"),
      checked_at: asString(parsed?.checked_at, "unknown"),
      missing_files: asCountString(parsed?.missing_files),
      hash_mismatches: asCountString(parsed?.hash_mismatches),
      error: "",
    }),
  );
} catch {
  process.stdout.write(
    JSON.stringify({
      ok: "0",
      exists: "1",
      status: "unknown",
      checked_at: "unknown",
      missing_files: "0",
      hash_mismatches: "0",
      error: "parse_error",
    }),
  );
}
