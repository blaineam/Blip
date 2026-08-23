#!/usr/bin/env node
/**
 * asc-autosubmit.mjs — ship a tagged release to the App Store from CI, using the build
 * Xcode Cloud made for THAT commit.
 *
 *   Scripts/asc-autosubmit.mjs --version 1.6.1 --commit <sha> [--tag v1.6.1]
 *       [--platforms IOS,MAC_OS] [--wait-build 120] [--wait-process 45]
 *       [--notes-dir .] [--no-submit] [--dry-run]
 *
 * What it does, in order (every step idempotent — re-running after a hiccup is safe):
 *   1. Find the Xcode Cloud build run whose source commit is `--commit`. If XCC never ran it
 *      (auto-cancel ate it, or the commit never touched apple/ core/ ci_scripts/), START one
 *      on the tag (or on `main` when main's tip IS the commit) and wait for it.
 *   2. Wait for the run to SUCCEED, collect its uploaded builds (one per platform), and wait
 *      for each to finish PROCESSING → VALID. Builds are confirmed on /v1/builds/{id}, never the
 *      list (the list can say VALID while the binary is still processing).
 *   3. Per platform: find-or-create the editable App Store version `--version`; set What's New
 *      for every localization from appstore-metadata[.<locale>].md (en-US must START with the
 *      version — stale notes fail the run instead of shipping); attach the build; answer export
 *      compliance on the build if ASC is still asking (NO — matches ITSAppUsesNonExemptEncryption).
 *   4. Submit via reviewSubmissions. A submission already WAITING_FOR_REVIEW / IN_REVIEW for this
 *      version is success. A wedged UNRESOLVED_ISSUES submission is reported, never silently reused.
 *
 * Auth (CI): env ASC_API_KEY_ID, ASC_API_ISSUER_ID, ASC_API_KEY_P8 (the .p8 contents, raw PEM or
 * base64). Locally the key may instead sit at ~/.appstoreconnect/private_keys/AuthKey_<id>.p8 with
 * ids from ~/.rocket/config.json, like the other Scripts/asc-*.mjs. The key needs App Manager.
 *
 * Why the commit and not "newest VALID build": XCC builds every push to main. If a push lands
 * between tagging and this job, "newest" would ship code the tag never pointed at.
 */
import { readFile } from 'node:fs/promises';
import { existsSync, readFileSync, appendFileSync } from 'node:fs';
import { createPrivateKey, sign } from 'node:crypto';
import { join } from 'node:path';
import { homedir } from 'node:os';
import { execFileSync } from 'node:child_process';

const API = 'https://api.appstoreconnect.apple.com';
const die = (m) => { console.error(`✗ ${m}`); summary(`❌ ${m}`); process.exit(1); };
const log = (m) => console.log(`• ${m}`);
const b64url = (b) => Buffer.from(b).toString('base64').replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const summary = (line) => { if (process.env.GITHUB_STEP_SUMMARY) appendFileSync(process.env.GITHUB_STEP_SUMMARY, line + '\n'); };

function parseArgs(argv) {
	const a = { bundleId: 'com.blaineam.kith', platforms: ['IOS', 'MAC_OS'], waitBuild: 120, waitProcess: 45, notesDir: '.', submit: true, dryRun: false };
	for (let i = 2; i < argv.length; i++) {
		switch (argv[i]) {
			case '--bundle-id': a.bundleId = argv[++i]; break;
			case '--version': a.version = argv[++i]; break;
			case '--commit': a.commit = argv[++i]; break;
			case '--tag': a.tag = argv[++i]; break;
			case '--platforms': a.platforms = argv[++i].split(',').map((s) => s.trim().toUpperCase()).filter(Boolean); break;
			case '--wait-build': a.waitBuild = Number(argv[++i]); break;
			case '--wait-process': a.waitProcess = Number(argv[++i]); break;
			case '--notes-dir': a.notesDir = argv[++i]; break;
			case '--no-submit': a.submit = false; break;
			case '--dry-run': a.dryRun = true; break;
			default: die(`unknown arg ${argv[i]}`);
		}
	}
	if (!a.version) die('--version required (X.Y.Z — the App Store marketing version)');
	if (!/^\d+\.\d+\.\d+$/.test(a.version)) die(`--version ${a.version} is not plain X.Y.Z (an rc never reaches the App Store)`);
	if (!a.commit) die('--commit required (the full sha the tag points at)');
	if (!a.tag) a.tag = `v${a.version}`;
	for (const p of a.platforms) if (!['IOS', 'MAC_OS', 'TV_OS', 'VISION_OS'].includes(p)) die(`unknown platform ${p}`);
	return a;
}

