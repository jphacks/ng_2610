import { readFile, stat } from 'node:fs/promises';
import { join } from 'node:path';
import { readJsonOrNull, ROOT, sha256 } from './util.mjs';

export const ASSETS_DIR = join(ROOT, 'assets');
export const WALLPAPER_KINDS = ['earthquake', 'tsunami'];
const PNG_SIGNATURE = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);

// Verified immutable artwork for downloads and shortcut generation.
export class AssetStore {
  constructor({ assetsDir = ASSETS_DIR } = {}) {
    this.assetsDir = assetsDir;
    this.wallpapers = new Map();
    this.manifest = null;
    this.languageManifest = null;
    this.shortcutManifest = null;
  }

  async load() {
    this.manifest = await readJsonOrNull(join(this.assetsDir, 'manifest.json'));
    this.languageManifest = await readJsonOrNull(join(this.assetsDir, 'languages/manifest.json'));
    this.shortcutManifest = await readJsonOrNull(join(this.assetsDir, 'shortcuts/manifest.json'));
    for (const kind of WALLPAPER_KINDS) {
      try {
        this.wallpapers.set(kind, await this.verifyWallpaper(kind));
      } catch {
        this.wallpapers.delete(kind);
      }
    }
  }

  get resourceVersion() {
    return this.manifest?.resourceVersion ?? null;
  }

  languagePackageVersion(languageId) {
    return this.languageManifest?.languages?.find((l) => l.languageId === languageId)?.packageVersion ?? null;
  }

  async verifyWallpaper(kind) {
    if (!WALLPAPER_KINDS.includes(kind)) throw new Error('unknown-wallpaper');
    const bytes = await readFile(join(this.assetsDir, 'wallpapers', `${kind}.png`));
    if (!bytes.subarray(0, 8).equals(PNG_SIGNATURE)) throw new Error('not-png');
    const expected = this.manifest?.files?.find((f) => f.path === `wallpapers/${kind}.png`)?.sha256;
    if (!expected || expected !== sha256(bytes)) throw new Error('checksum-mismatch');
    return bytes;
  }

  wallpaper(kind) {
    return this.wallpapers.get(kind) ?? null;
  }

  // Only files listed in the generated manifest are served (allowlist).
  async languageFile(languageId) {
    const entry = this.languageManifest?.languages?.find((l) => l.languageId === languageId);
    if (!entry) return null;
    const bytes = await readFile(join(this.assetsDir, 'languages', entry.file));
    return sha256(bytes) === entry.sha256 ? bytes : null;
  }

  async shortcutFile(fileName) {
    const allowed = new Set((this.shortcutManifest?.shortcuts ?? []).map((s) => s.file).filter(Boolean));
    if (this.shortcutManifest?.bundle?.file) allowed.add(this.shortcutManifest.bundle.file);
    if (!allowed.has(fileName)) return null;
    const path = join(this.assetsDir, 'shortcuts', fileName);
    try {
      await stat(path);
      return await readFile(path);
    } catch {
      return null;
    }
  }

  status() {
    return {
      resourceVersion: this.resourceVersion,
      wallpapers: Object.fromEntries(WALLPAPER_KINDS.map((k) => [k, this.wallpapers.has(k)])),
      languages: (this.languageManifest?.languages ?? []).map((l) => ({ languageId: l.languageId, packageVersion: l.packageVersion })),
      shortcuts: (this.shortcutManifest?.shortcuts ?? []).map((s) => ({ id: s.id, version: s.version, available: Boolean(s.file || s.iCloudURL) })),
    };
  }
}
