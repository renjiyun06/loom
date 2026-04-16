import { test } from "node:test";
import assert from "node:assert/strict";
import { homedir } from "node:os";
import { join } from "node:path";

import { CcAdapter } from "../../dist/adapters/claude-code/index.js";
import {
  encodeCwd,
  ccSessionFilePath,
} from "../../dist/adapters/claude-code/session-file.js";

test("CcAdapter.sessionFilePath encodes cwd by replacing / with -", () => {
  const p = ccSessionFilePath("/home/user/project", "abc-123");
  assert.equal(
    p,
    join(homedir(), ".claude", "projects", "-home-user-project", "abc-123.jsonl"),
  );
  assert.equal(encodeCwd("/home/x"), "-home-x");
});

test("CcAdapter.generateSessionId returns a UUID v4 format", () => {
  const adapter = new CcAdapter();
  const id = adapter.generateSessionId();
  assert.match(id, /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/);
});

test("CcAdapter.parseHookPayload returns mayBeFork=true on fork tool call", () => {
  const adapter = new CcAdapter();
  const raw = JSON.stringify({
    session_id: "cc-session-id",
    tool_name: "mcp__loom__fork",
    tool_use_id: "toolu_abc",
  });
  const info = adapter.parseHookPayload(raw);
  assert.equal(info.agentSessionId, "cc-session-id");
  assert.equal(info.triggerHint, "toolu_abc");
  assert.equal(info.mayBeFork, true);
});

test("CcAdapter.parseHookPayload mayBeFork=false on non-fork tool", () => {
  const adapter = new CcAdapter();
  const raw = JSON.stringify({
    session_id: "cc-id",
    tool_name: "Bash",
    tool_use_id: "toolu_bash",
  });
  assert.equal(adapter.parseHookPayload(raw).mayBeFork, false);
});

test("CcAdapter.parseHookPayload handles fork named bare 'fork'", () => {
  const adapter = new CcAdapter();
  const raw = JSON.stringify({
    session_id: "x",
    tool_name: "fork",
    tool_use_id: "toolu_y",
  });
  assert.equal(adapter.parseHookPayload(raw).mayBeFork, true);
});

test("CcAdapter.buildChildSessionEntries (inheritContext=true) slices + birth announcement", () => {
  const adapter = new CcAdapter();
  const parentEntries = [
    {
      type: "assistant",
      uuid: "parent-fork-uuid",
      sessionId: "parent-sid",
      message: {
        content: [
          { type: "tool_use", id: "toolu_fork", name: "fork", input: {} },
        ],
      },
    },
  ];
  const child = adapter.buildChildSessionEntries({
    forkLocation: {
      entries: parentEntries,
      forkIndex: 0,
      callId: "toolu_fork",
    },
    childAgentSessionId: "child-sid",
    parentBranchId: "main",
    childBranchId: "ff00aa",
    inheritContext: true,
    instruction: "",
    cwd: "/tmp",
    birthAnnouncementText: "You are branch ff00aa, forked from branch main.",
  });
  assert.equal(child.length, 2);
  // Parent fork tool_use entry should get its sessionId rewritten to child's.
  assert.equal(child[0].sessionId, "child-sid");
  // Birth announcement is a user-type entry with a tool_result matching the call_id.
  assert.equal(child[1].type, "user");
  assert.equal(
    child[1].message.content[0].tool_use_id,
    "toolu_fork",
  );
  assert.equal(
    child[1].message.content[0].content,
    "You are branch ff00aa, forked from branch main.",
  );
});

test("CcAdapter.buildLaunchCommand (resume) includes --resume + expected flags", () => {
  const adapter = new CcAdapter();
  const argv = adapter.buildLaunchCommand({
    agentSessionId: "abc",
    cwd: "/tmp",
    loomSessionId: "loom1",
    branchId: "main",
    systemPromptText: "hello",
    resume: true,
  });
  assert.equal(argv[0], "claude");
  assert.ok(argv.includes("--resume"));
  assert.ok(argv.includes("abc"));
  assert.ok(argv.includes("--append-system-prompt"));
  assert.ok(argv.includes("--dangerously-skip-permissions"));
});

test("CcAdapter.buildLaunchCommand (fresh) uses --session-id instead of --resume", () => {
  const adapter = new CcAdapter();
  const argv = adapter.buildLaunchCommand({
    agentSessionId: "newid",
    cwd: "/tmp",
    loomSessionId: "loom1",
    branchId: "main",
    systemPromptText: "hi",
    resume: false,
  });
  assert.ok(!argv.includes("--resume"));
  assert.ok(argv.includes("--session-id"));
  assert.ok(argv.includes("newid"));
});
