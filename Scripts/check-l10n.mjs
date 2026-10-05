#!/usr/bin/env node
// check-l10n.mjs — localization completeness gate for Blip (Soren suite `l10n`).
//
// For every string catalog that ships (Mac app, iOS app, iOS widgets):
//   1. every key that isn't `shouldTranslate: false` (and isn't stale) has a non-empty
//      translation in each shipped language — plural/device variations included;
//   2. every translation's format specifiers match the source string's, argument by
//      argument (a `%@` where the source has `%lld`, or a positional `%2$@` pointing at
//      the wrong argument, crashes or garbles at runtime);
// and every shipped Info.plist declares CFBundleDevelopmentRegion = en (a missing/other
// region once rendered the iOS app in German on English devices).
//
// No dependencies. Exit 0 = clean, 1 = problems (listed).
import { readFileSync, realpathSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const LANGS = ['de', 'es', 'fr', 'it', 'ja', 'ko', 'pt-BR', 'zh-Hans'];
const CATALOGS = [
  'Blip/Resources/Localizable.xcstrings',
  'BlipMobile/Resources/Localizable.xcstrings',
  'BlipMobileWidgets/Resources/Localizable.xcstrings',
];
const PLISTS = [
  'Blip/Resources/Info.plist',
  'BlipHelper/Resources/Info.plist',
  'BlipMobile/Resources/Info.plist',
  'BlipMobileWidgets/Resources/Info.plist',
];


// %[n$][flags][width][.precision][length]conversion — "%%" is a literal percent. The
// space flag is deliberately not recognised: in prose "100% and" is a percent sign, not a
// `% a` conversion, and no Blip string uses the space flag.
const SPEC = /%(?:(\d+)\$)?[-+#0]*(?:\d+|\*)?(?:\.(?:\d+|\*))?(hh|h|ll|l|q|z|t|j|L)?([@dDiuUxXoOfFeEgGaAcCsSp%])/g;

/** Argument index → "length+conversion" for one string, or an error string. */
export function specifiers(s) {
  const byArg = new Map();
  let next = 1;
  for (const m of s.matchAll(SPEC)) {
    const [, pos, len = '', conv] = m;
    if (conv === '%') continue;
    const index = pos ? Number(pos) : next++;
    const type = len + conv;
    if (byArg.has(index) && byArg.get(index) !== type) return `argument ${index} used as both ${byArg.get(index)} and ${type}`;
    byArg.set(index, type);
  }
  return byArg;
}

function describe(map) {
  return [...map.entries()].sort((a, b) => a[0] - b[0]).map(([i, t]) => `${i}:%${t}`).join(' ') || '(none)';
}

function sameSpecs(a, b) {
  if (a.size !== b.size) return false;
  for (const [k, v] of a) if (b.get(k) !== v) return false;
  return true;
}

/** Yields [variantPath, value] for every leaf string unit of a localization. */
function* leaves(loc, path = '') {
  if (!loc || typeof loc !== 'object') return;
  if (loc.stringUnit) yield [path || 'value', loc.stringUnit.value, loc.stringUnit.state];
  if (loc.variations) {
    for (const [kind, cases] of Object.entries(loc.variations)) {
      for (const [name, sub] of Object.entries(cases)) yield* leaves(sub, `${path}${kind}.${name} `);
    }
  }
  if (loc.substitutions) {
    for (const [name, sub] of Object.entries(loc.substitutions)) yield* leaves(sub, `${path}sub.${name} `);
  }
}

export function checkCatalog(file, catalog) {
  const out = [];
  const source = catalog.sourceLanguage || 'en';
  for (const [key, entry] of Object.entries(catalog.strings || {})) {
    if (entry.shouldTranslate === false || entry.extractionState === 'stale') continue;
    const locs = entry.localizations || {};
    const sourceText = locs[source]?.stringUnit?.value ?? key;
    const sourceSpecs = specifiers(sourceText);
    if (typeof sourceSpecs === 'string') { out.push(`${file}: "${key}" source: ${sourceSpecs}`); continue; }
    for (const lang of LANGS) {
      const loc = locs[lang];
      const units = [...leaves(loc)];
      if (!units.length) { out.push(`${file}: "${key}" missing ${lang}`); continue; }
      for (const [variant, value, state] of units) {
        const where = `${file}: "${key}" ${lang} ${variant.trim()}`;
        if (typeof value !== 'string' || !value.trim()) { out.push(`${where}: empty`); continue; }
        if (state && state !== 'translated' && state !== 'needs_review') { out.push(`${where}: state ${state}`); continue; }
        // A key without arguments is never run through a formatter, so a "%" in its
        // translation ("1-%-Schritten") is literal text — only formatted strings are checked.
        if (sourceSpecs.size === 0) continue;
        const specs = specifiers(value);
        if (typeof specs === 'string') { out.push(`${where}: ${specs}`); continue; }
        // Plural variants may drop the count ("one" → "a file"); never ADD or retype one.
        const pluralCase = /plural\./.test(variant);
        const ok = pluralCase
          ? [...specs].every(([i, t]) => sourceSpecs.get(i) === t)
          : sameSpecs(specs, sourceSpecs);
        if (!ok) out.push(`${where}: specifiers ${describe(specs)} ≠ source ${describe(sourceSpecs)}`);
      }
    }
  }
  return out;
}

export function checkPlist(file, text) {
  const m = text.match(/<key>CFBundleDevelopmentRegion<\/key>\s*<string>([^<]*)<\/string>/);
  if (!m) return [`${file}: no CFBundleDevelopmentRegion`];
  return m[1] === 'en' ? [] : [`${file}: CFBundleDevelopmentRegion is "${m[1]}", expected "en"`];
}

/** Checks the shipped catalogs + Info.plists; returns { problems, keys }. */
export function runL10n() {
  const problems = [];
  let keys = 0;
  for (const file of CATALOGS) {
    let catalog;
    try { catalog = JSON.parse(readFileSync(join(root, file), 'utf8')); }
    catch (e) { problems.push(`${file}: unreadable (${e.message})`); continue; }
    keys += Object.keys(catalog.strings || {}).length;
    problems.push(...checkCatalog(file, catalog));
  }
  for (const file of PLISTS) {
    try { problems.push(...checkPlist(file, readFileSync(join(root, file), 'utf8'))); }
    catch (e) { problems.push(`${file}: unreadable (${e.message})`); }
  }
  return { problems, keys };
}

if (process.argv[1] && import.meta.url === pathToFileURL(realpathSync(process.argv[1])).href) {
  const { problems, keys } = runL10n();
  if (problems.length) {
    console.error(`l10n: ${problems.length} problem(s):`);
    for (const p of problems) console.error(`  ${p}`);
    process.exit(1);
  }
  console.log(`l10n: OK — ${CATALOGS.length} catalogs, ${keys} keys, ${LANGS.length} languages, ${PLISTS.length} Info.plists`);
}
