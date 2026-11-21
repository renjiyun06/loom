import fs from 'node:fs/promises';
import path from 'node:path';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import {evaluate} from '../../src/bridge/runtime-client.mjs';
import {root} from '../../src/bridge/paths.mjs';

const source = await fs.readFile(path.join(root, 'prototypes/conversation-ui/app.js'), 'utf8');
const fixtureSource = source.slice(source.indexOf('var sampleUser='), source.indexOf('var messages='));
const fixture = vm.runInNewContext(`${fixtureSource}\n({sampleUser, sampleAnswer, activities})`, {
  tick: '`', fence: '```',
}, {timeout: 1000});
const now = new Date();
now.setHours(10, 48, 0, 0);
const payload = {
  messages: [
    {id: 'reference-user', role: 'user', text: fixture.sampleUser, createdAt: now.toISOString()},
    {id: 'reference-reply', role: 'assistant', text: fixture.sampleAnswer, ok: true},
  ],
  activities: fixture.activities.map(entry => entry.type === 'progress' ? {
    id: entry.id, type: 'agentMessage', phase: 'commentary', title: entry.title,
    text: `${entry.title}。${entry.text}`, createdAt: entry.time,
  } : {
    id: entry.id, type: 'dynamicToolCall', status: 'completed', title: entry.title,
    tool: entry.tool, durationMs: parseInt(entry.duration, 10), success: true,
    arguments: entry.args, result: entry.result,
  }),
  status: '已完成', processing: false, elapsed: 12.4,
};
const smalltalk = text => `'${text.replaceAll("'", "''")}'`;
const directory = path.join(root, 'tests/results/conversation-prototype');
await fs.mkdir(directory, {recursive: true});
const tag = process.argv.includes('--before') ? 'before' : 'after';
const results = [];
const scenarios = [[1493, 817], [760, 700]];
if (tag === 'after') scenarios.push([760, 700, true]);
for (const [width, height, openOverlay] of scenarios) {
  const name = `${tag}-${width}${openOverlay ? '-open' : ''}`;
  const image = path.join(directory, `${name}.png`);
  const receipt = path.join(directory, `${name}.json`);
  await fs.rm(receipt, {force: true});
  const reply = await evaluate(`
    LoomConversationWindow defer: [
      | ui element result |
      result := [
        ui := LMConversationUI new build.
        ui instVarNamed: 'followOutput' put: false.
        ui instVarNamed: 'activityFollow' put: false.
        ui applyUpdate: (STONJSON fromString: ${smalltalk(JSON.stringify(payload))}).
        element := ui instVarNamed: 'root'.
        element hExact: ${width}; vExact: ${height}; forceLayout; forceLayout.
        ${openOverlay ? 'ui toggleActivityPane. element requestLayout; forceLayout.' : ''}
        BlExporter png element: element; fileName: ${smalltalk(image)}; export.
        { true. LMConversationUI featureVersion.
          (ui instVarNamed: 'conversationPane') width.
          (ui instVarNamed: 'activityPane') width.
          (ui instVarNamed: 'historyItems') size.
          (ui instVarNamed: 'activityItems') size }
      ] on: Error do: [ :error | { false. error description } ].
      ${smalltalk(receipt)} asFileReference writeStreamDo: [ :stream | stream nextPutAll: (STONJSON toString: result) ] ].
    true`, `conversation-reference-${tag}-${width}`);
  if (!reply.ok) throw new Error(JSON.stringify(reply));
  let data;
  for (let i = 0; i < 60; i++) {
    try { data = JSON.parse(await fs.readFile(receipt, 'utf8')); break; }
    catch (error) { if (error.code !== 'ENOENT' && !(error instanceof SyntaxError)) throw error; }
    await new Promise(resolve => setTimeout(resolve, 200));
  }
  if (!data?.[0]) throw new Error(`Native capture ${width}: ${JSON.stringify(data)}`);
  assert.deepEqual(data.slice(4), [2, 6], 'The native capture must contain all prototype rows');
  if (tag === 'after' && width === 760) {
    assert.equal(data[2], 760);
    if (openOverlay) assert.equal(data[3], 380);
  }
  results.push({width, height, image, result: data});
}
console.log(JSON.stringify(results, null, 2));
