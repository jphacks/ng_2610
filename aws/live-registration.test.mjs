import assert from "node:assert/strict";
import { test } from "node:test";
import { setTimeout as delay } from "node:timers/promises";
import { disabledSubscription, registrationHandler } from "./live-registration.mjs";
import { earthquakeAreaId } from "../server/monitoring/regions.mjs";

test("only the provisioned device can enable or clear a validated subscription", async () => {
  const writes = [];
  const handler = registrationHandler({
    getToken: async () => "aa".repeat(32),
    save: async (value) => { writes.push(value); },
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
  assert.equal((await put(disabledSubscription)).statusCode, 204);
  assert.deepEqual(writes, [subscription, disabledSubscription]);
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
