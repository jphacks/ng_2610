// Discovers valid language packages, writes the public manifest and copies them into the iOS bundle.
// No hand-maintained supportedLanguages list (spec §12.2).
import { copyFileSync, mkdirSync, readdirSync, readFileSync, rmSync, statSync } from 'node:fs';
import { join } from 'node:path';
import { atomicWrite, ROOT, sha256 } from '../server/demo/util.mjs';
import { LANG_DIR, validateAll } from './languages-validate.mjs';

const IOS_LANG_DIR = join(ROOT, 'nigeyo-ios/Nigeyo/Resources/Languages');
const MAX_PACKAGE_BYTES = 256 * 1024;

const results = validateAll();
const bad = results.filter((r) => r.errors.length);
if (bad.length) {
  for (const r of bad) console.error(`✗ ${r.file}: ${r.errors.slice(0, 10).join(', ')}`);
  process.exit(1);
}
const languages = results.map(({ file, pkg }) => {
  const bytes = readFileSync(join(LANG_DIR, file));
  if (bytes.length > MAX_PACKAGE_BYTES) throw new Error(`${file} exceeds 256KB`);
  return { languageId: pkg.languageId, packageVersion: pkg.packageVersion, nativeName: pkg.nativeName, displayName: pkg.displayName, direction: pkg.direction, file, bytes: bytes.length, sha256: sha256(bytes) };
});
await atomicWrite(join(LANG_DIR, 'manifest.json'), JSON.stringify({ schemaVersion: 1, languages }, null, 2) + '\n');

mkdirSync(IOS_LANG_DIR, { recursive: true });
for (const f of readdirSync(IOS_LANG_DIR)) if (statSync(join(IOS_LANG_DIR, f)).isFile()) rmSync(join(IOS_LANG_DIR, f));
for (const l of languages) copyFileSync(join(LANG_DIR, l.file), join(IOS_LANG_DIR, l.file));
copyFileSync(join(ROOT, 'assets/cards.json'), join(ROOT, 'nigeyo-ios/Nigeyo/Resources/cards.json'));
console.log(`manifest: ${languages.map((l) => `${l.languageId}@${l.packageVersion}`).join(', ')}; copied to nigeyo-ios/Nigeyo/Resources/Languages`);
