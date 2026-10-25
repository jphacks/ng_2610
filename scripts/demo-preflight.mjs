// npm run demo:preflight — checks everything the live demo depends on (spec §18.1).
import { existsSync, readFileSync } from 'node:fs';
import { createServer } from 'node:net';
import { join } from 'node:path';
import { loadFixture } from '../server/demo/quake.mjs';
import { fetchLimited, readJsonOrNull, ROOT, sha256, STATE_DIR } from '../server/demo/util.mjs';
import { validateAll } from './languages-validate.mjs';

const PORT = Number(process.env.NIGEYO_PORT ?? 8788);
const results = [];
const check = (name, pass, detail = '') => results.push({ name, pass, detail });

const [major] = process.versions.node.split('.').map(Number);
check('Node.js >= 22 (team baseline 24)', major >= 22, process.version);

const portFree = await new Promise((resolve) => {
  const s = createServer().once('error', () => resolve(false)).once('listening', () => s.close(() => resolve(true))).listen(PORT, '127.0.0.1');
});
let serverRunning = false;
if (!portFree) {
  try {
    serverRunning = (await fetchLimited(`http://127.0.0.1:${PORT}/public/health`, { timeoutMs: 1500 })).status === 200;
  } catch {}
}
check(`port ${PORT}`, portFree || serverRunning, portFree ? 'free' : serverRunning ? 'in use by the Nigeyo demo server' : 'in use by another process');

const fixture = await loadFixture();
check('fixture quake551 valid', Boolean(fixture), fixture ? `${fixture.quake.sourceEventId} issued ${fixture.quake.issuedAt}, fetched ${fixture.meta.fetchedAt}` : 'run npm run demo:prepare');

for (const r of validateAll()) check(`language ${r.file}`, r.errors.length === 0, r.errors.slice(0, 3).join(', '));
const langManifest = await readJsonOrNull(join(ROOT, 'assets/languages/manifest.json'));
check('language manifest', Boolean(langManifest?.languages?.length), langManifest ? langManifest.languages.map((l) => l.languageId).join(', ') : 'missing');
for (const l of langManifest?.languages ?? []) {
  const ios = join(ROOT, 'nigeyo-ios/Nigeyo/Resources/Languages', l.file);
  check(`iOS bundle has ${l.file}`, existsSync(ios) && sha256(readFileSync(ios)) === l.sha256);
}

const manifest = await readJsonOrNull(join(ROOT, 'assets/manifest.json'));
check('asset manifest', Boolean(manifest?.resourceVersion), manifest ? `resourceVersion ${manifest.resourceVersion}` : 'missing');
for (const p of ['protect-head', 'check-surroundings', 'check-fire', 'secure-exit', 'tsunami-evacuate']) {
  check(`pictogram ${p}`, existsSync(join(ROOT, 'assets/pictograms', `${p}.svg`)) && existsSync(join(ROOT, 'nigeyo-ios/Nigeyo/Resources/Assets.xcassets', `${p}.imageset`, `${p}.svg`)));
}
for (const f of manifest?.files ?? []) {
  const path = join(ROOT, 'assets', f.path);
  check(`checksum ${f.path}`, existsSync(path) && sha256(readFileSync(path)) === f.sha256);
}

const shortcuts = await readJsonOrNull(join(ROOT, 'assets/shortcuts/manifest.json'));
for (const id of ['nigeyo']) {
  const s = shortcuts?.shortcuts?.find((x) => x.id === id);
  const path = s?.file ? join(ROOT, 'assets/shortcuts', s.file) : null;
  check(`signed shortcut ${id}`, Boolean(s?.signed && path && existsSync(path) && sha256(readFileSync(path)) === s.sha256), s ? s.file ?? 'unsigned' : 'run npm run shortcuts:build');
}

check('evacuation data bundled', existsSync(join(ROOT, 'nigeyo-ios/Nigeyo/Resources/evacuation-sites.json')), 'run npm run evacuation:import');

const config = await readJsonOrNull(join(STATE_DIR, 'config.json'));
if (config?.origin) {
  for (const p of ['/public/health', '/public/assets/wallpapers/earthquake.png', '/public/assets/wallpapers/tsunami.png', '/public/languages/manifest.json']) {
    try {
      const { status } = await fetchLimited(config.origin + p, { timeoutMs: 5000, maxBytes: 4 * 1024 * 1024 });
      check(`public ${p}`, status === 200, `HTTP ${status} via ${config.origin}`);
    } catch (err) {
      check(`public ${p}`, false, `${err.message} via ${config.origin}`);
    }
  }
} else check('public origin reachability', !serverRunning, 'no origin registered yet (set it on the PC screen, then re-run)');

let failed = 0;
for (const r of results) {
  if (!r.pass) failed++;
  console.log(`${r.pass ? '✓' : '✗'} ${r.name}${r.detail ? `  — ${r.detail}` : ''}`);
}
console.log(failed ? `\n${failed} check(s) failed` : '\nall checks passed');
process.exit(failed ? 1 : 0);