// ── auth ──────────────────────────────────────────────────────────────────────────────
function creds() {
	let keyId = process.env.ASC_API_KEY_ID, issuer = process.env.ASC_API_ISSUER_ID;
	let pem = process.env.ASC_API_KEY_P8 || '';
	if (pem && !pem.includes('-----BEGIN')) pem = Buffer.from(pem.trim(), 'base64').toString('utf8');
	if (!keyId || !issuer) {
		const cfg = join(homedir(), '.rocket/config.json');
		if (existsSync(cfg)) { const j = JSON.parse(readFileSync(cfg, 'utf8')); keyId = keyId || j.ascKeyId; issuer = issuer || j.ascIssuerId; }
	}
	if (!keyId || !issuer) die('No ASC creds — set ASC_API_KEY_ID + ASC_API_ISSUER_ID (+ ASC_API_KEY_P8 in CI)');
	if (!pem) {
		const p8 = join(homedir(), '.appstoreconnect/private_keys', `AuthKey_${keyId}.p8`);
		if (!existsSync(p8)) die(`Missing ASC_API_KEY_P8 and ${p8}`);
		pem = readFileSync(p8, 'utf8');
	}
	return { keyId, issuer, pem };
}

let CREDS = null, TOKEN = null, TOKEN_AT = 0;
function token() {
	// Re-mint every 15 minutes: the JWT lives 20 and this script waits for hours.
	if (TOKEN && Date.now() - TOKEN_AT < 15 * 60_000) return TOKEN;
	const { keyId, issuer, pem } = CREDS;
	const now = Math.floor(Date.now() / 1000);
	const input = `${b64url(JSON.stringify({ alg: 'ES256', kid: keyId, typ: 'JWT' }))}.` +
		`${b64url(JSON.stringify({ iss: issuer, iat: now, exp: now + 19 * 60, aud: 'appstoreconnect-v1' }))}`;
	const sig = sign('sha256', Buffer.from(input), { key: createPrivateKey(pem), dsaEncoding: 'ieee-p1363' });
	TOKEN = `${input}.${b64url(sig)}`; TOKEN_AT = Date.now();
	return TOKEN;
}

async function api(method, path, body, { retries = 3 } = {}) {
	for (let attempt = 0; ; attempt++) {
		const res = await fetch(path.startsWith('http') ? path : `${API}${path}`, {
			method, headers: { authorization: `Bearer ${token()}`, ...(body ? { 'content-type': 'application/json' } : {}) },
			body: body ? JSON.stringify(body) : undefined,
		}).catch((e) => ({ ok: false, status: 0, text: async () => String(e) }));
		if (res.status === 204) return null;
		const text = await res.text();
		let json = null; try { json = text ? JSON.parse(text) : null; } catch { /* */ }
		if (res.ok) return json;
		const detail = json?.errors?.map((e) => `${e.title}: ${e.detail}${e.meta?.associatedErrors ? ' ' + JSON.stringify(e.meta.associatedErrors) : ''}`).join('; ') || text;
		// Transient: network, 429, 5xx. Everything else is the caller's problem.
		if ((res.status === 0 || res.status === 429 || res.status >= 500) && attempt < retries) { await sleep(5000 * (attempt + 1)); continue; }
		const err = new Error(`${method} ${path} → ${res.status}: ${detail}`); err.status = res.status; throw err;
	}
}

async function paged(path, max = 5) {
	const out = [];
	let next = path;
	for (let i = 0; next && i < max; i++) {
		const r = await api('GET', next);
		out.push(...(r?.data || []));
		next = r?.links?.next || null;
	}
	return out;
}

// ── 1. the Xcode Cloud run for this commit ──────────────────────────────────────────────
async function ciProductFor(appId) {
	const r = await api('GET', `/v1/ciProducts?filter[productType]=APP&limit=200&include=app&fields[ciProducts]=name,app&fields[apps]=bundleId`);
	return (r.data || []).find((p) => p.relationships?.app?.data?.id === appId) || null;
}

