#!/usr/bin/env node
// Quality checks for the docs of both languages (README.md, README.ko.md, labs/*.md, labs/ko/*.md).
// Fails when rendering breaks or references dangle.
//
//   1) Strikethrough misparse: GFM turns a pair of `~` into strikethrough (~text~).
//      Write ranges like "$2~2.5" with `–` (en dash) or `\~`, otherwise they render as "$22.5" with a line through the middle.
//   2) Images (![](...)), links, and file paths written in backticks (`scripts/...`, `terraform/...`) must exist
//   3) Every diagram labs/diagrams/*.svg and labs/ko/diagrams/*.svg must be referenced by the docs of its language
//   4) Language pairing: every doc has a counterpart in the other language and links to it from a <!-- lang-switch --> block
//   5) Language purity: English docs and the shared sources (terraform/, scripts/, ...) contain no Hangul
//      (the Korean edition embeds the same English source files verbatim)
//
// Usage: node tools/check-docs.mjs
import { existsSync, readFileSync, readdirSync } from 'node:fs';
import { dirname, extname, join, resolve } from 'node:path';
import { Marked } from 'marked';
import { LANGS, LANG_SWITCH, ROOT, counterpart, docFiles } from './docs-config.mjs';

// Only backticked paths that "point to a real file" are checked (wildcards/placeholders are skipped).
const CHECKED_EXT = new Set(['.tf', '.sh', '.md', '.mjs', '.hcl', '.svg', '.json', '.yaml', '.yml', '.html']);
const PATH_PREFIX = /^(scripts|terraform|tools|labs)\//;
const PLACEHOLDER = /[*<>{}…$]|\.\.\.|NN|0X/;
const HANGUL = /[\u1100-\u11ff\u3130-\u318f\uac00-\ud7a3]/;

// Sources that both editions embed verbatim: they must stay English.
const ENGLISH_ONLY_DIRS = ['terraform', 'scripts'];
const ENGLISH_ONLY_FILES = ['tools/validate-all.sh', '.shellcheckrc', '.gitignore'];

const errors = [];
const marked = new Marked({ gfm: true });
let fileCount = 0;

function lineOf(source, snippet) {
  const idx = source.indexOf(snippet);
  return idx < 0 ? 1 : source.slice(0, idx).split('\n').length;
}

function walk(dir) {
  return readdirSync(dir, { withFileTypes: true }).flatMap((e) => {
    if (e.name === '.terraform' || e.name === 'node_modules') return [];
    const p = join(dir, e.name);
    return e.isDirectory() ? walk(p) : [p];
  });
}

function checkHangul(rel, text, what) {
  text.split('\n').forEach((line, i) => {
    if (HANGUL.test(line)) errors.push(`${rel}:${i + 1}  Hangul in ${what}: "${line.trim().slice(0, 60)}"`);
  });
}

for (const lang of Object.keys(LANGS)) {
  const cfg = LANGS[lang];
  const usedImages = new Set();

  for (const rel of docFiles(lang)) {
    fileCount += 1;
    const abs = join(ROOT, rel);
    const source = readFileSync(abs, 'utf8');
    const baseDir = dirname(abs);

    // 4) language pairing
    const other = counterpart(rel, lang);
    if (!existsSync(join(ROOT, other))) errors.push(`${rel}  has no ${LANGS[cfg.other].name} counterpart: ${other}`);
    const sw = /<!-- lang-switch -->([\s\S]*?)<!-- \/lang-switch -->/.exec(source);
    if (!sw) {
      errors.push(`${rel}  missing the <!-- lang-switch --> block that links to ${other}`);
    } else {
      const targets = [...sw[1].matchAll(/\]\(([^)]+)\)/g)].map((m) => resolve(baseDir, m[1]));
      if (!targets.includes(resolve(ROOT, other))) errors.push(`${rel}  the lang-switch block must link to ${other}`);
    }

    // 5) language purity (the lang-switch block carries the Korean language name on purpose)
    if (lang === 'en') {
      checkHangul(rel, source.replace(LANG_SWITCH, (m) => '\n'.repeat(m.split('\n').length - 1)), 'an English doc');
    }

    const tokens = marked.lexer(source);
    marked.walkTokens(tokens, (t) => {
      if (t.type === 'del') {
        errors.push(
          `${rel}:${lineOf(source, t.raw)}  parsed as strikethrough: "${t.raw.replace(/\n/g, ' ').slice(0, 60)}" → write ranges with \`–\` (en dash) or \`\\~\`.`,
        );
      }
      if (t.type === 'image' && !/^(https?:|data:)/.test(t.href)) {
        usedImages.add(resolve(baseDir, t.href));
        if (!existsSync(resolve(baseDir, t.href))) errors.push(`${rel}:${lineOf(source, t.raw)}  image file does not exist: ${t.href}`);
        if (!t.text.trim()) errors.push(`${rel}:${lineOf(source, t.raw)}  image has no alt text: ${t.href}`);
      }
      if (t.type === 'link' && t.href && !/^(https?:|mailto:|#)/.test(t.href)) {
        const target = t.href.split('#')[0];
        if (target && !existsSync(resolve(baseDir, target))) errors.push(`${rel}:${lineOf(source, t.raw)}  link target does not exist: ${t.href}`);
      }
      if (t.type === 'codespan') {
        const p = t.text.trim();
        if (PATH_PREFIX.test(p) && CHECKED_EXT.has(extname(p)) && !PLACEHOLDER.test(p) && !/\s/.test(p)) {
          if (!existsSync(join(ROOT, p))) errors.push(`${rel}:${lineOf(source, t.raw)}  references a file that does not exist: ${p}`);
        }
      }
    });
  }

  // 3) A diagram that no doc uses is a forgotten file.
  const diagrams = join(ROOT, cfg.diagramsDir);
  if (existsSync(diagrams)) {
    for (const f of readdirSync(diagrams).filter((x) => x.endsWith('.svg'))) {
      if (!usedImages.has(join(diagrams, f))) errors.push(`${cfg.diagramsDir}/${f}  is not referenced by any ${cfg.name} doc.`);
    }
  }
}

// 5) shared sources stay English
for (const dir of ENGLISH_ONLY_DIRS) {
  for (const abs of walk(join(ROOT, dir))) {
    const rel = abs.slice(ROOT.length + 1);
    if (/\.(png|jpg|gif|ico|zip|gz)$/.test(rel)) continue;
    checkHangul(rel, readFileSync(abs, 'utf8'), 'a source file (code and scripts are English-only; both doc editions embed them)');
  }
}
for (const rel of ENGLISH_ONLY_FILES) {
  if (existsSync(join(ROOT, rel))) checkHangul(rel, readFileSync(join(ROOT, rel), 'utf8'), 'a source file (code and scripts are English-only; both doc editions embed them)');
}

if (errors.length) {
  console.error(`✗ Docs check failed (${errors.length} issue(s))\n` + errors.map((e) => `  - ${e}`).join('\n'));
  process.exit(1);
}
console.log(
  `✓ Docs check passed (${fileCount} files in ${Object.keys(LANGS).length} languages: strikethrough · images/links/file paths · diagram references · language pairing · language purity)`,
);
