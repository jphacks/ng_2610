// Validates every assets/languages/*.json against contracts/required-string-keys.json (spec §12.2).
import { readdirSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { ROOT } from '../server/demo/util.mjs';

export const LANG_DIR = join(ROOT, 'assets/languages');
const BCP47 = /^[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8})*$/;
const TOP_KEYS = ['schemaVersion', 'packageVersion', 'languageId', 'displayName', 'nativeName', 'direction', 'strings'];
const placeholders = (s) => [...s.matchAll(/\{([A-Za-z]+)\}/g)].map((m) => m[1]).sort();

export function loadRequiredKeys() {
  return JSON.parse(readFileSync(join(ROOT, 'contracts/required-string-keys.json'), 'utf8')).keys;
}

// Returns a list of problems; empty means the package is acceptable as a whole.
export function validatePackage(pkg, required = loadRequiredKeys(), fileName = null) {
  const errors = [];
  if (typeof pkg !== 'object' || pkg === null || Array.isArray(pkg)) return ['not-an-object'];
  for (const k of Object.keys(pkg)) if (!TOP_KEYS.includes(k)) errors.push(`unknown-field:${k}`);
  if (pkg.schemaVersion !== 1) errors.push('schemaVersion');
  if (!Number.isInteger(pkg.packageVersion) || pkg.packageVersion < 1) errors.push('packageVersion');
  if (typeof pkg.languageId !== 'string' || !BCP47.test(pkg.languageId)) errors.push('languageId');
  if (fileName && fileName !== `${pkg.languageId}.json`) errors.push(`file-name-mismatch:${fileName}`);
  for (const k of ['displayName', 'nativeName']) if (typeof pkg[k] !== 'string' || !pkg[k].trim()) errors.push(k);
  if (!['ltr', 'rtl'].includes(pkg.direction)) errors.push('direction');
  const strings = pkg.strings;
  if (typeof strings !== 'object' || strings === null) return [...errors, 'strings'];
  for (const [key, types] of Object.entries(required)) {
    const v = strings[key];
    if (typeof v !== 'string') errors.push(`missing:${key}`);
    else if (!v.trim()) errors.push(`empty:${key}`);
    else if (JSON.stringify(placeholders(v)) !== JSON.stringify(Object.keys(types).sort())) errors.push(`placeholders:${key}`);
  }
  for (const key of Object.keys(strings)) if (!(key in required)) errors.push(`unknown-key:${key}`);
  return errors;
}

export function validateAll(dir = LANG_DIR) {
  const required = loadRequiredKeys();
  const results = [];
  const seen = new Set();
  for (const file of readdirSync(dir).filter((f) => f.endsWith('.json') && f !== 'manifest.json').sort()) {
    let pkg;
    let errors;
    try {
      pkg = JSON.parse(readFileSync(join(dir, file), 'utf8'));
      errors = validatePackage(pkg, required, file);
    } catch (err) {
      errors = [`invalid-json:${err.message}`];
    }
    const id = pkg?.languageId?.toLowerCase();
    if (id && seen.has(id)) errors.push('duplicate-languageId');
    if (id) seen.add(id);
    results.push({ file, languageId: pkg?.languageId ?? null, pkg, errors });
  }
  for (const id of ['en']) if (!seen.has(id)) results.push({ file: `${id}.json`, languageId: id, errors: ['required-bundled-language-missing'] });
  return results;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const results = validateAll();
  let failed = false;
  for (const r of results) {
    if (r.errors.length) {
      failed = true;
      console.error(`✗ ${r.file}: ${r.errors.slice(0, 20).join(', ')}${r.errors.length > 20 ? ` …(+${r.errors.length - 20})` : ''}`);
    } else console.log(`✓ ${r.file} (${r.languageId}, v${r.pkg.packageVersion}, ${Object.keys(r.pkg.strings).length} strings)`);
  }
  process.exit(failed ? 1 : 0);
}
