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
  listAllCodexRollouts,
  readRolloutSessionId,
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
import { sleep } from "../../core/utils.js";

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

  listExistingSessionFiles(_cwd: string): string[] {
    return listAllCodexRollouts();
  }

  async discoverNewSessionId(opts: {
    cwd: string;
    hintId: string;
    beforeFiles: string[];
    timeoutMs?: number;
  }): Promise<string> {
    // The initial prompt ("你好") is already part of Codex's launch
    // argv (see buildLaunchCommand), so Codex begins writing its
    // rollout file as soon as it starts. We just wait for that file.
    const timeoutMs = opts.timeoutMs ?? 30_000;
    const intervalMs = 150;
    const before = new Set(opts.beforeFiles);
    const started = Date.now();
    while (Date.now() - started < timeoutMs) {
      const now = listAllCodexRollouts();
      const newOnes = now.filter((p) => !before.has(p));
      // If we see exactly one new file, that's ours.
      if (newOnes.length === 1) {
        const id = readRolloutSessionId(newOnes[0]);
        if (id) return id;
      }
      // If multiple new ones (rare race), filter by matching cwd.
      if (newOnes.length > 1) {
        for (const p of newOnes) {
          const id = readRolloutSessionId(p);
          if (!id) continue;
          // Cheap cwd match: read first line as JSON, check cwd.
          try {
            const { readFileSync } = await import("node:fs");
            const first = readFileSync(p, "utf-8").split("\n", 1)[0];
            const obj = JSON.parse(first) as any;
            if (obj?.payload?.cwd === opts.cwd) return id;
          } catch {
            // ignore, keep searching
          }
        }
      }
      await sleep(intervalMs);
    }
    throw new Error(
      `discoverNewSessionId: no new Codex rollout appeared under ~/.codex/sessions in ${timeoutMs}ms`,
    );
  }
}
