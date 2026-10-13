#!/usr/bin/env node
// Generates the diagrams (SVG) of both languages. Sources: tools/diagrams/*.mjs (lib.mjs holds the shared helpers).
//
//   node tools/gen-diagrams.mjs           # write the SVG files
//   node tools/gen-diagrams.mjs --check   # fail if an SVG in the repo differs from its source (for CI)
//
//   English (default) → labs/diagrams/*.svg        Korean → labs/ko/diagrams/*.svg
//
// Each module exports `diagrams = [{ name, build() { ...returns a Diagram } }]`.
// Every visible text is written with `t('English', '한국어')` (see lib.mjs) and must be evaluated inside build(),
// because the generator runs every build() once per language.
// If text is estimated to overflow its box, a warning is printed and the run fails.
import { existsSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { LANGS, ROOT } from './docs-config.mjs';
import { setLang } from './diagrams/lib.mjs';

const SRC = join(ROOT, 'tools', 'diagrams');
const check = process.argv.includes('--check');

const modules = readdirSync(SRC)
  .filter((f) => f.endsWith('.mjs') && f !== 'lib.mjs')
  .sort();

let warnings = 0;
let stale = 0;
let count = 0;

for (const lang of Object.keys(LANGS)) {
  setLang(lang);
  const outDir = join(ROOT, LANGS[lang].diagramsDir);
  if (!existsSync(outDir)) mkdirSync(outDir, { recursive: true });
  const seen = new Set();

  for (const file of modules) {
    const { diagrams } = await import(pathToFileURL(join(SRC, file)).href);
    for (const def of diagrams) {
      if (seen.has(def.name)) throw new Error(`Duplicate diagram name: ${def.name}`);
      seen.add(def.name);
      const d = def.build();
      for (const w of d.warnings) {
        console.warn(`⚠ [${lang}] ${w}`);
        warnings += 1;
      }
      const svg = d.toString();
      const rel = `${LANGS[lang].diagramsDir}/${def.name}.svg`;
      const target = join(ROOT, rel);
      const current = existsSync(target) ? readFileSync(target, 'utf8') : null;
      count += 1;
      if (current !== svg) {
        if (check) {
          console.error(`✗ ${rel} differs from its source. Run node tools/gen-diagrams.mjs.`);
          stale += 1;
        } else {
          writeFileSync(target, svg);
          console.log(`✓ ${rel}`);
        }
      }
    }
  }
}

console.log(`Checked ${count} diagrams (${Object.keys(LANGS).join(' + ')})${check ? `, ${stale} out of date` : ''}${warnings ? `, ${warnings} warning(s)` : ''}.`);
if (warnings > 0 || (check && stale > 0)) process.exit(1);
