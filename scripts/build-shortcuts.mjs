// Builds the two distributable shortcuts (earthquake / tsunami), signs them with `shortcuts sign`
// when available, zips them with the guide, and writes assets/shortcuts/manifest.json (spec §11.4–11.5).
// Each shortcut: bundled PNG → decode locally → Set Wallpaper → Open nigeyo://guide.
// Each includes a native OS 27 notification automation header with its exact title filter.
// The recipient enables the imported trigger and verifies the target app and permissions.
import { execFileSync } from 'node:child_process';
import { chmodSync, existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { atomicWrite, ROOT, sha256 } from '../server/demo/util.mjs';
import { SHORTCUTS, workflow, plistValue } from './shortcut-workflows.mjs';

const DIR = join(ROOT, 'assets/shortcuts');
const TMP = join(ROOT, 'state/shortcuts-build');
const VERSION = '1.3.0';
const STEPS_VERSION = 3;
const APP_BUNDLE_ID = process.env.NIGEYO_APP_BUNDLE_ID ?? 'jp.nigeyo.hackathon';
mkdirSync(DIR, { recursive: true });
rmSync(TMP, { recursive: true, force: true });
mkdirSync(TMP, { recursive: true });
const entries = [];
for (const s of SHORTCUTS) {
  const png = readFileSync(join(ROOT, `assets/wallpapers/${s.id}.png`));
  const xml = `<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0">${plistValue(workflow(png, { ...s, bundleIdentifier: APP_BUNDLE_ID }))}</plist>\n`;
  const unsigned = join(TMP, `${s.id}.unsigned.shortcut`);
  writeFileSync(unsigned, xml);
  execFileSync('plutil', ['-convert', 'binary1', unsigned]);
  const file = `nigeyo-${s.id}.shortcut`;
  let signed = false;

  // Apple's signing service intermittently answers HTTP 500; retry a few times.
  for (let attempt = 1; attempt <= 4 && !signed; attempt++) {
    try {
      execFileSync('shortcuts', ['sign', '--mode', 'anyone', '--input', unsigned, '--output', join(DIR, file)], { stdio: 'pipe' });
      signed = existsSync(join(DIR, file));
    } catch (err) {
      console.warn(`! sign ${file} attempt ${attempt}: ${String(err.stderr ?? err.message).trim().split('\n')[0]}`);
      execFileSync('sleep', ['3']);
    }
  }
  if (signed) chmodSync(join(DIR, file), 0o644);
  entries.push({
    id: s.id, title: s.title, version: VERSION, minimumOSVersion: '27.0', triggerTitle: s.triggerTitle,
    automation: { included: true, type: 'notification', appBundleIdentifier: APP_BUNDLE_ID, titleContains: s.triggerTitle, requiresUserEnable: true },
    imageStorage: 'embedded-base64', imageFile: `${s.id}.png`, imageSHA256: sha256(png),
    file: signed ? file : null, sha256: signed ? sha256(readFileSync(join(DIR, file))) : null, iCloudURL: null, signed,
    importQuestions: [],
    actions: ['Embedded PNG', 'Base64 Decode', 'Get Images from Input', 'Set Wallpaper (Lock Screen, preview off)', 'Open URL nigeyo://guide'],
  });
  console.log(`${signed ? '✓' : '✗'} ${file}${signed ? '' : ' (unsigned; see docs/shortcuts.md for manual creation)'}`);
}

writeFileSync(join(TMP, 'manifest.json'), JSON.stringify({ shortcuts: entries }, null, 2));
const guide = join(ROOT, 'docs/shortcuts.md');
const zipInputs = [...entries.filter((e) => e.file).map((e) => join(DIR, e.file)), join(TMP, 'manifest.json'), ...SHORTCUTS.map((s) => join(ROOT, `assets/wallpapers/${s.id}.png`)), ...(existsSync(guide) ? [guide] : [])];
let bundle = null;
try {
  rmSync(join(DIR, 'bundle.zip'), { force: true });
  execFileSync('zip', ['-j', '-X', '-q', join(DIR, 'bundle.zip'), ...zipInputs]);
  bundle = { file: 'bundle.zip', sha256: sha256(readFileSync(join(DIR, 'bundle.zip'))), note: 'Two shortcuts with embedded local images, standalone PNGs and setup guide. Notification triggers included. Enable each imported automation and verify the Nigeyo app selection on the iPhone.' };
} catch (err) {
  console.warn(`! zip failed: ${err.message}`);
}
await atomicWrite(join(DIR, 'manifest.json'), JSON.stringify({ schemaVersion: 1, stepsVersion: STEPS_VERSION, shortcuts: entries, bundle }, null, 2) + '\n');
rmSync(TMP, { recursive: true, force: true });
console.log('wrote assets/shortcuts/manifest.json');

if (entries.some((e) => !e.signed)) process.exitCode = 1;
else {
  rmSync(join(DIR, 'nigeyo-nigeyo.shortcut'), { force: true });
  await import('./shortcuts-prepare.mjs');
}
