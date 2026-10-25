import { readFile } from 'node:fs/promises';
import { join } from 'node:path';
import WebSocket from 'ws';
import { AcquireError, FIXTURE_DIR } from './quake.mjs';
import { atomicWrite, fetchLimited, jstToIso, readJsonOrNull, sha256, STATE_DIR } from './util.mjs';

export const TSUNAMI_API_URL = 'https://api.p2pquake.net/v2/history?codes=552&limit=1';
export const P2P_WS_URL = 'wss://api.p2pquake.net/v2/ws';
export const CANDIDATE_GRADES = new Set(['MajorWarning', 'Warning', 'Watch']);
const ALL_GRADES = new Set([...CANDIDATE_GRADES, 'Unknown']);
// Demo test values (spec §6.4), not production recommendations.
export const FRESH_MAX_AGE_MS = 5 * 60_000;
export const FUTURE_TOLERANCE_MS = 5_000;

// Validates one code-552 item; returns a normalized record keeping every area.
export function parseTsunamiItem(item) {
  if (item?.code !== 552) throw new AcquireError('unexpected-code');
  if (typeof item.id !== 'string' || item.id.length === 0) throw new AcquireError('missing-id');
  const issuedAt = jstToIso(item.issue?.time);
  if (!issuedAt) throw new AcquireError('invalid-time');
  if (typeof item.cancelled !== 'boolean') throw new AcquireError('invalid-cancelled');
  if (!Array.isArray(item.areas)) throw new AcquireError('missing-areas');
  const areas = item.areas
    .filter((a) => typeof a?.name === 'string' && a.name.length > 0)
    .map((a) => ({ name: a.name, grade: ALL_GRADES.has(a.grade) ? a.grade : 'Unknown', immediate: a.immediate === true }));
  return { sourceEventId: item.id, code: 552, issuedAt, cancelled: item.cancelled, areas };
}

// History response text → record or null ("no latest tsunami history", which is NOT "no danger").
export function parseTsunamiHistory(text) {
  let json;
  try {
    json = JSON.parse(text);
  } catch {
    throw new AcquireError('invalid-json');
  }
  if (!Array.isArray(json)) throw new AcquireError('not-array');
  if (json.length === 0) return null;
  return parseTsunamiItem(json[0]);
}

// Summary sent to the phone: only the configured target area and its grade.
export function summaryFor(record, targetArea) {
  const area = record.areas.find((a) => a.name === targetArea);
  if (!area) return null;
  return { sourceEventId: record.sourceEventId, code: 552, issuedAt: record.issuedAt, cancelled: record.cancelled, area: area.name, grade: area.grade };
}

// Spec §6.4 new-candidate rule: not cancelled, target area present with a candidate grade, fresh.
export function evaluateCandidate(record, { targetArea, now = new Date() }) {
  if (!targetArea) return { candidate: false, reason: 'no-target-area' };
  if (record.cancelled) return { candidate: false, reason: 'cancelled' };
  const summary = summaryFor(record, targetArea);
  if (!summary) return { candidate: false, reason: 'area-not-targeted' };
  if (!CANDIDATE_GRADES.has(summary.grade)) return { candidate: false, reason: 'grade-not-candidate' };
  const age = now.getTime() - Date.parse(summary.issuedAt);
  if (age < -FUTURE_TOLERANCE_MS) return { candidate: false, reason: 'future-time' };
  if (age >= FRESH_MAX_AGE_MS) return { candidate: false, reason: 'expired' };
  return { candidate: true, summary };
}

async function loadStored(dir) {
  try {
    const text = await readFile(join(dir, 'tsunami552.json'), 'utf8');
    const meta = await readJsonOrNull(join(dir, 'tsunami552.metadata.json'));
    if (!meta || meta.sha256 !== sha256(text)) return null;
    const record = parseTsunamiHistory(text);
    return record ? { text, meta, record } : null;
  } catch {
    return null;
  }
}

/**
 * Drill data for an explicit tsunami drill: live-api → last-good → fixture → local (synthetic).
 * A 551 quake is never reused as 552.
 */
