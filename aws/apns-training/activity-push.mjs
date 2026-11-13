import { randomUUID } from "node:crypto";
import { readFileSync } from "node:fs";
import { sensitiveHeaders } from "node:http2";

const languages = Object.fromEntries(["en", "ja", "ko"].map((id) => [
  id, JSON.parse(readFileSync(new URL(`../../assets/languages/${id}.json`, import.meta.url))).strings,
]));

export function validActivityRegistration(activity) {
  return !!activity && typeof activity.token === "string" &&
    /^(?:[0-9a-f]{2}){16,256}$/i.test(activity.token) &&
    typeof activity.language === "string" && /^[a-z]{2,3}(?:-[a-z0-9]{2,8})*$/i.test(activity.language);
}

const staleMessages = {
  en: "Updates may be delayed. Check official alerts.",
  ja: "情報が更新されていません。気象庁・自治体の情報を確認してください。",
  ko: "정보가 갱신되지 않았습니다. 기상청과 지자체의 정보를 확인하세요.",
};

export function activityContent(hazard, language, training) {
  const t = Object.hasOwn(languages, language) ? languages[language] : languages.en;
  const tsunami = hazard === "tsunami";
  const badge = training ? t["training.badge"] : undefined;
  const compact = t[tsunami ? "liveActivity.compactTsunami" : "liveActivity.compactProtect"];
  return {
    layout: tsunami ? "tsunami" : "protect", hazard, phase: tsunami ? "tsunami-evacuate" : "protect",
    stateRevision: 1, pictograms: [tsunami ? "tsunami-evacuate" : "protect-head"],
    headline: t[tsunami ? "guide.tsunami.short" : "guide.protect.short"],
    labels: [], buttonTitle: t[tsunami ? "liveActivity.checkPlaces" : "guide.shakingQuestion"],
    badge, compactLabel: [badge, compact].filter(Boolean).join("・"), appName: t["app.name"], interactive: true,
    staleMessage: training ? undefined : (staleMessages[language] ?? staleMessages.en),
  };
}

export function buildActivityStart({ hazard, eventId, expiresAt, timestamp, alert, language, regionalAlert }) {
  return {
    aps: {
      timestamp, event: "start", "input-push-token": 1, "stale-date": Math.floor(Date.parse(expiresAt) / 1000),
      "attributes-type": "NigeyoActivityAttributes",
      attributes: {
        sessionId: eventId,
        ...(regionalAlert ? { regionalAlert } : { remoteTraining: { hazard, expiresAt } }),
      },
      "content-state": activityContent(hazard, language, !regionalAlert),
      alert,
    },
  };
}

export async function sendActivity({ send, config, jwt, token, expires, eventId, payload }) {
  if (Buffer.byteLength(JSON.stringify(payload)) > 4096) return { accepted: false, error: "activity_payload_too_large" };
  try {
    const status = await send({
      ":method": "POST",
      ":path": `/3/device/${token}`,
      "content-type": "application/json",
      authorization: `bearer ${jwt}`,
      [sensitiveHeaders]: ["authorization", ":path"],
      "apns-topic": `${config.bundleId}.push-type.liveactivity`,
      "apns-push-type": "liveactivity",
      "apns-priority": "10",
      "apns-id": randomUUID(),
      "apns-collapse-id": eventId,
      "apns-expiration": String(expires),
    }, payload);
    return { accepted: status === 200, apnsStatus: status };
  } catch {
    return { accepted: false, error: "apns_transport_failed" };
  }
}
