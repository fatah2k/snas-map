-- ============================================================
-- SNAS Database Optimisation — Run in Supabase SQL Editor
-- ============================================================

-- ── snas_streets: accelerate bbox RPC and name-search ───────────────────

-- GiST index for PostGIS spatial queries (used by get_roads_bbox RPC)
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_streets_geom_gist
  ON snas_streets USING GIST (geom);

-- Composite for district-scoped road loads (preloadDistrictRoads)
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_streets_district_hw
  ON snas_streets (district_id, highway_class);

-- Trigram indexes for ILIKE name searches (doSearch, chipSearch)
CREATE EXTENSION IF NOT EXISTS pg_trgm;

CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_streets_name_so_trgm
  ON snas_streets USING GIN (name_so gin_trgm_ops);

CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_streets_name_en_trgm
  ON snas_streets USING GIN (name_en gin_trgm_ops);

CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_streets_osm_name_trgm
  ON snas_streets USING GIN (osm_name gin_trgm_ops);

-- ── snas_pois: accelerate category chip search and nearest-neighbor ─────

-- Category filter (used by chipSearch nearest-POI lookup)
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_pois_category
  ON snas_pois (category);

-- Partial index: only named POIs (the ones the UI actually shows)
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_pois_named
  ON snas_pois (category, lat, lon)
  WHERE name_so IS NOT NULL OR name_en IS NOT NULL;

-- GiST for future PostGIS ST_DWithin nearest-neighbour queries
ALTER TABLE snas_pois ADD COLUMN IF NOT EXISTS geom geometry(Point, 4326);
UPDATE snas_pois SET geom = ST_SetSRID(ST_MakePoint(lon, lat), 4326)
  WHERE geom IS NULL AND lat IS NOT NULL AND lon IS NOT NULL;
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_pois_geom_gist
  ON snas_pois USING GIST (geom);

-- Keep geom in sync on upsert
CREATE OR REPLACE FUNCTION sync_poi_geom()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  NEW.geom := ST_SetSRID(ST_MakePoint(NEW.lon, NEW.lat), 4326);
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_sync_poi_geom ON snas_pois;
CREATE TRIGGER trg_sync_poi_geom
  BEFORE INSERT OR UPDATE OF lat, lon ON snas_pois
  FOR EACH ROW EXECUTE FUNCTION sync_poi_geom();

-- ── Optional: nearest-POI RPC (faster than client-side JS sort) ─────────
-- Call: POST /rest/v1/rpc/get_nearest_pois
-- Body: { "clat": 2.04, "clng": 45.34, "cat": "hospital", "lim": 10 }

CREATE OR REPLACE FUNCTION get_nearest_pois(
  clat DOUBLE PRECISION,
  clng DOUBLE PRECISION,
  cat  TEXT DEFAULT NULL,
  lim  INT  DEFAULT 10
)
RETURNS TABLE (
  poi_id        BIGINT,
  name_so       TEXT,
  name_en       TEXT,
  category      TEXT,
  lat           DOUBLE PRECISION,
  lon           DOUBLE PRECISION,
  phone         TEXT,
  website       TEXT,
  opening_hours TEXT,
  dist_m        DOUBLE PRECISION
)
LANGUAGE sql STABLE AS $$
  SELECT
    poi_id, name_so, name_en, category, lat, lon,
    phone, website, opening_hours,
    ST_Distance(
      geom::geography,
      ST_SetSRID(ST_MakePoint(clng, clat), 4326)::geography
    ) AS dist_m
  FROM snas_pois
  WHERE (cat IS NULL OR category = cat)
    AND (name_so IS NOT NULL OR name_en IS NOT NULL)
    AND geom IS NOT NULL
  ORDER BY geom <-> ST_SetSRID(ST_MakePoint(clng, clat), 4326)
  LIMIT lim;
$$;

-- Grant public read access
GRANT EXECUTE ON FUNCTION get_nearest_pois TO anon, authenticated;

-- ── Postcode format standardisation check ───────────────────────────────
-- Verify all districts have LLNN format prefix (e.g. MG, HD, BN)
SELECT district_id, name_en, postcode_prefix
FROM snas_districts
WHERE postcode_prefix IS NULL
   OR postcode_prefix !~ '^[A-Z]{2}$'
ORDER BY district_id;
-- If any rows return, fix them:
-- UPDATE snas_districts SET postcode_prefix = UPPER(LEFT(name_en,2)) WHERE postcode_prefix IS NULL;
