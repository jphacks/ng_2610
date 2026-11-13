import { createHash, timingSafeEqual } from "node:crypto";
import { GetObjectCommand, PutObjectCommand, S3Client } from "@aws-sdk/client-s3";
import { loadAPNsSecret, makeHandler, readConfig } from "./apns-training/index.mjs";
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

export function registrationHandler({ getDevices, save }) {
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
    if (!validSubscription(subscription)) return { statusCode: 400 };
    await save(device, subscription.enabled ? subscription : disabledSubscription);
    return { statusCode: 204 };
  };
}

export const handler = registrationHandler({
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
