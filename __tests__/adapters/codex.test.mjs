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

test("CodexAdapter.buildLaunchCommand (resume) has only mcp_servers -c, no developer_instructions", () => {
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
  // Resume: only mcp_servers env, NO developer_instructions (Codex doesn't
  // regenerate the developer message from it on resume anyway).
  assert.equal(cIdxs.length, 1);
  assert.ok(argv[cIdxs[0] + 1].includes("mcp_servers.loom.env"));
  assert.ok(argv[cIdxs[0] + 1].includes("LOOM_SESSION"));
  assert.ok(!argv.some((a) => typeof a === "string" && a.includes("developer_instructions")));
  // Resume requires the resume subcommand + id.
  const resumeIdx = argv.indexOf("resume");
  assert.ok(resumeIdx > 0);
  assert.equal(argv[resumeIdx + 1], "abc-123");
});

test("CodexAdapter.buildLaunchCommand (fresh) has two -c (mcp + developer_instructions) and no resume", () => {
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
  const cIdxs = argv.reduce((acc, v, i) => (v === "-c" ? [...acc, i] : acc), []);
  assert.equal(cIdxs.length, 2);
  assert.ok(argv.some((a) => typeof a === "string" && a.includes("developer_instructions")));
  // Fresh launch ends with the seed prompt so Codex writes rollout immediately.
  assert.equal(argv[argv.length - 1], "你好");
});

