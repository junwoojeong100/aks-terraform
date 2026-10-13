#!/usr/bin/env node
// labs/diagrams/*.svg 를 생성합니다. 소스는 tools/diagrams/*.mjs (lib.mjs 는 공통 도우미).
//
//   node tools/gen-diagrams.mjs           # SVG 생성
//   node tools/gen-diagrams.mjs --check   # 저장소의 SVG 가 소스와 다르면 실패 (CI 용)
//
// 각 모듈은 `export const diagrams = [{ name, build() { ...Diagram 반환 } }]` 형태입니다.
// 글자가 상자를 넘칠 것으로 추정되면 경고를 출력하고 실패합니다.
import { existsSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const SRC = join(ROOT, 'tools', 'diagrams');
const OUT = join(ROOT, 'labs', 'diagrams');
const check = process.argv.includes('--check');

const modules = readdirSync(SRC)
  .filter((f) => f.endsWith('.mjs') && f !== 'lib.mjs')
  .sort();

let warnings = 0;
let stale = 0;
let count = 0;
const seen = new Set();

if (!existsSync(OUT)) mkdirSync(OUT, { recursive: true });

for (const file of modules) {
  const { diagrams } = await import(pathToFileURL(join(SRC, file)).href);
  for (const def of diagrams) {
    if (seen.has(def.name)) throw new Error(`다이어그램 이름이 중복됩니다: ${def.name}`);
    seen.add(def.name);
    const d = def.build();
    for (const w of d.warnings) {
      console.warn(`⚠ ${w}`);
      warnings += 1;
    }
    const svg = d.toString();
    const target = join(OUT, `${def.name}.svg`);
    const current = existsSync(target) ? readFileSync(target, 'utf8') : null;
    count += 1;
    if (current !== svg) {
      if (check) {
        console.error(`✗ labs/diagrams/${def.name}.svg 가 소스와 다릅니다. node tools/gen-diagrams.mjs 를 실행하세요.`);
        stale += 1;
      } else {
        writeFileSync(target, svg);
        console.log(`✓ labs/diagrams/${def.name}.svg`);
      }
    }
  }
}

console.log(`다이어그램 ${count}개 확인${check ? `, ${stale}개 불일치` : ''}${warnings ? `, 경고 ${warnings}건` : ''}.`);
if (warnings > 0 || (check && stale > 0)) process.exit(1);
