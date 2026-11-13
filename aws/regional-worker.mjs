import { pathToFileURL } from "node:url";
import { sensitiveHeaders } from "node:http2";
import { setTimeout as delay } from "node:timers/promises";
import { deviceFingerprint, disabledSubscription, loadActivityUpdate, loadLiveSubscription } from "./live-registration.mjs";
import { createRegionalStateStore } from "./regional-state.mjs";
import { RegionalMonitor } from "../server/monitoring/service.mjs";
import { validSubscription } from "../server/monitoring/regions.mjs";
import { loadAPNsSecret, providerToken, readConfig, sendToAPNs } from "./apns-training/index.mjs";

import { activityContent, buildActivityStart, sendActivity, validActivityRegistration } from "./apns-training/activity-push.mjs";

const titles = {
  earthquake: "EARTHQUAKE_ALERT",
  Warning: "TSUNAMI_ALERT",
  MajorWarning: "TSUNAMI_ALERT",
  Watch: "TSUNAMI_WATCH",
};

// The existing monitor persists each regional decision before calling this sender.
// Never pass non-alert state changes, test events, or stale outbox entries to APNs.
export function buildRegionalPush(command, now = Date.now()) {
  const issuedAt = Date.parse(command.issuedAt);
  const expires = Math.floor((issuedAt + 120_000) / 1000);
  const title = command.hazard === "earthquake" ? titles.earthquake : titles[command.grade];
  if (!["earthquake", "tsunami"].includes(command.hazard) ||
      command.mode !== "live" || command.status !== "active" || !command.notify ||
      !Object.hasOwn(titles, command.hazard === "earthquake" ? "earthquake" : command.grade) ||
      !Number.isFinite(expires) || expires * 1000 <= now) return null;

  const matches = command.hazard === "earthquake" ? command.matches
    : command.matches.filter(({ region }) => command.tsunamiAreas?.[region] === command.grade);
  if (!matches.length) return null;
  const regions = [...new Set(matches.map(({ region }) => region))].join("、");
  const label = command.hazard === "earthquake" ? "緊急地震速報"
    : { Watch: "津波注意報", Warning: "津波警報", MajorWarning: "大津波警報" }[command.grade];
  const body = `登録地域（${regions}）に${label}が発表されました。気象庁・自治体の情報を確認してください。`;
  return {
    expires,
    payload: {
      aps: { alert: { title, body }, sound: "default" },
      nigeyoType: "regional-alert",
      regionalAlert: JSON.stringify({
        ...command, matches, sentAt: new Date(now).toISOString(), expiresAt: new Date(expires * 1000).toISOString(),
      }),
    },
  };
}

