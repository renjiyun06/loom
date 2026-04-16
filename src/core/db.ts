/**
 * SQLite persistence for Loom sessions and branches.
 *
 * Schema uses `PRAGMA user_version` to track migrations. Version 1 is
 * the legacy pre-Adapter schema (pre-2026-04); version 2 adds
 * `agent_type` and renames `cc_session_id` to `agent_session_id` for
 * multi-agent support.
 */

import Database from "better-sqlite3";
import { mkdirSync } from "node:fs";
import { dirname } from "node:path";
import { LOOM_DB } from "./paths.js";
import type { AgentType, Branch, Session } from "../types.js";

export type Db = Database.Database;

interface Migration {
  version: number;
  up: (db: Db) => void;
}

const MIGRATIONS: Migration[] = [
  {
    version: 1,
    up: (db) => {
      db.exec(`
        CREATE TABLE IF NOT EXISTS sessions (
          id          TEXT PRIMARY KEY,
          cwd         TEXT NOT NULL,
          created_at  INTEGER NOT NULL
        );
        CREATE TABLE IF NOT EXISTS branches (
          session_id       TEXT NOT NULL REFERENCES sessions(id),
          branch_id        TEXT NOT NULL,
          cc_session_id    TEXT NOT NULL UNIQUE,
          parent_branch_id TEXT,
          instruction      TEXT,
          inherit_context  INTEGER,
          created_at       INTEGER NOT NULL,
          PRIMARY KEY (session_id, branch_id)
        );
        CREATE INDEX IF NOT EXISTS idx_branches_cc_session ON branches(cc_session_id);
      `);
    },
  },
  {
    version: 2,
    up: (db) => {
      const hasAgentType = columnExists(db, "branches", "agent_type");
      const hasAgentSessionId = columnExists(db, "branches", "agent_session_id");
      const hasCcSessionId = columnExists(db, "branches", "cc_session_id");

      if (!hasAgentType) {
        db.exec(
          `ALTER TABLE branches ADD COLUMN agent_type TEXT NOT NULL DEFAULT 'claude-code'`,
        );
      }
      if (hasCcSessionId && !hasAgentSessionId) {
        db.exec(`ALTER TABLE branches RENAME COLUMN cc_session_id TO agent_session_id`);
      }
      db.exec(`DROP INDEX IF EXISTS idx_branches_cc_session`);
      db.exec(
        `CREATE INDEX IF NOT EXISTS idx_branches_agent_session ON branches(agent_session_id)`,
      );
    },
  },
];

function columnExists(db: Db, table: string, column: string): boolean {
  const rows = db.prepare(`PRAGMA table_info(${table})`).all() as Array<{
    name: string;
  }>;
  return rows.some((r) => r.name === column);
}

function getUserVersion(db: Db): number {
  const row = db.pragma("user_version", { simple: true });
  return typeof row === "number" ? row : Number(row);
}

function setUserVersion(db: Db, v: number): void {
  db.pragma(`user_version = ${v}`);
}

function runMigrations(db: Db): void {
  let current = getUserVersion(db);
  // Legacy DBs created by the bash CLI predate user_version and may already
  // have version-1 tables in place. If tables exist but user_version is 0,
  // bump it to 1 without running the initial CREATE.
  if (current === 0) {
    const row = db
      .prepare(
        `SELECT name FROM sqlite_master WHERE type='table' AND name IN ('sessions','branches')`,
      )
      .all() as Array<{ name: string }>;
    if (row.length === 2) {
      setUserVersion(db, 1);
      current = 1;
    }
  }
  for (const m of MIGRATIONS) {
    if (m.version > current) {
      db.transaction(() => {
        m.up(db);
        setUserVersion(db, m.version);
      })();
      current = m.version;
    }
  }
}

let cached: Db | null = null;

export function openDb(): Db {
  if (cached) return cached;
  mkdirSync(dirname(LOOM_DB), { recursive: true });
  const db = new Database(LOOM_DB);
  db.pragma("journal_mode = WAL");
  runMigrations(db);
  cached = db;
  return db;
}

