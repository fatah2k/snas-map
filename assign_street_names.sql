-- ============================================================
-- SNAS Auto Street Name Assignment
-- Assigns wordbank names to all unnamed roads in snas_streets
-- Run in Supabase SQL Editor in batches (same as postcode script)
-- ============================================================

-- Word bank arrays (18 types × 5 road types = 1620+ combinations)
-- Same logic as the JS autoName() function

WITH words AS (
  SELECT word, idx FROM (VALUES
    ('nabad',0),('xorriyad',1),('cusub',2),('weyn',3),('yar',4),
    ('hore',5),('bari',6),('galbeed',7),('waqooyi',8),('koonfur',9),
    ('badda',10),('dugsi',11),('masjid',12),('suuq',13),('garoon',14),
    ('cisbitaal',15),('dowlad',16),('xaafad',17)
  ) AS w(word, idx)
),
types AS (
  SELECT rtype, tidx FROM (VALUES
    ('Wadada',0),('Jidka',1),('Dhabbada',2),('Luuqa',3),('Xaariga',4)
  ) AS t(rtype, tidx)
),
batch AS (
  SELECT s.ctid,
    t.rtype || ' ' ||
    INITCAP(w1.word) ||
    CASE WHEN w1.idx != w2.idx THEN ' ' || INITCAP(w2.word) ELSE '' END AS auto_name
  FROM snas_streets s
  JOIN types t ON t.tidx = (ABS(s.street_id) % 5)
  JOIN words w1 ON w1.idx = (FLOOR(ABS(s.street_id)::NUMERIC / 5) % 18)::INT
  JOIN words w2 ON w2.idx = (FLOOR(ABS(s.street_id)::NUMERIC / 90) % 18)::INT
  WHERE (
    s.name_so IS NULL
    OR s.name_so = ''
    OR s.name_so = 'Unnamed'
    OR s.name_so ~ '^(Wadada|Jidka|Dhabbada|Luuqa|Avenyu|Bulvardi|Xaariga)\s+(\d{4,}|\d{1,4}-\d+)'
  )
  LIMIT 5000
)
UPDATE snas_streets s
SET name_so = batch.auto_name
FROM batch
WHERE s.ctid = batch.ctid;

-- Run the above repeatedly until it says 0 rows updated.
-- Then check remaining unnamed roads:
-- SELECT COUNT(*) FROM snas_streets
-- WHERE name_so IS NULL OR name_so='' OR name_so='Unnamed'
--   OR name_so ~ '^(Wadada|Jidka|Dhabbada|Luuqa|Avenyu|Bulvardi|Xaariga)\s+(\d{4,}|\d{1,4}-\d+)';
