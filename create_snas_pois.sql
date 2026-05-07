-- SNAS POI Table
-- Run in Supabase SQL Editor (Dashboard → SQL Editor)

CREATE TABLE IF NOT EXISTS snas_pois (
  poi_id    BIGSERIAL PRIMARY KEY,
  osm_id    BIGINT UNIQUE,
  name_so   TEXT,
  name_en   TEXT,
  name_ar   TEXT,
  category  TEXT NOT NULL DEFAULT 'other',
  subcategory TEXT,
  lat       DOUBLE PRECISION NOT NULL,
  lon       DOUBLE PRECISION NOT NULL,
  district_id INTEGER REFERENCES snas_districts(district_id)
);

CREATE INDEX IF NOT EXISTS idx_snas_pois_category  ON snas_pois(category);
CREATE INDEX IF NOT EXISTS idx_snas_pois_district  ON snas_pois(district_id);
CREATE INDEX IF NOT EXISTS idx_snas_pois_name_so   ON snas_pois(name_so);
CREATE INDEX IF NOT EXISTS idx_snas_pois_name_en   ON snas_pois(name_en);

ALTER TABLE snas_pois ENABLE ROW LEVEL SECURITY;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE tablename='snas_pois' AND policyname='public_read_pois') THEN
    CREATE POLICY "public_read_pois" ON snas_pois FOR SELECT USING (true);
  END IF;
END $$;

-- Allow inserts from service_role key only (anon cannot write)
-- The import script must use the service_role key, not the anon key.
