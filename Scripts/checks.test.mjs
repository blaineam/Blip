// node --test Scripts/ — unit tests for the localization and website gates, plus the gates
// themselves run against the real tree (so a failing catalog or page fails this suite).
import test from 'node:test';
import assert from 'node:assert/strict';
import { checkCatalog, checkPlist, specifiers, runL10n } from './check-l10n.mjs';
import { checkDictionaries, usedKeys, checkManifest, runSite } from './check-site-i18n.mjs';

const LANGS = ['de', 'es', 'fr', 'it', 'ja', 'ko', 'pt-BR', 'zh-Hans'];
const all = (value) => Object.fromEntries(LANGS.map((l) => [l, { stringUnit: { state: 'translated', value } }]));

test('specifiers: positional, literal percent, prose percent', () => {
  assert.deepEqual([...specifiers('%1$@ of %2$lld')], [[1, '@'], [2, 'lld']]);
  assert.deepEqual([...specifiers('%@ free · %lld%%')], [[1, '@'], [2, 'lld']]);
  assert.equal(specifiers('100% and rising').size, 0, '"% a" in prose is not a conversion');
  assert.match(specifiers('%1$@ %1$lld'), /argument 1/);
});

test('catalog: missing language, retyped and reordered specifiers are caught', () => {
  const problems = checkCatalog('t', {
    sourceLanguage: 'en',
    strings: {
      '%lld files': { localizations: { ...all('%lld Dateien'), de: { stringUnit: { state: 'translated', value: '%@ Dateien' } } } },
      'Hello': { localizations: { de: { stringUnit: { state: 'translated', value: 'Hallo' } } } },
      '%1$@ of %2$@': { localizations: all('%2$@ von %1$@') },                 // same types: fine
      '%1$@ on %2$lld': { localizations: { ...all('%1$@ / %2$lld'), fr: { stringUnit: { state: 'translated', value: '%2$@ / %1$lld' } } } },
      'Empty': { localizations: { ...all('x'), ja: { stringUnit: { state: 'translated', value: '  ' } } } },
      'Draft': { localizations: { ...all('x'), ko: { stringUnit: { state: 'new', value: 'x' } } } },
      'skip': { shouldTranslate: false },
      'old': { extractionState: 'stale' },
      'Steps of 1% each': { localizations: all('1-%-Schritte') },               // argless: literal
    },
  });
  assert.equal(problems.filter((p) => p.includes('"Hello" missing')).length, 7);
  assert.ok(problems.some((p) => p.includes('"%lld files" de') && p.includes('1:%@ ≠ source 1:%lld')));
  assert.ok(problems.some((p) => p.includes('"%1$@ on %2$lld" fr')));
  assert.ok(problems.some((p) => p.includes('"Empty" ja') && p.endsWith('empty')));
  assert.ok(problems.some((p) => p.includes('"Draft" ko') && p.includes('state new')));
  assert.equal(problems.length, 11, problems.join('\n'));
});

test('catalog: plural variants may drop the count but never retype it', () => {
  const plural = (one, other) => ({ variations: { plural: {
    one: { stringUnit: { state: 'translated', value: one } },
    other: { stringUnit: { state: 'translated', value: other } } } } });
  const ok = checkCatalog('t', { strings: { '%lld items': { localizations: Object.fromEntries(LANGS.map((l) => [l, plural('one item', '%lld items')])) } } });
  assert.deepEqual(ok, []);
  const bad = checkCatalog('t', { strings: { '%lld items': { localizations: { ...Object.fromEntries(LANGS.map((l) => [l, plural('one', '%lld')])), de: plural('ein', '%@ Dinge') } } } });
  assert.equal(bad.length, 1);
  assert.match(bad[0], /de plural\.other/);
});

test('Info.plist development region', () => {
  assert.deepEqual(checkPlist('p', '<key>CFBundleDevelopmentRegion</key>\n\t<string>en</string>'), []);
  assert.match(checkPlist('p', '<key>CFBundleDevelopmentRegion</key><string>de</string>')[0], /expected "en"/);
  assert.match(checkPlist('p', '<dict></dict>')[0], /no CFBundleDevelopmentRegion/);
});

test('site dictionaries must mirror English', () => {
  const problems = checkDictionaries('index', {
    en: { a: 'A', b: 'B' },
    de: { a: 'A-de' },                 // missing b
    fr: { a: 'A', b: 'B', c: 'C' },    // unknown c
    ja: { a: '', b: 'B' },             // empty a
  });
  assert.deepEqual(problems.sort(), [
    'index.de: missing "b"', 'index.fr: unknown key "c"', 'index.ja: empty "a"',
  ].sort());
});

test('site: keys used by a page, attribute pairs included', () => {
  const keys = usedKeys('<h1 data-i18n="t.1">x</h1><p data-i18n-html="h.2"></p><img data-i18n-attr="alt:a.3;title:b.4">');
  assert.deepEqual([...keys].sort(), ['a.3', 'b.4', 'h.2', 't.1']);
});

test('site: screenshot manifest coverage and existence', () => {
  const manifest = { langs: ['en', 'de'], sizes: { '02-bench': [1, 1] },
    files: { 'en/02-bench-560.avif': 'x', 'en/02-bench-1120.avif': 'x', 'de/02-bench-560.avif': 'x' } };
  const problems = checkManifest(manifest, (f) => f !== 'en/02-bench-560.avif');
  assert.deepEqual(problems.sort(), ['manifest: de lacks 02-bench at 1120w', 'manifest: en/02-bench-560.avif does not exist'].sort());
});

test('the shipped string catalogs and Info.plists pass', () => {
  const { problems, keys } = runL10n();
  assert.ok(keys > 500, `only ${keys} keys found — catalogs moved?`);
  assert.deepEqual(problems, []);
});

test('the website passes', () => {
  assert.deepEqual(runSite(), []);
});
