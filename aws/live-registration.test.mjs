import assert from "node:assert/strict";
import { test } from "node:test";
import { setTimeout as delay } from "node:timers/promises";
import { disabledSubscription, registrationHandler } from "./live-registration.mjs";
import { earthquakeAreaId } from "../server/monitoring/regions.mjs";

test("only the provisioned device can enable or clear a validated subscription", async () => {
  const writes = [];
  const handler = registrationHandler({
    getDevices: async () => [{ id: "tokyo", deviceToken: "aa".repeat(32) }, { id: "osaka", deviceToken: "cc".repeat(32) }],
    save: async (device, value) => { writes.push([device.id, value]); },
  });
  const area = { pref: "東京", name: "東京都２３区" };
  const subscription = { version: 2, enabled: true, targets: [{
    slot: "home.earthquake", siteId: "home", earthquakeArea: area,
    earthquakeAreaId: earthquakeAreaId(area),
    tsunamiStatus: "none", tsunamiAreas: [], tsunamiAreaIds: [],
  }] };
  const put = (value, token = "AA".repeat(32)) => handler({
    headers: { authorization: `Bearer ${token}` }, body: JSON.stringify(value),
  });

  assert.equal((await put(subscription, "bb".repeat(32))).statusCode, 403);
  assert.equal((await put({ ...subscription, targets: [] })).statusCode, 400);
  assert.equal(writes.length, 0);
  assert.equal((await put(subscription)).statusCode, 204);
  assert.equal((await put(disabledSubscription, "cc".repeat(32))).statusCode, 204);
  assert.deepEqual(writes, [["tokyo", subscription], ["osaka", disabledSubscription]]);
});

test("worker uses app registration without a subscription in the signing secret", async (t) => {
  const { generateKeyPairSync } = await import("node:crypto");
  const { EventEmitter } = await import("node:events");
  const { runRegionalWorker } = await import("./regional-worker.mjs");
  const { privateKey } = generateKeyPairSync("ec", { namedCurve: "prime256v1" });
  const area = { pref: "東京", name: "東京都２３区" };
  const enabledSubscription = { version: 2, enabled: true, targets: [{
    slot: "home.earthquake", siteId: "home", earthquakeArea: area,
    earthquakeAreaId: earthquakeAreaId(area),
    tsunamiStatus: "none", tsunamiAreas: [], tsunamiAreaIds: [],
  }] };
  let subscription = disabledSubscription;
  class Feed extends EventEmitter {
    terminate() {}
  }
  const pushes = [];
  const monitor = await runRegionalWorker({
    stateStore: { load: async () => null, save: async () => {} },
    secret: JSON.stringify({
      teamId: "TEAM123456", keyId: "KEY1234567", bundleId: "jp.nigeyo.hackathon",
      deviceToken: "aabb", privateKey: privateKey.export({ format: "pem", type: "pkcs8" }),
    }),
    WebSocketImpl: Feed,
    now: () => Date.parse("2026-11-13T03:00:01+09:00"),
    subscriptionSource: async () => subscription,
    send: async (headers) => { pushes.push(headers[":path"]); return 200; },
    log: () => {},
  });
  t.after(() => monitor.stop());

  const event = {
    code: 556, id: "quake", cancelled: false, areas: [area],
    issue: { time: "2026/11/13 03:00:00", eventId: "first", serial: "1" },
  };
  assert.equal(monitor.status("aws-demo-device").enabled, false);
  subscription = enabledSubscription;
  for (let attempt = 0; attempt < 50 && !monitor.status("aws-demo-device").enabled; attempt++) {
    await delay(100);
  }
  assert.equal(monitor.status("aws-demo-device").enabled, true);
  await monitor.ingest(event);
  await monitor.queue;
  assert.deepEqual(pushes, ["/3/device/aabb"]);

  subscription = disabledSubscription;
  await monitor.ingest({ ...event, issue: { ...event.issue, eventId: "second" } });
  await monitor.queue;
  assert.deepEqual(pushes, ["/3/device/aabb"]);
});

