import assert from 'node:assert/strict';
import { once } from 'node:events';
import { readFile, mkdtemp } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import WebSocket from 'ws';
import { SHORTCUTS, workflow, notificationTrigger } from '../scripts/shortcut-workflows.mjs';
import { inspectSignedShortcut } from '../scripts/inspect-signed-shortcut.mjs';
import { createDemoServer, renderSetupPage } from '../server/demo/server.mjs';
import { AssetStore } from '../server/demo/assets.mjs';
import { ROOT, sha256 } from '../server/demo/util.mjs';

test('each offline shortcut contains exactly its approved PNG and no network or file dependency', async () => {
  const hashes = new Set();
  for (const shortcut of SHORTCUTS) {
    const png = await readFile(join(ROOT, `assets/wallpapers/${shortcut.id}.png`));
    const appPng = await readFile(join(ROOT, `nigeyo-ios/Nigeyo/Resources/Wallpapers/${shortcut.id}.png`));
    assert.deepEqual(appPng, png);
    const w = workflow(png, shortcut);
    const actions = w.WFWorkflowActions;
    assert.equal(actions.length, 5);
    const embedded = Buffer.from(actions[0].WFWorkflowActionParameters.WFTextActionText, 'base64');
    assert.deepEqual(embedded, png);
    hashes.add(sha256(embedded));
    assert.equal(actions[1].WFWorkflowActionParameters.WFEncodeMode, 'Decode');
    assert.equal(actions[2].WFWorkflowActionIdentifier, 'is.workflow.actions.detect.images');
    assert.equal(actions[3].WFWorkflowActionIdentifier, 'is.workflow.actions.wallpaper.set');
    assert.equal(actions[3].WFWorkflowActionParameters.WFWallpaperShowPreview, false);
    assert.equal(actions[4].WFWorkflowActionParameters.WFInput, 'nigeyo://guide');
    assert.equal(w.WFWorkflowImportQuestions.length, 0);
    assert.ok(!JSON.stringify(w).includes('https://'));
    assert.ok(!JSON.stringify(w).includes('downloadurl'));
    assert.ok(!JSON.stringify(w).includes('getfile'));
  }
  assert.equal(hashes.size, 2, 'hazards must have different images');
  const assets = new AssetStore();
  await assets.load();
  assert.deepEqual(assets.wallpaper('earthquake'), await assets.verifyWallpaper('earthquake'));
  assert.equal(assets.wallpaper(), null, 'no shared mutable image');
});

test('setup explains two filtered automations and migration away from the catch-all', () => {
  const page = renderSetupPage({ shortcuts: SHORTCUTS.map((s) => ({ ...s, file: `nigeyo-${s.id}.shortcut`, version: '1.2.0' })) });
  for (const s of SHORTCUTS) {
    assert.ok(page.includes(s.triggerTitle));
    assert.ok(page.includes(`/public/shortcuts/nigeyo-${s.id}.shortcut`));
  }
  assert.ok(page.includes('同梱'));
  assert.ok(page.includes('無効'));
  assert.ok(!page.includes('YOUR-TUNNEL'));
});

test('native automation headers bind each title to Nigeyo, with fresh trigger ids', () => {
  const ids = new Set();
  for (const s of SHORTCUTS) {
    const w = workflow(Buffer.from('test'), s);
    assert.equal(w.WFWorkflowTriggers.length, 1);
    const t = w.WFWorkflowTriggers[0];
    assert.equal(t.WFTriggerIdentifier, 'WFNotificationTrigger');
    assert.match(t.WFTriggerUUID, /^[A-F0-9]{8}-(?:[A-F0-9]{4}-){3}[A-F0-9]{12}$/);
    ids.add(t.WFTriggerUUID);
    const p = t.WFTriggerSerializedParameters;
    assert.deepEqual(p.SelectedApps, { BundleIdentifier: 'jp.nigeyo.hackathon', Name: 'Nigeyo' });
    assert.equal(p.Conditions.WFSerializationType, 'WFContentPredicateTableTemplate');
    assert.deepEqual(p.Conditions.Value.WFActionParameterFilterTemplates,
      [{ Property: 'Title', Operator: 0, Values: { Title: s.triggerTitle }, Removable: true }]);
    assert.notEqual(t.WFTriggerUUID, notificationTrigger(s.triggerTitle).WFTriggerUUID);
  }
  assert.equal(ids.size, 2);
  assert.throws(() => workflow(Buffer.from('test')), /unsupported-notification-title/);
  assert.throws(() => notificationTrigger('OTHER_APP'), /unsupported-notification-title/);
  assert.throws(() => notificationTrigger('EARTHQUAKE_TEST', ''), /invalid-app-bundle-id/);
  assert.equal(notificationTrigger('EARTHQUAKE_TEST', 'jp.nigeyo.hackathon.alice').WFTriggerSerializedParameters.SelectedApps.BundleIdentifier,
    'jp.nigeyo.hackathon.alice');
});