export function closeDb(): void {
  if (cached) {
    cached.close();
    cached = null;
  }
}

// ── Query helpers ─────────────────────────────────────────────────────

export function insertSession(db: Db, s: Session): void {
  db.prepare(
    `INSERT INTO sessions (id, cwd, created_at) VALUES (@id, @cwd, @created_at)`,
  ).run(s);
}

export function getSession(db: Db, id: string): Session | undefined {
  return db
    .prepare(`SELECT id, cwd, created_at FROM sessions WHERE id = ?`)
    .get(id) as Session | undefined;
}

export function listSessions(db: Db): Session[] {
  return db
    .prepare(`SELECT id, cwd, created_at FROM sessions ORDER BY created_at DESC`)
    .all() as Session[];
}

export function deleteSession(db: Db, id: string): void {
  db.transaction(() => {
    db.prepare(`DELETE FROM branches WHERE session_id = ?`).run(id);
    db.prepare(`DELETE FROM sessions WHERE id = ?`).run(id);
  })();
}

export function insertBranch(db: Db, b: Branch): void {
  db.prepare(
    `INSERT INTO branches (
       session_id, branch_id, agent_type, agent_session_id,
       parent_branch_id, instruction, inherit_context, created_at
     ) VALUES (
       @session_id, @branch_id, @agent_type, @agent_session_id,
       @parent_branch_id, @instruction, @inherit_context, @created_at
     )`,
  ).run(b);
}

export function getBranch(
  db: Db,
  sessionId: string,
  branchId: string,
): Branch | undefined {
  return db
    .prepare(
      `SELECT session_id, branch_id, agent_type, agent_session_id,
              parent_branch_id, instruction, inherit_context, created_at
         FROM branches WHERE session_id = ? AND branch_id = ?`,
    )
    .get(sessionId, branchId) as Branch | undefined;
}

export function listBranches(db: Db, sessionId: string): Branch[] {
  return db
    .prepare(
      `SELECT session_id, branch_id, agent_type, agent_session_id,
              parent_branch_id, instruction, inherit_context, created_at
         FROM branches WHERE session_id = ? ORDER BY created_at ASC`,
    )
    .all(sessionId) as Branch[];
}

export function listDescendantBranchIds(
  db: Db,
  sessionId: string,
  rootBranchId: string,
): string[] {
  const rows = listBranches(db, sessionId);
  const children: Record<string, string[]> = {};
  for (const b of rows) {
    const parent = b.parent_branch_id ?? "__ROOT__";
    (children[parent] ??= []).push(b.branch_id);
  }
  const result: string[] = [];
  const stack = [rootBranchId];
  while (stack.length) {
    const id = stack.pop()!;
    result.push(id);
    for (const child of children[id] ?? []) stack.push(child);
  }
  return result;
}

export function deleteBranches(
  db: Db,
  sessionId: string,
  branchIds: string[],
): void {
  if (branchIds.length === 0) return;
  const placeholders = branchIds.map(() => "?").join(",");
  db.prepare(
    `DELETE FROM branches WHERE session_id = ? AND branch_id IN (${placeholders})`,
  ).run(sessionId, ...branchIds);
}

/**
 * Lookup a branch by its agent_session_id only (used by hook scripts that
 * receive session_id from the agent runtime without branch context).
 */
export function getBranchByAgentSessionId(
  db: Db,
  agentSessionId: string,
): Branch | undefined {
  return db
    .prepare(
      `SELECT session_id, branch_id, agent_type, agent_session_id,
              parent_branch_id, instruction, inherit_context, created_at
         FROM branches WHERE agent_session_id = ? LIMIT 1`,
    )
    .get(agentSessionId) as Branch | undefined;
}

export function coerceAgentType(v: string): AgentType {
  if (v === "claude-code" || v === "codex") return v;
  throw new Error(`Unknown agent type: ${v}`);
}
