import { createPrivateKey, randomUUID, sign } from "node:crypto";
import { connect, sensitiveHeaders } from "node:http2";
import { GetSecretValueCommand, SecretsManagerClient } from "@aws-sdk/client-secrets-manager";

const drills = {
  earthquake: { title: "EARTHQUAKE_TEST", body: "【訓練】地震です。頭を守ってください。" },
  tsunami: { title: "TSUNAMI_TEST", body: "【訓練】津波です。高い場所へ避難してください。" },
};
const ttlSeconds = 120;
const apnsOrigin = "https://api.push.apple.com";
const secrets = new SecretsManagerClient({ maxAttempts: 1 });

export function readConfig(value) {
  const { teamId, keyId, privateKey, bundleId, deviceToken } = JSON.parse(value);
  if (typeof teamId !== "string" || !/^[A-Z0-9]{10}$/.test(teamId) ||
      typeof keyId !== "string" || !/^[A-Z0-9]{10}$/.test(keyId) ||
      typeof bundleId !== "string" || !/^[a-zA-Z0-9-]+(?:\.[a-zA-Z0-9-]+)+$/.test(bundleId) ||
      typeof deviceToken !== "string" || !/^(?:[a-fA-F0-9]{2})+$/.test(deviceToken)) {
    throw new Error("Invalid APNs configuration");
  }
  const key = createPrivateKey(privateKey);
  if (key.asymmetricKeyType !== "ec" || key.asymmetricKeyDetails.namedCurve !== "prime256v1") {
    throw new Error("Invalid APNs key type");
  }
  return { teamId, keyId, key, bundleId, deviceToken };
}

export function providerToken({ keyId, teamId, key }, issuedAt) {
  const encode = (value) => Buffer.from(JSON.stringify(value)).toString("base64url");
  const claims = `${encode({ alg: "ES256", kid: keyId })}.${encode({ iss: teamId, iat: issuedAt })}`;
  const signature = sign("sha256", Buffer.from(claims), { key, dsaEncoding: "ieee-p1363" });
  return `${claims}.${signature.toString("base64url")}`;
}

export function sendToAPNs(headers, payload, openConnection = connect) {
  return new Promise((resolve, reject) => {
    const connection = openConnection(apnsOrigin);
    const timeout = setTimeout(() => connection.destroy(new Error("APNs request timed out")), 5000);
    connection.once("error", reject);
    connection.once("close", () => {
      clearTimeout(timeout);
      reject(new Error("APNs connection closed before the response"));
    });

    const request = connection.request(headers);
    let status;
    request.once("response", (response) => { status = response[":status"]; });
    request.once("error", reject);
    request.once("end", () => {
      connection.close();
      resolve(status);
    });
    request.resume();
    request.end(JSON.stringify(payload));
  });
}

export function makeHandler({ loadSecret, send = sendToAPNs, now = Date.now }) {
  // Reuse the provider JWT across warm invocations. A new Secrets Manager version
  // invalidates the cache immediately without putting credentials in the environment.
  let cached;
  return async (event) => {
    if (!event || Object.keys(event).length !== 1 || !Object.hasOwn(event, "hazard") ||
        typeof event.hazard !== "string" || !Object.hasOwn(drills, event.hazard)) {
      return { accepted: false, error: "expected_earthquake_or_tsunami" };
    }

    const hazard = event.hazard;
    const eventId = randomUUID();
    let config;
    let jwt;
    let issuedAt;
    try {
      const secret = await loadSecret();
      issuedAt = Math.floor(now() / 1000);
      if (!cached || cached.version !== secret.VersionId || issuedAt >= cached.issuedAt + 45 * 60) {
        config = readConfig(secret.SecretString);
        jwt = providerToken(config, issuedAt);
        cached = { version: secret.VersionId, issuedAt, config, jwt };
      } else {
        ({ config, jwt } = cached);
      }
    } catch {
      return { accepted: false, eventId, error: "apns_configuration_unavailable" };
    }

    const expires = issuedAt + ttlSeconds;
    const payload = {
      aps: { alert: drills[hazard], sound: "default" },
      nigeyoType: "remote-training",
      eventId,
      hazard,
      expiresAt: new Date(expires * 1000).toISOString(),
    };
    const headers = {
      ":method": "POST",
      ":path": `/3/device/${config.deviceToken}`,
      "content-type": "application/json",
      authorization: `bearer ${jwt}`,
      [sensitiveHeaders]: ["authorization", ":path"],
      "apns-topic": config.bundleId,
      "apns-push-type": "alert",
      "apns-priority": "10",
      "apns-id": eventId,
      "apns-expiration": String(expires),
    };
    try {
      const status = await send(headers, payload);
      if (!Number.isInteger(status)) throw new Error("APNs response had no status");
      return { accepted: status === 200, eventId, apnsStatus: status };
    } catch {
      return { accepted: false, eventId, error: "apns_transport_failed" };
    }
  };
}

export function loadAPNsSecret() {
  return secrets.send(
    new GetSecretValueCommand({ SecretId: process.env.APNS_SECRET_ARN }),
    { abortSignal: AbortSignal.timeout(3000) },
  );
}

export const handler = makeHandler({ loadSecret: loadAPNsSecret });
