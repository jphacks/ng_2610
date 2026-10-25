import { jstToIso, uuid } from '../demo/util.mjs';
import { validSubscription } from './regions.mjs';

const rank = { Watch: 1, Warning: 2, MajorWarning: 3 };
export const initialState = () => ({ eew: {}, tsunami: { issuedAt: null, areas: {} } });
const match = (t, region) => ({ slot: t.slot, siteId: t.siteId, region });

/** Pure transition: callers persist state + outbox atomically before delivery. */
export function evaluate(item, subscription, state = initialState(), { now = new Date(), source = 'live' } = {}) {
  const ignore = (reason) => ({ state, action: null, reason });
  if (!validSubscription(subscription) || !subscription.enabled) return ignore('regions-not-confirmed');
  if (source !== 'live' || (item?.test !== undefined && item.test !== false) || item?.issue?.type && item.issue.type !== 'Focus' && item.code === 552) return ignore('training-or-unsupported');
  if (![556, 552].includes(item?.code)) return ignore('information-only');
  const issuedAt = jstToIso(item.issue?.time);
  if (!issuedAt || typeof item.cancelled !== 'boolean' || typeof item.id !== 'string' || !item.id || item.id.length > 128) return ignore('invalid-event');
  const age = now - new Date(issuedAt);
  if (age < -5000) return ignore('future-time');
  const next = structuredClone(state);
  const targets = subscription.targets;
  let matches = [], notify = false, status = 'active', grade = null;
  if (item.code === 556) {
    const eventId = item.issue.eventId, serialText = String(item.issue.serial ?? '');
    const serial = Number(serialText);
    if (typeof eventId !== 'string' || !eventId || ['__proto__', 'constructor', 'prototype'].includes(eventId) || eventId.length > 128 || !/^\d+$/.test(serialText) || !Number.isSafeInteger(serial) || serial < 1) return ignore('invalid-eew');
    const previous = next.eew[eventId];
    if (previous && (serial <= previous.serial || issuedAt < previous.issuedAt || previous.cancelled)) return ignore('duplicate-or-old-revision');
    // This is a notification freshness policy, never a warning expiry or arrival-time test.
    if (!item.cancelled && age > 120_000) return ignore('stale-eew');
    if (!item.cancelled && (!Array.isArray(item.areas) || item.areas.some((a) => typeof a?.pref !== 'string' || typeof a?.name !== 'string'))) return ignore('invalid-areas');
    const entry = { serial, issuedAt, cancelled: item.cancelled, notified: previous?.notified ?? false, matches: previous?.matches ?? [] };
    next.eew[eventId] = entry;
    if (item.cancelled) {
      status = 'cancelled';
      matches = entry.matches;
    } else {
      matches = targets.filter((t) => item.areas.some((a) => a.pref === t.earthquakeArea.pref && a.name === t.earthquakeArea.name))
        .map((t) => match(t, t.earthquakeArea.name));
      notify = matches.length > 0 && !entry.notified;
      entry.notified ||= notify;
      if (matches.length) entry.matches = matches;
    }
    // Bound earthquake history by age; keep cancellations for a week against replay.
    for (const [id, e] of Object.entries(next.eew)) if (now - new Date(e.issuedAt) > 7 * 86400_000) delete next.eew[id];
  } else {
    const previous = next.tsunami;
    if (previous.issuedAt && issuedAt <= previous.issuedAt) return ignore('duplicate-or-old-tsunami');
    if (!Array.isArray(item.areas) || item.areas.some((a) => typeof a?.name !== 'string' || ![...Object.keys(rank), 'Unknown'].includes(a?.grade)) || new Set(item.areas.map((a) => a.name)).size !== item.areas.length || (item.cancelled && item.areas.length)) return ignore('invalid-areas');
    const areas = {};
    const names = new Set(targets.flatMap((t) => t.tsunamiAreas));
    for (const name of names) {
      const area = item.areas.find((a) => a.name === name);
      // Only explicit all-clear cancels. Absence in a partial update means unknown.
      const current = item.cancelled ? 'Cancelled' : area?.grade ?? (previous.areas[name] ? 'Unknown' : null);
      if (!current) continue;
      areas[name] = current;
      if ((rank[current] ?? 0) > (rank[previous.areas[name]] ?? 0)) notify = true;
      if (current !== previous.areas[name] || item.cancelled) {
        matches.push(...targets.filter((t) => t.tsunamiAreas.includes(name)).map((t) => match(t, name)));
      }
    }
    next.tsunami = { issuedAt, areas };
    grade = matches.map((m) => areas[m.region]).filter((g) => rank[g]).sort((a, b) => rank[b] - rank[a])[0] ?? null;
    status = item.cancelled ? 'cancelled' : !grade ? 'unknown' : 'active';
  }
  const action = matches.length && (item.code === 552 || notify || status === 'cancelled') ? { type: 'regional-alert', commandId: uuid(), hazard: item.code === 556 ? 'earthquake' : 'tsunami',
    sourceEventId: item.code === 556 ? item.issue.eventId : item.id, issuedAt, status, grade, notify, matches,
    tsunamiAreas: item.code === 552 ? next.tsunami.areas : null, mode: 'live' } : null;
  return { state: next, action, reason: action ? 'region-match' : 'outside-target-area' };
}