async function archiveWorkflow(productId) {
	const r = await api('GET', `/v1/ciProducts/${productId}/workflows?limit=50&fields[ciWorkflows]=name,isEnabled,actions,branchStartCondition`);
	const wfs = (r.data || []).filter((w) => w.attributes?.isEnabled && (w.attributes?.actions || []).some((x) => x.actionType === 'ARCHIVE'));
	if (!wfs.length) die('no enabled Xcode Cloud workflow with an Archive action — nothing can produce an App Store build');
	// Prefer the one that builds `main` on push (that's the TestFlight pipeline); else the first.
	return wfs.find((w) => (w.attributes?.branchStartCondition?.source?.patterns || []).some((p) => p.pattern === 'main')) || wfs[0];
}

async function findRun(productId, sha) {
	const runs = await paged(`/v1/ciProducts/${productId}/buildRuns?limit=200&sort=-number&fields[ciBuildRuns]=number,sourceCommit,executionProgress,completionStatus,createdDate,startReason`, 3);
	return runs.find((r) => (r.attributes?.sourceCommit?.commitSha || '').toLowerCase() === sha.toLowerCase()) || null;
}

async function gitReference(workflowId, { tag, commit }) {
	const repo = await api('GET', `/v1/ciWorkflows/${workflowId}/repository?fields[scmRepositories]=repositoryName`);
	const repoId = repo?.data?.id;
	if (!repoId) die('workflow has no SCM repository');
	// XCC learns about a new tag from the provider with a little lag — poll for it.
	for (let i = 0; i < 12; i++) {
		const refs = await paged(`/v1/scmRepositories/${repoId}/gitReferences?limit=200&fields[scmGitReferences]=name,canonicalName,kind,isDeleted`, 5);
		const t = refs.find((x) => x.attributes?.kind === 'TAG' && !x.attributes?.isDeleted && (x.attributes?.name === tag || x.attributes?.canonicalName === `refs/tags/${tag}`));
		if (t) return { ref: t, via: `tag ${tag}` };
		// Fallback: main's tip IS this commit → build main, which is the same tree.
		let mainTip = null;
		try { mainTip = execFileSync('git', ['rev-parse', 'origin/main'], { encoding: 'utf8' }).trim(); } catch { /* no checkout */ }
		if (mainTip && mainTip.toLowerCase() === commit.toLowerCase()) {
			const m = refs.find((x) => x.attributes?.kind === 'BRANCH' && !x.attributes?.isDeleted && x.attributes?.name === 'main');
			if (m) return { ref: m, via: 'branch main (its tip is this commit)' };
		}
		log(`Xcode Cloud hasn't seen tag ${tag} yet — waiting (${i + 1}/12)…`);
		await sleep(30_000);
	}
	die(`Xcode Cloud never listed tag ${tag} and main's tip is not ${commit.slice(0, 10)} — start a build of the tag in Xcode Cloud by hand and re-run`);
}

async function startRun(workflowId, ref) {
	const r = await api('POST', '/v1/ciBuildRuns', {
		data: {
			type: 'ciBuildRuns',
			relationships: {
				workflow: { data: { type: 'ciWorkflows', id: workflowId } },
				sourceBranchOrTag: { data: { type: 'scmGitReferences', id: ref.id } },
			},
		},
	});
	return r.data;
}

async function waitRun(runId, minutes) {
	const deadline = Date.now() + minutes * 60_000;
	for (;;) {
		const r = await api('GET', `/v1/ciBuildRuns/${runId}?fields[ciBuildRuns]=number,executionProgress,completionStatus,sourceCommit`);
		const at = r.data.attributes;
		if (at.executionProgress === 'COMPLETE') return r.data;
		if (Date.now() >= deadline) die(`Xcode Cloud run #${at.number} still ${at.executionProgress} after ${minutes} min`);
		log(`run #${at.number}: ${at.executionProgress}… (${Math.round((deadline - Date.now()) / 60_000)} min left)`);
		await sleep(60_000);
	}
}

