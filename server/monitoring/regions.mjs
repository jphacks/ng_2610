import { readFileSync } from 'node:fs';

// One table is shared with iOS; no second hand-maintained copy.
export const regions = JSON.parse(readFileSync(new URL('../../nigeyo-ios/Nigeyo/Resources/notification-regions-aichi.json', import.meta.url)));
const national = JSON.parse(readFileSync(new URL('../../nigeyo-ios/Nigeyo/Resources/notification-regions-national.json', import.meta.url)));
const earthquakesById = new Map(national.earthquakeAreas.map((area) => [area.id, area]));
const tsunamisById = new Map(national.tsunamiAreas.map((area) => [area.id, area.name]));
const earthquakeIds = new Map(national.earthquakeAreas.map(({ pref, name, id }) => [JSON.stringify([pref, name]), id]));
const tsunamiIds = new Map(national.tsunamiAreas.map(({ name, id }) => [name, id]));
export const earthquakeAreaId = ({ pref, name }) => earthquakeIds.get(JSON.stringify([pref, name]));
export const tsunamiAreaId = (name) => tsunamiIds.get(name);
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
  if (!c || ![regions.version, 2].includes(c.version) || typeof c.enabled !== 'boolean' || !Array.isArray(c.targets) || c.targets.length > 4) return false;
  const seen = new Set();
  for (const t of c.targets) {
    if (!t || !slots.has(t.slot) || seen.has(t.slot) || typeof t.siteId !== 'string' || !t.siteId || t.siteId.length > 128 ||
        !['configured', 'none'].includes(t.tsunamiStatus) || !Array.isArray(t.tsunamiAreas) || t.tsunamiAreas.length > 2 ||
        new Set(t.tsunamiAreas).size !== t.tsunamiAreas.length ||
        (t.tsunamiStatus === 'none' ? t.tsunamiAreas.length !== 0 : t.tsunamiAreas.length === 0)) return false;
    const sameEarthquake = (area) => area && area.pref === t.earthquakeArea?.pref && area.name === t.earthquakeArea?.name;
    if (c.version === 2) {
      if (!sameEarthquake(earthquakesById.get(t.earthquakeAreaId)) || !Array.isArray(t.tsunamiAreaIds) ||
          t.tsunamiAreaIds.length !== t.tsunamiAreas.length ||
          t.tsunamiAreaIds.some((id, i) => !tsunamisById.has(id) || tsunamisById.get(id) !== t.tsunamiAreas[i])) return false;
    } else if (!regions.earthquakeAreas.some(sameEarthquake) || t.tsunamiAreas.some((a) => !regions.tsunamiAreas.includes(a))) return false;
    seen.add(t.slot);
  }
  return !c.enabled || c.targets.length > 0;
}
