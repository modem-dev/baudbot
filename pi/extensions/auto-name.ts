/**
 * Auto-name extension.
 *
 * Sets the session name from the PI_SESSION_NAME env var on session start.
 * This is used instead of --name (which is not a real CLI flag) or
 * /name (which requires interactive TUI input).
 */

import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";

export default function (pi: ExtensionAPI) {
  const name = process.env.PI_SESSION_NAME;
  if (name) {
    pi.on("session_start", async () => {
      pi.setSessionName(name);
    });
  }
}
