import { pathToFileURL } from "node:url";
import { sensitiveHeaders } from "node:http2";
import { setTimeout as delay } from "node:timers/promises";
import { deviceFingerprint, disabledSubscription, loadLiveSubscription } from "./live-registration.mjs";
import { createRegionalStateStore } from "./regional-state.mjs";
import { RegionalMonitor } from "../server/monitoring/service.mjs";
import { validSubscription } from "../server/monitoring/regions.mjs";
import { loadAPNsSecret, providerToken, readConfig, sendToAPNs } from "./apns-training/index.mjs";

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

export async function runRegionalWorker({ stateStore, secret, send = sendToAPNs, WebSocketImpl, now = Date.now, log = console.log, subscriptionSource }) {
  const config = readConfig(secret);
  const devices = config.devices ?? [{ deviceToken: config.deviceToken, subscription: JSON.parse(secret).subscription }];
  const installations = new Map(devices.map((device) => [
    device.id ? `aws-device-${deviceFingerprint(device)}` : "aws-demo-device", device,
  ]));
  const subscriptions = new Map();
  const monitor = new RegionalMonitor({ stateStore, WebSocketImpl, now: () => new Date(now()), log: (event) => log(event) });
  const inFlight = new Set();
  let token;
  let tokenIssuedAt;

  function dispatch(installation, device, command, fingerprint) {
    if (inFlight.has(command.commandId)) return;
    inFlight.add(command.commandId);
    deliver(installation, device, command, fingerprint).catch(() => log("regional-apns-retry")).finally(() => inFlight.delete(command.commandId));
  }

  async function deliver(installation, device, command, fingerprint) {
    // A disable or region change must also invalidate queued pushes between polls.
    if (subscriptionSource && JSON.stringify(await subscriptionSource(device)) !== fingerprint) return;

    const timestamp = now();
    const push = buildRegionalPush(command, timestamp);
    if (!push || Buffer.byteLength(JSON.stringify(push.payload)) > 4096) {
      if (push) log("regional-apns-payload-too-large");
      await monitor.acknowledge(installation, command.commandId);
      return;
    }
    const seconds = Math.floor(timestamp / 1000);
    if (!token || seconds - tokenIssuedAt >= 45 * 60) {
      token = providerToken(config, seconds);
      tokenIssuedAt = seconds;
    }
    const status = await send({
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
    }, push.payload);
    log("regional-apns-result", { status, eventId: command.commandId });
    if (status === 200 || (status >= 400 && status < 500 && status !== 429)) {
      await monitor.acknowledge(installation, command.commandId);
    }
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
    const fingerprint = JSON.stringify(subscription);
    if (subscriptions.get(id) === fingerprint) return;
    await monitor.configure(id, subscription, (command) => dispatch(id, device, command, fingerprint));
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
    const monitor = await runRegionalWorker({ stateStore, secret: SecretString, subscriptionSource });
    process.on("SIGTERM", () => monitor.stop());
  } catch {
    console.error("regional-worker-startup-failed");
    process.exitCode = 1;
  }
}
