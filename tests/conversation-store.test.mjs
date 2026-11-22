import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {randomUUID} from 'node:crypto';
import {ConversationStore} from '../src/conversation/store.mjs';

const createdAt = '2026-11-22T04:45:00.000Z';

function fixture(t) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'loom-conversation-'));
  t.after(() => fs.rmSync(root, {recursive: true, force: true}));
  return root;
}

test('imports legacy messages and replies in order and preserves pending work', async t => {
  const root = fixture(t);
  const first = {id: randomUUID(), sequence: 4, text: '旧消息', createdAt};
  const second = {id: randomUUID(), sequence: 8, text: '', createdAt, audioId: randomUUID()};
  const reply = {id: first.id, ok: false, text: '旧回执', invocation: {turnId: 'old-turn'}, completedAt: createdAt};
  for (const [folder, records] of [['inputs', [second, first]], ['replies', [reply]]]) {
    const dir = path.join(root, folder);
    fs.mkdirSync(dir);
    for (const row of records) fs.writeFileSync(path.join(dir, row.id + '.json'), JSON.stringify(row));
  }
  const initial = new ConversationStore(root);
  assert.deepEqual(initial.records(), [{...first, reply}, second]);
  assert.deepEqual(initial.pending(), [second]);
  assert.deepEqual(initial.audioMessages().map(row => ({...row})), [{id: second.id, audioId: second.audioId}]);
  assert.equal(await initial.submit({id: randomUUID(), text: '', audioId: second.audioId, createdAt}), second.id);
  initial.close();

  const reopened = new ConversationStore(root);
  try {
    const id = await reopened.submit({id: randomUUID(), text: '新消息', createdAt});
    assert.deepEqual(reopened.records().map(row => [row.id, row.sequence]), [[first.id, 4], [second.id, 8], [id, 9]]);
  } finally { reopened.close(); }
});

test('attachment-only messages preserve file snapshots and attachment order across reopen', async t => {
  const root = fixture(t);
  const id = randomUUID();
  const picture = path.join(root, '截图.png');
  const notes = path.join(root, '记录.txt');
  fs.writeFileSync(picture, 'image fixture');
  fs.writeFileSync(notes, 'saved notes');
  const first = new ConversationStore(root);
  assert.equal(await first.submit({id, text: '', createdAt, files: [picture, notes]}), id);
  const [message] = first.pending();
  assert.equal(message.text, '');
  assert.equal(message.attachmentIds.length, 2);
  assert.equal(message.attachments, undefined);
  first.close();
  fs.unlinkSync(picture);
  fs.writeFileSync(notes, 'changed');

  const second = new ConversationStore(root);
  try {
    const attachments = message.attachmentIds.map(ref => second.attachment(ref));
    assert.deepEqual(attachments.map(item => [item.name, item.image]), [['截图.png', true], ['记录.txt', false]]);
    assert.deepEqual(attachments.map(item => fs.readFileSync(path.join(root, item.relativePath), 'utf8')),
      ['image fixture', 'saved notes']);
    assert.deepEqual(second.records()[0].attachments, attachments);
    assert.equal(await second.submit({id, text: '', createdAt, files: [picture]}), id);
    second.saveReply({id, ok: true, text: 'done'});
    assert.deepEqual(second.pending(), []);
    assert.equal(second.records()[0].reply.text, 'done');
  } finally { second.close(); }
});

test('failed attachment import leaves no committed message or copied files', async t => {
  const root = fixture(t);
  const source = path.join(root, 'one.txt');
  fs.writeFileSync(source, 'file fixture');
  const store = new ConversationStore(root);
  try {
    await assert.rejects(store.submit({id: randomUUID(), text: '', createdAt, files: [source, path.join(root, 'missing')]}),
      {code: 'ENOENT'});
    assert.deepEqual(store.records(), []);
    assert.deepEqual(fs.readdirSync(path.join(root, 'attachments')), []);
  } finally { store.close(); }
});
