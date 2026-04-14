/**
 * SQLite access for the Loom branch structure.
 *
 * Stored at `~/.loom/loom.db`. Two tables: `sessions` and `branches`.
 * Entries (JSONL content) are NOT stored here — those live in Claude
 * Code's own session files. This DB only tracks what branches exist,
 * how they relate to each other, and the mapping from Loom branch_id
 * to CC session uuid.
 */

import Database from "better-sqlite3";
import { mkdirSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

const LOOM_DIR = join(homedir(), ".loom");
const DB_PATH = join(LOOM_DIR, "loom.db");

export interface BranchRow {
  session_id: string;
  branch_id: string;
  cc_session_id: string;        // UUID Claude Code uses for the JSONL file
  parent_branch_id: string | null; // parent's branch_id, null for root (main)
  instruction: string | null;   // fork instruction that created this branch; null for root
  created_at: number;
}

export interface SessionRow {
  id: string;
  cwd: string;
  created_at: number;
}

export function openDb() {
  mkdirSync(LOOM_DIR, { recursive: true });
  const db = new Database(DB_PATH);
  db.pragma("journal_mode = WAL");
  db.pragma("foreign_keys = ON");

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
      created_at       INTEGER NOT NULL,
      PRIMARY KEY (session_id, branch_id)
    );

    CREATE INDEX IF NOT EXISTS idx_branches_cc_session
      ON branches(cc_session_id);
  `);

  // Idempotent upgrade path for DBs created before `instruction` existed.
  const cols = db
    .prepare(`PRAGMA table_info(branches)`)
    .all() as { name: string }[];
  if (!cols.some((c) => c.name === "instruction")) {
    db.exec(`ALTER TABLE branches ADD COLUMN instruction TEXT`);
  }

  return db;
}

export type Db = ReturnType<typeof openDb>;

export function ensureSession(db: Db, sessionId: string, cwd: string): void {
  db.prepare(
    `INSERT OR IGNORE INTO sessions (id, cwd, created_at) VALUES (?, ?, ?)`,
  ).run(sessionId, cwd, Date.now());
}

export function getSession(db: Db, sessionId: string): SessionRow | null {
  const row = db
    .prepare(`SELECT * FROM sessions WHERE id = ?`)
    .get(sessionId) as SessionRow | undefined;
  return row ?? null;
}

export function getBranch(
  db: Db,
  sessionId: string,
  branchId: string,
): BranchRow | null {
  const row = db
    .prepare(
      `SELECT * FROM branches WHERE session_id = ? AND branch_id = ?`,
    )
    .get(sessionId, branchId) as BranchRow | undefined;
  return row ?? null;
}

export function insertBranch(db: Db, row: BranchRow): void {
  db.prepare(
    `INSERT INTO branches
       (session_id, branch_id, cc_session_id, parent_branch_id, instruction, created_at)
     VALUES (?, ?, ?, ?, ?, ?)`,
  ).run(
    row.session_id,
    row.branch_id,
    row.cc_session_id,
    row.parent_branch_id,
    row.instruction,
    row.created_at,
  );
}

export function listBranches(db: Db, sessionId: string): BranchRow[] {
  return db
    .prepare(`SELECT * FROM branches WHERE session_id = ?`)
    .all(sessionId) as BranchRow[];
}
