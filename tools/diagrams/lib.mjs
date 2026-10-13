// 다이어그램(SVG) 생성용 작은 도우미 라이브러리.
//   - 외부 의존성 없이 SVG 문자열을 만듭니다.
//   - 색은 CSS 변수(--dg-*)로 지정합니다.
//       · 단독 SVG(GitHub 등)    : SVG 안의 <style> 이 라이트/다크(prefers-color-scheme)를 처리
//       · HTML 가이드에 인라인    : 페이지 CSS(.diagram-fig svg.dg)가 같은 변수를 덮어써서 라이트/다크 토글을 따름
//   - 글자가 상자를 넘치지 않도록 대략적인 글자 폭을 계산해 경고하고, 브라우저 검사용 data-w 속성을 남깁니다.

export const FONT =
  '-apple-system, BlinkMacSystemFont, "Apple SD Gothic Neo", "Malgun Gothic", "Noto Sans KR", "Segoe UI", Roboto, sans-serif';

export const TONES = ['neutral', 'aws', 'azure', 'ok', 'id', 'net', 'warn', 'danger'];

const PALETTE = {
  light: {
    bg: '#ffffff', fg: '#1f2328', muted: '#59636e', line: '#6e7781', card: '#f6f8fa', border: '#d1d9e0',
    aws: '#c2590a', 'aws-soft': '#fff1e5',
    azure: '#0b6ed0', 'azure-soft': '#e5f1ff',
    ok: '#1a7f37', 'ok-soft': '#e6f6ea',
    id: '#8250df', 'id-soft': '#f3ecff',
    net: '#0e7490', 'net-soft': '#e0f4f8',
    warn: '#9a6700', 'warn-soft': '#fff6d6',
    danger: '#cf222e', 'danger-soft': '#ffebe9',
  },
  dark: {
    bg: '#0d1117', fg: '#e6edf3', muted: '#9198a1', line: '#8b949e', card: '#151b23', border: '#30363d',
    aws: '#f0883e', 'aws-soft': '#2b1c10',
    azure: '#58a6ff', 'azure-soft': '#0f2238',
    ok: '#3fb950', 'ok-soft': '#0f2417',
    id: '#b392f0', 'id-soft': '#221a36',
    net: '#39c5cf', 'net-soft': '#0d2a2f',
    warn: '#d29922', 'warn-soft': '#2d2208',
    danger: '#ff7b72', 'danger-soft': '#3a1517',
  },
};

const vars = (p) => Object.entries(p).map(([k, v]) => `--dg-${k}:${v}`).join(';');

// HTML 페이지 CSS 가 매핑해야 하는 변수 이름 목록 (tools/assets/style.css 와 일치해야 합니다)
export const CSS_VAR_NAMES = Object.keys(PALETTE.light);

const STYLE = `
svg.dg{${vars(PALETTE.light)};font-family:${FONT}}
@media (prefers-color-scheme:dark){svg.dg{${vars(PALETTE.dark)}}}
.dg-bg{fill:var(--dg-bg)}
.dg-t{fill:var(--dg-fg)}
.dg-m{fill:var(--dg-muted)}
.dg-b{font-weight:650}
.dg-box,.dg-grp,.dg-chip{stroke-width:1.4}
.dg-box{fill:var(--dg-card);stroke:var(--dg-border)}
.dg-grp{fill:none;stroke:var(--dg-border)}
.dg-dash{stroke-dasharray:6 4}
.dg-chip{fill:var(--dg-bg);stroke:none}
.dg-line{fill:none;stroke:var(--dg-line);stroke-width:1.8}
.dg-ah{fill:var(--dg-line)}
${TONES.filter((t) => t !== 'neutral').map((t) => `.dg-box.dg-${t}{fill:var(--dg-${t}-soft);stroke:var(--dg-${t})}
.dg-grp.dg-${t}{stroke:var(--dg-${t})}
.dg-fill-${t}{fill:var(--dg-${t})}
.dg-tx-${t}{fill:var(--dg-${t})}
.dg-line.dg-${t}{stroke:var(--dg-${t})}
.dg-ah.dg-${t}{fill:var(--dg-${t})}`).join('\n')}
.dg-on{fill:#fff}
`.trim();

