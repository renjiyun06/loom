#!/usr/bin/env node
/**
 * PostToolUse hook entry for Claude Code. Installed via ~/.loom/settings.json.
 */

import { CcAdapter } from "../adapters/claude-code/index.js";
import { runHookFlow } from "../core/hook-runner.js";

runHookFlow(new CcAdapter()).catch((err) => {
  console.error("[loom-cc-hook] unhandled:", err);
});
