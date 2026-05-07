#!/usr/bin/env node
// import-pois.js — Fetch Somali POIs from Overpass API → upsert to Supabase snas_pois
// Usage: node import-pois.js
// Requires Node 18+ (built-in fetch) or: npm install node-fetch

const SB = 'https://fglmvdewfvxlqiwhpwue.supabase.co';
// ⚠️  Use your SERVICE_ROLE key from Supabase → Settings → API (not the anon key)
const SERVICE_KEY = process.env.SUPABASE_SERVICE_KEY || 'REPLACE_WITH_SERVICE_ROLE_KEY';

const HDR = {
  apikey: SERVICE_KEY,
  Authorization: 'Bearer ' + SERVICE_KEY,
  'Content-Type': 'application/json',
  Prefer: 'resolution=merge-duplicates',
};

const OVERPASS = 'https://overpass-api.de/api/interpreter';
const OVERPASS_MIRROR = 'https://overpass.kumi.systems/api/interpreter';

const QUERY = `
[out:json][timeout:180];
area["ISO3166-1"="SO"]->.somalia;
(
  node["amenity"~"^(hospital|clinic|pharmacy|school|university|college|bank|mosque|place_of_worship|marketplace|restaurant|cafe|fast_food|hotel|police|library|townhall|post_office|fuel)$"](area.somalia);
  node["healthcare"~"^(hospital|clinic|pharmacy)$"](area.somalia);
  node["tourism"~"^(hotel|hostel|motel|attraction)$"](area.somalia);
  node["shop"~"^(supermarket|mall|market|general|convenience)$"](area.somalia);
  node["office"~"^(government|ngo|diplomatic)$"](area.somalia);
);
out body;
`;

function categorize(tags) {
  const a = tags.amenity || '';
  const h = tags.healthcare || '';
  const t = tags.tourism || '';
  const s = tags.shop || '';
  const o = tags.office || '';
  const rel = tags.religion || '';
  if (a === 'hospital' || a === 'clinic' || h === 'hospital' || h === 'clinic') return ['hospital', a || h];
  if (a === 'pharmacy' || h === 'pharmacy') return ['pharmacy', 'pharmacy'];
  if (a === 'mosque' || a === 'place_of_worship' && rel === 'muslim') return ['mosque', 'mosque'];
  if (a === 'school' || a === 'university' || a === 'college') return ['school', a];
  if (a === 'bank') return ['bank', 'bank'];
  if (a === 'marketplace' || s) return ['market', s || 'marketplace'];
  if (a === 'restaurant' || a === 'cafe' || a === 'fast_food') return ['restaurant', a];
  if (t) return ['hotel', t];
  if (a === 'townhall' || o === 'government' || o === 'diplomatic') return ['government', a || o];
  if (a === 'police') return ['police', 'police'];
  return ['other', a || h || s || o || t || 'poi'];
}

async function overpassFetch(url) {
  const body = 'data=' + encodeURIComponent(QUERY.trim());
  return fetch(url, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/x-www-form-urlencoded',
      'Accept': 'application/json',
      'User-Agent': 'SNAS-Map-Importer/1.0',
    },
    body,
  });
}

async function run() {
  console.log('Fetching POIs from Overpass API...');
  let res = await overpassFetch(OVERPASS);
  if (!res.ok) {
    console.warn(`Primary endpoint returned ${res.status}, trying mirror...`);
    res = await overpassFetch(OVERPASS_MIRROR);
  }
  if (!res.ok) throw new Error('Overpass error: ' + res.status + ' — ' + await res.text());
  const data = await res.json();
  const nodes = data.elements || [];
  console.log(`Got ${nodes.length} nodes from Overpass`);

  const rows = nodes
    .filter(n => n.lat && n.lon)
    .map(n => {
      const tags = n.tags || {};
      const [category, subcategory] = categorize(tags);
      return {
        osm_id: n.id,
        name_so: tags['name:so'] || tags.name_so || null,
        name_en: tags['name:en'] || tags.name_en || tags.name || null,
        name_ar: tags['name:ar'] || null,
        category,
        subcategory,
        lat: n.lat,
        lon: n.lon,
      };
    })
    .filter(r => r.name_so || r.name_en); // skip completely unnamed nodes

  console.log(`Kept ${rows.length} named POIs`);

  // Upsert in batches of 500
  const BATCH = 500;
  let inserted = 0;
  for (let i = 0; i < rows.length; i += BATCH) {
    const batch = rows.slice(i, i + BATCH);
    const r = await fetch(SB + '/rest/v1/snas_pois', {
      method: 'POST',
      headers: HDR,
      body: JSON.stringify(batch),
    });
    if (!r.ok) {
      const err = await r.text();
      console.error(`Batch ${i / BATCH + 1} failed:`, err);
    } else {
      inserted += batch.length;
      console.log(`Upserted batch ${i / BATCH + 1} — ${inserted}/${rows.length}`);
    }
  }
  console.log('Done.');
}

run().catch(e => { console.error(e); process.exit(1); });