test('downloaded signed shortcuts and ZIP match the distributed manifest and approved images', async () => {
  const manifest = JSON.parse(await readFile(join(ROOT, 'assets/shortcuts/manifest.json'), 'utf8'));
  assert.equal(manifest.stepsVersion, 3);
  assert.deepEqual(manifest.shortcuts.map((s) => s.id), ['earthquake', 'tsunami']);
  for (const s of manifest.shortcuts) {
    assert.equal(s.signed, true);
    assert.equal(s.imageStorage, 'embedded-base64');
    assert.equal(s.automation.included, true);
    assert.equal(s.automation.titleContains, s.triggerTitle);
    assert.equal(s.automation.appBundleIdentifier, 'jp.nigeyo.hackathon');
    assert.equal(s.imageSHA256, sha256(await readFile(join(ROOT, 'assets/wallpapers', s.imageFile))));
    assert.equal(s.sha256, sha256(await readFile(join(ROOT, 'assets/shortcuts', s.file))));
  }
  assert.equal(manifest.bundle.sha256, sha256(await readFile(join(ROOT, 'assets/shortcuts', manifest.bundle.file))));
});

test('actual signed distribution archives contain both native triggers and their exact offline images', { skip: process.platform !== 'darwin' }, async () => {
  const ids = new Set();
  for (const s of SHORTCUTS) {
    const w = inspectSignedShortcut(join(ROOT, `assets/shortcuts/nigeyo-${s.id}.shortcut`));
    const trigger = w.WFWorkflowTriggers[0];
    ids.add(trigger.WFTriggerUUID);
    assert.equal(trigger.WFTriggerIdentifier, 'WFNotificationTrigger');
    const p = trigger.WFTriggerSerializedParameters;
    assert.deepEqual(p.SelectedApps, { BundleIdentifier: 'jp.nigeyo.hackathon', Name: 'Nigeyo' });
    assert.deepEqual(p.Conditions.Value.WFActionParameterFilterTemplates,
      [{ Property: 'Title', Operator: 0, Values: { Title: s.triggerTitle }, Removable: true }]);
    assert.deepEqual(Buffer.from(w.WFWorkflowActions[0].WFWorkflowActionParameters.WFTextActionText, 'base64'),
      await readFile(join(ROOT, `assets/wallpapers/${s.id}.png`)));
    assert.equal(w.WFWorkflowActions.at(-1).WFWorkflowActionParameters.WFInput, 'nigeyo://guide');
  }
  assert.equal(ids.size, 2);
});

const live = JSON.stringify([{ code: 551, id: 'multi-device-test', earthquake: { time: '2026/10/24 12:44:00', maxScale: 10, hypocenter: { name: 'test', magnitude: 2.9 } }, issue: { time: '2026/10/24 12:47:28' } }]);
const hello = (id, language) => ({ schemaVersion: 2, type: 'hello', installationId: id, preferredLanguage: language,
  appVersion: '1.1.0', notificationAuthorization: 'authorized', resourceVersion: 2, languagePackageVersion: 1, liveActivitiesEnabled: true });
const waitFor = async (predicate) => {
  for (let i = 0; i < 150; i++) {
    if (await predicate()) return;
    await new Promise((r) => setTimeout(r, 10));
  }
  assert.fail('timed out waiting for test state');
};

