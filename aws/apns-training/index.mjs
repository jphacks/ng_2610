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

function isDeviceToken(value) {
  return typeof value === "string" && /^(?:[a-fA-F0-9]{2})+$/.test(value);
}

function isRegion(value) {
  return typeof value === "string" && value.length > 0 && value.length <= 80 &&
    value === value.trim() && !/[\p{C}]/u.test(value);
}

function validTrainingRegions(regions) {
  return regions && Object.keys(regions).every((hazard) => Object.hasOwn(drills, hazard)) &&
    Object.values(regions).some((areas) => Array.isArray(areas) && areas.length) &&
    Object.values(regions).every((areas) => Array.isArray(areas) && areas.every(isRegion));
}

export function readConfig(value, { requireRegions = false } = {}) {
  const { teamId, keyId, privateKey, bundleId, deviceToken, devices } = JSON.parse(value);
  if (typeof teamId !== "string" || !/^[A-Z0-9]{10}$/.test(teamId) ||
      typeof keyId !== "string" || !/^[A-Z0-9]{10}$/.test(keyId) ||
      typeof bundleId !== "string" || !/^[a-zA-Z0-9-]+(?:\.[a-zA-Z0-9-]+)+$/.test(bundleId) ||
      (devices === undefined && !isDeviceToken(deviceToken))) {
    throw new Error("Invalid APNs configuration");
  }
  const key = createPrivateKey(privateKey);
  if (key.asymmetricKeyType !== "ec" || key.asymmetricKeyDetails.namedCurve !== "prime256v1") {
    throw new Error("Invalid APNs key type");
  }
  if (devices === undefined) return { teamId, keyId, key, bundleId, deviceToken };

  if (deviceToken !== undefined || !Array.isArray(devices) || devices.length < 1 || devices.length > 4) {
    throw new Error("Invalid APNs device list");
  }
  const ids = new Set();
  const tokens = new Set();
  for (const device of devices) {
    if (typeof device?.id !== "string" || !/^[A-Za-z0-9_-]{1,24}$/.test(device.id) ||
        !isDeviceToken(device.deviceToken) || ids.has(device.id) || tokens.has(device.deviceToken.toLowerCase()) ||
        ((requireRegions || device.regions !== undefined) && !validTrainingRegions(device.regions))) {
      throw new Error("Invalid APNs device");
    }
    ids.add(device.id);
    tokens.add(device.deviceToken.toLowerCase());
  }
  return { teamId, keyId, key, bundleId, devices };
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

export function makeHandler({ loadSecret, subscriptionSource, send = sendToAPNs, now = Date.now }) {
  // Reuse the provider JWT across warm invocations. A new Secrets Manager version
  // invalidates the cache immediately without putting credentials in the environment.
  let cached;
  return async (event) => {
    if (!event || Object.keys(event).some((key) => key !== "hazard" && key !== "region") || !Object.hasOwn(event, "hazard") ||
        typeof event.hazard !== "string" || !Object.hasOwn(drills, event.hazard)) {
      return { accepted: false, error: "expected_earthquake_or_tsunami" };
    }
    if (Object.hasOwn(event, "region") && !isRegion(event.region)) {
      return { accepted: false, error: "invalid_training_region" };
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
        config = readConfig(secret.SecretString, { requireRegions: !subscriptionSource });
        jwt = providerToken(config, issuedAt);
        cached = { version: secret.VersionId, issuedAt, config, jwt };
      } else {
        ({ config, jwt } = cached);
      }
    } catch {
      return { accepted: false, eventId, error: "apns_configuration_unavailable" };
    }

    const sendDrill = async (deviceToken, region, apnsId = eventId) => {
      const expires = issuedAt + ttlSeconds;
      const alert = drills[hazard];
      const payload = {
        aps: { alert: region ? { ...alert, body: `【訓練】${region}：${alert.body.slice("【訓練】".length)}` } : alert, sound: "default" },
        nigeyoType: "remote-training",
        eventId,
        hazard,
        expiresAt: new Date(expires * 1000).toISOString(),
      };
      const headers = {
        ":method": "POST",
        ":path": `/3/device/${deviceToken}`,
        "content-type": "application/json",
        authorization: `bearer ${jwt}`,
        [sensitiveHeaders]: ["authorization", ":path"],
        "apns-topic": config.bundleId,
        "apns-push-type": "alert",
        "apns-priority": "10",
        "apns-id": apnsId,
        "apns-expiration": String(expires),
      };
      try {
        const status = await send(headers, payload);
        if (!Number.isInteger(status)) throw new Error("APNs response had no status");
        return { accepted: status === 200, apnsStatus: status };
      } catch {
        return { accepted: false, error: "apns_transport_failed" };
      }
    };

    if (!config.devices && !subscriptionSource) {
      if (event.region) return { accepted: false, eventId, error: "regional_devices_not_configured" };
      return { ...await sendDrill(config.deviceToken), eventId };
    }
    if (!event.region) return { accepted: false, eventId, error: "training_region_required" };
    let matches;
    try {
      const devices = config.devices ?? [{ id: undefined, deviceToken: config.deviceToken }];
      const selected = await Promise.all(devices.map(async (device) => {
        if (!subscriptionSource) return device.regions?.[hazard]?.includes(event.region);
        const subscription = await subscriptionSource(device);
        return subscription.enabled && subscription.targets.some((target) =>
          hazard === "earthquake"
            ? target.earthquakeArea.name === event.region
            : target.tsunamiAreas.includes(event.region));
      }));
      matches = devices.filter((_, index) => selected[index]);
    } catch {
      return { accepted: false, eventId, error: "regional_subscriptions_unavailable" };
    }
    if (!matches.length) return { accepted: false, eventId, error: "no_devices_in_region" };
    const results = await Promise.all(matches.map(async (device) => ({
      id: device.id ?? "iphone-1",
      ...await sendDrill(device.deviceToken, event.region, randomUUID()),
    })));
    return { accepted: results.every((result) => result.accepted), eventId, results };
  };
}

export function loadAPNsSecret() {
  return secrets.send(
    new GetSecretValueCommand({ SecretId: process.env.APNS_SECRET_ARN }),
    { abortSignal: AbortSignal.timeout(3000) },
  );
}

export const handler = makeHandler({ loadSecret: loadAPNsSecret });
