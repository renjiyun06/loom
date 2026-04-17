/**
 * `loom list` — render all sessions with their branch trees.
 *
 * Default output is a human-readable tree; `--json` emits a flat
 * machine-readable document intended for programmatic consumers
 * (VS Code extension, dashboards, etc.).
 */

import {
  listBranches,
  listSessions,
  openDb,
} from "../core/db.js";
import { listLoomSessions, tmuxSessionName } from "../core/tmux.js";
import type { AgentType, Branch, Session } from "../types.js";

export interface ListOpts {
  json?: boolean;
}

export interface ForestJsonBranch {
  id: string;
  parent_id: string | null;
  agent_type: AgentType;
  agent_session_id: string;
  inherit_context: boolean | null;
  instruction: string | null;
  alive: boolean;
  tmux_name: string;
  created_at: string;
}

export interface ForestJsonSession {
  id: string;
  cwd: string;
  created_at: string;
  branches: ForestJsonBranch[];
}

export interface ForestJson {
  sessions: ForestJsonSession[];
}

function fmtTs(ms: number): string {
  const d = new Date(ms);
  const pad = (n: number) => String(n).padStart(2, "0");
  return (
    `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())} ` +
    `${pad(d.getHours())}:${pad(d.getMinutes())}`
  );
}

function truncate(s: string | null, n = 10): string {
  if (!s) return "";
  const t = s.replace(/\n/g, " ").trim();
  return t.length <= n ? t : t.slice(0, n - 1) + "…";
}

/**
 * Pure helper: turn DB rows + tmux liveness into the JSON shape.
 * Extracted so tests can feed synthetic data without touching the DB.
 */
export function buildForestJson(
  sessions: Session[],
  branchesBySession: Map<string, Branch[]>,
  liveTmuxSessions: Set<string>,
): ForestJson {
  return {
    sessions: sessions.map((s) => ({
      id: s.id,
      cwd: s.cwd,
      created_at: new Date(s.created_at).toISOString(),
      branches: (branchesBySession.get(s.id) ?? []).map((b) => {
        const tmux = tmuxSessionName(s.id, b.branch_id);
        return {
          id: b.branch_id,
          parent_id: b.parent_branch_id,
          agent_type: b.agent_type,
          agent_session_id: b.agent_session_id,
          inherit_context:
            b.inherit_context === null ? null : b.inherit_context === 1,
          instruction: b.instruction,
          alive: liveTmuxSessions.has(tmux),
          tmux_name: tmux,
          created_at: new Date(b.created_at).toISOString(),
        };
      }),
    })),
  };
}

function renderJson(
  sessions: Session[],
  branchesBySession: Map<string, Branch[]>,
  live: Set<string>,
): void {
  const doc = buildForestJson(sessions, branchesBySession, live);
  process.stdout.write(JSON.stringify(doc, null, 2) + "\n");
}

function renderTree(
  sessions: Session[],
  branchesBySession: Map<string, Branch[]>,
  live: Set<string>,
): void {
  if (!sessions.length) {
    console.log("loom: no sessions recorded");
    return;
  }

  sessions.forEach((s, i) => {
    if (i > 0) console.log();
    console.log(
      `session ${s.id}  cwd=${s.cwd}  created=${fmtTs(s.created_at)}`,
    );
    const branches = branchesBySession.get(s.id) ?? [];
    const children: Record<string, Branch[]> = {};
    for (const b of branches) {
      const key = b.parent_branch_id ?? "__ROOT__";
      (children[key] ??= []).push(b);
    }
    const render = (parent: string | null, prefix: string): void => {
      let kids = children[parent ?? "__ROOT__"] ?? [];
      if (parent === null) {
        kids = [...kids].sort(
          (a, b) =>
            (a.branch_id !== "main" ? 1 : 0) -
              (b.branch_id !== "main" ? 1 : 0) || a.created_at - b.created_at,
        );
      }
      kids.forEach((b, idx) => {
        const last = idx === kids.length - 1;
        const connector = last ? "└─ " : "├─ ";
        const tmux = tmuxSessionName(s.id, b.branch_id);
        const state = live.has(tmux) ? "alive" : "dead";
        const agentTag = `[${b.agent_type}]`;
        const ctxTag =
          b.inherit_context === null
            ? ""
            : b.inherit_context
              ? " (inherit)"
              : " (isolated)";
        const instr = truncate(b.instruction);
        let label = `${b.branch_id} ${agentTag} [${state}]${ctxTag}`;
        if (instr) label += `  "${instr}"`;
        console.log(`${prefix}${connector}${label}`);
        const nextPrefix = prefix + (last ? "   " : "│  ");
        render(b.branch_id, nextPrefix);
      });
    };
    render(null, "");
  });
}

export function cmdList(opts: ListOpts = {}): void {
  const db = openDb();
  const sessions = listSessions(db);
  const live = new Set(listLoomSessions());

  const branchesBySession = new Map<string, Branch[]>();
  for (const s of sessions) {
    branchesBySession.set(s.id, listBranches(db, s.id));
  }

  if (opts.json) {
    renderJson(sessions, branchesBySession, live);
    return;
  }
  renderTree(sessions, branchesBySession, live);
}