async function runBuilds(runId) {
	// The run→builds relationship comes back as bare ids (every attribute null), so hydrate
	// each build from its own resource — which is also the authoritative processingState.
	const ids = ((await api('GET', `/v1/ciBuildRuns/${runId}/builds?limit=50`)).data || []).map((b) => b.id);
	const out = [];
	for (const id of ids) {
		const r = await api('GET', `/v1/builds/${id}?include=preReleaseVersion&fields[builds]=version,processingState,uploadedDate,usesNonExemptEncryption,preReleaseVersion&fields[preReleaseVersions]=platform,version`);
		const p = (r.included || []).find((x) => x.type === 'preReleaseVersions')?.attributes || {};
		out.push({ id, number: r.data.attributes.version, state: r.data.attributes.processingState, platform: p.platform, marketing: p.version, usesNonExemptEncryption: r.data.attributes.usesNonExemptEncryption });
	}
	return out;
}

async function waitValid(build, minutes) {
	const deadline = Date.now() + minutes * 60_000;
	for (;;) {
		const r = await api('GET', `/v1/builds/${build.id}?fields[builds]=version,processingState,usesNonExemptEncryption`);
		const at = r.data.attributes;
		if (at.processingState === 'VALID') return { ...build, state: 'VALID', usesNonExemptEncryption: at.usesNonExemptEncryption };
		if (at.processingState === 'FAILED' || at.processingState === 'INVALID') die(`${build.platform} build ${build.number} is ${at.processingState} — Xcode Cloud uploaded a binary ASC rejected`);
		if (Date.now() >= deadline) die(`${build.platform} build ${build.number} still ${at.processingState} after ${minutes} min`);
		log(`${build.platform} build ${build.number}: ${at.processingState}…`);
		await sleep(60_000);
	}
}

// ── 3. version, notes, attach ──────────────────────────────────────────────────────────
const EDITABLE = new Set(['PREPARE_FOR_SUBMISSION', 'DEVELOPER_REJECTED', 'REJECTED', 'METADATA_REJECTED', 'INVALID_BINARY']);
const LIVE_OR_QUEUED = new Set(['WAITING_FOR_REVIEW', 'IN_REVIEW', 'PENDING_DEVELOPER_RELEASE', 'READY_FOR_SALE', 'READY_FOR_DISTRIBUTION', 'PROCESSING_FOR_DISTRIBUTION']);

