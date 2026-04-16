/**
 * Claude Code adapter.
 */

import { randomUUID } from "node:crypto";
import { readdirSync } from "node:fs";
import { dirname } from "node:path";
import type {
  AgentAdapter,
  BuildChildSessionOpts,
  EnsureGlobalConfigOpts,
  Entry,
  ForkLocation,
  HookTriggerInfo,
  LaunchCommandOpts,
} from "../types.js";
import {
  ccSessionFilePath,
  readCcEntries,
  writeCcEntries,
} from "./session-file.js";
import { sleep } from "../../core/utils.js";
import {
  ccBuildChildSessionEntries,
  ccWaitForForkCall,
} from "./fork-call.js";
import { ccBuildLaunchCommand, ccEnsureGlobalConfig } from "./launch.js";
import { ccParseHookPayload } from "./hook-payload.js";

export class CcAdapter implements AgentAdapter {
  readonly agentType = "claude-code" as const;

  generateSessionId(): string {
    return randomUUID();
  }

  sessionFilePath(cwd: string, agentSessionId: string): string {
    return ccSessionFilePath(cwd, agentSessionId);
  }

  readEntries(path: string): Entry[] {
    return readCcEntries(path);
  }

  writeEntries(path: string, entries: Entry[]): void {
    writeCcEntries(path, entries);
  }

  waitForForkCall(
    parentFile: string,
    triggerHint: string,
    options?: { timeoutMs?: number; pollIntervalMs?: number },
  ): Promise<ForkLocation> {
    return ccWaitForForkCall(parentFile, triggerHint, options);
  }

  buildChildSessionEntries(opts: BuildChildSessionOpts): Entry[] {
    return ccBuildChildSessionEntries(opts);
  }

  buildLaunchCommand(opts: LaunchCommandOpts): string[] {
    return ccBuildLaunchCommand(opts);
  }

  ensureGlobalConfig(opts: EnsureGlobalConfigOpts): void {
    ccEnsureGlobalConfig(opts);
  }

  parseHookPayload(rawPayload: string): HookTriggerInfo {
    return ccParseHookPayload(rawPayload);
  }

  listExistingSessionFiles(cwd: string): string[] {
    const dir = dirname(this.sessionFilePath(cwd, "placeholder"));
    try {
      return readdirSync(dir)
        .filter((n) => n.endsWith(".jsonl"))
        .map((n) => `${dir}/${n}`);
    } catch {
      return [];
    }
  }

  async discoverNewSessionId(opts: {
    cwd: string;
    hintId: string;
    beforeFiles: string[];
    timeoutMs?: number;
  }): Promise<string> {
    // CC is guaranteed to use `hintId` (we passed --session-id), so
    // there is nothing to discover. But we still want the user-facing
    // tmux attach to happen only after bash has exec'd claude and
    // claude is reading stdin — attaching sooner leaks terminal DA
    // query responses into the TUI. A short fixed wait is sufficient;
    // bash's exec to claude is sub-second and claude settles its
    // stdin handling almost immediately after that.
    await sleep(2_000);
    return opts.hintId;
  }
}
