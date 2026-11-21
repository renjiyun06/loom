import fs from 'node:fs/promises';
import {createRequire} from 'node:module';
import path from 'node:path';

// Run on the extracted icon directory with a verified svgpath 2.6.0 entry module.
// Bloc handles explicit path commands and cubic curves consistently.
const [directory, normalizer] = process.argv.slice(2);
if (!directory || !normalizer) throw new Error('Usage: prepare-lucide-paths.mjs <icons> <svgpath entry file>');
const svgpath = createRequire(import.meta.url)(path.resolve(normalizer));
const icons = (await fs.readdir(directory, {withFileTypes: true}))
  .filter(entry => entry.isFile() && /^[a-z0-9-]+\.svg$/.test(entry.name));
if (icons.length === 0) throw new Error('No Lucide SVG files found');

let changed = 0;
for (const {name} of icons) {
  const file = path.join(directory, name);
  const source = await fs.readFile(file, 'utf8');
  const prepared = source.replace(/(<path\b[^>]*\bd=")([^"]*)(")/g, (_, start, d, end) => {
    const parsed = svgpath(d);
    if (parsed.err) throw new Error(`${name}: ${parsed.err}`);
    const explicit = parsed.abs().unarc().unshort().round(4).segments.map(segment => segment.join(' ')).join(' ');
    return start + explicit + end;
  });
  if (prepared !== source) {
    await fs.writeFile(file, prepared);
    changed++;
  }
}
console.log(JSON.stringify({icons: icons.length, normalized: changed}));
