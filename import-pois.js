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
  node["amenity"](area.somalia);
  node["healthcare"](area.somalia);
  node["tourism"](area.somalia);
  node["shop"](area.somalia);
  node["office"](area.somalia);
  node["craft"](area.somalia);
  node["leisure"~"^(stadium|sports_centre|park|swimming_pool)$"](area.somalia);
);
out body;
`;

function categorize(tags) {
  const a = tags.amenity || '';
  const h = tags.healthcare || '';
  const t = tags.tourism || '';
  const s = tags.shop || '';
  const o = tags.office || '';
  const l = tags.leisure || '';
  const rel = tags.religion || '';
  if (['hospital','clinic'].includes(a) || ['hospital','clinic'].includes(h)) return ['hospital', a || h];
  if (a === 'pharmacy' || h === 'pharmacy') return ['pharmacy', 'pharmacy'];
  if (a === 'mosque' || (a === 'place_of_worship' && rel === 'muslim') || (a === 'place_of_worship')) return ['mosque', 'mosque'];
  if (['school','university','college','kindergarten'].includes(a)) return ['school', a];
  if (['bank','atm'].includes(a)) return ['bank', a];
  if (a === 'marketplace' || ['supermarket','mall','convenience','general','wholesale','kiosk','hardware','electronics','clothes','shoes','mobile_phone'].includes(s)) return ['market', s || a];
  if (['restaurant','cafe','fast_food','food_court','ice_cream','juice_bar'].includes(a)) return ['restaurant', a];
  if (['hotel','hostel','motel','guest_house'].includes(t) || a === 'hotel') return ['hotel', t || a];
  if (['townhall','embassy','courthouse','prison'].includes(a) || ['government','diplomatic','ngo'].includes(o)) return ['government', a || o];
  if (a === 'police' || a === 'fire_station') return ['police', a];
  if (a === 'fuel' || a === 'car_wash' || a === 'car_repair' || s === 'car' || s === 'car_parts') return ['fuel', a || s];
  if (['stadium','sports_centre','swimming_pool'].includes(l)) return ['leisure', l];
  if (t === 'attraction' || t === 'museum' || t === 'viewpoint') return ['tourism', t];
  if (s) return ['market', s];
  if (o) return ['government', o];
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
    const r = await fetch(SB + '/rest/v1/snas_pois?on_conflict=osm_id', {
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
