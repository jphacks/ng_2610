// Builds the two distributable shortcuts (earthquake / tsunami), signs them with `shortcuts sign`
// when available, zips them with the guide, and writes assets/shortcuts/manifest.json (spec §11.4–11.5).
// Each shortcut: Get Contents of URL (wallpaper, origin asked at import) → Set Wallpaper (no preview) → Open nigeyo://guide.
// No token, key or personal bundle ID is embedded; the notification automation itself is set up by the user.
import { execFileSync } from 'node:child_process';
import { chmodSync, existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { atomicWrite, ROOT, sha256 } from '../server/demo/util.mjs';

const DIR = join(ROOT, 'assets/shortcuts');
const TMP = join(ROOT, 'state/shortcuts-build');
const VERSION = '1.1.0';
const STEPS_VERSION = 1;
const SHORTCUTS = [
  // One shortcut for both hazards: the server swaps the image behind this fixed URL before each notification.
  { id: 'nigeyo', title: 'Nigeyo', triggerTitle: 'EARTHQUAKE_TEST / TSUNAMI_TEST', wallpaperPath: '/public/assets/wallpaper.png' },
];

const esc = (s) => String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
function plistValue(v) {
  if (v === true) return '<true/>';
  if (v === false) return '<false/>';
  if (typeof v === 'number') return Number.isInteger(v) ? `<integer>${v}</integer>` : `<real>${v}</real>`;
  if (typeof v === 'string') return `<string>${esc(v)}</string>`;
  if (Array.isArray(v)) return `<array>${v.map(plistValue).join('')}</array>`;
  return `<dict>${Object.entries(v).map(([k, x]) => `<key>${esc(k)}</key>${plistValue(x)}`).join('')}</dict>`;
}

function workflow({ wallpaperPath }) {
  const urlUUID = '4F1D3A52-0E1B-4C1C-9B7A-2D6E8F1A0001';
  const placeholderURL = `https://YOUR-TUNNEL.trycloudflare.com${wallpaperPath}`;
  return {
    WFWorkflowMinimumClientVersion: 900,
    WFWorkflowMinimumClientVersionString: '900',
    WFWorkflowClientVersion: '2302.0.4',
    WFWorkflowIcon: { WFWorkflowIconStartColor: 4282601983, WFWorkflowIconGlyphNumber: 59511 },
    WFWorkflowTypes: [],
    WFWorkflowInputContentItemClasses: [],
    WFWorkflowHasShortcutInputVariables: false,
    WFWorkflowImportQuestions: [{
      ActionIndex: 0, Category: 'Parameter', ParameterKey: 'WFURL', DefaultValue: placeholderURL,
      Text: `Nigeyo wallpaper URL: replace the host with the demo Mac's public HTTPS origin, keep the path ${wallpaperPath}`,
    }],
    WFWorkflowActions: [
      { WFWorkflowActionIdentifier: 'is.workflow.actions.downloadurl', WFWorkflowActionParameters: { WFURL: placeholderURL, WFHTTPMethod: 'GET', UUID: urlUUID } },
      { WFWorkflowActionIdentifier: 'is.workflow.actions.wallpaper.set', WFWorkflowActionParameters: {
        WFInput: { Value: { OutputUUID: urlUUID, Type: 'ActionOutput', OutputName: 'Contents of URL' }, WFSerializationType: 'WFTextTokenAttachment' },
        WFWallpaperShowPreview: false, WFWallpaperLocation: 'Lock Screen' } },
      { WFWorkflowActionIdentifier: 'is.workflow.actions.openurl', WFWorkflowActionParameters: { WFInput: 'nigeyo://guide' } },
    ],
  };
}

mkdirSync(DIR, { recursive: true });
rmSync(TMP, { recursive: true, force: true });
mkdirSync(TMP, { recursive: true });
const entries = [];
for (const s of SHORTCUTS) {
  const xml = `<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0">${plistValue(workflow(s))}</plist>\n`;
  const unsigned = join(TMP, `${s.id}.unsigned.shortcut`);
  writeFileSync(unsigned, xml);
  execFileSync('plutil', ['-convert', 'binary1', unsigned]);
  const file = `nigeyo-${s.id}.shortcut`;
  let signed = false;
  rmSync(join(DIR, file), { force: true });
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
    id: s.id, title: s.title, version: VERSION, minimumOSVersion: '27.0', triggerTitle: s.triggerTitle, wallpaperPath: s.wallpaperPath,
    file: signed ? file : null, sha256: signed ? sha256(readFileSync(join(DIR, file))) : null, iCloudURL: null, signed,
    importQuestions: ['wallpaper URL (public HTTPS origin + wallpaperPath)'],
    actions: ['Get Contents of URL', 'Set Wallpaper (Lock Screen, preview off)', 'Open URL nigeyo://guide'],
  });
  console.log(`${signed ? '✓' : '✗'} ${file}${signed ? '' : ' (unsigned; see docs/shortcuts.md for manual creation)'}`);
}

writeFileSync(join(TMP, 'manifest.json'), JSON.stringify({ shortcuts: entries }, null, 2));
const guide = join(ROOT, 'docs/shortcuts.md');
const zipInputs = [...entries.filter((e) => e.file).map((e) => join(DIR, e.file)), join(TMP, 'manifest.json'), ...(existsSync(guide) ? [guide] : [])];
let bundle = null;
try {
  rmSync(join(DIR, 'bundle.zip'), { force: true });
  execFileSync('zip', ['-j', '-X', '-q', join(DIR, 'bundle.zip'), ...zipInputs]);
  bundle = { file: 'bundle.zip', sha256: sha256(readFileSync(join(DIR, 'bundle.zip'))), note: 'Download only: adding and enabling each shortcut is done by the user on the iPhone.' };
} catch (err) {
  console.warn(`! zip failed: ${err.message}`);
}
await atomicWrite(join(DIR, 'manifest.json'), JSON.stringify({ schemaVersion: 1, stepsVersion: STEPS_VERSION, shortcuts: entries, bundle }, null, 2) + '\n');
rmSync(TMP, { recursive: true, force: true });
console.log('wrote assets/shortcuts/manifest.json');
