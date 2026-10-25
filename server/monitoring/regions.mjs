import { readFileSync } from 'node:fs';

// One table is shared with iOS; no second hand-maintained copy.
export const regions = JSON.parse(readFileSync(new URL('../../nigeyo-ios/Nigeyo/Resources/notification-regions-aichi.json', import.meta.url)));
const slots = new Set(['home.earthquake', 'home.tsunami', 'university.earthquake', 'university.tsunami']);
export function resolveRegion({ address = '', municipality = '' } = {}) {
  const normalize = (s) => String(s).normalize('NFKC').replace(/[\s　]/g, '');
  const values = [address, municipality].map(normalize).filter(Boolean);
  // Require a prefecture in at least one field. Bare "美浜町" is ambiguous nationwide.
  if (!values.some((s) => s.startsWith('愛知県'))) return null;
  if (values.some((s) => /^(?!愛知県).+[都道府県]/.test(s))) return null;
  const matches = regions.municipalities.filter((m) => values.some((s) => {
    const local = s.replace(/^愛知県/, '').replace(/^[^市町村]+郡/, '');
    return local.startsWith(m.name);
  }));
  return matches.length === 1 ? structuredClone(matches[0]) : null;
}

// Configuration is intentionally small, independently validated on the server.
export function validSubscription(c) {
  if (!c || c.version !== regions.version || typeof c.enabled !== 'boolean' || !Array.isArray(c.targets) || c.targets.length > 4) return false;
  const seen = new Set();
  for (const t of c.targets) {
    if (!t || !slots.has(t.slot) || seen.has(t.slot) || typeof t.siteId !== 'string' || !t.siteId || t.siteId.length > 128 ||
        !regions.earthquakeAreas.some((a) => a.pref === t.earthquakeArea?.pref && a.name === t.earthquakeArea?.name) ||
        !['configured', 'none'].includes(t.tsunamiStatus) || !Array.isArray(t.tsunamiAreas) || t.tsunamiAreas.length > 2 ||
        t.tsunamiAreas.some((a) => !regions.tsunamiAreas.includes(a)) || new Set(t.tsunamiAreas).size !== t.tsunamiAreas.length ||
        (t.tsunamiStatus === 'none' ? t.tsunamiAreas.length !== 0 : t.tsunamiAreas.length === 0)) return false;
    seen.add(t.slot);
  }
  return !c.enabled || c.targets.length > 0;
}
