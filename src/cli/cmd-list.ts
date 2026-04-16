/**
 * `loom list` — render all sessions with their branch trees.
 */

import {
  listBranches,
  listSessions,
  openDb,
} from "../core/db.js";
import { listLoomSessions, tmuxSessionName } from "../core/tmux.js";
import type { Branch } from "../types.js";

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

export function cmdList(): void {
  const db = openDb();
  const sessions = listSessions(db);
  if (!sessions.length) {
    console.log("loom: no sessions recorded");
    return;
  }

  const live = new Set(listLoomSessions());

  sessions.forEach((s, i) => {
    if (i > 0) console.log();
    console.log(
      `session ${s.id}  cwd=${s.cwd}  created=${fmtTs(s.created_at)}`,
    );
    const branches = listBranches(db, s.id);
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
