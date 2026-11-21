import fs from 'node:fs';
import path from 'node:path';

const activityTypes = new Set(['agentMessage', 'reasoning', 'plan', 'dynamicToolCall',
  'mcpToolCall', 'commandExecution', 'fileChange', 'webSearch']);
const detailFields = ['tool', 'server', 'arguments', 'command', 'aggregatedOutput', 'exitCode',
  'durationMs', 'success', 'error', 'result', 'contentItems', 'changes', 'action'];
const secretFields = new Set(['apikey', 'api_key', 'token', 'access_token', 'authorization', 'password', 'secret']);
const running = new Set(['inProgress', 'pending', '进行中']);
const activitySource = `FROM loom_activities a
  LEFT JOIN calls c ON c.request_id=a.call_id
  LEFT JOIN loom_sessions s ON s.client_key=COALESCE(json_extract(c.request_json,'$.clientKey'),
    (SELECT e.client_key FROM events e WHERE e.event='explicit-new-conversation'
      AND (e.request_id=a.call_id OR 'legacy-switch-'||e.id=a.call_id) ORDER BY e.id LIMIT 1),
    (SELECT e.client_key FROM events e WHERE e.event IN ('initialize','bound')
      AND e.thread_id=json_extract(c.result_json,'$.threadId') ORDER BY e.id LIMIT 1))`;

function prepareActivityPage(db, scope) {
  const selection=`${activitySource} WHERE a.visible=1${scope}`;
  return {
    recent:db.prepare(`SELECT min(seq) AS first FROM (SELECT a.seq ${selection} ORDER BY a.seq DESC LIMIT ?)`),
    earlier:db.prepare(`SELECT min(seq) AS first FROM (SELECT a.seq ${selection} AND a.seq < ? ORDER BY a.seq DESC LIMIT ?)`),
    read:db.prepare(`SELECT a.call_id,a.item_id,a.data,s.id AS sessionId ${selection} AND a.seq >= ? ORDER BY a.seq`),
    hasEarlier:db.prepare(`SELECT 1 ${selection} AND a.seq < ? LIMIT 1`),
  };
}

function safeValue(value) {
  if (Array.isArray(value)) return value.map(safeValue);
  if (value && typeof value === 'object') {
    return Object.fromEntries(Object.entries(value).map(([key, entry]) => [key,
      secretFields.has(key.toLowerCase()) ? '[已隐藏]' : safeValue(entry)]));
  }
  return value;
}

function isVisible(row) {
  if (row.type === 'agentMessage') return row.phase === 'commentary';
  if (row.type === 'reasoning' || row.type === 'plan') return Boolean(row.text);
  return true;
}

export class ActivityStore {
  constructor(db) {
    this.db = db;
    this.revision = 0;
    db.exec(`CREATE TABLE IF NOT EXISTS loom_activities (
      seq INTEGER PRIMARY KEY,
      call_id TEXT NOT NULL,
      item_id TEXT NOT NULL,
      visible INTEGER NOT NULL CHECK (visible IN (0,1)),
      data TEXT NOT NULL,
      UNIQUE (call_id, item_id)
    );
    CREATE INDEX IF NOT EXISTS loom_activity_visible ON loom_activities(seq) WHERE visible=1;`);
    this.item = db.prepare('SELECT data FROM loom_activities WHERE call_id=? AND item_id=?');
    this.upsert = db.prepare(`INSERT INTO loom_activities(call_id,item_id,visible,data) VALUES (?,?,?,?)
      ON CONFLICT(call_id,item_id) DO UPDATE SET visible=excluded.visible, data=excluded.data
      WHERE loom_activities.data <> excluded.data OR loom_activities.visible <> excluded.visible`);
    this.callItems = db.prepare('SELECT item_id,data FROM loom_activities WHERE call_id=? ORDER BY seq');
    this.hasVisible = db.prepare('SELECT 1 FROM loom_activities WHERE call_id=? AND visible=1 LIMIT 1');
    this.all = prepareActivityPage(db,'');
    this.managed = prepareActivityPage(db,' AND s.id IS NOT NULL');
    this.bySession = prepareActivityPage(db,' AND s.id=?');
    this.callItemsForSession = db.prepare(`SELECT a.data ${activitySource} WHERE a.call_id=? AND s.id=? ORDER BY a.seq`);
  }