// 글자 폭 추정 (em 단위 × 글꼴 크기). 한글은 1em, 영문/숫자는 평균 폭.
export function textWidth(str, size = 13, bold = false) {
  let w = 0;
  for (const ch of String(str)) {
    const c = ch.codePointAt(0);
    if (
      (c >= 0xac00 && c <= 0xd7a3) || (c >= 0x1100 && c <= 0x11ff) || (c >= 0x3130 && c <= 0x318f) ||
      (c >= 0x4e00 && c <= 0x9fff) || (c >= 0x3000 && c <= 0x303f) || (c >= 0xff00 && c <= 0xffef)
    ) w += 1.0;
    else if ((c >= 0x2190 && c <= 0x21ff) || (c >= 0x25a0 && c <= 0x25ff) || (c >= 0x2600 && c <= 0x27bf) || (c >= 0x2460 && c <= 0x24ff)) w += 1.0;
    else if (ch === ' ') w += 0.32;
    else if (/[A-Z]/.test(ch)) w += 0.68;
    else if (/[a-z]/.test(ch)) w += 0.57;
    else if (/[0-9]/.test(ch)) w += 0.6;
    else if (/[.,:;|!'`]/.test(ch)) w += 0.32;
    else if (/[()[\]{}/\\-]/.test(ch)) w += 0.4;
    else if (/[·×]/.test(ch)) w += 0.6;
    else w += 0.64;
  }
  return w * size * (bold ? 1.08 : 1.03);
}

const esc = (s) => String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
const num = (n) => Math.round(n * 10) / 10;

export class Diagram {
  constructor(name, width, height, { title, desc }) {
    this.name = name;
    this.width = width;
    this.height = height;
    this.title = title;
    this.desc = desc;
    this.parts = [];
    this.warnings = [];
    this.tonesUsed = new Set(['line']);
  }

  warn(msg) {
    this.warnings.push(`${this.name}: ${msg}`);
  }

  raw(s) {
    this.parts.push(s);
  }

  // --- 글자 ---------------------------------------------------------------------
  // text(x, y, 문자열, { size, bold, muted, tone, anchor, maxW })   y 는 글자 기준선(baseline)
  text(x, y, str, { size = 13, bold = false, muted = false, tone = null, anchor = 'start', maxW = null, cls = '' } = {}) {
    const w = textWidth(str, size, bold);
    if (maxW !== null && w > maxW) this.warn(`글자가 넘칩니다(${Math.round(w)}>${Math.round(maxW)}): "${str}"`);
    const classes = [];
    if (!cls.includes('dg-on')) classes.push(muted ? 'dg-m' : tone ? `dg-tx-${tone}` : 'dg-t');
    if (bold) classes.push('dg-b');
    if (cls) classes.push(cls);
    this.parts.push(
      `<text x="${num(x)}" y="${num(y)}" font-size="${size}"${anchor !== 'start' ? ` text-anchor="${anchor}"` : ''} class="${classes.join(' ')}"${
        maxW !== null ? ` data-w="${Math.round(maxW)}"` : ''
      }>${esc(str)}</text>`,
    );
    return w;
  }

  // 큰 제목 (그림 맨 위). 반환: 제목 아래 y 좌표
  heading(title, subtitle = '') {
    this.text(24, 32, title, { size: 18, bold: true });
    if (subtitle) this.text(24, 54, subtitle, { size: 12.5, muted: true });
    return subtitle ? 72 : 52;
  }

  // --- 도형 ---------------------------------------------------------------------
  rect(x, y, w, h, { cls = '', rx = 10 } = {}) {
    this.parts.push(`<rect x="${num(x)}" y="${num(y)}" width="${num(w)}" height="${num(h)}" rx="${rx}" class="${cls}"/>`);
  }

  _geom(x, y, w, h) {
    return { x, y, w, h, l: x, r: x + w, t: y, b: y + h, cx: x + w / 2, cy: y + h / 2 };
  }

  // 제목 + 여러 줄 설명이 들어가는 상자. h 를 null 로 두면 내용에 맞춰 높이를 계산합니다.
  box(x, y, w, h, { tone = 'neutral', title = '', lines = [], titleSize = 14, size = 12.5, align = 'left', pad = 12, padY = null, dashed = false, muted = true } = {}) {
    const lh = size + 5;
    const py = padY ?? pad;
    const titleH = title ? titleSize + 6 : 0;
    const height = h ?? Math.round(py * 2 - 2 + titleH + lines.length * lh);
    if (tone !== 'neutral') this.tonesUsed.add(tone);
    this.rect(x, y, w, height, { cls: `dg-box${tone !== 'neutral' ? ` dg-${tone}` : ''}${dashed ? ' dg-dash' : ''}` });
    const anchor = align === 'center' ? 'middle' : 'start';
    const tx = align === 'center' ? x + w / 2 : x + pad;
    let ty = y + py + titleSize - 2;
    const maxW = w - pad * 2;
    if (title) {
      this.text(tx, ty, title, { size: titleSize, bold: true, anchor, maxW });
      ty += titleSize + 4;
    }
    for (const line of lines) {
      if (line === '') {
        ty += lh / 2;
        continue;
      }
      this.text(tx, ty, line, { size, muted: title ? muted : false, anchor, maxW });
      ty += lh;
    }
    return this._geom(x, y, w, height);
  }

  // 점선/실선 테두리의 큰 영역 + 왼쪽 위 라벨
  group(x, y, w, h, { tone = 'neutral', label = '', dashed = false, labelSize = 12.5 } = {}) {
    if (tone !== 'neutral') this.tonesUsed.add(tone);
    this.rect(x, y, w, h, { cls: `dg-grp${tone !== 'neutral' ? ` dg-${tone}` : ''}${dashed ? ' dg-dash' : ''}`, rx: 14 });
    if (label) this.text(x + 14, y + 20, label, { size: labelSize, bold: true, tone: tone !== 'neutral' ? tone : null, muted: tone === 'neutral', maxW: w - 28 });
    return this._geom(x, y, w, h);
  }

  // 작은 알약(태그). 폭은 글자에 맞춰 자동 계산됩니다. 반환: 기하 정보 (w 포함)
  pill(x, y, str, { tone = 'neutral', size = 11.5, h = 22, solid = false, minW = 0 } = {}) {
    const w = Math.max(minW, Math.round(textWidth(str, size, true) + 18));
    if (tone !== 'neutral') this.tonesUsed.add(tone);
    this.rect(x, y, w, h, { cls: solid ? `dg-fill-${tone === 'neutral' ? 'azure' : tone}` : `dg-box${tone !== 'neutral' ? ` dg-${tone}` : ''}`, rx: h / 2 });
    this.text(x + w / 2, y + h / 2 + size * 0.36, str, { size, bold: true, anchor: 'middle', cls: solid ? 'dg-on' : '', tone: solid ? null : tone !== 'neutral' ? tone : null });
    return this._geom(x, y, w, h);
  }

  // 번호 배지 (단계 표시)
  badge(cx, cy, label, { tone = 'azure', r = 11 } = {}) {
    this.tonesUsed.add(tone);
    this.parts.push(`<circle cx="${num(cx)}" cy="${num(cy)}" r="${r}" class="dg-fill-${tone}"/>`);
    this.text(cx, cy + 4.2, String(label), { size: 12, bold: true, anchor: 'middle', cls: 'dg-on' });
    return this._geom(cx - r, cy - r, r * 2, r * 2);
  }

  line(x1, y1, x2, y2, { tone = null, dashed = false } = {}) {
    if (tone) this.tonesUsed.add(tone);
    this.parts.push(`<path d="M${num(x1)} ${num(y1)} L${num(x2)} ${num(y2)}" class="dg-line${tone ? ` dg-${tone}` : ''}${dashed ? ' dg-dash' : ''}"/>`);
  }

  // 화살표: points = [[x,y], ...] (직선 꺾임). label 은 경로 길이의 at(0~1) 위치에 놓입니다.
  arrow(points, { tone = null, dashed = false, label = '', at = 0.5, dx = 0, dy = 0, both = false, head = true } = {}) {
    if (tone) this.tonesUsed.add(tone);
    const t = tone ?? 'line';
    const d = points.map(([x, y], i) => `${i ? 'L' : 'M'}${num(x)} ${num(y)}`).join(' ');
    const mid = head ? ` marker-end="url(#${this.name}-ah-${t})"` : '';
    const start = both ? ` marker-start="url(#${this.name}-ah-${t})"` : '';
    this.parts.push(`<path d="${d}" class="dg-line${tone ? ` dg-${tone}` : ''}${dashed ? ' dg-dash' : ''}"${mid}${start}/>`);
    if (label) {
      const [lx, ly] = pointAlong(points, at);
      const w = Math.round(textWidth(label, 11.5, true)) + 10;
      this.rect(lx + dx - w / 2, ly + dy - 10, w, 20, { cls: 'dg-chip', rx: 6 });
      this.text(lx + dx, ly + dy + 4, label, { size: 11.5, bold: true, anchor: 'middle', tone });
    }
  }

  toString() {
    const markers = [...this.tonesUsed]
      .map(
        (t) =>
          `<marker id="${this.name}-ah-${t}" viewBox="0 0 10 10" refX="8.5" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse"><path d="M0 0 L10 5 L0 10 z" class="dg-ah${t === 'line' ? '' : ` dg-${t}`}"/></marker>`,
      )
      .join('');
    return (
      `<svg xmlns="http://www.w3.org/2000/svg" class="dg" viewBox="0 0 ${this.width} ${this.height}" width="${this.width}" height="${this.height}" role="img" aria-labelledby="${this.name}-t ${this.name}-d">` +
      `<title id="${this.name}-t">${esc(this.title)}</title><desc id="${this.name}-d">${esc(this.desc)}</desc>` +
      `<style>${STYLE}</style><defs>${markers}</defs>` +
      `<rect width="${this.width}" height="${this.height}" class="dg-bg" rx="12"/>\n` +
      this.parts.join('\n') +
      `\n</svg>\n`
    );
  }
}

// 꺾은선 위에서 전체 길이의 frac(0~1) 지점 좌표
function pointAlong(points, frac) {
  const segs = [];
  let total = 0;
  for (let i = 1; i < points.length; i++) {
    const len = Math.hypot(points[i][0] - points[i - 1][0], points[i][1] - points[i - 1][1]);
    segs.push(len);
    total += len;
  }
  let target = total * frac;
  for (let i = 0; i < segs.length; i++) {
    if (target <= segs[i] || i === segs.length - 1) {
      const k = segs[i] === 0 ? 0 : target / segs[i];
      return [points[i][0] + (points[i + 1][0] - points[i][0]) * k, points[i][1] + (points[i + 1][1] - points[i][1]) * k];
    }
    target -= segs[i];
  }
  return points[0];
}