export async function acquireTsunamiForDrill({ fetchImpl, stateDir = STATE_DIR, fixtureDir = FIXTURE_DIR, targetArea, now = () => new Date() } = {}) {
  let failureReason = null;
  try {
    const { status, text } = await fetchLimited(TSUNAMI_API_URL, { timeoutMs: 3000, fetchImpl });
    if (status !== 200) throw new AcquireError(`http-${status}`);
    const record = parseTsunamiHistory(text);
    if (!record) throw new AcquireError('empty-array');
    const fetchedAt = now().toISOString();
    const dir = join(stateDir, 'last-good');
    await atomicWrite(join(dir, 'tsunami552.json'), text);
    await atomicWrite(join(dir, 'tsunami552.metadata.json'), JSON.stringify({ source: TSUNAMI_API_URL, fetchedAt, sha256: sha256(text) }, null, 2));
    return { source: 'live-api', record, summary: targetArea ? summaryFor(record, targetArea) : null, raw: text, fetchedAt, failureReason };
  } catch (err) {
    failureReason = err?.message ?? 'error';
  }
  for (const [source, dir] of [['last-good', join(stateDir, 'last-good')], ['fixture', fixtureDir]]) {
    const stored = await loadStored(dir);
    if (stored) {
      return { source, record: stored.record, summary: targetArea ? summaryFor(stored.record, targetArea) : null, raw: stored.text, fetchedAt: stored.meta.fetchedAt, failureReason };
    }
  }
  return { source: 'local', record: null, summary: null, raw: null, fetchedAt: null, failureReason };
}

/**
 * Explicitly started production observation of code 552 over the P2P WebSocket.
 * Records connect/receive/evaluate separately; adoption is delegated to onCandidate.
 */
export class TsunamiObserver {
  constructor({ log, onCandidate, wsUrl = P2P_WS_URL, WebSocketImpl = WebSocket }) {
    this.log = log;
    this.onCandidate = onCandidate;
    this.wsUrl = wsUrl;
    this.WebSocketImpl = WebSocketImpl;
    this.ws = null;
    this.seen = new Set();
    this.events = [];
    this.state = 'stopped';
    this.targetArea = null;
    this.autoAdopt = false;
  }

  status() {
    return { state: this.state, targetArea: this.targetArea, autoAdopt: this.autoAdopt, events: this.events.slice(-20) };
  }

  start({ targetArea, autoAdopt }) {
    this.targetArea = targetArea || null;
    this.autoAdopt = autoAdopt === true;
    if (this.ws) return;
    this.state = 'connecting';
    const ws = new this.WebSocketImpl(this.wsUrl);
    this.ws = ws;
    ws.on('open', () => {
      this.state = 'observing';
      this.log('tsunami-observe-connected', {});
    });
    ws.on('message', (data) => this.handle(data.toString('utf8')));
    ws.on('close', () => {
      this.log('tsunami-observe-closed', {});
      this.ws = null;
      if (this.state !== 'stopped') {
        this.state = 'reconnecting';
        setTimeout(() => this.state === 'reconnecting' && this.start({ targetArea: this.targetArea, autoAdopt: this.autoAdopt }), 5000);
      }
    });
    ws.on('error', (err) => this.log('tsunami-observe-error', { message: err.message }));
  }

  stop() {
    this.state = 'stopped';
    this.ws?.close();
    this.ws = null;
  }

  handle(text) {
    let item;
    try {
      item = JSON.parse(text);
    } catch {
      return;
    }
    if (item?.code !== 552) return;
    let record;
    try {
      record = parseTsunamiItem(item);
    } catch (err) {
      this.log('tsunami-observe-invalid', { reason: err.message });
      return;
    }
    if (this.seen.has(record.sourceEventId)) return;
    this.seen.add(record.sourceEventId);
    const verdict = evaluateCandidate(record, { targetArea: this.targetArea });
    const event = { receivedAt: new Date().toISOString(), sourceEventId: record.sourceEventId, issuedAt: record.issuedAt, cancelled: record.cancelled, ...verdict, adopted: false };
    this.events.push(event);
    if (this.events.length > 100) this.events.shift();
    this.log('tsunami-observe-received', { sourceEventId: record.sourceEventId, issuedAt: record.issuedAt, cancelled: record.cancelled, candidate: verdict.candidate, reason: verdict.reason ?? null });
    if (verdict.candidate && this.autoAdopt) {
      event.adopted = true;
      this.onCandidate?.(verdict.summary, text);
    }
  }
}