  put(callId, itemId, activity) {
    const result = this.upsert.run(callId, itemId, Number(isVisible(activity)), JSON.stringify(activity));
    if (result.changes) this.revision++;
  }

  record(callId, title, text = '', at = new Date().toISOString()) {
    this.put(callId, 'summary', {type:'loomActivity', title, text, status:'completed', at});
  }

  accept(callId, message, at) {
    const {method, params} = message;
    if (!params) return;
    if (method === 'turn/completed') {
      if (params.turn?.status !== 'completed') this.interrupt(callId);
      return;
    }
    if (method === 'item/tool/call') {
      if (params.callId) this.put(callId, params.callId, {type:'dynamicToolCall', text:'', status:'inProgress',
        tool:params.tool, arguments:safeValue(params.arguments), at});
      return;
    }
    const deltaType = method === 'item/agentMessage/delta' ? 'agentMessage' :
      method === 'item/reasoning/summaryTextDelta' ? 'reasoning' : null;
    if (deltaType && params.itemId && typeof params.delta === 'string') {
      const row = this.entry(callId, params.itemId, deltaType, at);
      row.text += params.delta;
      this.put(callId, params.itemId, row);
      return;
    }
    const item = params.item;
    if (!['item/started', 'item/completed'].includes(method) || !item?.id || !activityTypes.has(item.type)) return;
    const row = this.entry(callId, item.id, item.type, at);
    row.status = item.status ?? (method === 'item/completed' ? 'completed' : 'inProgress');
    if (item.type === 'agentMessage') {
      if (item.phase) row.phase = item.phase;
      if (item.text || method === 'item/completed') row.text = item.text ?? '';
    }
    if (item.type === 'reasoning' && item.summary?.length) row.text = item.summary.join('\n');
    if (item.type === 'plan' && typeof item.text === 'string') row.text = item.text;
    for (const key of detailFields) if (Object.hasOwn(item, key)) row[key] = safeValue(item[key]);
    this.put(callId, item.id, row);
  }

  entry(callId, itemId, type, at) {
    const row = this.item.get(callId, itemId);
    return row ? JSON.parse(row.data) : {type, text:'', status:'inProgress', at};
  }

  interrupt(callId) {
    for (const {item_id, data} of this.callItems.all(callId)) {
      const row = JSON.parse(data);
      if (running.has(row.status)) this.put(callId, item_id, {...row, status:'interrupted'});
    }
  }

  finish(callId, ok, at) {
    if (!ok) {
      this.interrupt(callId);
      if (!this.item.get(callId, 'summary')) this.record(callId, 'Codex 调用未完成', '', at);
    } else if (!this.hasVisible.get(callId)) {
      this.record(callId, 'Codex 调用已完成', '', at);
    }
  }

  page({first = null, limit, previousLimit = limit, focus = null, session = null, managedOnly = false}) {
    const page=session!==null?this.bySession:managedOnly?this.managed:this.all;
    const args=session!==null?[session]:[];
    if (first === null) first = page.recent.get(...args,limit).first;
    else if (limit > previousLimit) first = page.earlier.get(...args,first,limit - previousLimit).first ?? first;
    const items = page.read.all(...args,first ?? 0).map(row => ({...JSON.parse(row.data),
      id:row.call_id+'/'+row.item_id,sessionId:row.sessionId}));
    const focusItems = focus ? (session===null?this.callItems.all(focus):this.callItemsForSession.all(focus,session)) : [];
    const answer = focusItems.map(row => JSON.parse(row.data))
      .filter(row => row.type === 'agentMessage' && row.phase === 'final_answer' && row.text)
      .map(row => row.text).join('\n');
    return {first, items, answer, older:first !== null && Boolean(page.hasEarlier.get(...args,first))};
  }
}

function readRecords(file) {
  return fs.readFileSync(file, 'utf8').split('\n');
}

