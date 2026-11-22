import fs from 'node:fs';
import path from 'node:path';
import {randomUUID} from 'node:crypto';
import {execFile} from 'node:child_process';
import {promisify} from 'node:util';
import {atomicJSON} from '../bridge/atomic-files.mjs';

const exec = promisify(execFile);
const pickerCommand = Buffer.from(`
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
Add-Type -AssemblyName System.Windows.Forms
$picker = [Windows.Forms.OpenFileDialog]::new()
try {
  $picker.Title = '选择附件'
  $picker.Multiselect = $true
  $picker.Filter = '所有文件|*.*'
  $files = @()
  if ($picker.ShowDialog() -eq [Windows.Forms.DialogResult]::OK) { $files = $picker.FileNames }
  ConvertTo-Json -Compress -InputObject $files
} finally { $picker.Dispose() }
`, 'utf16le').toString('base64');

export class ConversationService {
  constructor(ipc, store) {
    this.store = store;
    this.requests = path.join(ipc, 'conversation', 'requests');
    this.results = path.join(ipc, 'conversation', 'results');
    this.revision = path.join(ipc, 'conversation', 'revision.json');
    for (const directory of [this.requests, this.results]) fs.mkdirSync(directory, {recursive: true});
    this.active = new Map();
    this.abort = new AbortController();
    this.publish();
  }

  publish() {
    atomicJSON(this.revision, randomUUID());
    this.revisionDirty = false;
  }

  async handle(request) {
    switch (request.action) {
      case 'records': return this.store.records();
      case 'pending': return this.store.pending();
      case 'attachment': return this.store.attachment(request.attachmentId);
      case 'submit': {
        const id = await this.store.submit(request);
        this.revisionDirty = true;
        return id;
      }
      case 'reply':
        this.store.saveReply(request.reply);
        this.revisionDirty = true;
        return true;
      case 'pick': {
        const powershell = path.join(process.env.SystemRoot, 'System32/WindowsPowerShell/v1.0/powershell.exe');
        const {stdout} = await exec(powershell, ['-NoProfile', '-STA', '-EncodedCommand', pickerCommand],
          {windowsHide: true, timeout: 600000, signal: this.abort.signal});
        return JSON.parse(stdout);
      }
      default: throw Error('未知对话存储操作');
    }
  }

  poll(onError) {
    if (this.revisionDirty) {
      try { this.publish(); }
      catch (error) { console.error('Conversation revision:', error.message); }
    }
    for (const name of fs.readdirSync(this.requests).filter(file => /^[a-f0-9-]{36}\.json$/i.test(file))) {
      const receipt = path.join(this.results, name);
      if (this.active.has(name) || fs.existsSync(receipt)) continue;
      const operation = (async () => {
        let result;
        try {
          const request = JSON.parse(fs.readFileSync(path.join(this.requests, name), 'utf8'));
          result = {ok: true, value: await this.handle(request)};
        } catch (error) {
          result = {ok: false, error: error.message};
        }
        atomicJSON(receipt, result);
      })().catch(onError).finally(() => this.active.delete(name));
      this.active.set(name, operation);
    }
  }

  async close() {
    this.abort.abort();
    await Promise.allSettled(this.active.values());
    this.store.close();
  }
}
