// Converts the GSI 指定緊急避難場所 national CSV into the app's normalized JSON (spec §14).
// Usage: node scripts/import-evacuation-sites.mjs [csvPath] [--encoding utf-8|shift_jis] [--retrieved YYYY-MM-DD]
import { parse } from 'csv-parse/sync';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { atomicWrite, ROOT, sha256 } from '../server/demo/util.mjs';

const COLUMNS = {
  commonId: '共通ID',
  municipality: '都道府県名及び市町村名',
  name: '施設・場所名',
  address: '住所',
  earthquake: '地震',
  tsunami: '津波',
  latitude: '緯度',
  longitude: '経度',
  notes: '備考',
};

export function decodeCsv(buffer, encoding = 'utf-8') {
  const text = new TextDecoder(encoding === 'shift_jis' ? 'shift_jis' : 'utf-8', { fatal: true }).decode(buffer);
  return text.charCodeAt(0) === 0xfeff ? text.slice(1) : text;
}

const supported = (v) => v === 1 || (typeof v === 'string' && v.trim() === '1');

export function convertRows(rows) {
  const header = rows[0];
  if (!header) throw new Error('empty-csv');
  const index = {};
  for (const [key, name] of Object.entries(COLUMNS)) {
    const i = header.indexOf(name);
    if (i < 0) throw new Error(`missing-column:${name}`);
    index[key] = i;
  }
  const excluded = { missingName: 0, invalidCoordinate: 0, noEarthquakeOrTsunami: 0, duplicate: 0 };
  const byId = new Map();
  for (const row of rows.slice(1)) {
    const get = (k) => (row[index[k]] ?? '').trim();
    const name = get('name');
    if (!name) { excluded.missingName++; continue; }
    const latRaw = get('latitude');
    const lonRaw = get('longitude');
    const lat = Number(latRaw);
    const lon = Number(lonRaw);
    if (!latRaw || !lonRaw || !Number.isFinite(lat) || !Number.isFinite(lon) || lat < -90 || lat > 90 || lon < -180 || lon > 180) {
      excluded.invalidCoordinate++;
      continue;
    }
    const supportsEarthquake = supported(get('earthquake'));
    const supportsTsunami = supported(get('tsunami'));
    // Sites certified for neither hazard can never be offered by this app.
    if (!supportsEarthquake && !supportsTsunami) { excluded.noEarthquakeOrTsunami++; continue; }
    const municipality = get('municipality');
    const commonId = get('commonId');
    const id = commonId ? `gsi:${commonId}` : `gsi:sha256:${sha256(`${municipality}\u0000${name}\u0000${latRaw}\u0000${lonRaw}`)}`;
    const record = { id, name, address: get('address'), municipality, latitude: lat, longitude: lon, supportsEarthquake, supportsTsunami, notes: get('notes') || null };
    const existing = byId.get(id);
    if (existing) {
      if (JSON.stringify(existing) !== JSON.stringify(record)) throw new Error(`conflicting-duplicate:${id}`);
      excluded.duplicate++;
      continue;
    }
    byId.set(id, record);
  }
  const sites = [...byId.values()].sort((a, b) => (a.id < b.id ? -1 : a.id > b.id ? 1 : 0));
  return { sites, excluded, inputRows: rows.length - 1 };
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const args = process.argv.slice(2);
  const opt = (name, fallback) => { const i = args.indexOf(name); return i >= 0 ? args[i + 1] : fallback; };
  const csvPath = args.find((a, i) => !a.startsWith('--') && !args[i - 1]?.startsWith('--')) ?? join(ROOT, 'mergeFromCity_2.csv');
  const encoding = opt('--encoding', 'utf-8');
  const buffer = readFileSync(csvPath);
  const rows = parse(decodeCsv(buffer, encoding), { relax_column_count: false, skip_empty_lines: true, bom: true });
  const { sites, excluded, inputRows } = convertRows(rows);
  const out = JSON.stringify(sites);
  await atomicWrite(join(ROOT, 'nigeyo-ios/Nigeyo/Resources/evacuation-sites.json'), out);
  const manifest = {
    source: '国土地理院 指定緊急避難場所データ (https://www.gsi.go.jp/bousaichiri/hinanbasho.html)',
    license: '国土地理院コンテンツ利用規約 (出典の明示が必要)',
    retrievedAt: opt('--retrieved', null),
    inputFile: csvPath.split('/').pop(),
    inputSha256: sha256(buffer),
    encoding,
    inputRows,
    adoptedRows: sites.length,
    excluded,
    supportsEarthquake: sites.filter((s) => s.supportsEarthquake).length,
    supportsTsunami: sites.filter((s) => s.supportsTsunami).length,
    outputSha256: sha256(out),
  };
  await atomicWrite(join(ROOT, 'assets/evacuation-sites.manifest.json'), JSON.stringify(manifest, null, 2) + '\n');
  console.log(manifest);
}