function parse(line) {
  try { return JSON.parse(line); } catch { return null; }
}

function archivedItems(home, threadId) {
  const turns = new Map();
  for (const directory of ['sessions', 'archived_sessions']) {
    const base = path.join(home, directory);
    if (!fs.existsSync(base)) continue;
    const file = fs.readdirSync(base, {recursive:true}).find(name => name.endsWith(threadId+'.jsonl'));
    if (!file) continue;
    for (const line of readRecords(path.join(base, file))) {
      if (!line.includes('"item_completed"')) continue;
      const envelope = parse(line);
      const event = envelope?.payload;
      if (envelope?.type !== 'event_msg' || event?.type !== 'item_completed' || !event.turn_id || !event.item) continue;
      const original = event.item;
      const type = original.type?.replace(/^./, letter => letter.toLowerCase());
      if (!activityTypes.has(type)) continue;
      const item = {...original, type, contentItems: original.content_items};
      if (type === 'agentMessage') item.text = original.content?.map(part => part.text ?? '').join('\n') ?? '';
      if (type === 'reasoning') item.summary = original.summary_text;
      if (!turns.has(event.turn_id)) turns.set(event.turn_id, []);
      turns.get(event.turn_id).push({at:envelope.timestamp, message:{method:'item/completed',params:{item}}});
    }
    break;
  }
  return turns;
}

export function migrateActivities(registry, {logs, codexHome}) {
  const {db, activity} = registry;
  return registry.transaction(() => {
    if (db.prepare("SELECT 1 FROM meta WHERE key='loom_activities_v1'").get()) return false;
    const calls = db.prepare(`SELECT request_id AS id, json_extract(request_json,'$.action') AS action,
      json_extract(result_json,'$.ok') AS ok, json_extract(result_json,'$.threadId') AS threadId,
      json_extract(result_json,'$.turnId') AS turnId, json_extract(result_json,'$.startedAt') AS startedAt,
      json_extract(result_json,'$.completedAt') AS completedAt
      FROM calls ORDER BY rowid`).all();
    const archives = new Map();
    const switchTime = db.prepare("SELECT created_at FROM events WHERE request_id=? AND event='explicit-new-conversation' ORDER BY id LIMIT 1");
    const detachedSwitches = db.prepare(`SELECT id,request_id,created_at FROM events e
      WHERE event='explicit-new-conversation' AND NOT EXISTS (SELECT 1 FROM calls c WHERE c.request_id=e.request_id)
      ORDER BY created_at,id`).all();
    let switchIndex = 0;
    const importSwitches = before => {
      while (switchIndex < detachedSwitches.length && detachedSwitches[switchIndex].created_at <= before) {
        const event = detachedSwitches[switchIndex++];
        activity.record(event.request_id ?? 'legacy-switch-'+event.id, '已切换 Codex 会话', '', event.created_at);
      }
    };
    for (const call of calls) {
      if (call.action === 'newConversation') {
        const at = switchTime.get(call.id)?.created_at;
        if (at) importSwitches(at);
        activity.record(call.id, '已切换 Codex 会话', '', at);
        continue;
      }
      if (call.action !== 'ask') continue;
      if (call.startedAt) importSwitches(call.startedAt);
      const file = path.join(logs, 'codex-events', call.id+'.events.jsonl');
      if (fs.existsSync(file)) {
        for (const line of readRecords(file)) {
          const envelope = parse(line);
          if (envelope?.direction === 'server' && envelope.message) activity.accept(call.id, envelope.message, envelope.at);
        }
      } else if (call.threadId && call.turnId) {
        if (!archives.has(call.threadId)) archives.set(call.threadId, archivedItems(codexHome, call.threadId));
        for (const envelope of archives.get(call.threadId).get(call.turnId) ?? []) {
          activity.accept(call.id, envelope.message, envelope.at);
        }
      }
      activity.finish(call.id, call.ok === 1, call.completedAt ?? undefined);
    }
    importSwitches('\uffff');
    db.prepare("INSERT INTO meta VALUES ('loom_activities_v1',?)").run(new Date().toISOString());
    return true;
  });
}
