import { test } from "node:test";
import assert from "node:assert/strict";

import { CodexAdapter } from "../../dist/adapters/codex/index.js";

test("CodexAdapter.parseHookPayload extracts session_id + turn_id from Stop payload", () => {
  const adapter = new CodexAdapter();
  const raw = JSON.stringify({
    session_id: "019d9165-98aa-7242-9011-6981c07cdf9d",
    turn_id: "019d9167-6c11-7fe0-8f01-a0eb6422fa99",
    transcript_path: "/tmp/x.jsonl",
    hook_event_name: "Stop",
    model: "gpt-5.4",
  });
  const info = adapter.parseHookPayload(raw);
  assert.equal(info.agentSessionId, "019d9165-98aa-7242-9011-6981c07cdf9d");
  assert.equal(info.triggerHint, "019d9167-6c11-7fe0-8f01-a0eb6422fa99");
  assert.equal(info.mayBeFork, true); // Codex Stop always considers itself a candidate.
});

test("CodexAdapter.parseHookPayload returns empty on malformed input", () => {
  const adapter = new CodexAdapter();
  const info = adapter.parseHookPayload("{{not json");
  assert.equal(info.mayBeFork, false);
});

test("CodexAdapter.buildLaunchCommand includes two -c overrides and resume flag", () => {
  const adapter = new CodexAdapter();
  const argv = adapter.buildLaunchCommand({
    agentSessionId: "abc-123",
    cwd: "/tmp",
    loomSessionId: "loom1",
    branchId: "branch-a",
    systemPromptText: "You are branch branch-a...",
    resume: true,
  });
  assert.equal(argv[0], "codex");
  const cIdxs = argv.reduce((acc, v, i) => (v === "-c" ? [...acc, i] : acc), []);
  assert.equal(cIdxs.length, 2);
  assert.ok(argv[cIdxs[0] + 1].includes("mcp_servers.loom.env"));
  assert.ok(argv[cIdxs[0] + 1].includes("LOOM_SESSION"));
  assert.ok(argv[cIdxs[1] + 1].includes("developer_instructions"));
  // Resume requires the resume subcommand + id.
  const resumeIdx = argv.indexOf("resume");
  assert.ok(resumeIdx > 0);
  assert.equal(argv[resumeIdx + 1], "abc-123");
});

test("CodexAdapter.buildLaunchCommand (fresh/no-resume) omits resume subcommand", () => {
  const adapter = new CodexAdapter();
  const argv = adapter.buildLaunchCommand({
    agentSessionId: "xyz",
    cwd: "/tmp",
    loomSessionId: "loom1",
    branchId: "main",
    systemPromptText: "hi",
    resume: false,
  });
  assert.ok(!argv.includes("resume"));
});

test("CodexAdapter.buildChildSessionEntries inheritContext=true: slice + function_call_output + task_complete", () => {
  const adapter = new CodexAdapter();
  const entries = [
    {
      type: "session_meta",
      payload: { id: "parent-id", cwd: "/tmp", originator: "codex-tui" },
    },
    {
      type: "event_msg",
      payload: { type: "task_started", turn_id: "turn-1" },
    },
    {
      type: "response_item",
      payload: {
        type: "function_call",
        name: "mcp__loom__fork",
        arguments: "{}",
        call_id: "call_xyz",
      },
    },
  ];
  const child = adapter.buildChildSessionEntries({
    forkLocation: {
      entries,
      forkIndex: 2,
      callId: "call_xyz",
      turnId: "turn-1",
    },
    childAgentSessionId: "child-id",
    parentBranchId: "main",
    childBranchId: "abcdef",
    inheritContext: true,
    instruction: "",
    cwd: "/tmp",
    birthAnnouncementText: "You are branch abcdef, forked from branch main.",
  });

  // First entry is cloned session_meta with new id.
  assert.equal(child[0].type, "session_meta");
  assert.equal(child[0].payload.id, "child-id");
  // The prefix ends with the fork call.
  const callIdx = child.findIndex(
    (e) => e.payload?.type === "function_call" && e.payload?.call_id === "call_xyz",
  );
  assert.ok(callIdx >= 0);
  // After the call we expect a function_call_output with matching call_id and birth text.
  const outIdx = callIdx + 1;
  assert.equal(child[outIdx].payload.type, "function_call_output");
  assert.equal(child[outIdx].payload.call_id, "call_xyz");
  assert.equal(
    child[outIdx].payload.output,
    "You are branch abcdef, forked from branch main.",
  );
  // Final entry should be a task_complete for the fork's turn.
  const last = child[child.length - 1];
  assert.equal(last.type, "event_msg");
  assert.equal(last.payload.type, "task_complete");
  assert.equal(last.payload.turn_id, "turn-1");
});