async function ensureVersion(appId, platform, version, { dryRun }) {
	const versions = (await api('GET', `/v1/apps/${appId}/appStoreVersions?filter[platform]=${platform}&limit=50&fields[appStoreVersions]=versionString,appStoreState`)).data || [];
	const same = versions.find((v) => v.attributes.versionString === version);
	if (same && LIVE_OR_QUEUED.has(same.attributes.appStoreState)) return { version: same, state: same.attributes.appStoreState, done: true };
	if (same && EDITABLE.has(same.attributes.appStoreState)) return { version: same, state: same.attributes.appStoreState };
	if (same) die(`${platform} ${version} exists but is ${same.attributes.appStoreState} — neither editable nor shipping; sort it out in App Store Connect`);
	// One editable slot per platform. A stale draft with a different number that has no
	// build attached is just an abandoned number — rename it (its notes get rewritten below).
	const other = versions.find((v) => EDITABLE.has(v.attributes.appStoreState));
	if (other) {
		const b = await api('GET', `/v1/appStoreVersions/${other.id}/build?fields[builds]=version`).catch(() => null);
		if (b?.data) die(`${platform}: the editable slot is taken by ${other.attributes.versionString} (${other.attributes.appStoreState}) with build ${b.data.attributes.version} attached — ASC allows one editable version per platform. Submit or remove it in App Store Connect, then re-run.`);
		log(`${platform}: renaming abandoned draft ${other.attributes.versionString} (${other.attributes.appStoreState}, no build) → ${version}`);
		if (!dryRun) await api('PATCH', `/v1/appStoreVersions/${other.id}`, { data: { type: 'appStoreVersions', id: other.id, attributes: { versionString: version } } });
		return { version: { ...other, attributes: { ...other.attributes, versionString: version } }, state: other.attributes.appStoreState };
	}
	// SUPERSEDE: a version QUEUED for review (not yet live) also occupies the slot — POSTing a
	// new version 409s "cannot create a new version in the current state". When that queued
	// version is OLDER than the target, this release supersedes it: cancel its pending review
	// submission, wait for the version to fall back to an editable state, and rename it in
	// place (its notes are rewritten and the new build attached by the steps that follow).
	// Never touches a queued version that is NEWER than or equal to the target.
	const semverLt = (a, b) => {
		const pa = String(a).split('.').map(Number), pb = String(b).split('.').map(Number);
		for (let i = 0; i < 3; i++) { if ((pa[i] || 0) !== (pb[i] || 0)) return (pa[i] || 0) < (pb[i] || 0); }
		return false;
	};
	const QUEUED = new Set(['WAITING_FOR_REVIEW', 'READY_FOR_REVIEW', 'IN_REVIEW']);
	const queued = versions.find((v) => QUEUED.has(v.attributes.appStoreState) && semverLt(v.attributes.versionString, version));
	if (queued) {
		log(`${platform}: superseding ${queued.attributes.versionString} (${queued.attributes.appStoreState}) — canceling its review submission`);
		if (!dryRun) {
			const subs = (await api('GET', `/v1/reviewSubmissions?filter[app]=${appId}&filter[platform]=${platform}&filter[state]=READY_FOR_REVIEW,WAITING_FOR_REVIEW,IN_REVIEW&fields[reviewSubmissions]=state&limit=10`)).data || [];
			for (const sub of subs) {
				await api('PATCH', `/v1/reviewSubmissions/${sub.id}`, { data: { type: 'reviewSubmissions', id: sub.id, attributes: { canceled: true } } })
					.catch((e) => log(`${platform}: cancel of submission ${sub.id} → ${e.message || e} (continuing)`));
			}
			// The version takes a moment to fall back to an editable state after the cancel.
			let st = queued.attributes.appStoreState;
			for (let i = 0; i < 24; i++) {
				await new Promise((r) => setTimeout(r, 5000));
				const fresh = await api('GET', `/v1/appStoreVersions/${queued.id}?fields[appStoreVersions]=appStoreState`).catch(() => null);
				st = fresh?.data?.attributes?.appStoreState || st;
				if (EDITABLE.has(st)) break;
			}
			if (!EDITABLE.has(st)) die(`${platform}: canceled the review but ${queued.attributes.versionString} is still ${st} after 2min — check App Store Connect and re-run`);
			log(`${platform}: ${queued.attributes.versionString} back to ${st} — renaming → ${version}`);
			await api('PATCH', `/v1/appStoreVersions/${queued.id}`, { data: { type: 'appStoreVersions', id: queued.id, attributes: { versionString: version } } });
		}
		return { version: { ...queued, attributes: { ...queued.attributes, versionString: version } }, state: 'PREPARE_FOR_SUBMISSION' };
	}
	if (dryRun) return { version: { id: 'dry-run', attributes: { versionString: version } }, state: 'PREPARE_FOR_SUBMISSION' };
	const created = (await api('POST', '/v1/appStoreVersions', {
		data: { type: 'appStoreVersions', attributes: { platform, versionString: version }, relationships: { app: { data: { type: 'apps', id: appId } } } },
	})).data;
	log(`${platform}: created App Store version ${version}`);
	return { version: created, state: 'PREPARE_FOR_SUBMISSION' };
}

// `## whats_new` (and `## promotional_text`) from appstore-metadata[.<locale>].md, per
// locale that has a file. Promotional text rides along because a NEW App Store version
// does not inherit it from its predecessor — 1.6.1 went into review with it blank.
async function notesByLocale(dir) {
	const section = (md, key) => { const m = md.match(new RegExp(`^##\\s+${key}\\s*$\\n([\\s\\S]*?)(?=^##\\s+|\\s*$(?![\\s\\S]))`, 'm')); return m ? m[1].replace(/<!--[\s\S]*?-->/g, '').trim() : null; };
	const out = {}, promo = {};
	const { readdir } = await import('node:fs/promises');
	for (const f of await readdir(dir)) {
		const m = f.match(/^appstore-metadata(?:\.([A-Za-z-]+))?\.md$/);
		if (!m) continue;
		const locale = m[1] || 'en-US';
		const md = await readFile(join(dir, f), 'utf8');
		const body = section(md, 'whats_new');
		if (body) out[locale] = body;
		const p = section(md, 'promotional_text');
		if (p) promo[locale] = p;
	}
	return Object.assign(out, { __promo: promo });
}

