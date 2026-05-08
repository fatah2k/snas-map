-- ============================================================
-- SNAS Segment Postcode System — Format LLNN LL (e.g. KA01 AB)
-- LL = district prefix · NN = zone 01-99 · LL = road code AA-ZZ
-- Run in Supabase SQL Editor
-- ============================================================

-- Add segment postcode column if not present
ALTER TABLE snas_streets ADD COLUMN IF NOT EXISTS segment_postcode TEXT;

-- Helper: encode street_id as LLNN LL within its district
-- Total capacity: 99 × 26 × 26 = 66,924 unique codes per district
UPDATE snas_streets s
SET segment_postcode = (
  WITH vals AS (
    SELECT
      ((s.street_id % (99 * 676)) % 99 + 1)                        AS zone,
      FLOOR((s.street_id % (99 * 676)) / 99)::INT                  AS si
  )
  SELECT
    COALESCE(d.postcode_prefix, 'SO') ||
    LPAD(vals.zone::TEXT, 2, '0') || ' ' ||
    CHR(65 + (vals.si / 26) % 26) ||
    CHR(65 + (vals.si % 26))
  FROM vals
)
FROM snas_districts d
WHERE s.district_id = d.district_id;

-- Index for fast postcode lookup
CREATE INDEX IF NOT EXISTS idx_streets_segment_postcode
  ON snas_streets (segment_postcode);

-- RPC: reverse geocode a point → nearest road + postcode + district prefix
CREATE OR REPLACE FUNCTION get_address_at_point(
  clat DOUBLE PRECISION,
  clng DOUBLE PRECISION
)
RETURNS TABLE (
  street_id        BIGINT,
  name_so          TEXT,
  name_en          TEXT,
  segment_postcode TEXT,
  postcode_prefix  TEXT,
  district_name    TEXT,
  region_name      TEXT,
  dist_m           DOUBLE PRECISION
)
LANGUAGE sql STABLE AS $$
  SELECT
    s.street_id,
    s.name_so,
    s.name_en,
    s.segment_postcode,
    d.postcode_prefix,
    d.name_en  AS district_name,
    d.region_id AS region_name,
    ST_Distance(
      ST_SetSRID(ST_MakePoint(clng, clat), 4326)::geography,
      s.geom::geography
    ) AS dist_m
  FROM snas_streets s
  JOIN snas_districts d ON s.district_id = d.district_id
  WHERE s.geom IS NOT NULL
    AND s.name_so IS NOT NULL
  ORDER BY s.geom <-> ST_SetSRID(ST_MakePoint(clng, clat), 4326)
  LIMIT 1;
$$;

GRANT EXECUTE ON FUNCTION get_address_at_point TO anon, authenticated;

-- Road label view
CREATE OR REPLACE VIEW snas_road_labels AS
SELECT DISTINCT ON (COALESCE(name_so, name_en, osm_name))
  street_id,
  district_id,
  COALESCE(name_so, name_en, osm_name) AS display_name,
  name_so,
  name_en,
  highway_class,
  segment_postcode,
  ST_Centroid(geom) AS label_point
FROM snas_streets
WHERE COALESCE(name_so, name_en, osm_name) IS NOT NULL
  AND geom IS NOT NULL
ORDER BY COALESCE(name_so, name_en, osm_name),
         ST_Length(geom::geography) DESC;

GRANT SELECT ON snas_road_labels TO anon, authenticated;
