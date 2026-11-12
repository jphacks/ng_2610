import { timingSafeEqual } from "node:crypto";
import { GetObjectCommand, PutObjectCommand, S3Client } from "@aws-sdk/client-s3";
import { loadAPNsSecret } from "./apns-training/index.mjs";
import { validSubscription } from "../server/monitoring/regions.mjs";

const client = new S3Client({});
const key = "live-subscription.json";
export const disabledSubscription = { version: 2, enabled: false, targets: [] };

export async function loadLiveSubscription(bucket) {
  try {
    const result = await client.send(new GetObjectCommand({ Bucket: bucket, Key: key }));
    const subscription = JSON.parse(await result.Body.transformToString());
    if (!validSubscription(subscription)) throw new Error("Invalid live subscription");
    return subscription;
  } catch (error) {
    if (error.name !== "NoSuchKey") throw error;
    return disabledSubscription;
  }
}

// This private pilot uses the already provisioned device's APNs token as a
// scoped write credential. It cannot change the recipient or send a push.
export function registrationHandler({ getToken, save }) {
  return async (event) => {
    const supplied = event.headers?.authorization?.match(/^Bearer ([0-9a-f]{32,512})$/i)?.[1];
    if (!supplied) return { statusCode: 403 };
    const expected = await getToken();
    if (typeof expected !== "string" || !/^[0-9a-f]+$/i.test(expected) || supplied.length !== expected.length ||
        !timingSafeEqual(Buffer.from(supplied.toLowerCase()), Buffer.from(expected.toLowerCase()))) {
      return { statusCode: 403 };
    }
    if (event.isBase64Encoded || typeof event.body !== "string" || Buffer.byteLength(event.body) > 8192) {
      return { statusCode: 400 };
    }
    let subscription;
    try { subscription = JSON.parse(event.body); }
    catch { return { statusCode: 400 }; }
    if (!validSubscription(subscription)) return { statusCode: 400 };
    await save(subscription.enabled ? subscription : disabledSubscription);
    return { statusCode: 204 };
  };
}

export const handler = registrationHandler({
  getToken: async () => JSON.parse((await loadAPNsSecret()).SecretString).deviceToken,
  save: (subscription) => client.send(new PutObjectCommand({
    Bucket: process.env.STATE_BUCKET, Key: key, ContentType: "application/json",
    Body: JSON.stringify(subscription),
  })),
});
