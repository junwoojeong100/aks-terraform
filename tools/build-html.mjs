#!/usr/bin/env node
// README.md + labs/*.md 를 읽어 "단일 파일 HTML" 가이드(aks-terraform-guide.html)를 만듭니다.
//   - 코드는 빌드 시점에 하이라이트(highlight.js) → 외부 CDN/JS 의존성 없이 오프라인에서도 동작
//   - 사이드바/검색/복사 버튼/다크 모드/실습 진행 체크는 인라인 JS 로 구현
// 사용법: cd tools && npm install && npm run build
import { readFileSync, writeFileSync, readdirSync, existsSync } from 'node:fs';
import { basename, dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { Marked } from 'marked';
import hljs from 'highlight.js';
import hcl from './assets/hcl.mjs';
import { CSS_VAR_NAMES } from './diagrams/lib.mjs';

hljs.registerLanguage('hcl', hcl);

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const OUT = join(ROOT, 'aks-terraform-guide.html');
const CSS = readFileSync(join(import.meta.dirname ?? dirname(fileURLToPath(import.meta.url)), 'assets/style.css'), 'utf8');
const JS = readFileSync(join(import.meta.dirname ?? dirname(fileURLToPath(import.meta.url)), 'assets/app.js'), 'utf8');

const VERIFIED_AT = '2026-10-13';
const VERSIONS = [
  ['Terraform', '1.16.5'],
  ['azurerm', '5.9.0'],
  ['AzAPI', '2.13.0'],
  ['AKS (Kubernetes)', '1.36'],
  ['Azure CLI', '2.86+'],
];

const GROUPS = [
  { title: '시작하기', labs: ['readme', '00-aws-azure-mapping', '01-prerequisites'] },
  { title: 'Part 1 · 기반 구축', labs: ['02-bootstrap', '03-network', '04-platform'] },
  { title: 'Part 2 · AKS 클러스터', labs: ['05-aks', '06-workload-identity', '07-ingress'] },
  { title: 'Part 3 · 거버넌스 · 운영', labs: ['08-governance', '09-operations', '10-aks-automatic', '11-cleanup'] },
  { title: '부록', labs: ['99-appendix'] },
];

const CALLOUT = {
  NOTE: ['note', 'ℹ️', '참고'],
  TIP: ['tip', '💡', '팁'],
  IMPORTANT: ['important', '❗', '중요'],
  WARNING: ['warning', '⚠️', '주의'],
  CAUTION: ['caution', '🛑', '경고'],
};

const esc = (s) => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
const stripTags = (s) => s.replace(/<[^>]+>/g, '').replace(/&amp;/g, '&').replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"').replace(/&#39;/g, "'");

// 같은 SVG 를 문서에서 두 번 이상 인라인하면 id(marker, aria-labelledby)가 중복되므로 두 번째부터 접두사를 바꿉니다.
const inlineCount = new Map();
function inlineSvg(file) {
  const name = basename(file, '.svg');
  const n = (inlineCount.get(name) ?? 0) + 1;
  inlineCount.set(name, n);
  const svg = readFileSync(file, 'utf8').trim();
  return n === 1 ? svg : svg.replaceAll(`${name}-`, `${name}-${n}-`);
}

function renderCode(text, info, ctx) {
  const m = /^(\S*)(?:\s+title="([^"]*)")?/.exec(info || '');
  let lang = (m && m[1]) || '';
  const title = (m && m[2]) || '';
  const code = text.replace(/\n$/, '');
  const lines = code.split('\n').length;
  const alias = { sh: 'bash', shell: 'bash', console: 'bash', zsh: 'bash', tf: 'hcl', terraform: 'hcl', yml: 'yaml', ps1: 'powershell' };
  lang = alias[lang] || lang;

  const plain = lang === '' || lang === 'text' || lang === 'ascii' || lang === 'diagram';
  let body;
  if (!plain && hljs.getLanguage(lang)) {
    body = hljs.highlight(code, { language: lang, ignoreIllegals: true }).value;
  } else {
    body = esc(code);
  }

  const isShell = lang === 'bash' || lang === 'powershell';
  const classes = ['code'];
  if (plain && !title) classes.push('diagram');
  if (isShell && !title) classes.push('shell');
  const long = lines > 60;
  if (long) classes.push('collapsed');

  const fileLabel = title || (plain ? '다이어그램' : isShell ? '터미널' : lang);
  const meta = `${plain ? 'text' : lang} · ${lines}줄`;
  const label = `전체 코드 보기 (${lines}줄) ▼`;
  return (
    `<figure class="${classes.join(' ')}">` +
    `<figcaption><span class="file">${esc(fileLabel)}</span><span class="meta">${esc(meta)}</span><button class="copy" type="button">복사</button></figcaption>` +
    `<div class="code-body"><pre><code class="hljs language-${esc(lang || 'text')}">${body}</code></pre></div>` +
    (long ? `<button class="expand" type="button" data-label="${label}">${label}</button>` : '') +
    `</figure>\n`
  );
}

