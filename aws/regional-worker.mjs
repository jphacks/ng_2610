import { pathToFileURL } from "node:url";
import { sensitiveHeaders } from "node:http2";
import { setTimeout as delay } from "node:timers/promises";
import { loadLiveSubscription } from "./live-registration.mjs";
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
  let subscription = subscriptionSource ? await subscriptionSource() : JSON.parse(secret).subscription;
  if (!validSubscription(subscription) || (!subscriptionSource && !subscription.enabled)) {
    throw new Error("Missing confirmed regional subscription");
  }

  const installation = "aws-demo-device";
  const monitor = new RegionalMonitor({ stateStore, WebSocketImpl, now: () => new Date(now()), log: (event) => log(event) });
  const inFlight = new Set();
  let token;
  let tokenIssuedAt;

  function dispatch(command, fingerprint) {
    if (inFlight.has(command.commandId)) return;
    inFlight.add(command.commandId);
    deliver(command, fingerprint).catch(() => log("regional-apns-retry")).finally(() => inFlight.delete(command.commandId));
  }

  async function deliver(command, fingerprint) {
    // A disable or region change must also invalidate queued pushes between polls.
    if (subscriptionSource && JSON.stringify(await subscriptionSource()) !== fingerprint) return;

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
      ":path": `/3/device/${config.deviceToken}`,
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

  await monitor.load();
  await configure(subscription);
  if (subscriptionSource) void refreshSubscription();
  return monitor;

  function configure(value) {
    const fingerprint = JSON.stringify(value);
    return monitor.configure(installation, value, (command) => dispatch(command, fingerprint));
  }

  async function refreshSubscription() {
    while (!monitor.stopped) {
      await delay(3000);
      if (monitor.stopped) return;
      try {
        const next = await subscriptionSource();
        if (JSON.stringify(next) === JSON.stringify(subscription)) continue;
        const previous = subscription;
        subscription = next;
        try { await configure(next); }
        catch (error) { subscription = previous; throw error; }
      } catch {
        log("regional-subscription-refresh-failed");
      }
    }
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    const { SecretString } = await loadAPNsSecret();
    const stateStore = createRegionalStateStore({ bucket: process.env.STATE_BUCKET });
    const subscriptionSource = process.env.APP_REGISTRATION_ENABLED === "true"
      ? () => loadLiveSubscription(process.env.STATE_BUCKET)
      : undefined;
    const monitor = await runRegionalWorker({ stateStore, secret: SecretString, subscriptionSource });
    process.on("SIGTERM", () => monitor.stop());
  } catch {
    console.error("regional-worker-startup-failed");
    process.exitCode = 1;
  }
}