export async function runRegionalWorker({ stateStore, secret, send = sendToAPNs, WebSocketImpl, now = Date.now, log = console.log, subscriptionSource, activityUpdateSource }) {
  const config = readConfig(secret);
  const devices = config.devices ?? [{ deviceToken: config.deviceToken, subscription: JSON.parse(secret).subscription }];
  const installations = new Map(devices.map((device) => [
    device.id ? `aws-device-${deviceFingerprint(device)}` : "aws-demo-device", device,
  ]));
  const subscriptions = new Map();
  const monitor = new RegionalMonitor({ stateStore, WebSocketImpl, now: () => new Date(now()), log: (event) => log(event) });
  const inFlight = new Set();
  const startedActivities = new Map();
  const acceptedNotifications = new Map();
  let token;
  let tokenIssuedAt;

  function dispatch(installation, device, command, fingerprint) {
    if (inFlight.has(command.commandId)) return;
    inFlight.add(command.commandId);
    deliver(installation, device, command, fingerprint).catch(() => log("regional-apns-retry")).finally(() => inFlight.delete(command.commandId));
  }

  async function deliver(installation, device, command, fingerprint) {
    // A disable or region change must also invalidate queued pushes between polls.
    const subscription = subscriptionSource ? await subscriptionSource(device) : device.subscription;
    if (subscriptionSource && JSON.stringify(regionalSettings(subscription)) !== fingerprint) return;
    if (!monitor.records[installation]?.pending.some((item) => item.commandId === command.commandId)) return;

    const timestamp = now();
    const push = buildRegionalPush(command, timestamp);
    const seconds = Math.floor(timestamp / 1000);
    if (!token || seconds - tokenIssuedAt >= 45 * 60) {
      token = providerToken(config, seconds);
      tokenIssuedAt = seconds;
    }
    const activity = subscription?.activity;
    for (const cache of [startedActivities, acceptedNotifications]) {
      for (const [id, expiry] of cache) if (expiry <= seconds) cache.delete(id);
    }
    const shouldEnd = activityUpdateSource && validActivityRegistration(activity) &&
      (command.status === "cancelled" || (command.hazard === "tsunami" && command.grade === "Watch" &&
        Object.values(command.tsunamiAreas ?? {}).every((grade) => ["Watch", "Cancelled"].includes(grade))));
    const withinEndWindow = Date.parse(command.issuedAt) + 120_000 > timestamp;
    const ending = shouldEnd && withinEndWindow
      ? endActivity(device, command, seconds, activity.language).catch(() => false)
      : Promise.resolve(true);
    if (!push || Buffer.byteLength(JSON.stringify(push.payload)) > 4096) {
      if (push) log("regional-apns-payload-too-large");
      if (await ending) await monitor.acknowledge(installation, command.commandId);
      return;
    }
    const notification = acceptedNotifications.has(command.commandId) ? Promise.resolve(200) : send({
      ":method": "POST",
      ":path": `/3/device/${device.deviceToken}`,
      "content-type": "application/json",
      authorization: `bearer ${token}`,
      [sensitiveHeaders]: ["authorization", ":path"],
      "apns-topic": config.bundleId,
      "apns-push-type": "alert",
      "apns-priority": "10",
      "apns-id": command.commandId,
      "apns-collapse-id": command.commandId,
      "apns-expiration": String(push.expires),
    }, push.payload).catch(() => 503);
    let activitySettled = true;
    if (command.grade !== "Watch" && validActivityRegistration(activity) &&
        !startedActivities.has(command.commandId)) {
      const result = await sendActivity({ send, config, jwt: token, token: activity.token, expires: push.expires,
        eventId: command.commandId,
        payload: buildActivityStart({ hazard: command.hazard, eventId: command.commandId,
          expiresAt: new Date(push.expires * 1000).toISOString(), timestamp: seconds,
          alert: { title: "nigeyo", body: push.payload.aps.alert.body }, language: activity.language,
          regionalAlert: push.payload.regionalAlert }),
      });
      log("regional-activity-result", { status: result.apnsStatus, eventId: command.commandId });
      if (result.accepted) startedActivities.set(command.commandId, push.expires);
      activitySettled = result.accepted || result.error === "activity_payload_too_large" ||
        (result.apnsStatus >= 400 && result.apnsStatus < 500 && result.apnsStatus !== 429);
    }
    const status = await notification;
    if (status === 200) acceptedNotifications.set(command.commandId, push.expires);
    log("regional-apns-result", { status, eventId: command.commandId });
    if ((status === 200 || (status >= 400 && status < 500 && status !== 429)) && activitySettled && await ending) {
      await monitor.acknowledge(installation, command.commandId);
    }
  }

  async function endActivity(device, command, timestamp, language) {
    const update = await activityUpdateSource(device, command.hazard);
    if (!update) return false;
    if (Date.parse(update.issuedAt) > Date.parse(command.issuedAt)) return true;
    if (command.hazard === "earthquake" && update.sourceEventId !== command.sourceEventId) return false;
    const result = await sendActivity({ send, config, jwt: token, token: update.token,
      eventId: command.commandId, expires: timestamp + 60,
      payload: { aps: { timestamp, event: "end", "dismissal-date": timestamp,
        "content-state": { ...activityContent(command.hazard, language, false), interactive: false },
      } },
    });
    log("regional-activity-end-result", { status: result.apnsStatus, eventId: command.commandId });
    return result.accepted || result.apnsStatus === 410;
  }

  // Token rotations and language changes must not reset the monitor's deduplication history.
  function regionalSettings({ version, enabled, targets }) {
    return { version, enabled, targets };
  }

  try {
    await monitor.load();
    for (const id of Object.keys(monitor.records)) {
      if (!installations.has(id)) await monitor.configure(id, disabledSubscription, () => {});
    }
    for (const [id, device] of installations) await configure(id, device);
  } catch (error) {
    monitor.stop();
    throw error;
  }
  if (subscriptionSource) void refreshSubscriptions();
  return monitor;

  async function configure(id, device) {
    const subscription = subscriptionSource ? await subscriptionSource(device) : device.subscription;
    if (!validSubscription(subscription) || (!subscriptionSource && !subscription.enabled)) {
      throw new Error("Missing confirmed regional subscription");
    }
    const settings = regionalSettings(subscription);
    const fingerprint = JSON.stringify(settings);
    if (subscriptions.get(id) === fingerprint) return;
    await monitor.configure(id, settings, (command) => dispatch(id, device, command, fingerprint));
    subscriptions.set(id, fingerprint);
  }

  async function refreshSubscriptions() {
    while (!monitor.stopped) {
      await delay(3000);
      if (monitor.stopped) return;
      for (const [id, device] of installations) {
        try { await configure(id, device); }
        catch { log("regional-subscription-refresh-failed"); }
      }
    }
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    const { SecretString } = await loadAPNsSecret();
    const stateStore = createRegionalStateStore({ bucket: process.env.STATE_BUCKET });
    const subscriptionSource = process.env.APP_REGISTRATION_ENABLED === "true"
      ? (device) => loadLiveSubscription(process.env.STATE_BUCKET, device)
      : undefined;
    const activityUpdateSource = subscriptionSource
      ? (device, hazard) => loadActivityUpdate(process.env.STATE_BUCKET, device, hazard)
      : undefined;
    const monitor = await runRegionalWorker({ stateStore, secret: SecretString, subscriptionSource, activityUpdateSource });
    process.on("SIGTERM", () => monitor.stop());
  } catch {
    console.error("regional-worker-startup-failed");
    process.exitCode = 1;
  }
}