test('two live WebSockets get different concurrent hazards; ACKs, retry and reset stay on their phone', async () => {
  const pending = [];
  const timers = {
    setTimeout(fn) { const timer = { fn, cleared: false }; pending.push(timer); return timer; },
    clearTimeout(timer) { timer.cleared = true; },
  };
  const app = await createDemoServer({ port: 0, timers, stateDir: await mkdtemp(join(tmpdir(), 'nigeyo-multi-')), log: async () => {},
    fetchImpl: async (url) => new Response(url.includes('552') ? '[]' : live) });
  const port = app.server.address().port;
  const base = `http://127.0.0.1:${port}`;
  const headers = { origin: base, 'content-type': 'application/json' };
  const status = async () => (await fetch(`${base}/api/status`, { headers })).json();
  const post = (path, body) => fetch(base + path, { method: 'POST', headers, body: JSON.stringify(body) });
  const sockets = [];
  try {
    const messages = [[], []];
    for (let i = 0; i < 2; i++) {
      const ws = new WebSocket(`ws://127.0.0.1:${port}/public/device`, { headers: { authorization: `Bearer ${app.token}` } });
      sockets.push(ws);
      ws.on('message', (data) => messages[i].push(JSON.parse(data)));
      await once(ws, 'open');
      ws.send(JSON.stringify(hello(i ? 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb' : 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', i ? 'en' : 'ja')));
    }
    await waitFor(async () => (await status()).devices.filter((d) => d.device.language).length === 2);
    const initial = await status();
    const [nagoya, tokyo] = initial.devices;
    assert.equal((await post('/api/demo/run', { scenario: 'earthquake' })).status, 409, 'multiple phones require an explicit target');
    assert.equal((await post('/api/demo/run', { scenario: 'earthquake', deviceId: 'missing' })).status, 404);
    const responses = await Promise.all([
      post('/api/demo/run', { deviceId: nagoya.id, scenario: 'earthquake-tsunami' }),
      post('/api/demo/run', { deviceId: tokyo.id, scenario: 'tsunami' }),
    ]);
    assert.deepEqual(responses.map((r) => r.status), [202, 202]);
    const starts = await Promise.all(responses.map((r) => r.json()));
    await waitFor(() => messages.every((m) => m.length === 1));
    assert.equal(messages[0][0].hazard, 'earthquake');
    assert.equal(messages[0][0].language, 'ja');
    assert.equal(messages[1][0].hazard, 'tsunami');
    assert.equal(messages[1][0].language, 'en');
    assert.notEqual(starts[0].runId, starts[1].runId);
    const ack = (runId) => JSON.stringify({ schemaVersion: 2, type: 'notification-ack', runId, status: 'scheduled' });
    sockets[1].send(ack(starts[0].runId));
    await new Promise((r) => setTimeout(r, 30));
    assert.equal((await status()).devices[0].run.ack, null, 'another phone cannot ACK the Nagoya run');
    sockets[1].send(ack(starts[1].runId));
    await waitFor(async () => (await status()).devices[1].run.status === 'scheduled');
    for (const t of pending.splice(0)) if (!t.cleared) t.fn();
    await waitFor(() => messages[0].length === 2);
    assert.equal(messages[0][1].runId, starts[0].runId);
    assert.equal(messages[1].length, 1, 'only the unacknowledged phone is retried');
    sockets[0].send(ack(starts[0].runId));
    await waitFor(async () => (await status()).devices.every((d) => d.run.status === 'scheduled'));
    assert.equal((await post('/api/demo/tsunami', { deviceId: nagoya.id })).status, 202);
    await waitFor(() => messages[0].length === 3);
    assert.equal(messages[0][2].type, 'hazard-update');
    assert.equal(messages[0][2].sessionId, starts[0].runId);
    assert.equal(messages[1].length, 1, 'the update never goes to Tokyo');
    assert.equal((await post('/api/demo/reset', { deviceId: tokyo.id })).status, 200);
    const latest = await status();
    assert.equal(latest.devices[1].run, null);
    assert.equal(latest.devices[0].run.runId, starts[0].runId);
    assert.equal((await fetch(`${base}/public/assets/wallpaper.png`)).status, 410);
    assert.equal((await fetch(`${base}/public/shortcuts/nigeyo-nigeyo.shortcut`)).status, 404);
    assert.equal((await fetch(`${base}/public/assets/wallpapers/earthquake.png`)).status, 200);
    assert.equal((await fetch(`${base}/public/assets/wallpapers/tsunami.png`)).status, 200);
    const detached = once(sockets[0], 'close');
    sockets[0].close();
    await detached;
    await waitFor(async () => (await status()).devices.length === 1);
    assert.equal((await post('/api/demo/run', { deviceId: nagoya.id, scenario: 'earthquake' })).status, 404, 'stale target must not redirect to Tokyo');
    assert.equal((await status()).devices[0].run, null);
  } finally {
    for (const ws of sockets) ws.terminate();
    await app.close();
  }
});