function createMarked(ctx) {
  const m = new Marked({ gfm: true, breaks: false });
  m.use({
    renderer: {
      heading({ tokens, depth }) {
        const html = this.parser.parseInline(tokens);
        const plainText = stripTags(html).trim();
        if (ctx.labId === 'readme' && depth === 1) {
          // README 의 제목은 상단 hero 영역과 중복되므로 본문에서는 생략합니다.
          ctx.title = '개요 · 학습 경로';
          return '';
        }
        let id = `${ctx.labId}--` + plainText.toLowerCase().replace(/[^\p{L}\p{N}\s-]/gu, '').trim().replace(/\s+/g, '-');
        if (ctx.ids.has(id)) id += `-${ctx.ids.size}`;
        ctx.ids.add(id);
        if (depth === 1 && !ctx.title) ctx.title = plainText;
        if (depth === 2) ctx.toc.push({ id, text: plainText });
        return `<h${depth} id="${id}">${html}<a class="anchor" href="#${id}" aria-label="이 제목 링크">#</a></h${depth}>\n`;
      },
      code({ text, lang }) {
        return renderCode(text, lang, ctx);
      },
      blockquote({ tokens }) {
        let body = this.parser.parse(tokens);
        const mm = /^<p>\s*\[!(NOTE|TIP|IMPORTANT|WARNING|CAUTION)\]\s*(?:<br\s*\/?>)?\s*/i.exec(body);
        if (mm) {
          const [cls, icon, label] = CALLOUT[mm[1].toUpperCase()];
          body = body.slice(mm[0].length);
          if (!body.startsWith('<p>')) body = `<p>${body}`;
          return `<aside class="callout ${cls}"><div class="callout-title"><span>${icon}</span><span>${label}</span></div>${body}</aside>\n`;
        }
        return `<blockquote>${body}</blockquote>\n`;
      },
      table(token) {
        const html = Object.getPrototypeOf(this).table.call(this, token);
        const withCols = html.replace(/<th([^>]*)>(AWS[^<]*|Azure[^<]*)<\/th>/g, (_w, attrs, text) => {
          const cls = text.startsWith('AWS') ? 'col-aws' : 'col-azure';
          return `<th${attrs} class="${cls}">${text}</th>`;
        });
        return `<div class="table-wrap">${withCols}</div>\n`;
      },
      link({ href, title, tokens }) {
        const text = this.parser.parseInline(tokens);
        const lab = /^(?:\.{1,2}\/)*(?:labs\/)?(README|\d\d-[\w-]+)\.md(#[\w가-힣%-]+)?$/.exec(href || '');
        if (lab) {
          const id = lab[1] === 'README' ? 'readme' : lab[1];
          return `<a href="#lab-${id}">${text}</a>`;
        }
        if (/^https?:\/\//.test(href || '')) {
          return `<a href="${esc(href)}"${title ? ` title="${esc(title)}"` : ''} target="_blank" rel="noopener noreferrer">${text}</a>`;
        }
        if ((href || '').startsWith('#')) return `<a href="${esc(href)}">${text}</a>`;
        return `<code class="filelink">${text}</code>`;
      },
      paragraph(token) {
        // 이미지 하나뿐인 문단은 <p> 없이 <figure> 로 렌더링합니다.
        if (token.tokens.length === 1 && token.tokens[0].type === 'image') return `${this.parser.parseInline(token.tokens)}\n`;
        return Object.getPrototypeOf(this).paragraph.call(this, token);
      },
      image({ href, title, text }) {
        if (/^https?:\/\//.test(href || '')) {
          return `<img src="${esc(href)}" alt="${esc(text)}"${title ? ` title="${esc(title)}"` : ''} loading="lazy">`;
        }
        // 단일 파일 HTML 이므로 SVG 를 그대로 인라인합니다 (라이트/다크 테마 변수를 페이지 CSS 가 매핑).
        const file = resolve(ctx.dir, href || '');
        if (!(href || '').endsWith('.svg') || !existsSync(file)) {
          throw new Error(`${ctx.labId}: 인라인할 SVG 를 찾을 수 없습니다 → ${href}`);
        }
        return `<figure class="diagram-fig"><div class="diagram-scroll">${inlineSvg(file)}</div></figure>\n`;
      },
      checkbox({ checked }) {
        const idx = ctx.taskIndex++;
        return `<input type="checkbox" data-task="${idx}"${checked ? ' checked' : ''}> `;
      },
      listitem(item) {
        const body = this.parser.parse(item.tokens, !!item.loose);
        return `<li${item.task ? ' class="task"' : ''}>${body}</li>\n`;
      },
    },
  });
  return m;
}

function loadSections() {
  const files = [['readme', join(ROOT, 'README.md')]];
  for (const f of readdirSync(join(ROOT, 'labs')).filter((x) => x.endsWith('.md')).sort()) {
    files.push([f.replace(/\.md$/, ''), join(ROOT, 'labs', f)]);
  }
  const order = GROUPS.flatMap((g) => g.labs);
  files.sort((a, b) => order.indexOf(a[0]) - order.indexOf(b[0]));

  return files.map(([labId, path]) => {
    const source = readFileSync(path, 'utf8')
      .replace(/<!-- \/?tf:include[^>]*-->\n?/g, '')
      .replace(/<!-- \/?count[^>]*-->/g, '');
    const ctx = { labId, dir: dirname(path), title: '', toc: [], ids: new Set(), taskIndex: 0 };
    const html = createMarked(ctx).parse(source);
    return { labId, ctx, html };
  });
}

function labNumber(labId) {
  if (labId === 'readme') return '★';
  if (labId === '99-appendix') return 'A';
  return labId.slice(0, 2);
}

// 빌드 결과 검증: 깨진 렌더링/링크가 있으면 HTML 을 만들지 않고 실패합니다.
function verifyOutput(sections, body, sidebar) {
  // 이 가이드는 취소선을 쓰지 않습니다. `$2~2.5` 같은 범위 표기가 취소선으로 해석된 경우입니다.
  const struck = sections.filter((s) => /<del[\s>]/.test(s.html)).map((s) => s.labId);
  if (struck.length) {
    throw new Error(`취소선(<del>)이 생성되었습니다: ${struck.join(', ')} — 범위 표기의 ~ 를 – 로 바꾸세요 (node tools/check-docs.mjs 로 위치 확인)`);
  }

  const idList = [...body.matchAll(/\sid="([^"]+)"/g)].map((m) => m[1]);
  const dup = [...new Set(idList.filter((id, i) => idList.indexOf(id) !== i))];
  if (dup.length) throw new Error(`중복된 id: ${dup.join(', ')}`);
  const ids = new Set(idList);
  const broken = new Set();
  for (const m of (body + sidebar).matchAll(/href="#([^"]+)"/g)) {
    let id = m[1];
    try {
      id = decodeURIComponent(id);
    } catch {
      /* 그대로 비교 */
    }
    if (!ids.has(id)) broken.add(id);
  }
  if (broken.size) throw new Error(`깨진 내부 링크(#): ${[...broken].join(', ')}`);

  // 다이어그램 색 변수가 페이지 CSS 에 모두 매핑되어 있어야 라이트/다크 토글이 올바로 동작합니다.
  const missingVars = CSS_VAR_NAMES.filter((n) => !CSS.includes(`--dg-${n}:`));
  if (missingVars.length) throw new Error(`tools/assets/style.css 에 다이어그램 색 변수가 없습니다: ${missingVars.map((n) => `--dg-${n}`).join(', ')}`);
}

