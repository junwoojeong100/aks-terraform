#!/usr/bin/env node
// 가이드(md) 안의 Terraform 코드 블록을 실제 소스 파일과 동기화합니다.
//
// md 에서 아래 마커 한 쌍을 쓰면, 두 마커 사이가 실제 파일 내용으로 채워집니다.
//
//   <!-- tf:include path="terraform/03-network/main.tf" -->
//   <!-- /tf:include -->
//
// 이렇게 하면 "문서에 있는 코드 == terraform validate/test 를 통과한 코드" 가 항상 보장됩니다.
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

let changed = 0;
let included = 0;

for (const file of readdirSync(LABS).filter((f) => f.endsWith('.md')).sort()) {
  const mdPath = join(LABS, file);
  const original = readFileSync(mdPath, 'utf8');

  const updated = original.replace(MARKER, (_whole, relPath, from, to) => {
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
      console.error(`✗ ${file}: 코드 블록이 소스와 다릅니다. node tools/sync-code.mjs 를 실행하세요.`);
    } else {
      writeFileSync(mdPath, updated);
      console.log(`✓ ${file}: 코드 블록 갱신`);
    }
  }
}

console.log(`코드 포함 ${included}곳 확인, ${changed}개 파일 ${check ? '불일치' : '갱신'}.`);
if (check && changed > 0) process.exit(1);
