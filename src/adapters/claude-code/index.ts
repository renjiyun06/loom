/**
 * Claude Code adapter.
 */

import { randomUUID } from "node:crypto";
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
}
