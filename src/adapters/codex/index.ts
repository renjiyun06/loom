/**
 * Codex adapter.
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
  codexSessionFilePath,
  readCodexEntries,
  writeCodexEntries,
} from "./session-file.js";
import {
  codexBuildChildSessionEntries,
  codexWaitForForkCall,
} from "./fork-call.js";
import {
  codexBuildLaunchCommand,
  codexEnsureGlobalConfig,
} from "./launch.js";
import { codexParseHookPayload } from "./hook-payload.js";

export class CodexAdapter implements AgentAdapter {
  readonly agentType = "codex" as const;

  generateSessionId(): string {
    return randomUUID();
  }

  sessionFilePath(cwd: string, agentSessionId: string): string {
    return codexSessionFilePath(cwd, agentSessionId);
  }

  readEntries(path: string): Entry[] {
    return readCodexEntries(path);
  }

  writeEntries(path: string, entries: Entry[]): void {
    writeCodexEntries(path, entries);
  }

  waitForForkCall(
    parentFile: string,
    triggerHint: string,
    options?: { timeoutMs?: number; pollIntervalMs?: number },
  ): Promise<ForkLocation> {
    return codexWaitForForkCall(parentFile, triggerHint, options);
  }

  buildChildSessionEntries(opts: BuildChildSessionOpts): Entry[] {
    return codexBuildChildSessionEntries(opts);
  }

  buildLaunchCommand(opts: LaunchCommandOpts): string[] {
    return codexBuildLaunchCommand(opts);
  }

  ensureGlobalConfig(opts: EnsureGlobalConfigOpts): void {
    codexEnsureGlobalConfig(opts);
  }

  parseHookPayload(rawPayload: string): HookTriggerInfo {
    return codexParseHookPayload(rawPayload);
  }
}
