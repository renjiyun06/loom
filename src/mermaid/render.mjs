import { existsSync } from 'node:fs';
import { readFile } from 'node:fs/promises';
import { createRequire } from 'node:module';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import readline from 'node:readline/promises';

const origin = 'http://loom-mermaid.invalid';
const sourceRoot = import.meta.dirname;
const runtime = path.resolve(sourceRoot, '../../runtime/mermaid');
const modules = path.join(runtime, 'node_modules');
const requireFromRuntime = createRequire(path.join(runtime, 'package.json'));
const libraries = new Map([
  ['/mermaid/', path.join(modules, 'mermaid', 'dist')],
  ['/zenuml/', path.join(modules, '@mermaid-js', 'mermaid-zenuml', 'dist')],
]);
const document = `<!doctype html>
<html><head><meta charset="utf-8">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'self'; style-src 'unsafe-inline'; img-src data:; font-src data:; worker-src blob:">
<style>
  html, body { margin: 0; padding: 0; }
  #diagram { display: inline-block; padding: 8px; background: white; }
  #diagram > svg { display: block; }
</style></head><body>
<div id="diagram"></div>
<script type="module" src="/page.mjs"></script>
</body></html>`;

function chromiumPath() {
  const programFiles = [process.env.ProgramW6432, process.env.ProgramFiles, process.env['ProgramFiles(x86)'], process.env.LOCALAPPDATA];
  const candidates = programFiles.filter(Boolean).flatMap((base) => [
    path.join(base, 'Google', 'Chrome', 'Application', 'chrome.exe'),
    path.join(base, 'Microsoft', 'Edge', 'Application', 'msedge.exe'),
  ]);
  const executable = candidates.find(existsSync);
  if (!executable) throw new Error('未找到 Chrome 或 Edge。');
  return executable;
}

async function respond(request) {
  const url = new URL(request.url());
  if (url.origin !== origin) {
    if (url.protocol === 'data:' || url.protocol === 'blob:') {
      await request.continue();
    } else {
      await request.abort();
    }
    return;
  }
  if (url.pathname === '/') {
    await request.respond({ contentType: 'text/html; charset=utf-8', body: document });
    return;
  }

  let file;
  if (url.pathname === '/page.mjs') {
    file = path.join(sourceRoot, 'page.mjs');
  } else {
    for (const [prefix, folder] of libraries) {
      if (!url.pathname.startsWith(prefix)) continue;
      const relative = url.pathname.slice(prefix.length);
      if (!/^[A-Za-z0-9_./-]+\.m?js$/.test(relative)) break;
      const candidate = path.resolve(folder, relative);
      if (candidate.startsWith(folder + path.sep)) file = candidate;
      break;
    }
  }

  if (!file) {
    await request.respond({ status: 404 });
    return;
  }
  try {
    await request.respond({ contentType: 'text/javascript; charset=utf-8', body: await readFile(file) });
  } catch (error) {
    if (error.code !== 'ENOENT') throw error;
    await request.respond({ status: 404 });
  }
}

export async function openRenderer() {
  if (!existsSync(path.join(modules, 'mermaid', 'dist', 'mermaid.esm.min.mjs'))) {
    throw new Error('Mermaid 渲染依赖未安装。');
  }
  const puppeteerModule = requireFromRuntime.resolve('puppeteer-core');
  const { default: puppeteer } = await import(pathToFileURL(puppeteerModule).href);
  const browser = await puppeteer.launch({
    executablePath: chromiumPath(),
    headless: true,
    pipe: true,
    timeout: 12000,
    protocolTimeout: 12000,
    defaultViewport: { width: 1320, height: 900, deviceScaleFactor: 1.5 },
  });
  try {
    const [page] = await browser.pages();
    await page.setRequestInterception(true);
    page.on('request', (request) => {
      respond(request).catch(() => request.abort().catch(() => {}));
    });
    await page.goto(origin + '/', { waitUntil: 'load', timeout: 12000 });
    await page.waitForFunction('typeof window.renderDiagram === "function"', { timeout: 5000 });
    return {
      async render(source) {
        const dimensions = await page.evaluate((code) => window.renderDiagram(code), source);
        const { width, height, diagramType } = dimensions;
        if (width < 1 || height < 1 || width > 1320 || height > 8020) {
          throw new Error('图形尺寸超出对话显示范围。');
        }
        const scale = Math.min(1, Math.sqrt(6_000_000 / (width * height)));
        const png = await page.screenshot({
          type: 'png',
          encoding: 'base64',
          clip: { x: 0, y: 0, width, height, scale },
          captureBeyondViewport: true,
        });
        return { ok: true, width, height, diagramType, png };
      },
      close: () => browser.close(),
    };
  } catch (error) {
    await browser.close();
    throw error;
  }
}

async function main() {
  const input = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });
  let renderer;
  try {
    for await (const line of input) {
      if (!renderer) renderer = await openRenderer();
      try {
        const { source } = JSON.parse(line);
        if (typeof source !== 'string' || !source.trim()) throw new Error('Mermaid 代码为空。');
        process.stdout.write(JSON.stringify(await renderer.render(source)) + '\n');
      } catch (error) {
        process.stdout.write(JSON.stringify({ ok: false, error: error.message.split('\n')[0] }) + '\n');
      }
    }
  } catch (error) {
    process.stdout.write(JSON.stringify({ ok: false, error: error.message.split('\n')[0] }) + '\n');
  } finally {
    input.close();
    if (renderer) await renderer.close();
  }
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  await main();
}
