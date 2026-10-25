import { createHash, randomUUID } from 'node:crypto';
import { mkdir, readFile, rename, writeFile, appendFile } from 'node:fs/promises';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

export const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
export const STATE_DIR = process.env.NIGEYO_STATE_DIR ?? join(ROOT, 'state');
export const ARTIFACTS_DIR = process.env.NIGEYO_ARTIFACTS_DIR ?? join(ROOT, 'artifacts/demo');
export const SERVER_VERSION = '1.1.0';
export const SCHEMA_VERSION = 2;

export const sha256 = (data) => createHash('sha256').update(data).digest('hex');
export const uuid = () => randomUUID();

export async function atomicWrite(path, data) {
  await mkdir(dirname(path), { recursive: true });
  const tmp = `${path}.${process.pid}.${Date.now()}.tmp`;
  await writeFile(tmp, data);
  await rename(tmp, path);
}

export async function readJson(path) {
  return JSON.parse(await readFile(path, 'utf8'));
}

export async function readJsonOrNull(path) {
  try {
    return await readJson(path);
  } catch {
    return null;
  }
}

// P2P API times are JST wall-clock ("2026/10/24 21:08:00" or with ".625"); normalize strictly.
const JST_RE = /^(\d{4})\/(\d{2})\/(\d{2}) (\d{2}):(\d{2}):(\d{2})(?:\.(\d{1,3}))?$/;
export function jstToIso(value) {
  if (typeof value !== 'string') return null;
  const m = JST_RE.exec(value);
  if (!m) return null;
  const [, y, mo, d, h, mi, s] = m.map((v, i) => (i === 0 ? v : Number(v)));
  const utc = Date.UTC(y, mo - 1, d, h - 9, mi, s);
  const check = new Date(utc + 9 * 3600_000);
  if (check.getUTCFullYear() !== y || check.getUTCMonth() !== mo - 1 || check.getUTCDate() !== d ||
      check.getUTCHours() !== h || check.getUTCMinutes() !== mi || check.getUTCSeconds() !== s) return null;
  const pad = (n) => String(n).padStart(2, '0');
  return `${y}-${pad(mo)}-${pad(d)}T${pad(h)}:${pad(mi)}:${pad(s)}+09:00`;
}

// Fetch with a hard deadline covering headers *and* body, and a byte cap.
export async function fetchLimited(url, { timeoutMs = 3000, maxBytes = 1024 * 1024, fetchImpl = fetch } = {}) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(new Error('timeout')), timeoutMs);
  try {
    const res = await fetchImpl(url, { signal: controller.signal, redirect: 'error', headers: { accept: 'application/json' } });
    const reader = res.body?.getReader();
    const chunks = [];
    let size = 0;
    if (reader) {
      for (;;) {
        const { done, value } = await reader.read();
        if (done) break;
        size += value.byteLength;
        if (size > maxBytes) {
          controller.abort();
          throw new Error('body-too-large');
        }
        chunks.push(value);
      }
    }
    return { status: res.status, text: Buffer.concat(chunks).toString('utf8') };
  } catch (err) {
    if (controller.signal.aborted && err?.message !== 'body-too-large') throw new Error('timeout');
    throw err;
  } finally {
    clearTimeout(timer);
  }
}

export function createLogger(dir = ARTIFACTS_DIR) {
  return async function log(event, fields = {}) {
    const now = new Date();
    const line = JSON.stringify({ at: now.toISOString(), event, ...fields });
    try {
      await mkdir(dir, { recursive: true });
      await appendFile(join(dir, `${now.toISOString().slice(0, 10)}.jsonl`), line + '\n');
    } catch (err) {
      console.error('log write failed', err.message);
    }
  };
}
