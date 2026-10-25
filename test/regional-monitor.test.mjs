import assert from 'node:assert/strict';
import { test } from 'node:test';
import { mkdtemp, readFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { EventEmitter } from 'node:events';
import { evaluate, initialState } from '../server/monitoring/engine.mjs';
import { regions, resolveRegion, validSubscription } from '../server/monitoring/regions.mjs';
import { RegionalMonitor } from '../server/monitoring/service.mjs';

const now = new Date('2026-10-25T10:00:05+09:00');
const area = { pref: '愛知', name: '愛知県西部' };
const target = (slot = 'home.earthquake', extra = {}) => ({ slot, siteId: slot, earthquakeArea: area, tsunamiStatus: 'configured', tsunamiAreas: ['伊勢・三河湾'], ...extra });
const subscription = { version: 1, enabled: true, targets: [target(), target('university.earthquake')] };
const eew = (serial = 1, extra = {}) => ({ code: 556, id: `e-${serial}`, issue: { time: '2026/10/25 10:00:00', eventId: 'event', serial: String(serial) }, cancelled: false, areas: [area], ...extra });
const tsunami = (second, grade = 'Watch', extra = {}) => ({ code: 552, id: `t-${second}`, issue: { time: `2026/10/25 10:00:${String(second).padStart(2, '0')}`, type: 'Focus' }, cancelled: false, areas: [{ name: '伊勢・三河湾', grade }], ...extra });
const run = (item, state, sub = subscription) => evaluate(item, sub, state, { now: new Date(+now + 60000) });

test('Aichi municipality mapping covers 54 municipalities, official names and inland/ambiguous cases', () => {
  assert.equal(regions.municipalities.length, 54);
  assert.deepEqual(resolveRegion({ address: '愛知県名古屋市千種区不老町' }).earthquakeArea, area);
  assert.equal(resolveRegion({ municipality: '愛知県知多郡美浜町' }).tsunamiStatus, 'configured');
  assert.equal(resolveRegion({ municipality: '愛知県日進市' }).tsunamiStatus, 'none');
  assert.equal(resolveRegion({ municipality: '愛知県豊橋市' }).tsunamiStatus, 'unconfigured');
  assert.equal(resolveRegion({ address: '愛知県田原市' }).tsunamiStatus, 'unconfigured');
  assert.equal(resolveRegion({ municipality: '美浜町' }), null);
  assert.equal(resolveRegion({ address: '福井県美浜町', municipality: '美浜町' }), null);
  assert.equal(resolveRegion({ address: '愛知県名古屋市', municipality: '豊橋市' }), null);
  assert.equal(resolveRegion({ address: '愛知県不明市' }), null);
  assert.equal(resolveRegion({ address: '東京都府中市' }), null);
});

test('subscriptions reject unknown, unconfirmed, duplicate slots and ambiguous tsunami configuration', () => {
  assert(validSubscription(subscription));
  assert(!validSubscription({ ...subscription, targets: [] }));
  assert(!validSubscription({ ...subscription, targets: [target(), target()] }));
  assert(!validSubscription({ ...subscription, targets: [target('home.earthquake', { tsunamiStatus: 'unconfigured' })] }));
  assert(!validSubscription({ ...subscription, targets: [target('home.earthquake', { earthquakeArea: { pref: '愛知県', name: '愛知県西部' } })] }));
  assert(!validSubscription({ ...subscription, targets: [target('home.earthquake', { tsunamiStatus: 'none' })] }));
  assert(validSubscription({ ...subscription, targets: [target('home.earthquake', { tsunamiStatus: 'none', tsunamiAreas: [] })] }));
});

test('556 groups home and school into one notification, without additional intensity/arrival checks', () => {
  const first = run(eew(), initialState());
  assert(first.action.notify);
  assert.equal(first.action.matches.length, 2);
  assert.equal(run(eew(), first.state).action, null);
  assert.equal(run(eew(2), first.state).action, null);
  assert.equal(run(eew(0), first.state).action, null);
  assert.equal(first.action.mode, 'live');
  assert.equal(run({ code: 551 }, initialState()).action, null);
});

test('later 556 revision can newly include region, cancellation does not create a new alert', () => {
  const outside = run(eew(1, { areas: [{ pref: '北海道道北', name: '上川地方北部' }] }), initialState());
  assert.equal(outside.action, null);
  const added = run(eew(2), outside.state);
  assert(added.action.notify);
  const cancelled = run(eew(3, { cancelled: true, areas: undefined }), added.state);
  assert.equal(cancelled.action.status, 'cancelled');
  assert.equal(cancelled.action.notify, false);
  assert.equal(run(eew(4), cancelled.state).action, null);
});

test('training, stale, malformed and future events never notify or poison state', () => {
  for (const item of [eew(1, { test: true }), eew(1, { areas: null }), eew(1, { issue: { time: '2026/10/25 11:00:00', eventId: 'x', serial: '1' } }), eew(1, { issue: { time: '2020/01/01 00:00:00', eventId: 'x', serial: '1' } })]) {
    const result = run(item, initialState());
    assert.equal(result.action, null);
    assert.deepEqual(result.state, initialState());
  }
  assert.equal(evaluate(eew(), subscription, initialState(), { now, source: 'sandbox' }).action, null);
  assert.equal(run(eew(), initialState(), { ...subscription, enabled: false }).action, null);
});

test('552 notifies on escalation, stores downgrade, rejects old updates and handles empty all-clear', () => {
  let r = run(tsunami(0), initialState());
  assert.equal(r.action.grade, 'Watch');
  assert(r.action.notify);
  r = run(tsunami(1, 'Warning'), r.state);
  assert(r.action.notify);
  r = run(tsunami(2, 'MajorWarning'), r.state);
  assert(r.action.notify);
  let repeated = run(tsunami(3, 'MajorWarning'), r.state);
  assert.equal(repeated.action, null);
  r = run(tsunami(4, 'Watch'), repeated.state);
  assert.equal(r.action.notify, false);
  assert.equal(run(tsunami(1, 'Warning'), r.state).action, null);
  r = run(tsunami(5, 'Watch', { cancelled: true, areas: [] }), r.state);
  assert.equal(r.action.status, 'cancelled');
  assert.equal(r.action.notify, false);
  assert.equal(r.state.tsunami.areas['伊勢・三河湾'], 'Cancelled');
});

test('552 no TTL all-clear: old active warning persists; absence and Unknown never mean safe', () => {
  let r = evaluate(tsunami(0, 'Warning'), subscription, initialState(), { now: new Date('2026-10-26T10:00:00+09:00') });
  assert(r.action.notify, 'tsunami is not expired by a 5-minute notification TTL');
  r = run(tsunami(1, 'Unknown', { areas: [] }), r.state);
  assert.equal(r.action.status, 'unknown');
  assert.equal(r.action.notify, false);
  assert.equal(r.state.tsunami.areas['伊勢・三河湾'], 'Unknown');
});

class FakeSocket extends EventEmitter { terminate() {} }
test('monitor persists before delivery, isolates devices, retries same ID and dedupes across restart', async () => {
  const stateDir = await mkdtemp(join(tmpdir(), 'nigeyo-regional-'));
  const options = { stateDir, WebSocketImpl: FakeSocket, now: () => now };
  const monitor = new RegionalMonitor(options);
  await monitor.load();
  const sent = [], other = [];
  await monitor.configure('nagoya', subscription, (p) => sent.push(p));
  await monitor.configure('east', { ...subscription, targets: [target('home.earthquake', { earthquakeArea: { pref: '愛知', name: '愛知県東部' }, tsunamiStatus: 'none', tsunamiAreas: [] })] }, (p) => other.push(p));
  await monitor.ingest(eew());
  assert.equal(sent.length, 1);
  assert.equal(other.length, 0);
  const persisted = JSON.parse(await readFile(join(stateDir, 'regional-monitor.json')));
  assert.equal(persisted.records.nagoya.pending[0].commandId, sent[0].commandId);
  monitor.flush('nagoya');
  assert.equal(sent[1].commandId, sent[0].commandId);
  await monitor.acknowledge('nagoya', sent[0].commandId);
  monitor.stop();
  const again = new RegionalMonitor(options);
  await again.load();
  await again.configure('nagoya', subscription, (p) => sent.push(p));
  await again.ingest(eew(2));
  assert.equal(sent.length, 2);
  assert.equal(again.status('nagoya').state.eew.event.serial, 2);
  again.stop();
});

test('real server wire: hello config → national event → one alert → persisted ACK; manual demo unaffected', async () => {
  const { createDemoServer } = await import('../server/demo/server.mjs');
  const { default: WebSocket } = await import('ws');
  const stateDir = await mkdtemp(join(tmpdir(), 'nigeyo-regional-wire-'));
  const app = await createDemoServer({ port: 0, stateDir, log: async () => {}, monitorOptions: { WebSocketImpl: FakeSocket, now: () => now } });
  const ws = new WebSocket(`ws://127.0.0.1:${app.server.address().port}/public/device`, { headers: { Authorization: `Bearer ${app.token}` } });
  try {
    await new Promise((resolve, reject) => { ws.once('open', resolve); ws.once('error', reject); });
    const id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
    ws.send(JSON.stringify({ schemaVersion: 2, type: 'hello', installationId: id.toUpperCase(), preferredLanguage: 'en',
      notificationAuthorization: 'authorized', languagePackageVersion: 1, resourceVersion: 2, liveActivitiesEnabled: true, regionalSubscription: subscription }));
    // Wait for the websocket handler's asynchronous configuration transaction.
    for (let n = 0; n < 100 && !app.monitor.status(id).enabled; n++) await new Promise((r) => setTimeout(r, 5));
    assert(app.monitor.status(id).enabled);
    const received = new Promise((resolve) => ws.once('message', (m) => resolve(JSON.parse(m))));
    await app.monitor.ingest(eew());
    const command = await received;
    assert.equal(command.type, 'regional-alert');
    assert.equal(command.mode, 'live');
    assert.equal(command.matches.length, 2);
    ws.send(JSON.stringify({ schemaVersion: 2, type: 'regional-ack', commandId: command.commandId, status: 'stored' }));
    for (let n = 0; n < 100 && app.monitor.status(id).pending; n++) await new Promise((r) => setTimeout(r, 5));
    assert.equal(app.monitor.status(id).pending, 0);
    assert.equal(app.hub.target().run, null, 'automatic monitoring must not create a manual demo run');
  } finally { ws.terminate(); await app.close(); }
});

test('an unrelated earthquake cancellation cannot erase an unacknowledged earthquake alert', async () => {
  const monitor = new RegionalMonitor({ stateDir: await mkdtemp(join(tmpdir(), 'nigeyo-overlap-')), WebSocketImpl: FakeSocket, now: () => now });
  await monitor.load();
  await monitor.configure('nagoya', subscription, () => {});
  await monitor.ingest(eew());
  await monitor.ingest(eew(1, { id: 'other', issue: { time: '2026/10/25 10:00:01', eventId: 'other-event', serial: '1' } }));
  await monitor.ingest(eew(2, { cancelled: true, areas: [] }));
  assert.equal(monitor.records.nagoya.pending.length, 2);
  assert(monitor.records.nagoya.pending.some((p) => p.sourceEventId === 'other-event' && p.notify));
  monitor.stop();
});

test('storage failure rolls back registration and never delivers an uncommitted alert', async () => {
  const monitor = new RegionalMonitor({ stateDir: await mkdtemp(join(tmpdir(), 'nigeyo-storage-')), WebSocketImpl: FakeSocket, now: () => now });
  await monitor.load();
  let sends = 0;
  const save = monitor.save.bind(monitor);
  monitor.save = async () => { throw new Error('disk-full'); };
  await assert.rejects(monitor.configure('nagoya', subscription, () => sends++), /disk-full/);
  assert.equal(monitor.records.nagoya, undefined);
  monitor.save = save;
  await monitor.configure('nagoya', subscription, () => sends++);
  monitor.save = async () => { throw new Error('disk-full'); };
  await assert.rejects(monitor.ingest(eew()), /disk-full/);
  assert.equal(sends, 0);
  assert.deepEqual(monitor.records.nagoya.state, initialState());
  monitor.stop();
});
