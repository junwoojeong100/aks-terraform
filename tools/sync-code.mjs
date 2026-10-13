#!/usr/bin/env node
// 가이드(md) 안의 코드 블록과 숫자를 실제 소스와 동기화합니다.
//
// 1) 마커 한 쌍을 쓰면, 두 마커 사이가 실제 파일 내용으로 채워집니다 (Terraform, 셸 스크립트 등).
//
//      <!-- tf:include path="terraform/03-network/main.tf" -->
//      <!-- /tf:include -->
//
//    이렇게 하면 "문서에 있는 코드 == terraform validate/test 를 통과한 코드" 가 항상 보장됩니다.
//
// 2) 문서 속 숫자는 소스에서 계산해 채웁니다 (사용 가능: test-runs, test-files, tf-files).
//
//      <!-- count:test-runs -->28<!-- /count -->
//
//   node tools/sync-code.mjs           # md 를 갱신
//   node tools/sync-code.mjs --check   # 갱신이 필요하면 실패(CI 용)
import { readFileSync, writeFileSync, readdirSync, existsSync } from 'node:fs';
import { dirname, extname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const LABS = join(ROOT, 'labs');
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

// 문서 속 숫자를 소스에서 계산해 자동으로 채웁니다 (손으로 쓴 숫자가 낡는 문제 방지).
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

const targets = [join(ROOT, 'README.md'), ...readdirSync(LABS).filter((f) => f.endsWith('.md')).sort().map((f) => join(LABS, f))];

for (const mdPath of targets) {
  const file = mdPath.slice(ROOT.length + 1);
  const original = readFileSync(mdPath, 'utf8');

  const withCounts = original.replace(COUNT_MARKER, (_whole, name) => {
    const counter = COUNTERS[name];
    if (!counter) throw new Error(`${file}: 알 수 없는 count 마커 → ${name} (사용 가능: ${Object.keys(COUNTERS).join(', ')})`);
    return `<!-- count:${name} -->${counter()}<!-- /count -->`;
  });

  const updated = withCounts.replace(MARKER, (_whole, relPath, from, to) => {
    const srcPath = join(ROOT, relPath);
    if (!existsSync(srcPath)) {
      throw new Error(`${file}: 포함할 파일이 없습니다 → ${relPath}`);
    }

    let lines = readFileSync(srcPath, 'utf8').replace(/\s+$/, '').split('\n');
    if (from && to) lines = lines.slice(Number(from) - 1, Number(to));
    const lang = LANG[extname(srcPath)] ?? '';
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
      console.error(`✗ ${file}: 코드 블록/숫자가 소스와 다릅니다. node tools/sync-code.mjs 를 실행하세요.`);
    } else {
      writeFileSync(mdPath, updated);
      console.log(`✓ ${file}: 코드 블록/숫자 갱신`);
    }
  }
}

console.log(`코드 포함 ${included}곳 확인, ${changed}개 파일 ${check ? '불일치' : '갱신'}.`);
if (check && changed > 0) process.exit(1);
