import { readFile } from 'node:fs/promises';
import { join } from 'node:path';
import { atomicWrite, fetchLimited, jstToIso, readJsonOrNull, ROOT, sha256, STATE_DIR } from './util.mjs';

export const QUAKE_API_URL = 'https://api.p2pquake.net/v2/history?codes=551&limit=1';
export const FIXTURE_DIR = join(ROOT, 'fixtures/demo');
const VALID_SCALES = new Set([10, 20, 30, 40, 45, 50, 55, 60, 70]);

export class AcquireError extends Error {}

// Validates the raw history response text and returns a normalized QuakeSummary (contract v2 §4.2).
export function parseQuake551(text) {
  let json;
  try {
    json = JSON.parse(text);
  } catch {
    throw new AcquireError('invalid-json');
  }
  if (!Array.isArray(json)) throw new AcquireError('not-array');
  if (json.length === 0) throw new AcquireError('empty-array');
  const item = json[0];
  if (item?.code !== 551) throw new AcquireError('unexpected-code');
  if (typeof item.id !== 'string' || item.id.length === 0) throw new AcquireError('missing-id');
  const occurredAt = jstToIso(item.earthquake?.time);
  const issuedAt = jstToIso(item.issue?.time);
  if (!occurredAt || !issuedAt) throw new AcquireError('invalid-time');
  const hypocenter = item.earthquake?.hypocenter ?? {};
  const name = typeof hypocenter.name === 'string' && hypocenter.name.trim() ? hypocenter.name : null;
  // The API uses -1 for "unknown"; never show that as a number.
  const magnitude = typeof hypocenter.magnitude === 'number' && hypocenter.magnitude >= 0 ? hypocenter.magnitude : null;
  const maxScale = VALID_SCALES.has(item.earthquake?.maxScale) ? item.earthquake.maxScale : null;
  return { sourceEventId: item.id, code: 551, occurredAt, issuedAt, hypocenterName: name, magnitude, maxScale };
}

export async function fetchLiveQuake({ fetchImpl, url = QUAKE_API_URL } = {}) {
  const { status, text } = await fetchLimited(url, { timeoutMs: 3000, maxBytes: 1024 * 1024, fetchImpl });
  if (status !== 200) throw new AcquireError(`http-${status}`);
  return { text, quake: parseQuake551(text) };
}

async function loadStored(dir, name) {
  const text = await readFileOrNull(join(dir, `${name}.json`));
  const meta = await readJsonOrNull(join(dir, `${name}.metadata.json`)) ?? await readJsonOrNull(join(dir, 'metadata.json'));
  if (!text || !meta) return null;
  if (meta.sha256 && meta.sha256 !== sha256(text)) return null;
  try {
    return { text, meta, quake: parseQuake551(text) };
  } catch {
    return null;
  }
}

async function readFileOrNull(path) {
  try {
    return await readFile(path, 'utf8');
  } catch {
    return null;
  }
}

export async function saveLastGood(text, fetchedAt, { stateDir = STATE_DIR, url = QUAKE_API_URL } = {}) {
  const dir = join(stateDir, 'last-good');
  await atomicWrite(join(dir, 'quake551.json'), text);
  await atomicWrite(join(dir, 'quake551.metadata.json'), JSON.stringify({ source: url, fetchedAt, sha256: sha256(text) }, null, 2));
}

export const loadLastGood = (stateDir = STATE_DIR) => loadStored(join(stateDir, 'last-good'), 'quake551');
export const loadFixture = (fixtureDir = FIXTURE_DIR) => loadStored(fixtureDir, 'quake551');

/**
 * live-api → last-good → fixture (spec §6.2). Never rewrites times; reports the real source.
 * Throws only when all three are unavailable.
 */
export async function acquireQuake({ fetchImpl, stateDir = STATE_DIR, fixtureDir = FIXTURE_DIR, now = () => new Date() } = {}) {
  const startedAt = now().toISOString();
  let failureReason = null;
  try {
    const { text, quake } = await fetchLiveQuake({ fetchImpl });
    const fetchedAt = now().toISOString();
    await saveLastGood(text, fetchedAt, { stateDir });
    return { source: 'live-api', quake, raw: text, fetchedAt, startedAt, finishedAt: fetchedAt, failureReason, sha256: sha256(text) };
  } catch (err) {
    failureReason = err instanceof AcquireError ? err.message : (err?.message === 'timeout' ? 'timeout' : `network:${err?.message ?? 'error'}`);
  }
  const finishedAt = now().toISOString();
  const lastGood = await loadLastGood(stateDir);
  if (lastGood) {
    return { source: 'last-good', quake: lastGood.quake, raw: lastGood.text, fetchedAt: lastGood.meta.fetchedAt, startedAt, finishedAt, failureReason, sha256: sha256(lastGood.text) };
  }
  const fixture = await loadFixture(fixtureDir);
  if (fixture) {
    return { source: 'fixture', quake: fixture.quake, raw: fixture.text, fetchedAt: fixture.meta.fetchedAt, startedAt, finishedAt, failureReason, sha256: sha256(fixture.text) };
  }
  const err = new AcquireError('no-data-available');
  err.failureReason = failureReason;
  throw err;
}
