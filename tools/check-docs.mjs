#!/usr/bin/env node
// 문서(README.md, labs/*.md) 품질 검사. 렌더링이 깨지거나 참조가 끊어지면 실패합니다.
//
//   1) 취소선 오인식: GFM 은 `~` 두 개를 취소선(~텍스트~)으로 해석합니다.
//      범위 표기 "$2~2.5" 가 "$22.5"(가운데에 취소선)로 보이는 문제를 막기 위해 `–`(en dash) 또는 `\~` 를 쓰세요.
//   2) 이미지(![](...))와 링크, 백틱으로 쓴 파일 경로(`scripts/...`, `terraform/...`)가 실제로 존재하는지
//   3) labs/diagrams/*.svg 가 문서에서 한 번도 참조되지 않은 채 남아 있지 않은지
//
// 사용법: node tools/check-docs.mjs
import { existsSync, readFileSync, readdirSync } from 'node:fs';
import { dirname, extname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { Marked } from 'marked';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const FILES = ['README.md', ...readdirSync(join(ROOT, 'labs')).filter((f) => f.endsWith('.md')).sort().map((f) => `labs/${f}`)];

// 백틱 경로 중 "실제 파일을 가리키는" 것만 검사합니다 (와일드카드/자리표시자는 제외).
const CHECKED_EXT = new Set(['.tf', '.sh', '.md', '.mjs', '.hcl', '.svg', '.json', '.yaml', '.yml', '.html']);
const PATH_PREFIX = /^(scripts|terraform|tools|labs)\//;
const PLACEHOLDER = /[*<>{}…$]|\.\.\.|NN|0X/;

const errors = [];
const marked = new Marked({ gfm: true });
const usedImages = new Set();

function lineOf(source, snippet) {
  const idx = source.indexOf(snippet);
  return idx < 0 ? 1 : source.slice(0, idx).split('\n').length;
}

for (const rel of FILES) {
  const abs = join(ROOT, rel);
  const source = readFileSync(abs, 'utf8');
  const baseDir = dirname(abs);
  const tokens = marked.lexer(source);

  marked.walkTokens(tokens, (t) => {
    if (t.type === 'del') {
      errors.push(
        `${rel}:${lineOf(source, t.raw)}  취소선으로 해석됨: "${t.raw.replace(/\n/g, ' ').slice(0, 60)}" → 범위 표기는 \`–\`(en dash) 또는 \`\\~\` 를 쓰세요.`,
      );
    }
    if (t.type === 'image' && !/^(https?:|data:)/.test(t.href)) {
      usedImages.add(resolve(baseDir, t.href));
      if (!existsSync(resolve(baseDir, t.href))) errors.push(`${rel}:${lineOf(source, t.raw)}  이미지 파일이 없습니다: ${t.href}`);
      if (!t.text.trim()) errors.push(`${rel}:${lineOf(source, t.raw)}  이미지에 대체 텍스트(alt)가 없습니다: ${t.href}`);
    }
    if (t.type === 'link' && t.href && !/^(https?:|mailto:|#)/.test(t.href)) {
      const target = t.href.split('#')[0];
      if (target && !existsSync(resolve(baseDir, target))) errors.push(`${rel}:${lineOf(source, t.raw)}  링크 대상 파일이 없습니다: ${t.href}`);
    }
    if (t.type === 'codespan') {
      const p = t.text.trim();
      if (PATH_PREFIX.test(p) && CHECKED_EXT.has(extname(p)) && !PLACEHOLDER.test(p) && !/\s/.test(p)) {
        if (!existsSync(join(ROOT, p))) errors.push(`${rel}:${lineOf(source, t.raw)}  존재하지 않는 파일을 참조합니다: ${p}`);
      }
    }
  });
}

// 문서에서 한 번도 쓰이지 않은 다이어그램은 잊힌 파일입니다.
const DIAGRAMS = join(ROOT, 'labs', 'diagrams');
if (existsSync(DIAGRAMS)) {
  for (const f of readdirSync(DIAGRAMS).filter((x) => x.endsWith('.svg'))) {
    if (!usedImages.has(join(DIAGRAMS, f))) errors.push(`labs/diagrams/${f}  어떤 문서에서도 참조하지 않는 다이어그램입니다.`);
  }
}

if (errors.length) {
  console.error(`✗ 문서 검사 실패 (${errors.length}건)\n` + errors.map((e) => `  - ${e}`).join('\n'));
  process.exit(1);
}
console.log(`✓ 문서 검사 통과 (${FILES.length}개 파일: 취소선 오인식 · 이미지/링크/파일 경로 · 다이어그램 참조)`);
