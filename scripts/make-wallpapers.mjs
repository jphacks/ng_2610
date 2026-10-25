// Approved raster artwork is the source of truth. Never regenerate it from the UI SVGs.
// Validate and copy the same assets into the app's offline export resources.
import { copyFile, readFile } from 'node:fs/promises';
import { join } from 'node:path';
import { ROOT, sha256 } from '../server/demo/util.mjs';

for (const kind of ['earthquake', 'tsunami']) {
  const source = join(ROOT, 'assets/wallpapers', `${kind}.png`);
  const bytes = await readFile(source);
  if (!bytes.subarray(0, 8).equals(Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]))) throw new Error(`invalid-png:${kind}`);
  await copyFile(source, join(ROOT, 'nigeyo-ios/Nigeyo/Resources/Wallpapers', `${kind}.png`));
  console.log(`verified ${kind}.png (${sha256(bytes)}) and copied to iOS`);
}
