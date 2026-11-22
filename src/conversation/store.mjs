import fs from 'node:fs';
import path from 'node:path';
import {randomUUID} from 'node:crypto';
import {DatabaseSync} from 'node:sqlite';

const uuid = value => typeof value === 'string' && /^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(value);
const imageExtensions = new Set(['.png', '.jpg', '.jpeg', '.gif', '.bmp']);

export class ConversationStore {
  constructor(directory) {
    this.directory = directory;
    fs.mkdirSync(directory, {recursive: true});
    this.db = new DatabaseSync(path.join(directory, 'conversation.sqlite'));
    try {
      this.db.exec(`
        PRAGMA journal_mode=WAL;
        PRAGMA synchronous=FULL;
        PRAGMA foreign_keys=ON;
        PRAGMA busy_timeout=3000;
        CREATE TABLE IF NOT EXISTS metadata (key TEXT PRIMARY KEY);
        CREATE TABLE IF NOT EXISTS messages (
          id TEXT PRIMARY KEY, sequence INTEGER NOT NULL UNIQUE, audio_id TEXT UNIQUE, data TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS replies (
          id TEXT PRIMARY KEY REFERENCES messages(id), data TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS attachments (
          id TEXT PRIMARY KEY, message_id TEXT NOT NULL REFERENCES messages(id), data TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS attachments_message ON attachments(message_id);
      `);
      this.migrate();
    } catch (error) {
      this.db.close();
      throw error;
    }
  }

  transaction(operation) {
    this.db.exec('BEGIN IMMEDIATE');
    try {
      const result = operation();
      this.db.exec('COMMIT');
      return result;
    } catch (error) {
      this.db.exec('ROLLBACK');
      throw error;
    }
  }

  legacyRecords(folder) {
    const directory = path.join(this.directory, folder);
    if (!fs.existsSync(directory)) return [];
    return fs.readdirSync(directory).filter(name => name.endsWith('.json')).map(name => {
      const record = JSON.parse(fs.readFileSync(path.join(directory, name), 'utf8'));
      if (record.id !== path.basename(name, '.json')) throw Error(`Invalid legacy record: ${name}`);
      return record;
    });
  }

  migrate() {
    this.transaction(() => {
      if (this.db.prepare("SELECT 1 FROM metadata WHERE key='legacy-imported'").get()) return;
      for (const message of this.legacyRecords('inputs')) this.insertMessage(message);
      for (const reply of this.legacyRecords('replies')) this.saveReply(reply);
      this.db.prepare("INSERT INTO metadata VALUES ('legacy-imported')").run();
    });
  }

  insertMessage(message) {
    this.db.prepare('INSERT INTO messages VALUES (?, ?, ?, ?)')
      .run(message.id, message.sequence, message.audioId ?? null, JSON.stringify(message));
  }

  async submit({id, text, createdAt, audioId, recordedMessageId, files = []}) {
    if (!uuid(id) || typeof createdAt !== 'string' || typeof text !== 'string' ||
        text.length > 50000 || !Array.isArray(files) || (audioId !== undefined && !uuid(audioId)) ||
        (!text.trim() && !audioId && !files.length)) throw Error('消息内容或附件无效');
    const findMessage = this.db.prepare('SELECT id FROM messages WHERE id=? OR audio_id=?');
    const existing = findMessage.get(id, audioId ?? null);
    if (existing) return existing.id;
    if (recordedMessageId) throw Error('此音频已发送');
    const attachments = [];
    let committed = false;
    try {
      for (const source of files) {
        if (typeof source !== 'string' || !path.isAbsolute(source) || !(await fs.promises.stat(source)).isFile())
          throw Error('附件必须是可读取的文件');
        const attachmentId = randomUUID();
        const name = path.basename(source);
        const extension = path.extname(name).toLowerCase();
        const storedName = /^[.][a-z0-9]{1,16}$/.test(extension) ? 'original' + extension : 'original';
        const relativePath = `attachments/${attachmentId}/${storedName}`;
        const file = path.join(this.directory, relativePath);
        fs.mkdirSync(path.dirname(file), {recursive: true});
        attachments.push({id: attachmentId, name, relativePath, image: imageExtensions.has(extension)});
        await fs.promises.copyFile(source, file, fs.constants.COPYFILE_EXCL);
        const handle = await fs.promises.open(file, 'r+');
        try { await handle.sync(); } finally { await handle.close(); }
      }
      const result = this.transaction(() => {
        const previous = findMessage.get(id, audioId ?? null);
        if (previous) return {id: previous.id, inserted: false};
        const sequence = this.db.prepare('SELECT coalesce(max(sequence), 0) + 1 AS next FROM messages').get().next;
        const message = {id, sequence, text, createdAt};
        if (audioId) message.audioId = audioId;
        if (attachments.length) message.attachmentIds = attachments.map(attachment => attachment.id);
        this.insertMessage(message);
        const insert = this.db.prepare('INSERT INTO attachments VALUES (?, ?, ?)');
        for (const attachment of attachments) insert.run(attachment.id, id, JSON.stringify(attachment));
        return {id, inserted: true};
      });
      committed = result.inserted;
      return result.id;
    } finally {
      if (!committed) for (const attachment of attachments) {
        const file = path.join(this.directory, attachment.relativePath);
        fs.rmSync(file, {force: true});
        fs.rmdirSync(path.dirname(file));
      }
    }
  }

  saveReply(reply) {
    this.db.prepare('INSERT INTO replies VALUES (?, ?) ON CONFLICT(id) DO NOTHING')
      .run(reply.id, JSON.stringify(reply));
  }

  records() {
    const attachments = new Map(this.db.prepare('SELECT id, data FROM attachments').all()
      .map(row => [row.id, JSON.parse(row.data)]));
    return this.db.prepare(`SELECT m.data, r.data AS reply FROM messages m
      LEFT JOIN replies r ON r.id=m.id ORDER BY m.sequence`).all().map(row => {
      const message = JSON.parse(row.data);
      if (row.reply) message.reply = JSON.parse(row.reply);
      if (message.attachmentIds) message.attachments = message.attachmentIds.map(id => attachments.get(id));
      return message;
    });
  }

  pending() {
    return this.db.prepare(`SELECT m.data FROM messages m
      WHERE NOT EXISTS (SELECT 1 FROM replies r WHERE r.id=m.id) ORDER BY m.sequence`)
      .all().map(row => JSON.parse(row.data));
  }

  audioMessages() {
    return this.db.prepare('SELECT id, audio_id AS audioId FROM messages WHERE audio_id IS NOT NULL').all();
  }

  attachment(id) {
    const row = this.db.prepare('SELECT data FROM attachments WHERE id=?').get(id);
    return row ? JSON.parse(row.data) : null;
  }

  close() { this.db.close(); }
}
