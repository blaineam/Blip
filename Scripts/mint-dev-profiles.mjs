#!/usr/bin/env node
/**
 * mint-dev-profiles.mjs — LOCAL tool: create/refresh iOS *development* provisioning
 * profiles for Blip for iOS (app + widget extension) via the App Store Connect API,
 * and install them where Xcode's build system looks.
 *
 * Why this exists: command-line `xcodebuild -allowProvisioningUpdates` on this Mac
 * reports "No Accounts", so automatic signing can only reach the team wildcard
 * profile — which carries no App Groups, so the widget extension (and the shared
 * store) can't ship in local device builds. This mints real profiles by API key.
 *
 *   node Scripts/mint-dev-profiles.mjs           # find-or-create + install both profiles
 *   node Scripts/mint-dev-profiles.mjs --force   # revoke same-name profiles, recreate
 *
 * Auth: ~/.rocket/config.json (ascKeyId/ascIssuerId) + ~/.appstoreconnect/private_keys.
 * The key needs App Manager (same key the release scripts use).
 */
import { existsSync, readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { createPrivateKey, sign, createHash } from 'node:crypto';
import { join } from 'node:path';
import { homedir } from 'node:os';
import { execFileSync } from 'node:child_process';

const API = 'https://api.appstoreconnect.apple.com';
const die = (m) => { console.error(`✗ ${m}`); process.exit(1); };
const log = (m) => console.log(`• ${m}`);
const b64url = (b) => Buffer.from(b).toString('base64').replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');

const FORCE = process.argv.includes('--force');
const APP_BUNDLE = 'com.blainemiller.Blip';           // universal purchase — iOS shares the Mac app's id
const WIDGET_BUNDLE = 'com.blainemiller.Blip.widgets';
const PROFILES = [
  { name: 'Blip iOS Dev App', bundle: APP_BUNDLE },
  { name: 'Blip iOS Dev Widgets', bundle: WIDGET_BUNDLE },
];

function creds() {
  const cfg = join(homedir(), '.rocket/config.json');
  if (!existsSync(cfg)) die('~/.rocket/config.json missing');
  const j = JSON.parse(readFileSync(cfg, 'utf8'));
  const keyId = j.ascKeyId, issuer = j.ascIssuerId;
  const p8 = join(homedir(), '.appstoreconnect/private_keys', `AuthKey_${keyId}.p8`);
  if (!existsSync(p8)) die(`missing ${p8}`);
  return { keyId, issuer, pem: readFileSync(p8, 'utf8') };
}
let CREDS = null, TOKEN = null, TOKEN_AT = 0;
function token() {
  if (TOKEN && Date.now() - TOKEN_AT < 15 * 60_000) return TOKEN;
  const { keyId, issuer, pem } = CREDS;
  const now = Math.floor(Date.now() / 1000);
  const input = `${b64url(JSON.stringify({ alg: 'ES256', kid: keyId, typ: 'JWT' }))}.` +
    `${b64url(JSON.stringify({ iss: issuer, iat: now, exp: now + 19 * 60, aud: 'appstoreconnect-v1' }))}`;
  const sig = sign('sha256', Buffer.from(input), { key: createPrivateKey(pem), dsaEncoding: 'ieee-p1363' });
  TOKEN = `${input}.${b64url(sig)}`; TOKEN_AT = Date.now();
  return TOKEN;
}
async function api(method, path, body) {
  const res = await fetch(path.startsWith('http') ? path : `${API}${path}`, {
    method, headers: { authorization: `Bearer ${token()}`, ...(body ? { 'content-type': 'application/json' } : {}) },
    body: body ? JSON.stringify(body) : undefined,
  });
  if (res.status === 204) return null;
  const text = await res.text();
  let json = null; try { json = text ? JSON.parse(text) : null; } catch { /* */ }
  if (res.ok) return json;
  const detail = json?.errors?.map((e) => `${e.title}: ${e.detail}`).join('; ') || text;
  const err = new Error(`${method} ${path} → ${res.status}: ${detail}`); err.status = res.status; throw err;
}

/** SHA-1 of the local signing identity so we pick the matching ASC certificate. */
function localIdentitySHA1s() {
  try {
    const out = execFileSync('security', ['find-identity', '-v', '-p', 'codesigning'], { encoding: 'utf8' });
    return [...out.matchAll(/([0-9A-F]{40}) "Apple Development/g)].map((m) => m[1]);
  } catch { return []; }
}

async function main() {
  CREDS = creds();

  // 1. Development certificates — prefer ones actually present in this Mac's keychain.
  const certs = (await api('GET', '/v1/certificates?filter[certificateType]=DEVELOPMENT&limit=200'))?.data || [];
  if (!certs.length) die('no development certificates on the account');
  const localHashes = new Set(localIdentitySHA1s());
  const usable = certs.filter((c) => {
    const der = Buffer.from(c.attributes.certificateContent, 'base64');
    const sha1 = createHash('sha1').update(der).digest('hex').toUpperCase();
    return localHashes.has(sha1);
  });
  const chosen = usable.length ? usable : certs;
  log(`certificates: ${chosen.length} (${usable.length ? 'matched local keychain' : 'NO local match — using all; signing may still fail'})`);

  // 2. Every enabled iOS device (standard team-dev-profile shape).
  const allDevices = (await api('GET', '/v1/devices?filter[platform]=IOS&filter[status]=ENABLED&limit=200'))?.data || [];
  // IOS_APP_DEVELOPMENT profiles accept only iPhone/iPad hardware (watches and TVs
  // ride along under the IOS platform filter but 409 the profile create).
  const devices = allDevices.filter((d) => ['IPHONE', 'IPAD'].includes(d.attributes.deviceClass));
  if (!devices.length) die('no enabled iPhone/iPad devices registered');
  log(`devices: ${devices.length} iPhone/iPad of ${allDevices.length} enabled`);

  // 3. Bundle ids — the widget id may not exist yet; register it.
  const bundleIdFor = async (identifier) => {
    const r = await api('GET', `/v1/bundleIds?filter[identifier]=${encodeURIComponent(identifier)}&limit=5`);
    let found = (r?.data || []).find((b) => b.attributes.identifier === identifier);
    if (!found) {
      log(`registering bundle id ${identifier}`);
      found = (await api('POST', '/v1/bundleIds', {
        data: { type: 'bundleIds', attributes: { identifier, name: identifier.replace(/\./g, ' '), platform: 'IOS' } },
      })).data;
    }
    return found;
  };

  // 4. Ensure App Groups capability on both ids (profile embeds the groups assigned
  //    to the id in the portal; enabling the capability is the API-visible half).
  const ensureAppGroups = async (bundleIdObj) => {
    const caps = (await api('GET', `/v1/bundleIds/${bundleIdObj.id}/bundleIdCapabilities`))?.data || [];
    if (caps.some((c) => c.attributes.capabilityType === 'APP_GROUPS')) return;
    log(`enabling APP_GROUPS on ${bundleIdObj.attributes.identifier}`);
    await api('POST', '/v1/bundleIdCapabilities', {
      data: {
        type: 'bundleIdCapabilities',
        attributes: { capabilityType: 'APP_GROUPS', settings: [] },
        relationships: { bundleId: { data: { type: 'bundleIds', id: bundleIdObj.id } } },
      },
    });
  };

  const installDirs = [
    join(homedir(), 'Library/MobileDevice/Provisioning Profiles'),
    join(homedir(), 'Library/Developer/Xcode/UserData/Provisioning Profiles'),
  ];
  for (const d of installDirs) mkdirSync(d, { recursive: true });

  for (const spec of PROFILES) {
    const bid = await bundleIdFor(spec.bundle);
    await ensureAppGroups(bid);

    // Find-or-create by name; --force (or an INVALID state) recreates.
    const existing = ((await api('GET', `/v1/profiles?filter[name]=${encodeURIComponent(spec.name)}&limit=5`))?.data || [])
      .find((p) => p.attributes.name === spec.name);
    let profile = existing;
    if (existing && (FORCE || existing.attributes.profileState !== 'ACTIVE')) {
      log(`deleting ${existing.attributes.profileState} profile "${spec.name}"`);
      await api('DELETE', `/v1/profiles/${existing.id}`);
      profile = null;
    }
    if (!profile) {
      log(`creating profile "${spec.name}" for ${spec.bundle}`);
      profile = (await api('POST', '/v1/profiles', {
        data: {
          type: 'profiles',
          attributes: { name: spec.name, profileType: 'IOS_APP_DEVELOPMENT' },
          relationships: {
            bundleId: { data: { type: 'bundleIds', id: bid.id } },
            certificates: { data: chosen.map((c) => ({ type: 'certificates', id: c.id })) },
            devices: { data: devices.map((d) => ({ type: 'devices', id: d.id })) },
          },
        },
      })).data;
    } else {
      log(`profile "${spec.name}" already ACTIVE — reusing`);
    }

    const content = Buffer.from(profile.attributes.profileContent, 'base64');
    for (const d of installDirs) {
      writeFileSync(join(d, `${profile.attributes.uuid}.mobileprovision`), content);
    }
    log(`installed ${spec.name} (${profile.attributes.uuid})`);

    // Honesty check: does the minted profile actually carry the app group?
    const plist = execFileSync('security', ['cms', '-D'], { input: content, encoding: 'utf8' });
    const hasGroup = plist.includes('group.com.blainemiller.Blip');
    log(`  app group in profile: ${hasGroup ? 'YES (group.com.blainemiller.Blip)' : 'NO — assign the group to the bundle id in the developer portal, then re-run with --force'}`);
  }
  log('done');
}
main().catch((e) => die(e.message));