async function setNotes(versionId, version, notes, { dryRun }) {
	const en = notes['en-US'];
	if (!en) die('appstore-metadata.md has no `## whats_new` — nothing to ship as release notes');
	if (!en.startsWith(version)) die(`appstore-metadata.md whats_new starts with "${en.split('\n')[0].slice(0, 60)}" — it must start with "${version}" (stale notes would ship otherwise)`);
	const locs = (await api('GET', `/v1/appStoreVersions/${versionId}/appStoreVersionLocalizations?limit=50&fields[appStoreVersionLocalizations]=locale,whatsNew,promotionalText`)).data || [];
	let set = 0; const fellBack = [];
	for (const loc of locs) {
		const locale = loc.attributes.locale;
		let text = notes[locale];
		// A translation still on an older version is worse than English: fall back, loudly.
		if (locale !== 'en-US' && (!text || !text.startsWith(version))) { fellBack.push(locale); text = en; }
		if (text.length > 4000) die(`${locale} whats_new is ${text.length} chars (ASC max 4000)`);
		const attrs = {};
		if (loc.attributes.whatsNew !== text) attrs.whatsNew = text;
		const promo = (notes.__promo || {})[locale];
		if (promo != null) {
			if (promo.length > 170) die(`${locale} promotional_text is ${promo.length} chars (ASC max 170)`);
			if ((loc.attributes.promotionalText || '') !== promo) attrs.promotionalText = promo;
		}
		if (Object.keys(attrs).length && !dryRun) {
			await api('PATCH', `/v1/appStoreVersionLocalizations/${loc.id}`, { data: { type: 'appStoreVersionLocalizations', id: loc.id, attributes: attrs } });
		}
		set++;
	}
	log(`What's New${Object.keys(notes.__promo || {}).length ? ' + promotional text' : ''} set on ${set}/${locs.length} localization(s)`);
	if (fellBack.length) {
		const msg = `no ${version} translation for ${fellBack.join(', ')} — those listings got the English notes (run \`rocket loc translate Haven --locale big8 --provider claude\` and re-push with \`rocket meta Haven --locale all\`)`;
		console.log(`⚠ ${msg}`); summary(`- ⚠️ ${msg}`);
	}
	return { set, fellBack };
}

// ── 4. review submission ───────────────────────────────────────────────────────────────
async function submit(appId, platform, versionId) {
	const subs = (await api('GET', `/v1/reviewSubmissions?filter[app]=${appId}&filter[platform]=${platform}&filter[state]=READY_FOR_REVIEW,WAITING_FOR_REVIEW,IN_REVIEW,UNRESOLVED_ISSUES&fields[reviewSubmissions]=state,platform&limit=10`)).data || [];
	const itemsOf = async (sub) => new Set(((await api('GET', `/v1/reviewSubmissions/${sub.id}/items?include=appStoreVersion&limit=50`).catch(() => ({}))).included || []).filter((x) => x.type === 'appStoreVersions').map((x) => x.id));
	for (const s of subs) {
		if (['WAITING_FOR_REVIEW', 'IN_REVIEW'].includes(s.attributes.state)) {
			if ((await itemsOf(s)).has(versionId)) { log(`${platform}: already ${s.attributes.state} (submission ${s.id})`); return s.attributes.state; }
			die(`${platform}: another submission (${s.id}) is ${s.attributes.state} — ASC allows one at a time; wait for it or cancel it in App Store Connect`);
		}
		if (s.attributes.state === 'UNRESOLVED_ISSUES') die(`${platform}: submission ${s.id} is UNRESOLVED_ISSUES (a rejected item) — ASC refuses new items on it. Cancel it in App Store Connect (App Review → Cancel Submission) and re-run.`);
	}
	let sub = subs.find((s) => s.attributes.state === 'READY_FOR_REVIEW') || null;
	if (!sub) {
		sub = (await api('POST', '/v1/reviewSubmissions', { data: { type: 'reviewSubmissions', attributes: { platform }, relationships: { app: { data: { type: 'apps', id: appId } } } } })).data;
		log(`${platform}: opened review submission ${sub.id}`);
	}
	if (!(await itemsOf(sub)).has(versionId)) {
		// ASC settles for a moment after a version edit/attach; a 409 here is usually that.
		for (let i = 0; ; i++) {
			try {
				await api('POST', '/v1/reviewSubmissionItems', { data: { type: 'reviewSubmissionItems', relationships: { reviewSubmission: { data: { type: 'reviewSubmissions', id: sub.id } }, appStoreVersion: { data: { type: 'appStoreVersions', id: versionId } } } } });
				break;
			} catch (e) { if (e.status === 409 && i < 5) { log(`${platform}: item add 409 — retrying in 60s (${i + 1}/5): ${e.message.split(':').slice(-1)[0].trim()}`); await sleep(60_000); continue; } throw e; }
		}
		log(`${platform}: version added to submission`);
	}
	await api('PATCH', `/v1/reviewSubmissions/${sub.id}`, { data: { type: 'reviewSubmissions', id: sub.id, attributes: { submitted: true } } });
	const after = await api('GET', `/v1/reviewSubmissions/${sub.id}?fields[reviewSubmissions]=state`);
	const state = after?.data?.attributes?.state;
	if (state !== 'WAITING_FOR_REVIEW' && state !== 'IN_REVIEW') die(`${platform}: submitted=true accepted but submission is ${state}, not WAITING_FOR_REVIEW`);
	return state;
}

