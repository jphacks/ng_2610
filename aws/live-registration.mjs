import { createHash, timingSafeEqual } from "node:crypto";
import { GetObjectCommand, PutObjectCommand, S3Client } from "@aws-sdk/client-s3";
import { loadAPNsSecret, makeHandler, readConfig } from "./apns-training/index.mjs";
import { validActivityRegistration } from "./apns-training/activity-push.mjs";
import { validSubscription } from "../server/monitoring/regions.mjs";

const client = new S3Client({});
export const disabledSubscription = { version: 2, enabled: false, targets: [] };

export function deviceFingerprint(device) {
  return createHash("sha256").update(device.deviceToken.toLowerCase()).digest("hex");
}

function subscriptionKey(device) {
  return device.id ? `subscriptions/${deviceFingerprint(device)}.json` : "live-subscription.json";
}

export async function loadLiveSubscription(bucket, device) {
  try {
    const result = await client.send(new GetObjectCommand({ Bucket: bucket, Key: subscriptionKey(device) }));
    const subscription = JSON.parse(await result.Body.transformToString());
    if (!validSubscription(subscription)) throw new Error("Invalid live subscription");
    return subscription;
  } catch (error) {
    if (error.name !== "NoSuchKey") throw error;
    return disabledSubscription;
  }
}

export function registrationHandler({ getDevices, save, saveActivity }) {
  return async (event) => {
    const supplied = event.headers?.authorization?.match(/^Bearer ([0-9a-f]{32,512})$/i)?.[1]?.toLowerCase();
    if (!supplied) return { statusCode: 403 };
    const credential = Buffer.from(supplied);
    const device = (await getDevices()).find(({ deviceToken }) =>
      deviceToken.length === credential.length &&
      timingSafeEqual(credential, Buffer.from(deviceToken.toLowerCase())));
    if (!device) return { statusCode: 403 };
    if (event.isBase64Encoded || typeof event.body !== "string" || Buffer.byteLength(event.body) > 8192) {
      return { statusCode: 400 };
    }
    let subscription;
    try { subscription = JSON.parse(event.body); }
    catch { return { statusCode: 400 }; }
    if (event.rawPath === "/activity") {
      if (!saveActivity || !validUpdateToken(subscription)) return { statusCode: 400 };
      await saveActivity(device, subscription);
      return { statusCode: 204 };
    }
    if (!validSubscription(subscription) ||
        (Object.hasOwn(subscription, "activity") && !validActivityRegistration(subscription.activity))) {
      return { statusCode: 400 };
    }
    await save(device, subscription.enabled ? subscription : disabledSubscription);
    return { statusCode: 204 };
  };
}

export const handler = registrationHandler({
  saveActivity: saveUpdateToken,
  getDevices: async () => {
    const { SecretString } = await loadAPNsSecret();
    const config = readConfig(SecretString);
    return config.devices ?? [{ deviceToken: config.deviceToken }];
  },
  save: (device, subscription) => client.send(new PutObjectCommand({
    Bucket: process.env.STATE_BUCKET, Key: subscriptionKey(device), ContentType: "application/json",
    Body: JSON.stringify(subscription),
  })),
});

export const trainingHandler = makeHandler({
  loadSecret: loadAPNsSecret,
  subscriptionSource: process.env.STATE_BUCKET
    ? (device) => loadLiveSubscription(process.env.STATE_BUCKET, device)
    : undefined,
});

function updateTokenKey(device, hazard) {
  return `activity-updates/${deviceFingerprint(device)}/${hazard}.json`;
}

async function readUpdateToken(bucket, device, hazard) {
  try {
    const result = await client.send(new GetObjectCommand({ Bucket: bucket, Key: updateTokenKey(device, hazard) }));
    return { value: JSON.parse(await result.Body.transformToString()), etag: result.ETag };
  } catch (error) {
    if (error.name !== "NoSuchKey") throw error;
    return {};
  }
}

export async function loadActivityUpdate(bucket, device, hazard) {
  return (await readUpdateToken(bucket, device, hazard)).value;
}

function validUpdateToken(value) {
  return !!value && validActivityRegistration({ token: value.token, language: "en" }) &&
    ["earthquake", "tsunami"].includes(value.hazard) &&
    typeof value.sessionId === "string" && /^[\da-f]{8}(?:-[\da-f]{4}){3}-[\da-f]{12}$/i.test(value.sessionId) &&
    typeof value.sourceEventId === "string" && value.sourceEventId.length > 0 && value.sourceEventId.length <= 128 &&
    typeof value.issuedAt === "string" && Number.isFinite(Date.parse(value.issuedAt)) &&
    Date.parse(value.issuedAt) >= Date.now() - 8 * 3600_000 && Date.parse(value.issuedAt) <= Date.now() + 5000;
}

async function saveUpdateToken(device, value) {
  const bucket = process.env.STATE_BUCKET;
  for (let attempt = 0; attempt < 3; attempt++) {
    const current = await readUpdateToken(bucket, device, value.hazard);
    if (current.value && Date.parse(current.value.issuedAt) > Date.parse(value.issuedAt)) return;
    try {
      await client.send(new PutObjectCommand({
        Bucket: bucket, Key: updateTokenKey(device, value.hazard), ContentType: "application/json",
        Body: JSON.stringify(value),
        ...(current.etag ? { IfMatch: current.etag } : { IfNoneMatch: "*" }),
      }));
      return;
    } catch (error) {
      if (![409, 412].includes(error.$metadata?.httpStatusCode)) throw error;
    }
  }
  throw new Error("Activity registration was updated concurrently");
}
