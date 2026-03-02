#!/usr/bin/env node

import process from "node:process";

function readInput() {
  const encoded = process.env.SUBAGENT_UTIL_ARGS_B64?.trim();
  if (!encoded) return {};

  try {
    const raw = Buffer.from(encoded, "base64").toString("utf-8");
    const parsed = JSON.parse(raw);
    return parsed && typeof parsed === "object" ? parsed : {};
  } catch {
    return {};
  }
}

function extractIssueId(text) {
  if (!text) return null;
  const match = text.match(/issues\/(\d+)/i);
  return match?.[1] ?? null;
}

const input = readInput();
const candidates = [];

if (typeof input.issue_id === "string") candidates.push(input.issue_id);
if (typeof input.url === "string") candidates.push(input.url);
if (typeof input.text === "string") candidates.push(input.text);

let resolved = null;
for (const value of candidates) {
  if (/^\d+$/.test(value.trim())) {
    resolved = value.trim();
    break;
  }
  const extracted = extractIssueId(value);
  if (extracted) {
    resolved = extracted;
    break;
  }
}

if (!resolved) {
  process.stdout.write(
    `${JSON.stringify({ ok: false, error: "Could not extract Sentry issue id", input_keys: Object.keys(input) })}\n`,
  );
  process.exit(1);
}

process.stdout.write(`${JSON.stringify({ ok: true, issue_id: resolved })}\n`);