// ── main ───────────────────────────────────────────────────────────────────────────────
async function main() {
	const args = parseArgs(process.argv);
	CREDS = creds();
	const app = (await api('GET', `/v1/apps?filter[bundleId]=${encodeURIComponent(args.bundleId)}&limit=1&fields[apps]=name,bundleId`)).data?.[0];
	if (!app) die(`No app for ${args.bundleId}`);
	log(`${app.attributes.name} ${args.version} ← commit ${args.commit.slice(0, 10)} (${args.tag})${args.dryRun ? ' — DRY RUN' : ''}`);

	// 1. the run
	const product = await ciProductFor(app.id);
	if (!product) die('no Xcode Cloud product for this app');
	let run = await findRun(product.id, args.commit);
	const workflow = await archiveWorkflow(product.id);
	if (run && run.attributes.executionProgress === 'COMPLETE' && run.attributes.completionStatus !== 'SUCCEEDED') {
		log(`Xcode Cloud run #${run.attributes.number} for this commit ${run.attributes.completionStatus} — starting a fresh one`);
		run = null;
	}
	if (!run) {
		// XCC builds every push to main and lists the run with some lag. A commit pushed minutes
		// ago almost certainly HAS a run incoming — poll before resorting to a manual start.
		for (let i = 0; i < 8 && !run; i++) {
			log(`no Xcode Cloud run listed for ${args.commit.slice(0, 10)} yet — waiting for the push-triggered one (${i + 1}/8)…`);
			await sleep(30_000);
			run = await findRun(product.id, args.commit);
			if (run && run.attributes.executionProgress === 'COMPLETE' && run.attributes.completionStatus !== 'SUCCEEDED') run = null;
		}
	}
	if (!run) {
		if (args.dryRun) die('dry run: no Xcode Cloud run for this commit, and a dry run does not start one');
		const { ref, via } = await gitReference(workflow.id, { tag: args.tag, commit: args.commit });
		try {
			run = await startRun(workflow.id, ref);
			log(`started Xcode Cloud run #${run.attributes?.number ?? '?'} on workflow "${workflow.attributes.name}" via ${via}`);
		} catch (e) {
			// XCC refuses manual runs on a TAG unless the workflow's start condition lists tags
			// ("the tag is not associated with the workflow", 409). Ours builds on branch pushes —
			// fall back to starting the BRANCH when its tip carries the same tree/version.
			if (!/not associated with the workflow/i.test(String(e?.message || e))) throw e;
			log(`tag start refused by the workflow's start condition — starting branch main instead`);
			const repo = await api('GET', `/v1/ciWorkflows/${workflow.id}/repository?fields[scmRepositories]=repositoryName`);
			const refs = await paged(`/v1/scmRepositories/${repo.data.id}/gitReferences?limit=200&fields[scmGitReferences]=name,kind,isDeleted`, 5);
			const m = refs.find((x) => x.attributes?.kind === 'BRANCH' && !x.attributes?.isDeleted && x.attributes?.name === 'main');
			if (!m) die('no main branch reference in Xcode Cloud — start the build by hand and re-run');
			run = await startRun(workflow.id, m);
			log(`started Xcode Cloud run #${run.attributes?.number ?? '?'} via branch main`);
			args.commit = '';   // the branch tip may differ from the tagged sha — trust the run, not the pin
		}
	} else log(`Xcode Cloud run #${run.attributes.number} (${run.attributes.executionProgress}/${run.attributes.completionStatus || 'running'})`);
	run = await waitRun(run.id, args.waitBuild);
	if (run.attributes.completionStatus !== 'SUCCEEDED') die(`Xcode Cloud run #${run.attributes.number} ${run.attributes.completionStatus} — fix the build, push, re-tag`);
	// args.commit is emptied by the branch-main fallback (the branch tip is the pin then); the
	// marketing-version check right below still guards against building the wrong tree.
	if (args.commit && (run.attributes.sourceCommit?.commitSha || '').toLowerCase() !== args.commit.toLowerCase()) die(`run #${run.attributes.number} built ${run.attributes.sourceCommit?.commitSha?.slice(0, 10)}, not ${args.commit.slice(0, 10)}`);
	log(`run #${run.attributes.number} SUCCEEDED`);

	// 2. the builds
	let builds = await runBuilds(run.id);
	if (!builds.length) die(`run #${run.attributes.number} uploaded no builds`);
	const wrongVersion = builds.filter((b) => b.marketing && b.marketing !== args.version);
	if (wrongVersion.length) die(`run #${run.attributes.number} built marketing version ${wrongVersion[0].marketing}, not ${args.version} — MARKETING_VERSION in apple/project.yml is out of step with the tag`);
	const byPlatform = {};
	for (const p of args.platforms) {
		const b = builds.filter((x) => x.platform === p).sort((x, y) => Number(y.number) - Number(x.number))[0];
		if (!b) die(`run #${run.attributes.number} has no ${p} build (got: ${builds.map((x) => `${x.platform} ${x.number}`).join(', ') || 'none'})`);
		byPlatform[p] = await waitValid(b, args.waitProcess);
		log(`${p}: build ${byPlatform[p].number} VALID`);
	}

	// 3 + 4. per platform
	const notes = await notesByLocale(args.notesDir);
	const results = [];
	for (const platform of args.platforms) {
		const build = byPlatform[platform];
		const { version, state, done } = await ensureVersion(app.id, platform, args.version, { dryRun: args.dryRun });
		if (done) { log(`${platform} ${args.version} is already ${state} — nothing to do`); results.push(`${platform} ${args.version}: already ${state}`); continue; }
		log(`${platform}: editable version ${args.version} (${state})`);
		if (!args.dryRun) {
			await setNotes(version.id, args.version, notes, { dryRun: false });
			const attached = await api('GET', `/v1/appStoreVersions/${version.id}/build?fields[builds]=version`).catch(() => null);
			if (attached?.data?.id !== build.id) {
				await api('PATCH', `/v1/appStoreVersions/${version.id}/relationships/build`, { data: { type: 'builds', id: build.id } });
				log(`${platform}: attached build ${build.number}`);
			} else log(`${platform}: build ${build.number} already attached`);
			if (build.usesNonExemptEncryption == null) {
				// ITSAppUsesNonExemptEncryption=NO is in the Info.plist, so ASC normally never asks;
				// if a build arrives unanswered anyway, answer the same thing rather than stall.
				await api('PATCH', `/v1/builds/${build.id}`, { data: { type: 'builds', id: build.id, attributes: { usesNonExemptEncryption: false } } });
				log(`${platform}: answered export compliance on build ${build.number} (exempt)`);
			}
			if (!args.submit) { results.push(`${platform} ${args.version}: build ${build.number} attached, not submitted (--no-submit)`); continue; }
			const st = await submit(app.id, platform, version.id);
			results.push(`${platform} ${args.version}: build ${build.number} → ${st}`);
			console.log(`✓ ${platform} ${args.version} (build ${build.number}) ${st}`);
		} else {
			await setNotes(version.id === 'dry-run' ? null : version.id, args.version, notes, { dryRun: true }).catch((e) => { if (version.id !== 'dry-run') throw e; log(`(dry run) ${e.message}`); });
			results.push(`${platform} ${args.version}: would attach build ${build.number} and submit`);
		}
	}
	summary(`### App Store — ${app.attributes.name} ${args.version}\n- Xcode Cloud run #${run.attributes.number} (commit \`${args.commit.slice(0, 10)}\`)\n${results.map((r) => `- ${r}`).join('\n')}`);
}

main().catch((e) => die(e.message));
