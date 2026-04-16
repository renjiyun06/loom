import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, writeFileSync, rmSync, existsSync } from "node:fs";
import { tmpdir, homedir } from "node:os";
import { join } from "node:path";
import Database from "better-sqlite3";

/**
 * We can't easily swap LOOM_DB without DI; test the migration logic
 * against a freshly-created SQLite file by replicating the pre-v2
 * schema manually, then invoking the version-2 migration's column
 * additions directly against a local db.
 *
 * That's awkward to import through the cached singleton, so instead
 * we exercise a fresh migration by creating a scratch DB with legacy
 * schema + user_version=1 and running the upgrade SQL inline.
 */

const scratchDir = mkdtempSync(join(tmpdir(), "loom-db-test-"));
const dbPath = join(scratchDir, "test.db");

test("db schema v1→v2 migration preserves data and renames column", () => {
  const db = new Database(dbPath);
  db.pragma("user_version = 1");
  db.exec(`
    CREATE TABLE sessions (
      id          TEXT PRIMARY KEY,
      cwd         TEXT NOT NULL,
      created_at  INTEGER NOT NULL
    );
    CREATE TABLE branches (
      session_id       TEXT NOT NULL REFERENCES sessions(id),
      branch_id        TEXT NOT NULL,
      cc_session_id    TEXT NOT NULL UNIQUE,
      parent_branch_id TEXT,
      instruction      TEXT,
      inherit_context  INTEGER,
      created_at       INTEGER NOT NULL,
      PRIMARY KEY (session_id, branch_id)
    );
    CREATE INDEX idx_branches_cc_session ON branches(cc_session_id);
    INSERT INTO sessions (id, cwd, created_at) VALUES ('s1', '/tmp', 1);
    INSERT INTO branches (session_id, branch_id, cc_session_id, created_at) VALUES ('s1', 'main', 'cc-uuid-1', 1);
  `);
  db.close();

  // Import the real openDb function and point LOOM_DB at scratchDir.
  // Since paths are module-level constants, we instead simulate the
  // real migration by copying the upgrade logic.
  const db2 = new Database(dbPath);
  // The migration from db.ts v2:
  db2.exec(`ALTER TABLE branches ADD COLUMN agent_type TEXT NOT NULL DEFAULT 'claude-code'`);
  db2.exec(`ALTER TABLE branches RENAME COLUMN cc_session_id TO agent_session_id`);
  db2.exec(`DROP INDEX IF EXISTS idx_branches_cc_session`);
  db2.exec(`CREATE INDEX IF NOT EXISTS idx_branches_agent_session ON branches(agent_session_id)`);
  db2.pragma("user_version = 2");

  const row = db2.prepare(`SELECT branch_id, agent_type, agent_session_id FROM branches`).get();
  assert.equal(row.branch_id, "main");
  assert.equal(row.agent_type, "claude-code");
  assert.equal(row.agent_session_id, "cc-uuid-1");
  db2.close();
  rmSync(scratchDir, { recursive: true, force: true });
});

test("db.ts openDb runs migrations against current ~/.loom/loom.db", async () => {
  const { openDb, closeDb } = await import("../../dist/core/db.js");
  const db = openDb();
  const version = db.pragma("user_version", { simple: true });
  assert.ok(version >= 2, `expected user_version >= 2, got ${version}`);
  const hasAgentType = db
    .prepare(`PRAGMA table_info(branches)`)
    .all()
    .some((r) => r.name === "agent_type");
  assert.ok(hasAgentType, "expected branches.agent_type column after migration");
  closeDb();
});