test("CodexAdapter.buildChildSessionEntries inheritContext=true: slice + rewrite dev msg + closure", () => {
  const adapter = new CodexAdapter();
  const parentLoomPromptText =
    "# Loom Branch System\n\nYour **branch ID** is: `main`\n(parent loom prompt body)";
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
        type: "message",
        role: "developer",
        content: [
          { type: "input_text", text: "<permissions instructions>perms</permissions instructions>" },
          { type: "input_text", text: parentLoomPromptText },
          { type: "input_text", text: "<collaboration_mode>x</collaboration_mode>" },
        ],
      },
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
      forkIndex: 3,
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

  // Developer message present and loom-prompt section rewritten for child.
  const devIdx = child.findIndex(
    (e) => e.type === "response_item" && e.payload?.role === "developer",
  );
  assert.ok(devIdx >= 0);
  const devContent = child[devIdx].payload.content;
  assert.equal(devContent.length, 3);
  // content[0] permissions unchanged
  assert.ok(devContent[0].text.startsWith("<permissions instructions>"));
  // content[1] loom prompt: must NOT contain parent's marker body; must contain child's branch id
  assert.ok(!devContent[1].text.includes("(parent loom prompt body)"));
  assert.ok(devContent[1].text.includes("abcdef"));
  assert.ok(devContent[1].text.startsWith("# Loom Branch System"));
  // content[2] collaboration_mode unchanged
  assert.ok(devContent[2].text.startsWith("<collaboration_mode>"));

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

test("CodexAdapter.buildChildSessionEntries inheritContext=false: 9-entry synth with inherited dev msg + env_ctx + turn_ctx + user_message event", () => {
  const adapter = new CodexAdapter();
  const parentLoomPromptText =
    "# Loom Branch System\n\nYour **branch ID** is: `main`\n(parent body)";
  const parentTurnContextPayload = {
    turn_id: "parent-turn-1",
    cwd: "/tmp",
    model: "gpt-5.4",
    developer_instructions: "<parent's turn_ctx developer_instructions>",
    approval_policy: "never",
  };
  const entries = [
    {
      type: "session_meta",
      payload: {
        id: "parent-id",
        timestamp: "2026-04-16T00:00:00Z",
        cwd: "/tmp",
        originator: "codex-tui",
        base_instructions: { text: "You are Codex..." },
      },
    },
    {
      type: "event_msg",
      payload: { type: "task_started", turn_id: "parent-turn-1" },
    },
    {
      type: "response_item",
      payload: {
        type: "message",
        role: "developer",
        content: [
          { type: "input_text", text: "<permissions instructions>p</permissions instructions>" },
          { type: "input_text", text: parentLoomPromptText },
          { type: "input_text", text: "<apps_instructions>a</apps_instructions>" },
        ],
      },
    },
    {
      type: "response_item",
      payload: {
        type: "message",
        role: "user",
        content: [
          {
            type: "input_text",
            text: "<environment_context>\n  <cwd>/tmp</cwd>\n</environment_context>",
          },
        ],
      },
    },
    {
      type: "turn_context",
      payload: parentTurnContextPayload,
    },
    {
      type: "response_item",
      payload: {
        type: "function_call",
        name: "mcp__loom__fork",
        arguments: JSON.stringify({ instruction: "do X", inherit_context: false }),
        call_id: "call_parent_fork",
      },
    },
  ];

  const child = adapter.buildChildSessionEntries({
    forkLocation: {
      entries,
      forkIndex: 5,
      callId: "call_parent_fork",
      turnId: "parent-turn-1",
    },
    childAgentSessionId: "child-id",
    parentBranchId: "main",
    childBranchId: "c0ffee",
    inheritContext: false,
    instruction: "do X",
    cwd: "/tmp",
    birthAnnouncementText:
      "You are branch c0ffee, forked from branch main without context inheritance.",
  });

  // Exactly 9 entries (8 content + synthetic user_message event so
  // reconstruct_history_from_rollout treats this as a real user turn).
  assert.equal(child.length, 9);

  // [0] session_meta: id swapped to child, base_instructions inherited.
  assert.equal(child[0].type, "session_meta");
  assert.equal(child[0].payload.id, "child-id");
  assert.equal(child[0].payload.base_instructions.text, "You are Codex...");
  // Parent's id should NOT leak.
  assert.notEqual(child[0].payload.id, "parent-id");

  // [1] task_started — capture its turn_id for later assertions.
  assert.equal(child[1].type, "event_msg");
  assert.equal(child[1].payload.type, "task_started");
  const newTurnId = child[1].payload.turn_id;
  assert.ok(typeof newTurnId === "string" && newTurnId.length > 0);
  assert.notEqual(newTurnId, "parent-turn-1");

  // [2] developer message: loom prompt rewritten to child, other sections preserved.
  assert.equal(child[2].type, "response_item");
  assert.equal(child[2].payload.role, "developer");
  const devContent = child[2].payload.content;
  assert.equal(devContent.length, 3);
  assert.ok(devContent[0].text.startsWith("<permissions instructions>"));
  assert.ok(devContent[1].text.startsWith("# Loom Branch System"));
  assert.ok(devContent[1].text.includes("c0ffee"));
  assert.ok(!devContent[1].text.includes("(parent body)"));
  assert.ok(devContent[2].text.startsWith("<apps_instructions>"));

  // [3] environment_context user message: cloned from parent.
  assert.equal(child[3].type, "response_item");
  assert.equal(child[3].payload.role, "user");
  assert.ok(child[3].payload.content[0].text.startsWith("<environment_context>"));

  // [4] turn_context: inherited from parent's latest, turn_id swapped.
  assert.equal(child[4].type, "turn_context");
  assert.equal(child[4].payload.turn_id, newTurnId);
  assert.equal(child[4].payload.model, "gpt-5.4");
  assert.equal(child[4].payload.approval_policy, "never");

  // [5] event_msg: user_message — required for Codex to treat our synth
  // turn as a user turn on reconstruction (so reference_context_item is
  // captured from [4] and build_initial_context doesn't re-run).
  assert.equal(child[5].type, "event_msg");
  assert.equal(child[5].payload.type, "user_message");
  // message content is ignored by reconstruction (matched as `_`) and
  // never surfaced to the model.
  assert.equal(child[5].payload.message, "");

  // [6] function_call: synthetic fork call with instruction.
  assert.equal(child[6].type, "response_item");
  assert.equal(child[6].payload.type, "function_call");
  assert.equal(child[6].payload.name, "mcp__loom__fork");
  const args = JSON.parse(child[6].payload.arguments);
  assert.equal(args.instruction, "do X");
  assert.equal(args.inherit_context, false);
  const syntheticCallId = child[6].payload.call_id;
  // Must be a fresh call_id, not the parent's fork call_id.
  assert.notEqual(syntheticCallId, "call_parent_fork");

  // [7] function_call_output: birth announcement, matching the synth call_id.
  assert.equal(child[7].type, "response_item");
  assert.equal(child[7].payload.type, "function_call_output");
  assert.equal(child[7].payload.call_id, syntheticCallId);
  assert.ok(
    child[7].payload.output.includes(
      "You are branch c0ffee, forked from branch main without context inheritance.",
    ),
  );

  // [8] task_complete: matching the new turn_id.
  assert.equal(child[8].type, "event_msg");
  assert.equal(child[8].payload.type, "task_complete");
  assert.equal(child[8].payload.turn_id, newTurnId);
});
