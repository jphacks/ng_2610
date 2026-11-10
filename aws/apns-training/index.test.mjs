import assert from "node:assert/strict";
import { generateKeyPairSync, verify } from "node:crypto";
import { connect, createServer } from "node:http2";
import { test } from "node:test";
import { makeHandler, sendToAPNs } from "./index.mjs";

const { privateKey, publicKey } = generateKeyPairSync("ec", { namedCurve: "prime256v1" });
const config = {
  teamId: "TEAM123456",
  keyId: "KEY1234567",
  privateKey: privateKey.export({ format: "pem", type: "pkcs8" }),
  bundleId: "jp.nigeyo.hackathon",
  deviceToken: "aabb",
};
const secret = (version, fields = config) => ({ VersionId: version, SecretString: JSON.stringify(fields) });

test("sends only fixed drills over HTTP/2 with a valid ES256 token and matching expiry", async (t) => {
  const received = [];
  const server = createServer();
  server.on("stream", (stream, headers) => {
    let body = "";
    stream.setEncoding("utf8");
    stream.on("data", (chunk) => { body += chunk; });
    stream.on("end", () => {
      received.push({ headers, payload: JSON.parse(body) });
      stream.respond({ ":status": received.length === 1 ? 200 : 410 });
      stream.end();
    });
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  t.after(() => server.close());

  const now = Date.parse("2026-11-10T06:00:00Z");
  let activeSecret = secret("first");
  const handler = makeHandler({
    loadSecret: async () => activeSecret,
    now: () => now,
    send: (headers, payload) => sendToAPNs(headers, payload, (origin) => {
      assert.equal(origin, "https://api.push.apple.com");
      return connect(`http://127.0.0.1:${server.address().port}`);
    }),
  });

  const quake = await handler({ hazard: "earthquake" });
  activeSecret = secret("second", { ...config, deviceToken: "ccdd" });
  const tsunami = await handler({ hazard: "tsunami" });
  assert.equal(quake.accepted, true);
  assert.equal(tsunami.accepted, false);
  assert.equal(tsunami.apnsStatus, 410);
  assert.notEqual(quake.eventId, tsunami.eventId);
  assert.deepEqual(received.map(({ headers }) => headers[":path"]), ["/3/device/aabb", "/3/device/ccdd"]);

  for (const [index, result] of [quake, tsunami].entries()) {
    const { headers, payload } = received[index];
    const hazard = index === 0 ? "earthquake" : "tsunami";
    assert.equal(headers[":method"], "POST");
    assert.equal(headers["apns-topic"], config.bundleId);
    assert.equal(headers["apns-push-type"], "alert");
    assert.equal(headers["apns-id"], result.eventId);
    assert.equal(Number(headers["apns-expiration"]), now / 1000 + 120);
    assert.equal(payload.nigeyoType, "remote-training");
    assert.equal(payload.eventId, result.eventId);
    assert.equal(payload.hazard, hazard);
    assert.equal(Date.parse(payload.expiresAt), now + 120_000);
    assert.equal(payload.aps.alert.title, `${hazard.toUpperCase()}_TEST`);
    assert.match(payload.aps.alert.body, /^【訓練】/);

    const [head, claims, signature] = headers.authorization.slice("bearer ".length).split(".");
    assert.deepEqual(JSON.parse(Buffer.from(head, "base64url")), { alg: "ES256", kid: config.keyId });
    assert.deepEqual(JSON.parse(Buffer.from(claims, "base64url")), { iss: config.teamId, iat: now / 1000 });
    assert.equal(verify("sha256", Buffer.from(`${head}.${claims}`),
      { key: publicKey, dsaEncoding: "ieee-p1363" }, Buffer.from(signature, "base64url")), true);
  }
});

test("rejects caller-selected destinations and redacts failures", async () => {
  const handler = makeHandler({
    loadSecret: async () => secret("test"),
    send: async () => { throw new Error("must not expose the request path or authorization header"); },
  });
  for (const event of [null, { hazard: "live" }, { hazard: ["tsunami"] }, { hazard: "earthquake", deviceToken: "ff" }]) {
    assert.deepEqual(await handler(event), { accepted: false, error: "expected_earthquake_or_tsunami" });
  }
  const { eventId, ...failure } = await handler({ hazard: "earthquake" });
  assert.ok(eventId);
  assert.deepEqual(failure, { accepted: false, error: "apns_transport_failed" });
  const unavailable = makeHandler({ loadSecret: async () => secret("invalid", { ...config, privateKey: "invalid" }) });
  assert.equal((await unavailable({ hazard: "earthquake" })).error, "apns_configuration_unavailable");
});
