// npm run demo:prepare — refreshes the real-API fixture, wallpapers, asset/language manifests.
// Offline with a valid existing fixture succeeds; no fixture and no API fails. Never invents a quake.
import { execFileSync } from 'node:child_process';
import { existsSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { FIXTURE_DIR, fetchLiveQuake, loadFixture, QUAKE_API_URL } from '../server/demo/quake.mjs';
import { parseTsunamiHistory, TSUNAMI_API_URL } from '../server/demo/tsunami.mjs';
import { atomicWrite, fetchLimited, ROOT, sha256 } from '../server/demo/util.mjs';

export const RESOURCE_VERSION = 2;
let ok = true;

// 1. Earthquake fixture (real 551 response, times untouched).
try {
  const { text, quake } = await fetchLiveQuake();
  const fetchedAt = new Date().toISOString();
  await atomicWrite(join(FIXTURE_DIR, 'quake551.json'), text);
  await atomicWrite(join(FIXTURE_DIR, 'metadata.json'), JSON.stringify({ source: QUAKE_API_URL, fetchedAt, sha256: sha256(text), sourceEventId: quake.sourceEventId, issuedAt: quake.issuedAt, note: 'Real P2P地震情報 API response captured by demo:prepare.' }, null, 2) + '\n');
  console.log(`✓ fixture refreshed from live API (${quake.sourceEventId}, issued ${quake.issuedAt})`);
} catch (err) {
  const fixture = await loadFixture();
  if (fixture) console.log(`! live API unavailable (${err.message}); existing fixture is valid (${fixture.quake.sourceEventId})`);
  else {
    console.error(`✗ live API unavailable (${err.message}) and no valid fixtures/demo/quake551.json`);
    ok = false;
  }
}

// 2. Tsunami fixture only if the real history has an item; an empty array means "no latest history".
try {
  const { status, text } = await fetchLimited(TSUNAMI_API_URL, { timeoutMs: 3000 });
  if (status !== 200) throw new Error(`http-${status}`);
  const record = parseTsunamiHistory(text);
  if (record) {
    await atomicWrite(join(FIXTURE_DIR, 'tsunami552.json'), text);
    await atomicWrite(join(FIXTURE_DIR, 'tsunami552.metadata.json'), JSON.stringify({ source: TSUNAMI_API_URL, fetchedAt: new Date().toISOString(), sha256: sha256(text), sourceEventId: record.sourceEventId }, null, 2) + '\n');
    console.log(`✓ tsunami fixture saved (${record.sourceEventId}, areas: ${record.areas.length})`);
  } else console.log('· tsunami history is empty (no latest history ≠ no danger); tsunami drills fall back to source=local');
} catch (err) {
  console.log(`· tsunami history unavailable (${err.message}); keeping existing tsunami fixture if any`);
}

// 3. Wallpapers.
try {
  execFileSync(process.execPath, [join(ROOT, 'scripts/make-wallpapers.mjs')], { stdio: 'inherit' });
} catch {
  if (['earthquake', 'tsunami'].every((k) => existsSync(join(ROOT, 'assets/wallpapers', `${k}.png`)))) console.log('! could not re-render wallpapers (rsvg-convert/magick); using committed PNGs');
  else { console.error('✗ wallpapers missing'); ok = false; }
}

// 4. Asset manifest (versioned, checksummed; no internal paths).
const files = ['wallpapers/earthquake.png', 'wallpapers/tsunami.png', 'cards.json',
  ...['protect-head', 'check-surroundings', 'check-fire', 'secure-exit', 'tsunami-evacuate'].map((p) => `pictograms/${p}.svg`)]
  .filter((p) => existsSync(join(ROOT, 'assets', p)))
  .map((path) => ({ path, sha256: sha256(readFileSync(join(ROOT, 'assets', path))) }));
await atomicWrite(join(ROOT, 'assets/manifest.json'), JSON.stringify({ schemaVersion: 1, resourceVersion: RESOURCE_VERSION, files }, null, 2) + '\n');
console.log(`✓ assets/manifest.json (resourceVersion ${RESOURCE_VERSION}, ${files.length} files)`);

// 5. Language manifest + iOS copy.
try {
  execFileSync(process.execPath, [join(ROOT, 'scripts/languages-prepare.mjs')], { stdio: 'inherit' });
} catch {
  ok = false;
}

process.exit(ok ? 0 : 1);
