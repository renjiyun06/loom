import { test } from "node:test";
import assert from "node:assert/strict";

const { buildForestJson } = await import("../../dist/cli/cmd-list.js");

const ms = (iso) => new Date(iso).getTime();

test("buildForestJson: empty sessions yields empty forest", () => {
  const out = buildForestJson([], new Map(), new Set());
  assert.deepEqual(out, { sessions: [] });
});

test("buildForestJson: single session with main branch", () => {
  const session = {
    id: "abc123",
    cwd: "/home/x",
    created_at: ms("2026-01-01T00:00:00Z"),
  };
  const main = {
    session_id: "abc123",
    branch_id: "main",
    agent_type: "claude-code",
    agent_session_id: "cc-uuid-1",
    parent_branch_id: null,
    instruction: null,
    inherit_context: null,
    created_at: ms("2026-01-01T00:00:00Z"),
  };
  const out = buildForestJson(
    [session],
    new Map([["abc123", [main]]]),
    new Set(["loom-abc123-main"]),
  );
  assert.equal(out.sessions.length, 1);
  const s = out.sessions[0];
  assert.equal(s.id, "abc123");
  assert.equal(s.cwd, "/home/x");
  assert.equal(s.created_at, "2026-01-01T00:00:00.000Z");
  assert.equal(s.branches.length, 1);
  const b = s.branches[0];
  assert.equal(b.id, "main");
  assert.equal(b.parent_id, null);
  assert.equal(b.agent_type, "claude-code");
  assert.equal(b.agent_session_id, "cc-uuid-1");
  assert.equal(b.inherit_context, null);
  assert.equal(b.instruction, null);
  assert.equal(b.alive, true);
  assert.equal(b.tmux_name, "loom-abc123-main");
  assert.equal(b.created_at, "2026-01-01T00:00:00.000Z");
});

test("buildForestJson: parent-child chain with flat array + parent_id", () => {
  const session = {
    id: "sX",
    cwd: "/tmp",
    created_at: ms("2026-02-01T00:00:00Z"),
  };
  const main = {
    session_id: "sX",
    branch_id: "main",
    agent_type: "claude-code",
    agent_session_id: "cc-main",
    parent_branch_id: null,
    instruction: null,
    inherit_context: null,
    created_at: ms("2026-02-01T00:00:00Z"),
  };
  const child = {
    session_id: "sX",
    branch_id: "deadbeef",
    agent_type: "claude-code",
    agent_session_id: "cc-child",
    parent_branch_id: "main",
    instruction: "explore the auth module",
    inherit_context: 1,
    created_at: ms("2026-02-01T00:05:00Z"),
  };
  const grandchild = {
    session_id: "sX",
    branch_id: "cafef00d",
    agent_type: "codex",
    agent_session_id: "codex-grand",
    parent_branch_id: "deadbeef",
    instruction: "check the lockfile",
    inherit_context: 0,
    created_at: ms("2026-02-01T00:10:00Z"),
  };
  const out = buildForestJson(
    [session],
    new Map([["sX", [main, child, grandchild]]]),
    new Set(["loom-sX-main"]),
  );
  const branches = out.sessions[0].branches;
  assert.equal(branches.length, 3);

  const byId = Object.fromEntries(branches.map((b) => [b.id, b]));
  assert.equal(byId["main"].parent_id, null);
  assert.equal(byId["deadbeef"].parent_id, "main");
  assert.equal(byId["cafef00d"].parent_id, "deadbeef");

  assert.equal(byId["deadbeef"].inherit_context, true);
  assert.equal(byId["cafef00d"].inherit_context, false);

  assert.equal(byId["deadbeef"].instruction, "explore the auth module");
  assert.equal(byId["cafef00d"].agent_type, "codex");

  assert.equal(byId["main"].alive, true);
  assert.equal(byId["deadbeef"].alive, false);
  assert.equal(byId["cafef00d"].alive, false);

  assert.equal(byId["cafef00d"].tmux_name, "loom-sX-cafef00d");
});

test("buildForestJson: multiple sessions preserve insertion order", () => {
  const s1 = { id: "alpha", cwd: "/a", created_at: ms("2026-01-01T00:00:00Z") };
  const s2 = { id: "beta", cwd: "/b", created_at: ms("2026-03-01T00:00:00Z") };
  const mkMain = (sid, tsIso) => ({
    session_id: sid,
    branch_id: "main",
    agent_type: "claude-code",
    agent_session_id: `cc-${sid}`,
    parent_branch_id: null,
    instruction: null,
    inherit_context: null,
    created_at: ms(tsIso),
  });

  const out = buildForestJson(
    [s1, s2],
    new Map([
      ["alpha", [mkMain("alpha", "2026-01-01T00:00:00Z")]],
      ["beta", [mkMain("beta", "2026-03-01T00:00:00Z")]],
    ]),
    new Set(),
  );
  assert.equal(out.sessions.length, 2);
  assert.equal(out.sessions[0].id, "alpha");
  assert.equal(out.sessions[1].id, "beta");
  assert.equal(out.sessions[0].branches[0].alive, false);
  assert.equal(out.sessions[1].branches[0].alive, false);
});

test("buildForestJson: instruction is never truncated", () => {
  const longText =
    "这是一个非常长的 instruction 文本，包含了很多字符，远远超过 loom list 人类视图里 10 字的截断长度，用来确保 JSON 视图保留全文。";
  const s = { id: "z", cwd: "/", created_at: ms("2026-04-17T00:00:00Z") };
  const b = {
    session_id: "z",
    branch_id: "main",
    agent_type: "claude-code",
    agent_session_id: "cc-z",
    parent_branch_id: null,
    instruction: longText,
    inherit_context: 1,
    created_at: ms("2026-04-17T00:00:00Z"),
  };
  const out = buildForestJson([s], new Map([["z", [b]]]), new Set());
  assert.equal(out.sessions[0].branches[0].instruction, longText);
});
