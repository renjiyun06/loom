/**
 * The heavy-lifting part of `fork`: build the child branch's JSONL
 * projection and launch a Claude Code agent on it.
 *
 * Invoked by the PostToolUse hook (after the parent CC has written the
 * fork tool_use and tool_result to its JSONL), NOT by the MCP handler
 * directly. This lets us strictly validate that the fork tool_use has
 * been flushed before building the child.
 */

import { openDb, type Db } from "./db.js";
import {
  createChildForkToolResult,
  createSyntheticForkCall,
  findForkToolUseById,
  readEntries,
  rewriteSessionId,
  sessionFilePath,
  writeEntries,
  type Entry,
} from "./jsonl.js";
import { launchCc } from "./launcher.js";
import { sendKeys, tmuxSessionName } from "./tmux.js";
import { sendLockPath, sleep, withFileLock } from "./utils.js";

export interface ForkJob {
  sessionId: string;           // Loom session id
  parentBranchId: string;
  parentCcSessionId: string;
  childBranchId: string;
  childCcSessionId: string;
  instruction: string;
  inheritContext: boolean;
}

async function waitForForkToolUse(
  parentPath: string,
  toolUseId: string,
  maxAttempts = 5,
  retryMs = 200,
): Promise<{ entries: Entry[]; index: number; entryUuid: string }> {
  for (let attempt = 0; attempt < maxAttempts; attempt++) {
    const entries = readEntries(parentPath);
    const found = findForkToolUseById(entries, toolUseId);
    if (found) {
      return { entries, index: found.index, entryUuid: found.entryUuid };
    }
    if (attempt < maxAttempts - 1) await sleep(retryMs);
  }
  throw new Error(
    `fork tool_use with id ${toolUseId} not found in parent's JSONL ` +
      `(${parentPath}) after ${maxAttempts} attempts. Aborting — will ` +
      `not create tmux session or write child JSONL.`,
  );
}

export async function executeFork(
  job: ForkJob,
  toolUseId: string,
  db?: Db,
): Promise<void> {
  const ownDb = !db;
  const database = db ?? openDb();

  try {
    // Look up parent session's cwd.
    const sessionRow = database
      .prepare(`SELECT cwd FROM sessions WHERE id = ?`)
      .get(job.sessionId) as { cwd: string } | undefined;
    if (!sessionRow) {
      throw new Error(
        `executeFork: session ${job.sessionId} not registered in database`,
      );
    }
    const cwd = sessionRow.cwd;

    // Strict validation: wait for the *exact* fork tool_use entry
    // (identified by the tool_use_id from the hook's stdin) to be
    // flushed to parent's JSONL. Applies to both inherit modes — we
    // want to be sure CC really made the call before we spawn a child.
    const parentPath = sessionFilePath(cwd, job.parentCcSessionId);
    const { entries: parentEntries, index: forkEntryIndex, entryUuid: forkEntryUuid } =
      await waitForForkToolUse(parentPath, toolUseId);

    // Build the child's JSONL.
    let childEntries: Entry[];
    let forkToolUseId: string;
    let forkToolUseUuid: string;

    if (job.inheritContext) {
      childEntries = parentEntries
        .slice(0, forkEntryIndex + 1)
        .map((e) => rewriteSessionId(e, job.childCcSessionId));
      forkToolUseId = toolUseId;
      forkToolUseUuid = forkEntryUuid;
    } else {
      const synthetic = createSyntheticForkCall({
        instruction: job.instruction,
        ccSessionId: job.childCcSessionId,
        cwd,
      });
      childEntries = [synthetic.assistantEntry];
      forkToolUseId = synthetic.toolUseId;
      forkToolUseUuid = synthetic.entryUuid;
    }

    // Append the child-version fork tool_result (birth announcement).
    const birth = createChildForkToolResult({
      toolUseId: forkToolUseId,
      childBranchId: job.childBranchId,
      parentBranchId: job.parentBranchId,
      inheritContext: job.inheritContext,
      ccSessionId: job.childCcSessionId,
      parentUuid: forkToolUseUuid,
      cwd,
    });
    childEntries.push(birth);

    // Write the child's JSONL file.
    writeEntries(sessionFilePath(cwd, job.childCcSessionId), childEntries);

    // Launch the child CC in a tmux session.
    launchCc({
      sessionId: job.sessionId,
      branchId: job.childBranchId,
      ccSessionId: job.childCcSessionId,
      cwd,
    });

    // Wait for CC to come up, then inject the kickoff message.
    await sleep(2500);
    const tmuxName = tmuxSessionName(job.sessionId, job.childBranchId);
    await withFileLock(sendLockPath(tmuxName), () => {
      sendKeys(tmuxName, "[loom] Begin.");
    });
  } finally {
    if (ownDb) database.close();
  }
}