test("four app-configured regions isolate both drill and live pushes", async (t) => {
  const { generateKeyPairSync } = await import("node:crypto");
  const { EventEmitter } = await import("node:events");
  const { makeHandler } = await import("./apns-training/index.mjs");
  const { runRegionalWorker } = await import("./regional-worker.mjs");
  const { tsunamiAreaId } = await import("../server/monitoring/regions.mjs");
  const { privateKey } = generateKeyPairSync("ec", { namedCurve: "prime256v1" });
  const areas = [
    ["tokyo", "東京", "東京都２３区", "東京湾内湾"],
    ["osaka", "大阪", "大阪府北部", "大阪府"],
    ["nagoya", "愛知", "愛知県西部", "伊勢・三河湾"],
    ["hakata", "福岡", "福岡県福岡", "福岡県日本海沿岸"],
  ];
  const devices = areas.map(([id], index) => ({ id, deviceToken: `0${index + 1}`.repeat(32) }));
  const secret = JSON.stringify({
    teamId: "TEAM123456", keyId: "KEY1234567", bundleId: "jp.nigeyo.hackathon",
    privateKey: privateKey.export({ format: "pem", type: "pkcs8" }), devices,
  });

  const subscriptions = new Map();
  const put = registrationHandler({
    getDevices: async () => devices,
    save: async (device, subscription) => { subscriptions.set(device.id, subscription); },
  });
  const register = (device, value) => put({
    headers: { authorization: `Bearer ${device.deviceToken}` },
    body: JSON.stringify(value),
  });
  const values = areas.map(([id, pref, name, tsunamiArea]) => {
    const earthquakeArea = { pref, name };
    return { version: 2, enabled: true, targets: [{
      slot: "home.earthquake", siteId: id, earthquakeArea, earthquakeAreaId: earthquakeAreaId(earthquakeArea),
      tsunamiStatus: "configured", tsunamiAreas: [tsunamiArea], tsunamiAreaIds: [tsunamiAreaId(tsunamiArea)],
    }] };
  });
  for (const [index, device] of devices.entries()) {
    assert.equal((await register(device, values[index])).statusCode, 204);
  }

  const subscriptionSource = async (device) => subscriptions.get(device.id) ?? disabledSubscription;
  const activity = { token: "ab".repeat(32), language: "ja" };
  const sends = [];
  const cards = [];
  const send = async (headers, payload) => {
    if (headers["apns-push-type"] === "liveactivity") cards.push({ headers, aps: payload.aps });
    else sends.push([headers[":path"], payload.aps.alert.title]);
    return 200;
  };
  const now = () => Date.parse("2026-11-13T03:00:05+09:00");
  const drill = makeHandler({
    loadSecret: async () => ({ VersionId: "v1", SecretString: secret }), subscriptionSource, send, now,
  });
  for (const [index, [id, , region]] of areas.entries()) {
    assert.deepEqual((await drill({ hazard: "earthquake", region })).results.map((r) => r.id), [id]);
    assert.deepEqual(sends.splice(0), [[`/3/device/${devices[index].deviceToken}`, "EARTHQUAKE_TEST"]]);
  }
  assert.equal((await register(devices[1], { ...values[1], activity: { ...activity, token: "invalid" } })).statusCode, 400);
  assert.equal((await register(devices[1], { ...values[1], activity })).statusCode, 204);
  const training = await drill({ hazard: "tsunami", region: "大阪府" });
  assert.equal(training.results[0].liveActivity.accepted, true);
  assert.equal(cards[0].headers[":path"], `/3/device/${activity.token}`);
  assert.equal(cards[0].headers["apns-topic"], "jp.nigeyo.hackathon.push-type.liveactivity");
  assert.equal(cards[0].aps.event, "start");
  assert.equal(cards[0].aps.attributes.sessionId, training.eventId);
  assert.equal(cards[0].aps["content-state"].layout, "tsunami");
  assert.equal(cards[0].aps["content-state"].badge, "訓練");
  cards.length = 0;
  assert.deepEqual(sends.splice(0), [[`/3/device/${devices[1].deviceToken}`, "TSUNAMI_TEST"]]);

  class Feed extends EventEmitter { terminate() {} }
  const updateToken = "bc".repeat(32);
  const monitor = await runRegionalWorker({
    stateStore: { load: async () => null, save: async () => {} },
    secret, WebSocketImpl: Feed, now, subscriptionSource, send, log: () => {},
    activityUpdateSource: async (device, hazard) => device.id === "osaka" && hazard === "earthquake"
      ? { token: updateToken, sourceEventId: "osaka-event", issuedAt: "2026-11-13T03:00:00+09:00" }
      : undefined,
  });
  t.after(() => monitor.stop());
  const event = {
    code: 556, id: "quake", cancelled: false, areas: [{ pref: "大阪", name: "大阪府北部" }],
    issue: { time: "2026/11/13 03:00:00", eventId: "osaka-event", serial: "1" },
  };
  await monitor.ingest(event);
  await monitor.queue;
  assert.deepEqual(sends.splice(0), [[`/3/device/${devices[1].deviceToken}`, "EARTHQUAKE_ALERT"]]);
  assert.equal(cards[0].headers[":path"], `/3/device/${activity.token}`);
  assert.equal(cards[0].aps["content-state"].badge, undefined);
  assert.equal(cards[0].aps["content-state"].layout, "protect");
  const command = JSON.parse(cards[0].aps.attributes.regionalAlert);
  assert.equal(command.mode, "live");
  assert.equal(command.commandId, cards[0].aps.attributes.sessionId);
  await monitor.ingest({ ...event, cancelled: true, areas: [], issue: { ...event.issue, serial: "2" } });
  await monitor.queue;
  assert.equal(cards[1].headers[":path"], `/3/device/${updateToken}`);
  assert.equal(cards[1].aps.event, "end");
  assert.equal(cards[1].aps["content-state"].interactive, false);
  await monitor.ingest({
    code: 552, id: "tsunami", cancelled: false, issue: { time: "2026/11/13 03:00:01", type: "Focus" },
    areas: [{ name: "福岡県日本海沿岸", grade: "Warning" }],
  });
  await monitor.queue;
  assert.deepEqual(sends.splice(0), [[`/3/device/${devices[3].deviceToken}`, "TSUNAMI_ALERT"]]);

  assert.equal((await register(devices[1], disabledSubscription)).statusCode, 204);
  assert.equal((await drill({ hazard: "earthquake", region: "大阪府北部" })).error, "no_devices_in_region");
  await monitor.ingest({ ...event, issue: { ...event.issue, eventId: "after-disable" } });
  await monitor.queue;
  assert.deepEqual(sends, []);

  assert.equal((await register(devices[1], values[0])).statusCode, 204);
  assert.equal((await drill({ hazard: "earthquake", region: "大阪府北部" })).error, "no_devices_in_region");
  assert.deepEqual((await drill({ hazard: "earthquake", region: "東京都２３区" })).results.map((r) => r.id),
    ["tokyo", "osaka"]);
});
