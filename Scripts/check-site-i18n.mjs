#!/usr/bin/env node
// check-site-i18n.mjs — consistency gate for blip.wemiller.com (docs/), Soren suite `web`.
//
//   • every page dictionary docs/i18n/<page>.<lang>.json parses, has exactly the English
//     key set, and no empty values (a missing key silently leaves English on the page);
//   • every data-i18n / data-i18n-html / data-i18n-attr key used by the page exists in
//     its English dictionary (special keys `_title`, `_meta.*` included);
//   • the screenshot manifest only references files that exist, covers every scene for
//     every language it lists, and each <img>/<source> the page swaps exists in English;
//   • relative links/asset references in the pages resolve to files in docs/.
//
// No dependencies. Exit 0 = clean, 1 = problems (listed).
import { existsSync, readFileSync, realpathSync } from 'node:fs';
import { dirname, join, normalize } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const docs = join(dirname(fileURLToPath(import.meta.url)), '..', 'docs');
const LANGS = ['en', 'de', 'es', 'fr', 'it', 'ja', 'ko', 'pt-BR', 'zh-Hans'];
const PAGES = { index: 'index.html', features: 'features/index.html', faq: 'faq/index.html' };

/** Problems with one page's dictionaries, given {lang: object}. */
export function checkDictionaries(page, dicts) {
  const out = [];
  const en = dicts.en;
  if (!en) return [`${page}: no English dictionary`];
  const enKeys = new Set(Object.keys(en));
  for (const [lang, dict] of Object.entries(dicts)) {
    const keys = new Set(Object.keys(dict));
    for (const k of enKeys) if (!keys.has(k)) out.push(`${page}.${lang}: missing "${k}"`);
    for (const k of keys) if (!enKeys.has(k)) out.push(`${page}.${lang}: unknown key "${k}"`);
    for (const [k, v] of Object.entries(dict)) {
      if (typeof v !== 'string' || !v.trim()) out.push(`${page}.${lang}: empty "${k}"`);
    }
  }
  return out;
}

/** Keys an HTML page asks the runtime to translate. */
export function usedKeys(html) {
  const keys = new Set();
  for (const m of html.matchAll(/data-i18n(?:-html)?="([^"]+)"/g)) keys.add(m[1]);
  for (const m of html.matchAll(/data-i18n-attr="([^"]+)"/g)) {
    for (const pair of m[1].split(';')) {
      const key = pair.split(':').slice(1).join(':').trim();
      if (key) keys.add(key);
    }
  }
  return keys;
}

export function checkManifest(manifest, fileExists) {
  const out = [];
  const files = Object.keys(manifest.files || {});
  for (const f of files) if (!fileExists(f)) out.push(`manifest: ${f} does not exist`);
  const scenes = Object.keys(manifest.sizes || {});
  const widths = new Set(files.map((f) => f.match(/-(\d+)\.\w+$/)?.[1]).filter(Boolean));
  for (const lang of manifest.langs || []) {
    for (const scene of scenes) {
      for (const w of widths) {
        const hit = files.some((f) => f.startsWith(`${lang}/${scene}-${w}.`));
        if (!hit) out.push(`manifest: ${lang} lacks ${scene} at ${w}w`);
      }
    }
  }
  return out;
}

/** Checks docs/; returns the list of problems. */
export function runSite() {
  const problems = [];
  const read = (p) => readFileSync(join(docs, p), 'utf8');

  for (const [page, htmlPath] of Object.entries(PAGES)) {
    const dicts = {};
    for (const lang of LANGS) {
      const file = `i18n/${page}.${lang}.json`;
      try { dicts[lang] = JSON.parse(read(file)); }
      catch (e) { problems.push(`${file}: ${e.code === 'ENOENT' ? 'missing' : `invalid JSON (${e.message})`}`); }
    }
    problems.push(...checkDictionaries(page, dicts));

    const html = read(htmlPath);
    const declared = html.match(/i18n\.js[^>]*data-page="([^"]+)"/)?.[1];
    if (declared !== page) problems.push(`${htmlPath}: i18n.js data-page="${declared}", expected "${page}"`);
    for (const key of usedKeys(html)) {
      if (dicts.en && !(key in dicts.en)) problems.push(`${htmlPath}: uses "${key}" which isn't in ${page}.en.json`);
    }

    // Relative src/href/srcset targets must exist (ignore absolute, anchors, mailto, etc.).
    const base = dirname(htmlPath);
    const refs = new Set();
    for (const m of html.matchAll(/\s(?:src|href)="([^"]+)"/g)) refs.add(m[1]);
    for (const m of html.matchAll(/\ssrcset="([^"]+)"/g)) {
      for (const part of m[1].split(',')) refs.add(part.trim().split(/\s+/)[0]);
    }
    for (const ref of refs) {
      if (!ref || /^(?:[a-z]+:|\/\/|#|\/)/i.test(ref)) continue;
      const path = normalize(join(base, ref.split(/[?#]/)[0]));
      if (path.endsWith('/') || path === '.' ) continue;
      if (!existsSync(join(docs, path))) problems.push(`${htmlPath}: broken reference ${ref}`);
    }
  }

  try {
    const manifest = JSON.parse(read('assets/screens/manifest.json'));
    problems.push(...checkManifest(manifest, (f) => existsSync(join(docs, 'assets/screens', f))));
  } catch (e) {
    problems.push(`assets/screens/manifest.json: ${e.message}`);
  }

  return problems;
}

if (process.argv[1] && import.meta.url === pathToFileURL(realpathSync(process.argv[1])).href) {
  const problems = runSite();
  if (problems.length) {
    console.error(`site i18n: ${problems.length} problem(s):`);
    for (const p of problems) console.error(`  ${p}`);
    process.exit(1);
  }
  console.log(`site i18n: OK — ${Object.keys(PAGES).length} pages × ${LANGS.length} languages, manifest consistent`);
}
