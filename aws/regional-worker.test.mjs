import assert from "node:assert/strict";
import { generateKeyPairSync } from "node:crypto";
import { EventEmitter } from "node:events";
import { test } from "node:test";
import { createRegionalStateStore } from "./regional-state.mjs";
import { runRegionalWorker } from "./regional-worker.mjs";

test("feed events reach APNs only for fresh, matching live warnings", async (t) => {
  let snapshot;
  let revision = 0;
  const client = {
    async send(command) {
      assert.equal(command.input.Key, "regional-monitor.json");
      if (command.constructor.name === "GetObjectCommand") {
        if (!revision) throw Object.assign(new Error(), { name: "NoSuchKey" });
        return { ETag: `"${revision}"`, Body: { transformToString: async () => snapshot } };
      }
      assert.equal(command.constructor.name, "PutObjectCommand");
      if (revision) assert.equal(command.input.IfMatch, `"${revision}"`);
      else assert.equal(command.input.IfNoneMatch, "*");
      snapshot = command.input.Body;
      return { ETag: `"${++revision}"` };
    },
  };
  const { privateKey } = generateKeyPairSync("ec", { namedCurve: "prime256v1" });
  const area = { pref: "愛知", name: "愛知県西部" };
  const secret = JSON.stringify({
    teamId: "TEAM123456", keyId: "KEY1234567", bundleId: "jp.nigeyo.hackathon", deviceToken: "aabb",
    privateKey: privateKey.export({ format: "pem", type: "pkcs8" }),
    subscription: { version: 1, enabled: true, targets: [{
      slot: "home.earthquake", siteId: "fixture", earthquakeArea: area,
      tsunamiStatus: "configured", tsunamiAreas: ["伊勢・三河湾"],
    }] },
  });
  class Feed extends EventEmitter {
    terminate() {}
  }
  const sent = [];
  let status = 200;
  let now = Date.parse("2026-11-10T12:00:10+09:00");
  const start = () => runRegionalWorker({
    stateStore: createRegionalStateStore({ bucket: "test", client }),
    secret, WebSocketImpl: Feed, now: () => now,
    send: async (headers, payload) => { sent.push({ headers, payload }); return status; }, log: () => {},
  });
  let monitor = await start();
  t.after(() => monitor.stop());

  const quake = {
    code: 556, id: "quake", cancelled: false, areas: [area],
    issue: { time: "2026/11/10 12:00:00", eventId: "fixture-event", serial: "1" },
  };
  const publish = async (event) => {
    monitor.ws.emit("message", Buffer.from(JSON.stringify(event)), false);
    await monitor.queue;
    await monitor.queue; // The mocked APNs response queues an outbox acknowledgment.
  };
  await publish({ ...quake, test: true });
  await publish({ ...quake, areas: [{ pref: "愛知", name: "愛知県東部" }] });
  await publish({ ...quake, issue: { ...quake.issue, time: "2026/11/10 11:57:00" } });
  assert.equal(sent.length, 0);
  await publish({ ...quake, issue: { ...quake.issue, serial: "2" } });
  await publish({ ...quake, issue: { ...quake.issue, serial: "2" } });
  await publish({ ...quake, cancelled: true, areas: [], issue: { ...quake.issue, serial: "3" } });
  await publish({
    code: 552, id: "tsunami", cancelled: false, issue: { time: "2026/11/10 12:00:02", type: "Focus" },
    areas: [{ name: "伊勢・三河湾", grade: "Warning" }],
  });
  assert.deepEqual(sent.map(({ payload }) => payload.aps.alert.title), ["EARTHQUAKE_ALERT", "TSUNAMI_ALERT"]);
  for (const { payload, headers } of sent) {
    const command = JSON.parse(payload.regionalAlert);
    assert.equal(payload.nigeyoType, "regional-alert");
    assert.equal(command.mode, "live");
    assert.equal(command.schemaVersion, 2);
    assert.equal(command.matches[0].siteId, "fixture");
    assert.equal(command.commandId, headers["apns-id"]);
    assert.equal(headers[":path"], "/3/device/aabb");
    assert.equal(Date.parse(command.expiresAt), Number(headers["apns-expiration"]) * 1000);
  }

  // A successful delivery stays deduplicated across task replacement.
  monitor.stop();
  monitor = await start();
  await publish({ ...quake, issue: { ...quake.issue, serial: "2" } });
  assert.equal(sent.length, 2);

  // A transient failure leaves a durable, unexpired command for the next task.
  status = 503;
  const laterQuake = { ...quake, issue: { ...quake.issue, eventId: "later-event" } };
  await publish(laterQuake);
  const pendingId = sent.at(-1).headers["apns-id"];
  assert.equal(sent.length, 3);
  assert.equal(monitor.status("aws-demo-device").pending, 1);
  monitor.stop();
  status = 200;
  monitor = await start();
  await monitor.queue;
  assert.equal(sent.length, 4);
  assert.equal(sent.at(-1).headers["apns-id"], pendingId);
  assert.equal(monitor.status("aws-demo-device").pending, 0);

  status = 503;
  await publish({ ...quake, issue: { ...quake.issue, eventId: "expired-event" } });
  monitor.stop();
  now += 120_000;
  monitor = await start();
  assert.equal(sent.length, 5);

});
