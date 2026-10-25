// Copy verified, already-signed files into the app. No signing service or server required.
import { copyFileSync, mkdirSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { ROOT, sha256 } from '../server/demo/util.mjs';

const source = join(ROOT, 'assets/shortcuts');
const target = join(ROOT, 'nigeyo-ios/Nigeyo/Resources/Shortcuts');
const manifest = JSON.parse(readFileSync(join(source, 'manifest.json'), 'utf8'));
const files = ['earthquake', 'tsunami'].map((id) => {
  const item = manifest.shortcuts.find((s) => s.id === id);
  if (!item?.signed || item.file !== `nigeyo-${id}.shortcut`) throw new Error(`missing-signed-shortcut:${id}`);
  const bytes = readFileSync(join(source, item.file));
  if (bytes.subarray(0, 4).toString() !== 'AEA1' || sha256(bytes) !== item.sha256) throw new Error(`invalid-signed-shortcut:${id}`);
  return item.file;
});
mkdirSync(target, { recursive: true });
for (const file of files) {
  copyFileSync(join(source, file), join(target, file));
  console.log(`✓ bundled ${file}`);
}
