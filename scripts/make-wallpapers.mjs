// Renders the two lock-screen wallpapers (1170×2532 PNG) from the shared Figma pictograms.
// Layout follows the Figma lock-screen frames: flat background, pictogram centred in the
// 35–70 % band, no embedded text (spec §11.1). Requires rsvg-convert and ImageMagick (dev only).
import { execFileSync } from 'node:child_process';
import { mkdirSync, rmSync } from 'node:fs';
import { join } from 'node:path';
import { ROOT } from '../server/demo/util.mjs';

const OUT = join(ROOT, 'assets/wallpapers');
const TMP = join(ROOT, 'state/tmp');
const WALLPAPERS = [
  { kind: 'earthquake', pictogram: 'protect-head', background: '#ffe7d9' },
  { kind: 'tsunami', pictogram: 'tsunami-evacuate', background: '#ff6b35' },
];
const SIZE = 640; // ≈ 52 % of the width; spans 37–63 % of the height when centred

mkdirSync(OUT, { recursive: true });
mkdirSync(TMP, { recursive: true });
for (const { kind, pictogram, background } of WALLPAPERS) {
  const raster = join(TMP, `${pictogram}.png`);
  execFileSync('rsvg-convert', ['-w', String(SIZE), '-h', String(SIZE), '-o', raster, join(ROOT, 'assets/pictograms', `${pictogram}.svg`)]);
  execFileSync('magick', ['-size', '1170x2532', `xc:${background}`, raster, '-gravity', 'center', '-composite',
    '-depth', '8', '-strip', '-define', 'png:exclude-chunks=date,time', `PNG24:${join(OUT, `${kind}.png`)}`]);
  console.log(`wrote assets/wallpapers/${kind}.png`);
}
rmSync(TMP, { recursive: true, force: true });
