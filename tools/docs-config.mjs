// Shared layout of the bilingual docs. English is the default language; Korean lives next to it.
//
//             English (default)             Korean
//   README    README.md                     README.ko.md
//   labs      labs/NN-*.md                  labs/ko/NN-*.md
//   diagrams  labs/diagrams/*.svg           labs/ko/diagrams/*.svg
//   HTML      aks-terraform-guide.html      aks-terraform-guide.ko.html
//
// Terraform code and shell scripts are English-only: both editions embed the same files verbatim.
import { readdirSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

export const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
export const DEFAULT_LANG = 'en';

export const LANGS = {
  en: { code: 'en', name: 'English', readme: 'README.md', labsDir: 'labs', diagramsDir: 'labs/diagrams', html: 'aks-terraform-guide.html', other: 'ko' },
  ko: { code: 'ko', name: '한국어', readme: 'README.ko.md', labsDir: 'labs/ko', diagramsDir: 'labs/ko/diagrams', html: 'aks-terraform-guide.ko.html', other: 'en' },
};

// Block at the top of every md file that links to the same page in the other language.
// GitHub renders it; the HTML build strips it (the HTML guide has its own language button).
export const LANG_SWITCH = /<!-- lang-switch -->[\s\S]*?<!-- \/lang-switch -->\n?/g;

// Markdown files of one language, relative to ROOT: the README first, then the labs in file-name order.
export function docFiles(lang) {
  const { readme, labsDir } = LANGS[lang];
  const labs = readdirSync(join(ROOT, labsDir))
    .filter((f) => f.endsWith('.md'))
    .sort();
  return [readme, ...labs.map((f) => `${labsDir}/${f}`)];
}

// The same document in the other language (README.md <-> README.ko.md, labs/X.md <-> labs/ko/X.md).
export function counterpart(rel, lang) {
  const from = LANGS[lang];
  const to = LANGS[from.other];
  return rel === from.readme ? to.readme : `${to.labsDir}/${rel.slice(from.labsDir.length + 1)}`;
}
