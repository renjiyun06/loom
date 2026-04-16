#!/usr/bin/env node
/**
 * Stop hook entry for Codex. Installed via ~/.codex/hooks.json. Requires
 * `codex features enable codex_hooks` to actually fire.
 */

import { CodexAdapter } from "../adapters/codex/index.js";
import { runHookFlow } from "../core/hook-runner.js";

runHookFlow(new CodexAdapter()).catch((err) => {
  console.error("[loom-codex-hook] unhandled:", err);
});
