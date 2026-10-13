#!/usr/bin/env node
// Keeps the code blocks and numbers in the guide (md) in sync with the real sources.
//
// 1) A marker pair is filled with the content of a real file (Terraform, shell scripts, ...):
//
//      <!-- tf:include path="terraform/03-network/main.tf" -->
//      <!-- /tf:include -->
//
//    This guarantees "the code in the docs == the code that passed terraform validate/test".
//    The English and the Korean docs include the same (English) source files.
//
// 2) Numbers in the text are computed from the sources (available: test-runs, test-files, tf-files):
//
//      <!-- count:test-runs -->28<!-- /count -->
//
//   node tools/sync-code.mjs           # update the md files
//   node tools/sync-code.mjs --check   # fail if an update is needed (for CI)
import { readFileSync, writeFileSync, readdirSync, existsSync } from 'node:fs';
import { extname, join } from 'node:path';
import { LANGS, ROOT, docFiles } from './docs-config.mjs';

const check = process.argv.includes('--check');

const LANG = {
  '.tf': 'hcl',
  '.tfvars': 'hcl',
  '.hcl': 'hcl',
  '.sh': 'bash',
  '.yaml': 'yaml',
  '.yml': 'yaml',
  '.json': 'json',
  '.mjs': 'javascript',
  '.js': 'javascript',
};

const MARKER = /<!-- tf:include path="([^"]+)"(?: lines="(\d+)-(\d+)")? -->[\s\S]*?<!-- \/tf:include -->/g;

// Numbers in the text are computed from the sources, so hand-written numbers can't go stale.
//   <!-- count:test-runs -->28<!-- /count -->
const COUNT_MARKER = /<!-- count:([\w-]+) -->[^<]*<!-- \/count -->/g;

function walk(dir) {
  return readdirSync(dir, { withFileTypes: true }).flatMap((e) => {
    if (e.name === '.terraform' || e.name === 'node_modules') return [];
    const p = join(dir, e.name);
    return e.isDirectory() ? walk(p) : [p];
  });
}

const tfTests = () => walk(join(ROOT, 'terraform')).filter((f) => f.endsWith('.tftest.hcl'));
const COUNTERS = {
  'test-runs': () => tfTests().reduce((n, f) => n + (readFileSync(f, 'utf8').match(/^run\s+"/gm) ?? []).length, 0),
  'test-files': () => tfTests().length,
  'tf-files': () => walk(join(ROOT, 'terraform')).filter((f) => f.endsWith('.tf')).length,
};

let changed = 0;
let included = 0;

const targets = Object.keys(LANGS).flatMap((lang) => docFiles(lang));

for (const file of targets) {
  const mdPath = join(ROOT, file);
  const original = readFileSync(mdPath, 'utf8');

  const withCounts = original.replace(COUNT_MARKER, (_whole, name) => {
    const counter = COUNTERS[name];
    if (!counter) throw new Error(`${file}: unknown count marker → ${name} (available: ${Object.keys(COUNTERS).join(', ')})`);
    return `<!-- count:${name} -->${counter()}<!-- /count -->`;
  });

  const updated = withCounts.replace(MARKER, (_whole, relPath, from, to) => {
    const srcPath = join(ROOT, relPath);
    if (!existsSync(srcPath)) {
      throw new Error(`${file}: file to include does not exist → ${relPath}`);
    }

    let lines = readFileSync(srcPath, 'utf8').replace(/\s+$/, '').split('\n');
    if (from && to) lines = lines.slice(Number(from) - 1, Number(to));
    const lang = LANG[extname(srcPath)] ?? 'text';
    const range = from && to ? ` lines="${from}-${to}"` : '';
    included += 1;

    return [
      `<!-- tf:include path="${relPath}"${range} -->`,
      '```' + `${lang} title="${relPath}"`,
      lines.join('\n'),
      '```',
      '<!-- /tf:include -->',
    ].join('\n');
  });

  if (updated !== original) {
    changed += 1;
    if (check) {
      console.error(`✗ ${file}: code blocks/numbers differ from the sources. Run node tools/sync-code.mjs.`);
    } else {
      writeFileSync(mdPath, updated);
      console.log(`✓ ${file}: code blocks/numbers updated`);
    }
  }
}

console.log(`Checked ${included} code includes in ${targets.length} files; ${changed} file(s) ${check ? 'out of date' : 'updated'}.`);
if (check && changed > 0) process.exit(1);
