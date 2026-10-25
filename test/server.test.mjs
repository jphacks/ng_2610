import assert from 'node:assert/strict';
import { mkdtemp, readFile, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import WebSocket from 'ws';
import { acquireQuake, parseQuake551 } from '../server/demo/quake.mjs';
import { DemoController, validateDeviceMessage } from '../server/demo/runs.mjs';
import { bearerMatches, createDemoServer, isLocalRequest, originAllowed } from '../server/demo/server.mjs';
import { evaluateCandidate, parseTsunamiHistory, parseTsunamiItem, summaryFor } from '../server/demo/tsunami.mjs';
import { jstToIso, ROOT, sha256 } from '../server/demo/util.mjs';
import { validatePackage, loadRequiredKeys } from '../scripts/languages-validate.mjs';
import { convertRows } from '../scripts/import-evacuation-sites.mjs';

const LIVE = JSON.stringify([{ code: 551, id: 'live-1', earthquake: { time: '2026/10/24 12:44:00', maxScale: 10, hypocenter: { name: '陸奥湾', magnitude: 2.9 } }, issue: { time: '2026/10/24 12:47:28' } }]);
const OLD = JSON.stringify([{ code: 551, id: 'old-1', earthquake: { time: '2025/01/01 00:00:00', maxScale: -1, hypocenter: { name: '', magnitude: -1 } }, issue: { time: '2025/01/01 00:03:00' } }]);
const fetchReturning = (text, status = 200) => async () => new Response(text, { status });
const fetchFailing = (msg = 'offline') => async () => { throw new Error(msg); };
const tmp = () => mkdtemp(join(tmpdir(), 'nigeyo-test-'));
const noLog = async () => {};

async function fixtureDir(text = OLD) {
  const dir = await tmp();
  await writeFile(join(dir, 'quake551.json'), text);
  await writeFile(join(dir, 'metadata.json'), JSON.stringify({ source: 'test', fetchedAt: '2025-01-01T00:05:00Z', sha256: sha256(text) }));
  return dir;
}

// ---------- quake 551 ----------
test('jstToIso is strict and keeps JST wall time', () => {
  assert.equal(jstToIso('2026/10/24 12:44:00'), '2026-10-24T12:44:00+09:00');
  assert.equal(jstToIso('2026/10/24 21:10:47.625'), '2026-10-24T21:10:47+09:00');
  assert.equal(jstToIso('2026/02/30 00:00:00'), null);
  assert.equal(jstToIso('2026-10-24T12:44:00'), null);
});

test('parseQuake551 normalizes and maps unknowns to null', () => {
  assert.deepEqual(parseQuake551(LIVE), { sourceEventId: 'live-1', code: 551, occurredAt: '2026-10-24T12:44:00+09:00', issuedAt: '2026-10-24T12:47:28+09:00', hypocenterName: '陸奥湾', magnitude: 2.9, maxScale: 10 });
  const old = parseQuake551(OLD);
  assert.equal(old.maxScale, null);
  assert.equal(old.magnitude, null);
  assert.equal(old.hypocenterName, null);
});

test('parseQuake551 rejects broken JSON, empty array, other code, bad time, missing id', () => {
  for (const [text, reason] of [['{', 'invalid-json'], ['[]', 'empty-array'], ['{}', 'not-array'],
    [JSON.stringify([{ code: 552, id: 'x' }]), 'unexpected-code'], [JSON.stringify([{ code: 551, id: '' }]), 'missing-id'],
    [JSON.stringify([{ code: 551, id: 'x', earthquake: { time: 'bad' }, issue: { time: '2026/10/24 12:47:28' } }]), 'invalid-time']]) {
    assert.throws(() => parseQuake551(text), { message: reason });
  }
});

test('acquireQuake: live success is stored as last-good and labelled live-api', async () => {
  const stateDir = await tmp();
  const r = await acquireQuake({ fetchImpl: fetchReturning(LIVE), stateDir, fixtureDir: await fixtureDir() });
  assert.equal(r.source, 'live-api');
  assert.equal(r.quake.issuedAt, '2026-10-24T12:47:28+09:00');
  assert.equal(await readFile(join(stateDir, 'last-good/quake551.json'), 'utf8'), LIVE);
});

test('acquireQuake: HTTP error / timeout / bad data fall back to last-good, then fixture, with the real reason', async () => {
  const stateDir = await tmp();
  const fx = await fixtureDir();
  let r = await acquireQuake({ fetchImpl: fetchReturning('oops', 503), stateDir, fixtureDir: fx });
  assert.equal(r.source, 'fixture');
  assert.equal(r.failureReason, 'http-503');
  assert.equal(r.quake.issuedAt, '2025-01-01T00:03:00+09:00', 'fixture time is never rewritten');
  await acquireQuake({ fetchImpl: fetchReturning(LIVE), stateDir, fixtureDir: fx });
  r = await acquireQuake({ fetchImpl: fetchReturning('[]'), stateDir, fixtureDir: fx });
  assert.equal(r.source, 'last-good');
  assert.equal(r.failureReason, 'empty-array');
  r = await acquireQuake({ fetchImpl: (url, { signal }) => new Promise((_, rej) => signal.addEventListener('abort', () => rej(signal.reason))), stateDir, fixtureDir: fx });
  assert.equal(r.failureReason, 'timeout');
  assert.equal(r.source, 'last-good');
});

test('acquireQuake: no live, no last-good, no fixture → throws', async () => {
  await assert.rejects(acquireQuake({ fetchImpl: fetchFailing(), stateDir: await tmp(), fixtureDir: await tmp() }), { message: 'no-data-available' });
});

test('acquireQuake: tampered fixture is rejected', async () => {
  const fx = await fixtureDir();
  await writeFile(join(fx, 'quake551.json'), LIVE);
  await assert.rejects(acquireQuake({ fetchImpl: fetchFailing(), stateDir: await tmp(), fixtureDir: fx }));
});

test('repo fixture is a valid real API capture', async () => {
  const text = await readFile(join(ROOT, 'fixtures/demo/quake551.json'), 'utf8');
  const meta = JSON.parse(await readFile(join(ROOT, 'fixtures/demo/metadata.json'), 'utf8'));
  assert.equal(meta.sha256, sha256(text));
  assert.match(meta.source, /api\.p2pquake\.net/);
  assert.equal(parseQuake551(text).code, 551);
});

// ---------- tsunami 552 ----------
const T_ITEM = (over = {}) => ({ code: 552, id: 't-1', issue: { time: '2026/10/24 12:00:00' }, cancelled: false, areas: [{ name: '宮城県', grade: 'Warning', immediate: false }, { name: '岩手県', grade: 'Unknown' }], ...over });
const AT = (iso) => new Date(iso);

test('552 candidate rules: target area, grade, cancelled, freshness', () => {
  const rec = parseTsunamiItem(T_ITEM());
  assert.equal(evaluateCandidate(rec, { targetArea: '宮城県', now: AT('2026-10-24T03:02:00Z') }).candidate, true);
  assert.equal(evaluateCandidate(rec, { targetArea: null, now: AT('2026-10-24T03:02:00Z') }).reason, 'no-target-area');
  assert.equal(evaluateCandidate(rec, { targetArea: '東京都', now: AT('2026-10-24T03:02:00Z') }).reason, 'area-not-targeted');
  assert.equal(evaluateCandidate(rec, { targetArea: '岩手県', now: AT('2026-10-24T03:02:00Z') }).reason, 'grade-not-candidate');
  assert.equal(evaluateCandidate(rec, { targetArea: '宮城県', now: AT('2026-10-24T03:05:00Z') }).reason, 'expired');
  assert.equal(evaluateCandidate(rec, { targetArea: '宮城県', now: AT('2026-10-24T02:59:50Z') }).reason, 'future-time');
  assert.equal(evaluateCandidate(rec, { targetArea: '宮城県', now: AT('2026-10-24T02:59:56Z') }).candidate, true);
  const cancelled = parseTsunamiItem(T_ITEM({ cancelled: true }));
  assert.equal(evaluateCandidate(cancelled, { targetArea: '宮城県', now: AT('2026-10-24T03:01:00Z') }).reason, 'cancelled');
});

test('552 validation and empty history', () => {
  assert.equal(parseTsunamiHistory('[]'), null);
  assert.throws(() => parseTsunamiItem(T_ITEM({ cancelled: 'no' })), { message: 'invalid-cancelled' });
  assert.throws(() => parseTsunamiItem(T_ITEM({ areas: undefined })), { message: 'missing-areas' });
  assert.throws(() => parseTsunamiItem({ ...T_ITEM(), code: 551 }), { message: 'unexpected-code' });
  assert.deepEqual(summaryFor(parseTsunamiItem(T_ITEM()), '宮城県'), { sourceEventId: 't-1', code: 552, issuedAt: '2026-10-24T12:00:00+09:00', cancelled: false, area: '宮城県', grade: 'Warning' });
});

// ---------- device protocol / controller ----------
const INSTALL = '6c43c859-d9af-47da-a627-685f0096547d';
const hello = (over = {}) => JSON.stringify({ schemaVersion: 2, type: 'hello', installationId: INSTALL, appVersion: '1.0.0', preferredLanguage: 'en', languagePackageVersion: 1, resourceVersion: 2, liveActivitiesEnabled: true, notificationAuthorization: 'authorized', ...over });

test('validateDeviceMessage', () => {
  assert.equal(validateDeviceMessage(hello()).ok, true);
  assert.equal(validateDeviceMessage(hello({ schemaVersion: 1 })).errorCode, 'unsupported-version');
  assert.equal(validateDeviceMessage(hello({ notificationAuthorization: 'maybe' })).errorCode, 'invalid-payload');
  assert.equal(validateDeviceMessage(JSON.stringify({ schemaVersion: 2, type: 'nope' })).errorCode, 'invalid-payload');
  assert.equal(validateDeviceMessage('x'.repeat(17 * 1024)).errorCode, 'invalid-payload');
  assert.equal(validateDeviceMessage(JSON.stringify({ schemaVersion: 2, type: 'notification-ack', runId: INSTALL, status: 'rejected' })).errorCode, 'invalid-payload');
  assert.equal(validateDeviceMessage(JSON.stringify({ schemaVersion: 2, type: 'notification-ack', runId: INSTALL, status: 'rejected', errorCode: 'clock-skew' })).ok, true);
});

function fakeAssets(order = []) {
  return {
    resourceVersion: 2,
    languagePackageVersion: (id) => ({ en: 1, ja: 1, ko: 1 })[id] ?? null,
    wallpaper: () => Buffer.from('png'),
    verifyWallpaper: async (kind) => { order.push(`wallpaper:${kind}`); return { kind }; },
  };
}

function fakeTimers() {
  const pending = [];
  return {
    setTimeout: (fn, ms) => { const t = { fn, ms, cleared: false }; pending.push(t); return t; },
    clearTimeout: (t) => { if (t) t.cleared = true; },
    fire: () => { const due = pending.splice(0).filter((t) => !t.cleared); due.forEach((t) => t.fn()); return due.length; },
  };
}

async function readyController({ order = [], fetchImpl = fetchReturning(LIVE) } = {}) {
  const timers = fakeTimers();
  const sent = [];
  const socket = { send: (t) => { const m = JSON.parse(t); sent.push(m); order.push(`send:${m.type}`); }, close() {} };
  const c = new DemoController({ assets: fakeAssets(order), log: noLog, fetchImpl, stateDir: await tmp(), fixtureDir: await fixtureDir(), timers });
  c.attachDevice(socket);
  c.handleDeviceText(socket, hello());
  return { c, socket, sent, timers };
}
const settle = () => new Promise((r) => setTimeout(r, 20));
const ack = (runId, status = 'scheduled', extra = {}) => JSON.stringify({ schemaVersion: 2, type: 'notification-ack', runId, status, receivedAt: new Date().toISOString(), scheduledAt: new Date().toISOString(), appState: 'background', protectedDataAvailable: false, ...extra });

test('run: immutable asset is verified before start-guide; ACK → scheduled', async () => {
  const order = [];
  const { c, socket, sent } = await readyController({ order });
  const run = c.startRun({ scenario: 'earthquake' });
  await settle();
  assert.deepEqual(order, ['wallpaper:earthquake', 'send:start-guide']);
  const cmd = sent[0];
  assert.equal(cmd.runId, run.runId);
  assert.equal(cmd.source, 'live-api');
  assert.equal(cmd.language, 'en');
  assert.equal(Date.parse(cmd.expiresAt) - Date.parse(cmd.sentAt), 20_000);
  c.handleDeviceText(socket, ack(run.runId));
  assert.equal(c.run.status, 'scheduled');
});

test('run: tsunami scenario verifies its fixed asset and sends hazard tsunami', async () => {
  const order = [];
  const { c, sent } = await readyController({ order });
  c.startRun({ scenario: 'tsunami' });
  await settle();
  assert.deepEqual(order, ['wallpaper:tsunami', 'send:start-guide']);
  assert.equal(sent[0].hazard, 'tsunami');
  assert.equal(sent[0].scenario, 'tsunami');
});

test('run: upper-case UUIDs from Swift match the server run (found in simulator E2E)', async () => {
  const { c, socket } = await readyController();
  const run = c.startRun({ scenario: 'earthquake' });
  await settle();
  c.handleDeviceText(socket, ack(run.runId.toUpperCase()));
  assert.equal(c.run.status, 'scheduled');
});

test('run: no ACK → one resend with the same runId → ack-unknown; late ACK upgrades to scheduled', async () => {
  const { c, socket, sent, timers } = await readyController();
  const run = c.startRun({ scenario: 'earthquake' });
  await settle();
  timers.fire();
  assert.equal(sent.length, 2);
  assert.equal(sent[1].runId, run.runId);
  timers.fire();
  assert.equal(sent.length, 2, 'never a third send');
  assert.equal(c.run.status, 'ack-unknown');
  c.handleDeviceText(socket, ack(run.runId, 'duplicate'));
  assert.equal(c.run.status, 'scheduled');
});

test('run: explicit failure ACK → failed; source stays fixture when API fails', async () => {
  const { c, socket, sent } = await readyController({ fetchImpl: fetchFailing() });
  const run = c.startRun({ scenario: 'earthquake' });
  await settle();
  assert.equal(sent[0].source, 'fixture');
  c.handleDeviceText(socket, ack(run.runId, 'rejected', { errorCode: 'session-busy' }));
  assert.equal(c.run.status, 'failed');
});

test('run: 409 while running, when disconnected or heartbeat stale; 400 on bad scenario', async () => {
  const { c } = await readyController();
  assert.throws(() => c.startRun({ scenario: 'flood' }), { status: 400 });
  c.startRun({ scenario: 'earthquake' });
  assert.throws(() => c.startRun({ scenario: 'earthquake' }), { status: 409 });
  const stale = await readyController();
  stale.c.device.lastHeartbeatAt = new Date(Date.now() - 16_000).toISOString();
  assert.throws(() => stale.c.startRun({ scenario: 'earthquake' }), { status: 409, code: 'heartbeat-stale' });
  const none = new DemoController({ assets: fakeAssets(), log: noLog });
  assert.throws(() => none.startRun({ scenario: 'earthquake' }), { status: 409, code: 'device-not-connected' });
});

test('readiness requires authorized notifications and matching versions; provisional is not ready', async () => {
  const { c, socket } = await readyController();
  assert.equal(c.readiness().ready, true);
  c.handleDeviceText(socket, hello({ notificationAuthorization: 'provisional' }));
  assert.deepEqual(c.readiness().reasons, ['notifications-provisional']);
  c.handleDeviceText(socket, hello({ resourceVersion: 1 }));
  assert.ok(c.readiness().reasons.includes('resource-version-mismatch'));
});

test('tsunami: verifies immutable asset; local source when no 552 data; same session', async () => {
  const order = [];
  const { c, socket, sent } = await readyController({ order, fetchImpl: async (url) => new Response(url.includes('552') ? '[]' : LIVE) });
  const run = c.startRun({ scenario: 'earthquake-tsunami' });
  await settle();
  c.handleDeviceText(socket, ack(run.runId));
  const cmd = await c.sendTsunami();
  const update = sent.at(-1);
  assert.deepEqual(order.slice(-2), ['wallpaper:tsunami', 'send:hazard-update']);
  assert.equal(update.sessionId, run.runId);
  assert.equal(update.source, 'local');
  assert.equal(update.tsunami, null, 'no fabricated sourceEventId');
  assert.equal(update.hazardRevision, 1);
  c.handleDeviceText(socket, JSON.stringify({ schemaVersion: 2, type: 'notification-ack', commandId: cmd.commandId, sessionId: run.runId, hazardRevision: 1, stateRevision: 3, status: 'scheduled' }));
  assert.equal(cmd.status, 'scheduled');
});

// ---------- HTTP boundary ----------
test('local-only guard: Host, tunnel headers and Origin', () => {
  assert.equal(isLocalRequest({ headers: { host: 'localhost:8788' } }, 8788), true);
  assert.equal(isLocalRequest({ headers: { host: 'abc.trycloudflare.com' } }, 8788), false);
  assert.equal(isLocalRequest({ headers: { host: '127.0.0.1:8788', 'cf-connecting-ip': '1.2.3.4' } }, 8788), false);
  assert.equal(isLocalRequest({ headers: { host: '127.0.0.1:8788', 'x-forwarded-for': '1.2.3.4' } }, 8788), false);
  assert.equal(originAllowed({ headers: { origin: 'http://localhost:8788' } }, 8788), true);
  assert.equal(originAllowed({ headers: { origin: 'https://evil.example' } }, 8788), false);
  assert.equal(bearerMatches('Bearer abc', 'abc'), true);
  assert.equal(bearerMatches('Bearer abd', 'abc'), false);
  assert.equal(bearerMatches(undefined, 'abc'), false);
});

test('server: token is never reachable through the tunnel; public routes are allowlisted', async () => {
  const stateDir = await tmp();
  const port = 18788 + Math.floor(Math.random() * 1000);
  const app = await createDemoServer({ port, stateDir, log: noLog, fetchImpl: fetchReturning(LIVE) });
  const base = `http://127.0.0.1:${port}`;
  try {
    const viaTunnel = await fetch(`${base}/api/status`, { headers: { 'cf-connecting-ip': '1.2.3.4', 'x-forwarded-for': '1.2.3.4' } });
    assert.equal(viaTunnel.status, 403);
    const local = await (await fetch(`${base}/api/status`)).json();
    assert.equal(local.pairingString, null);
    const health = await (await fetch(`${base}/public/health`)).text();
    assert.ok(!health.includes(app.token));
    const wp = await fetch(`${base}/public/assets/wallpapers/tsunami.png`);
    assert.equal(wp.status, 200);
    assert.equal(wp.headers.get('content-type'), 'image/png');
    assert.equal(wp.headers.get('cache-control'), 'no-store, no-cache, must-revalidate, max-age=0');
    assert.equal((await fetch(`${base}/public/languages/../../package.json`)).status, 404);
    assert.equal((await fetch(`${base}/public/languages/fr.json`)).status, 404);
    assert.equal((await fetch(`${base}/public/languages/ja.json`)).status, 200);
    assert.equal((await fetch(`${base}/public/shortcuts/../manifest.json`)).status, 404);
    const crossOrigin = await fetch(`${base}/api/demo/run`, { method: 'POST', headers: { origin: 'https://evil.example', 'content-type': 'application/json' }, body: '{}' });
    assert.equal(crossOrigin.status, 403);
    const big = await fetch(`${base}/api/config`, { method: 'POST', headers: { origin: base }, body: 'x'.repeat(9000) });
    assert.equal(big.status, 413);
    const cfg = await (await fetch(`${base}/api/config`, { method: 'POST', headers: { origin: base }, body: JSON.stringify({ origin: 'https://demo.example.com' }) })).json();
    assert.match(cfg.pairingString, /^wss:\/\/demo\.example\.com\/public\/device\?token=[A-Za-z0-9_-]{43}$/);
    // WebSocket: bearer required; multiple phones may connect.
    await assert.rejects(new Promise((res, rej) => { const ws = new WebSocket(`ws://127.0.0.1:${port}/public/device`); ws.on('open', res); ws.on('error', rej); }));
    const ws1 = new WebSocket(`ws://127.0.0.1:${port}/public/device`, { headers: { authorization: `Bearer ${app.token}` } });
    await new Promise((res, rej) => { ws1.on('open', res); ws1.on('error', rej); });
    const ws2 = new WebSocket(`ws://127.0.0.1:${port}/public/device`, { headers: { authorization: `Bearer ${app.token}` } });
    await new Promise((res, rej) => { ws2.on('open', res); ws2.on('error', rej); });
    ws2.close();
    ws1.close();
  } finally {
    await app.close();
  }
});

// ---------- languages & data ----------
test('bundled language packages are complete and consistent', async () => {
  const required = loadRequiredKeys();
  for (const id of ['en', 'ja', 'ko']) {
    const pkg = JSON.parse(await readFile(join(ROOT, 'assets/languages', `${id}.json`), 'utf8'));
    assert.deepEqual(validatePackage(pkg, required, `${id}.json`), [], id);
  }
});

test('language validation rejects missing keys, empty strings, placeholder drift and bad ids', async () => {
  const required = loadRequiredKeys();
  const pkg = JSON.parse(await readFile(join(ROOT, 'assets/languages/en.json'), 'utf8'));
  const broken = structuredClone(pkg);
  delete broken.strings['guide.unsafeButton'];
  broken.strings['training.badge'] = ' ';
  broken.strings['distance.straight'] = 'Distance {dist}';
  broken.languageId = 'english!';
  const errors = validatePackage(broken, required);
  for (const e of ['missing:guide.unsafeButton', 'empty:training.badge', 'placeholders:distance.straight', 'languageId']) assert.ok(errors.includes(e), e);
  const fourth = { ...structuredClone(pkg), languageId: 'vi', displayName: 'Vietnamese', nativeName: 'Tiếng Việt' };
  assert.deepEqual(validatePackage(fourth, required, 'vi.json'), [], 'a fourth language needs no code change');
});

test('evacuation import: column names, flags, exclusions, stable hash id, conflict detection', () => {
  const header = ['NO', '共通ID', '都道府県名及び市町村名', '施設・場所名', '住所', '地震', '津波', '緯度', '経度', '備考'];
  const rows = [header,
    ['1', 'E1', '宮城県仙台市', 'A公園', '住所A', '1', '', '38.1', '140.8', ''],
    ['2', '', '宮城県仙台市', 'B高台', '住所B', '', '1', '38.2', '140.9', '備考'],
    ['3', 'E3', '宮城県仙台市', 'C', '住所C', '', '', '38.3', '140.9', ''],
    ['4', 'E4', '宮城県仙台市', '', '住所D', '1', '', '38.3', '140.9', ''],
    ['5', 'E5', '宮城県仙台市', 'E', '住所E', '1', '', '200', '140.9', '']];
  const { sites, excluded } = convertRows(rows);
  assert.equal(sites.length, 2);
  assert.deepEqual(excluded, { missingName: 1, invalidCoordinate: 1, noEarthquakeOrTsunami: 1, duplicate: 0 });
  const b = sites.find((s) => s.name === 'B高台');
  assert.match(b.id, /^gsi:sha256:[0-9a-f]{64}$/);
  assert.equal(b.supportsTsunami, true);
  assert.equal(b.supportsEarthquake, false);
  assert.throws(() => convertRows([header, rows[1], ['9', 'E1', '宮城県仙台市', 'A公園', '別住所', '1', '', '38.1', '140.8', '']]), /conflicting-duplicate/);
  assert.equal(convertRows([header, rows[1], rows[1]]).excluded.duplicate, 1);
});