function build() {
  const sections = loadSections();
  const byId = Object.fromEntries(sections.map((s) => [s.labId, s]));
  const missing = GROUPS.flatMap((g) => g.labs).filter((id) => !byId[id]);
  if (missing.length) console.warn(`⚠ 아직 작성되지 않은 항목: ${missing.join(', ')}`);

  const ordered = GROUPS.flatMap((g) => g.labs).filter((id) => byId[id]).map((id) => byId[id]);

  const sidebar = GROUPS.map((g) => {
    const items = g.labs
      .filter((id) => byId[id])
      .map((id) => {
        const s = byId[id];
        const sub = s.ctx.toc.map((t) => `<a href="#${t.id}">${esc(t.text)}</a>`).join('');
        return (
          `<a class="lab-link" data-lab="${id}" href="#lab-${id}"><span class="num">${labNumber(id)}</span><span>${esc(s.ctx.title)}</span></a>` +
          `<div class="sub">${sub}</div>`
        );
      })
      .join('');
    return items ? `<h4>${esc(g.title)}</h4>${items}` : '';
  }).join('');

  const body = ordered
    .map((s, i) => {
      const prev = ordered[i - 1];
      const next = ordered[i + 1];
      const pager =
        `<nav class="pager">` +
        (prev ? `<a class="prev" href="#lab-${prev.labId}"><small>← 이전</small>${esc(prev.ctx.title)}</a>` : '<span></span>') +
        (next ? `<a class="next" href="#lab-${next.labId}"><small>다음 →</small>${esc(next.ctx.title)}</a>` : '<span></span>') +
        `</nav>`;
      const done =
        s.labId === 'readme'
          ? ''
          : `<label class="lab-done"><input type="checkbox" class="lab-done-cb"> 이 실습을 완료했어요 (진행 상황은 이 브라우저에 저장됩니다)</label>`;
      const kicker = s.labId === 'readme' ? '개요' : s.labId === '99-appendix' ? '부록' : `Lab ${labNumber(s.labId)}`;
      return (
        `<section class="lab" id="lab-${s.labId}" data-lab="${s.labId}" data-title="${esc(s.ctx.title)}">` +
        `<div class="lab-kicker">${kicker}</div>${s.html}${done}${pager}</section>`
      );
    })
    .join('\n');

  const badges = VERSIONS.map(([k, v]) => `<span class="badge">${esc(k)} <b>${esc(v)}</b></span>`).join('');
  const first = ordered[0] ? ordered[0].labId : 'readme';

  verifyOutput(ordered, body, sidebar);

  const html = `<!doctype html>
<html lang="ko" data-theme="light">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>AWS 엔지니어를 위한 AKS + Terraform 실습 가이드</title>
<meta name="description" content="AWS 경험자가 Azure Best Practice 기반으로 Terraform 으로 AKS 클러스터를 구축하는 실습 가이드 (${VERIFIED_AT} 기준 최신 버전)">
<link rel="icon" href="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 32 32'%3E%3Ccircle cx='16' cy='16' r='14' fill='%230b6ed0'/%3E%3Ccircle cx='16' cy='16' r='7' fill='%23f0883e'/%3E%3C/svg%3E">
<style>
${CSS}
</style>
</head>
<body>
<header class="topbar">
  <button id="menu-btn" class="icon-btn" type="button" aria-label="메뉴">☰</button>
  <a class="brand" href="#lab-${first}" style="color:inherit;text-decoration:none"><span class="dot"></span><span class="name">AKS + Terraform 실습 가이드</span></a>
  <div class="spacer"></div>
  <div class="search">
    <input id="search-input" type="search" placeholder="검색 (예: azurerm_kubernetes_cluster, NAT, IRSA)" autocomplete="off" aria-label="검색">
    <kbd>/</kbd>
    <div id="results" class="results" role="listbox"></div>
  </div>
  <button id="theme-btn" class="icon-btn" type="button">☾ 다크</button>
</header>
<div class="progress"></div>
<div class="layout">
  <nav class="sidebar" aria-label="목차">${sidebar}</nav>
  <main class="content">
    <div class="content-inner">
      <div class="hero">
        <h1>AWS 엔지니어를 위한 AKS + Terraform 실습 가이드</h1>
        <p>EKS 와 VPC 에 익숙한 엔지니어가 Azure 의 Best Practice 로 프로덕션급 AKS 를 Terraform 으로 구축합니다. 모든 코드는 <code>terraform validate</code> / <code>terraform test</code> 를 통과한 실제 파일에서 가져왔습니다.</p>
        <div class="badges">${badges}<span class="badge">기준일 <b>${VERIFIED_AT}</b></span></div>
        <a class="cta" href="#lab-00-aws-azure-mapping">AWS ↔ Azure 비교부터 보기</a><a class="cta alt" href="#lab-01-prerequisites">바로 실습 시작</a>
      </div>
${body}
      <footer class="site-footer">이 문서는 <code>tools/build-html.mjs</code> 로 README.md 와 labs/*.md 에서 생성되었습니다 (기준일 ${VERIFIED_AT}).</footer>
    </div>
  </main>
</div>
<script>
${JS}
</script>
</body>
</html>
`;
  writeFileSync(OUT, html);
  const kb = Math.round(Buffer.byteLength(html) / 1024);
  console.log(`✓ ${OUT} (${kb} KB, 섹션 ${ordered.length}개)`);
}

build();
