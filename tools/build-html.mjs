#!/usr/bin/env node
// Reads README.md + labs/*.md (English, default) and README.ko.md + labs/ko/*.md (Korean) and builds
// single-file HTML guides:  aks-terraform-guide.html (English)  and  aks-terraform-guide.ko.html (Korean).
//   - Code is highlighted at build time (highlight.js) → works offline, no CDN/JS dependencies
//   - Sidebar / search / copy buttons / dark mode / lab progress checkboxes are implemented with inline JS
// Usage: cd tools && npm install && npm run build           (node build-html.mjs [--lang en|ko] builds one language)
import { readFileSync, writeFileSync, readdirSync, existsSync } from 'node:fs';
import { basename, dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { Marked } from 'marked';
import hljs from 'highlight.js';
import hcl from './assets/hcl.mjs';
import { CSS_VAR_NAMES } from './diagrams/lib.mjs';
import { LANGS, LANG_SWITCH, ROOT } from './docs-config.mjs';

hljs.registerLanguage('hcl', hcl);

const ASSETS = join(import.meta.dirname ?? dirname(fileURLToPath(import.meta.url)), 'assets');
const CSS = readFileSync(join(ASSETS, 'style.css'), 'utf8');
const JS = readFileSync(join(ASSETS, 'app.js'), 'utf8');

const VERIFIED_AT = '2026-10-13';
const VERSIONS = [
  ['Terraform', '1.16.5'],
  ['azurerm', '5.9.0'],
  ['AzAPI', '2.13.0'],
  ['AKS (Kubernetes)', '1.36'],
  ['Azure CLI', '2.86+'],
];

// Lab groups in the sidebar (ids = file names without .md; 'readme' = the README)
const GROUP_LABS = [
  ['readme', '00-aws-azure-mapping', '01-prerequisites'],
  ['02-bootstrap', '03-network', '04-platform'],
  ['05-aks', '06-workload-identity', '07-ingress'],
  ['08-governance', '09-operations', '10-aks-automatic', '11-cleanup'],
  ['99-appendix'],
];

const CALLOUT_STYLE = {
  NOTE: ['note', 'ℹ️'],
  TIP: ['tip', '💡'],
  IMPORTANT: ['important', '❗'],
  WARNING: ['warning', '⚠️'],
  CAUTION: ['caution', '🛑'],
};

// Every user-visible string of the generated page, per language.
const UI = {
  en: {
    title: 'AKS + Terraform Hands-on Guide for AWS Engineers',
    description: `A hands-on guide for AWS engineers to build an AKS cluster with Terraform following Azure best practices (latest versions as of ${VERIFIED_AT})`,
    brand: 'AKS + Terraform Hands-on Guide',
    menu: 'Menu',
    searchPlaceholder: 'Search (e.g. azurerm_kubernetes_cluster, NAT, IRSA)',
    searchLabel: 'Search',
    toc: 'Table of contents',
    langTitle: 'Read this guide in Korean',
    themeDark: '☾ Dark',
    themeLight: '☀ Light',
    heroText:
      'Engineers who know EKS and VPC build a production-grade AKS cluster with Terraform, following Azure best practices. Every piece of code comes from real files that pass <code>terraform validate</code> and <code>terraform test</code>.',
    asOf: 'As of',
    ctaMapping: 'Start with the AWS ↔ Azure comparison',
    ctaStart: 'Jump into the labs',
    footer: (v) => `Generated from README.md and labs/*.md by <code>tools/build-html.mjs</code> (as of ${v}).`,
    groups: ['Getting started', 'Part 1 · Foundation', 'Part 2 · AKS cluster', 'Part 3 · Governance & operations', 'Appendix'],
    callouts: { NOTE: 'Note', TIP: 'Tip', IMPORTANT: 'Important', WARNING: 'Warning', CAUTION: 'Caution' },
    diagram: 'Diagram',
    terminal: 'Terminal',
    copy: 'Copy',
    copied: 'Copied ✓',
    lines: (n) => `${n} lines`,
    expand: (n) => `Show all ${n} lines ▼`,
    collapse: 'Collapse code ▲',
    anchor: 'Link to this heading',
    readmeTitle: 'Overview · learning path',
    prev: '← Previous',
    next: 'Next →',
    done: 'I finished this lab (progress is saved in this browser)',
    kickerReadme: 'Overview',
    kickerAppendix: 'Appendix',
    kickerLab: (n) => `Lab ${n}`,
    noResults: 'No results found.',
  },
  ko: {
    title: 'AWS 엔지니어를 위한 AKS + Terraform 실습 가이드',
    description: `AWS 경험자가 Azure Best Practice 기반으로 Terraform 으로 AKS 클러스터를 구축하는 실습 가이드 (${VERIFIED_AT} 기준 최신 버전)`,
    brand: 'AKS + Terraform 실습 가이드',
    menu: '메뉴',
    searchPlaceholder: '검색 (예: azurerm_kubernetes_cluster, NAT, IRSA)',
    searchLabel: '검색',
    toc: '목차',
    langTitle: '영문 가이드로 보기',
    themeDark: '☾ 다크',
    themeLight: '☀ 라이트',
    heroText:
      'EKS 와 VPC 에 익숙한 엔지니어가 Azure 의 Best Practice 로 프로덕션급 AKS 를 Terraform 으로 구축합니다. 모든 코드는 <code>terraform validate</code> / <code>terraform test</code> 를 통과한 실제 파일에서 가져왔습니다.',
    asOf: '기준일',
    ctaMapping: 'AWS ↔ Azure 비교부터 보기',
    ctaStart: '바로 실습 시작',
    footer: (v) => `이 문서는 <code>tools/build-html.mjs</code> 로 README.ko.md 와 labs/ko/*.md 에서 생성되었습니다 (기준일 ${v}).`,
    groups: ['시작하기', 'Part 1 · 기반 구축', 'Part 2 · AKS 클러스터', 'Part 3 · 거버넌스 · 운영', '부록'],
    callouts: { NOTE: '참고', TIP: '팁', IMPORTANT: '중요', WARNING: '주의', CAUTION: '경고' },
    diagram: '다이어그램',
    terminal: '터미널',
    copy: '복사',
    copied: '복사됨 ✓',
    lines: (n) => `${n}줄`,
    expand: (n) => `전체 코드 보기 (${n}줄) ▼`,
    collapse: '코드 접기 ▲',
    anchor: '이 제목 링크',
    readmeTitle: '개요 · 학습 경로',
    prev: '← 이전',
    next: '다음 →',
    done: '이 실습을 완료했어요 (진행 상황은 이 브라우저에 저장됩니다)',
    kickerReadme: '개요',
    kickerAppendix: '부록',
    kickerLab: (n) => `Lab ${n}`,
    noResults: '검색 결과가 없습니다.',
  },
};

const esc = (s) => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
const stripTags = (s) => s.replace(/<[^>]+>/g, '').replace(/&amp;/g, '&').replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"').replace(/&#39;/g, "'");

function renderCode(text, info, ui) {
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

  const fileLabel = title || (plain ? ui.diagram : isShell ? ui.terminal : lang);
  const meta = `${plain ? 'text' : lang} · ${ui.lines(lines)}`;
  const label = ui.expand(lines);
  return (
    `<figure class="${classes.join(' ')}">` +
    `<figcaption><span class="file">${esc(fileLabel)}</span><span class="meta">${esc(meta)}</span><button class="copy" type="button">${esc(ui.copy)}</button></figcaption>` +
    `<div class="code-body"><pre><code class="hljs language-${esc(lang || 'text')}">${body}</code></pre></div>` +
    (long ? `<button class="expand" type="button" data-label="${label}">${label}</button>` : '') +
    `</figure>\n`
  );
}

function createMarked(ctx, ui) {
  const m = new Marked({ gfm: true, breaks: false });
  m.use({
    renderer: {
      heading({ tokens, depth }) {
        const html = this.parser.parseInline(tokens);
        const plainText = stripTags(html).trim();
        if (ctx.labId === 'readme' && depth === 1) {
          // The README title duplicates the hero area at the top, so it is omitted from the body.
          ctx.title = ui.readmeTitle;
          return '';
        }
        let id = `${ctx.labId}--` + plainText.toLowerCase().replace(/[^\p{L}\p{N}\s-]/gu, '').trim().replace(/\s+/g, '-');
        if (ctx.ids.has(id)) id += `-${ctx.ids.size}`;
        ctx.ids.add(id);
        if (depth === 1 && !ctx.title) ctx.title = plainText;
        if (depth === 2) ctx.toc.push({ id, text: plainText });
        return `<h${depth} id="${id}">${html}<a class="anchor" href="#${id}" aria-label="${esc(ui.anchor)}">#</a></h${depth}>\n`;
      },
      code({ text, lang }) {
        return renderCode(text, lang, ui);
      },
      blockquote({ tokens }) {
        let body = this.parser.parse(tokens);
        const mm = /^<p>\s*\[!(NOTE|TIP|IMPORTANT|WARNING|CAUTION)\]\s*(?:<br\s*\/?>)?\s*/i.exec(body);
        if (mm) {
          const kind = mm[1].toUpperCase();
          const [cls, icon] = CALLOUT_STYLE[kind];
          body = body.slice(mm[0].length);
          if (!body.startsWith('<p>')) body = `<p>${body}`;
          return `<aside class="callout ${cls}"><div class="callout-title"><span>${icon}</span><span>${ui.callouts[kind]}</span></div>${body}</aside>\n`;
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
        // links to other labs/README (any language edition) become in-page links
        const lab = /^(?:\.{1,2}\/)*(?:labs\/(?:ko\/)?)?(README|\d\d-[\w-]+)(?:\.ko)?\.md(#[\w가-힣%-]+)?$/.exec(href || '');
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
        // A paragraph that only holds an image is rendered as a <figure> without <p>.
        if (token.tokens.length === 1 && token.tokens[0].type === 'image') return `${this.parser.parseInline(token.tokens)}\n`;
        return Object.getPrototypeOf(this).paragraph.call(this, token);
      },
      image({ href, title, text }) {
        if (/^https?:\/\//.test(href || '')) {
          return `<img src="${esc(href)}" alt="${esc(text)}"${title ? ` title="${esc(title)}"` : ''} loading="lazy">`;
        }
        // It is a single-file HTML, so the SVG is inlined as is (the page CSS maps the light/dark theme variables).
        const file = resolve(ctx.dir, href || '');
        if (!(href || '').endsWith('.svg') || !existsSync(file)) {
          throw new Error(`${ctx.labId}: cannot find the SVG to inline → ${href}`);
        }
        return `<figure class="diagram-fig"><div class="diagram-scroll">${ctx.inlineSvg(file)}</div></figure>\n`;
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

function loadSections(lang, ui) {
  const cfg = LANGS[lang];
  const files = [['readme', join(ROOT, cfg.readme)]];
  for (const f of readdirSync(join(ROOT, cfg.labsDir)).filter((x) => x.endsWith('.md')).sort()) {
    files.push([f.replace(/\.md$/, ''), join(ROOT, cfg.labsDir, f)]);
  }
  const order = GROUP_LABS.flat();
  files.sort((a, b) => order.indexOf(a[0]) - order.indexOf(b[0]));

  // The same SVG inlined twice in one document would duplicate ids (marker, aria-labelledby): rename from the second use on.
  const inlineCount = new Map();
  const inlineSvg = (file) => {
    const name = basename(file, '.svg');
    const n = (inlineCount.get(name) ?? 0) + 1;
    inlineCount.set(name, n);
    const svg = readFileSync(file, 'utf8').trim();
    return n === 1 ? svg : svg.replaceAll(`${name}-`, `${name}-${n}-`);
  };

  return files.map(([labId, path]) => {
    const source = readFileSync(path, 'utf8')
      .replace(LANG_SWITCH, '')
      .replace(/<!-- \/?tf:include[^>]*-->\n?/g, '')
      .replace(/<!-- \/?count[^>]*-->/g, '');
    const ctx = { labId, dir: dirname(path), title: '', toc: [], ids: new Set(), taskIndex: 0, inlineSvg };
    const html = createMarked(ctx, ui).parse(source);
    return { labId, ctx, html };
  });
}

function labNumber(labId) {
  if (labId === 'readme') return '★';
  if (labId === '99-appendix') return 'A';
  return labId.slice(0, 2);
}

// Build output verification: if rendering or links are broken, no HTML is written and the build fails.
function verifyOutput(lang, sections, body, sidebar) {
  // This guide does not use strikethrough. A range like `$2~2.5` was interpreted as strikethrough.
  const struck = sections.filter((s) => /<del[\s>]/.test(s.html)).map((s) => s.labId);
  if (struck.length) {
    throw new Error(`[${lang}] strikethrough (<del>) was generated: ${struck.join(', ')} — replace the ~ in ranges with – (run node tools/check-docs.mjs to locate it)`);
  }

  const idList = [...body.matchAll(/\sid="([^"]+)"/g)].map((m) => m[1]);
  const dup = [...new Set(idList.filter((id, i) => idList.indexOf(id) !== i))];
  if (dup.length) throw new Error(`[${lang}] duplicate ids: ${dup.join(', ')}`);
  const ids = new Set(idList);
  const broken = new Set();
  for (const m of (body + sidebar).matchAll(/href="#([^"]+)"/g)) {
    let id = m[1];
    try {
      id = decodeURIComponent(id);
    } catch {
      /* compare as is */
    }
    if (!ids.has(id)) broken.add(id);
  }
  if (broken.size) throw new Error(`[${lang}] broken internal links (#): ${[...broken].join(', ')}`);

  // Every diagram color variable must be mapped in the page CSS, otherwise the light/dark toggle breaks the diagrams.
  const missingVars = CSS_VAR_NAMES.filter((n) => !CSS.includes(`--dg-${n}:`));
  if (missingVars.length) throw new Error(`tools/assets/style.css lacks diagram color variables: ${missingVars.map((n) => `--dg-${n}`).join(', ')}`);
}

function build(lang) {
  const cfg = LANGS[lang];
  const other = LANGS[cfg.other];
  const ui = UI[lang];
  const out = join(ROOT, cfg.html);

  const sections = loadSections(lang, ui);
  const byId = Object.fromEntries(sections.map((s) => [s.labId, s]));
  const missing = GROUP_LABS.flat().filter((id) => !byId[id]);
  if (missing.length) console.warn(`⚠ [${lang}] not written yet: ${missing.join(', ')}`);

  const ordered = GROUP_LABS.flat().filter((id) => byId[id]).map((id) => byId[id]);

  const sidebar = GROUP_LABS.map((labs, gi) => {
    const items = labs
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
    return items ? `<h4>${esc(ui.groups[gi])}</h4>${items}` : '';
  }).join('');

  const body = ordered
    .map((s, i) => {
      const prev = ordered[i - 1];
      const next = ordered[i + 1];
      const pager =
        `<nav class="pager">` +
        (prev ? `<a class="prev" href="#lab-${prev.labId}"><small>${ui.prev}</small>${esc(prev.ctx.title)}</a>` : '<span></span>') +
        (next ? `<a class="next" href="#lab-${next.labId}"><small>${ui.next}</small>${esc(next.ctx.title)}</a>` : '<span></span>') +
        `</nav>`;
      const done = s.labId === 'readme' ? '' : `<label class="lab-done"><input type="checkbox" class="lab-done-cb"> ${ui.done}</label>`;
      const kicker = s.labId === 'readme' ? ui.kickerReadme : s.labId === '99-appendix' ? ui.kickerAppendix : ui.kickerLab(labNumber(s.labId));
      return (
        `<section class="lab" id="lab-${s.labId}" data-lab="${s.labId}" data-title="${esc(s.ctx.title)}">` +
        `<div class="lab-kicker">${kicker}</div>${s.html}${done}${pager}</section>`
      );
    })
    .join('\n');

  const badges = VERSIONS.map(([k, v]) => `<span class="badge">${esc(k)} <b>${esc(v)}</b></span>`).join('');
  const first = ordered[0] ? ordered[0].labId : 'readme';

  verifyOutput(lang, ordered, body, sidebar);

  const clientStrings = JSON.stringify({ light: ui.themeLight, dark: ui.themeDark, copied: ui.copied, collapse: ui.collapse, noResults: ui.noResults }).replace(/</g, '\\u003c');

  const html = `<!doctype html>
<html lang="${lang}" data-theme="light">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${esc(ui.title)}</title>
<meta name="description" content="${esc(ui.description)}">
<link rel="alternate" hreflang="${other.code}" href="${other.html}">
<link rel="icon" href="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 32 32'%3E%3Ccircle cx='16' cy='16' r='14' fill='%230b6ed0'/%3E%3Ccircle cx='16' cy='16' r='7' fill='%23f0883e'/%3E%3C/svg%3E">
<style>
${CSS}
</style>
</head>
<body>
<header class="topbar">
  <button id="menu-btn" class="icon-btn" type="button" aria-label="${esc(ui.menu)}">☰</button>
  <a class="brand" href="#lab-${first}" style="color:inherit;text-decoration:none"><span class="dot"></span><span class="name">${esc(ui.brand)}</span></a>
  <div class="spacer"></div>
  <div class="search">
    <input id="search-input" type="search" placeholder="${esc(ui.searchPlaceholder)}" autocomplete="off" aria-label="${esc(ui.searchLabel)}">
    <kbd>/</kbd>
    <div id="results" class="results" role="listbox"></div>
  </div>
  <a class="lang-btn" href="${other.html}" hreflang="${other.code}" lang="${other.code}" title="${esc(ui.langTitle)}">${other.name}</a>
  <button id="theme-btn" class="icon-btn" type="button">${esc(ui.themeDark)}</button>
</header>
<div class="progress"></div>
<div class="layout">
  <nav class="sidebar" aria-label="${esc(ui.toc)}">${sidebar}</nav>
  <main class="content">
    <div class="content-inner">
      <div class="hero">
        <h1>${esc(ui.title)}</h1>
        <p>${ui.heroText}</p>
        <div class="badges">${badges}<span class="badge">${esc(ui.asOf)} <b>${VERIFIED_AT}</b></span></div>
        <a class="cta" href="#lab-00-aws-azure-mapping">${esc(ui.ctaMapping)}</a><a class="cta alt" href="#lab-01-prerequisites">${esc(ui.ctaStart)}</a>
      </div>
${body}
      <footer class="site-footer">${ui.footer(VERIFIED_AT)}</footer>
    </div>
  </main>
</div>
<script>
window.AKS_I18N=${clientStrings};
${JS}
</script>
</body>
</html>
`;
  writeFileSync(out, html);
  const kb = Math.round(Buffer.byteLength(html) / 1024);
  console.log(`✓ ${out} (${kb} KB, ${ordered.length} sections)`);
}

const wanted = process.argv.includes('--lang') ? [process.argv[process.argv.indexOf('--lang') + 1]] : Object.keys(LANGS);
for (const lang of wanted) {
  if (!LANGS[lang]) throw new Error(`Unknown language: ${lang} (available: ${Object.keys(LANGS).join(', ')})`);
  build(lang);
}
