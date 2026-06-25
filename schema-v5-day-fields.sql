-- Championship tracker — v5 migration: rich qualifier days + liga description
--
-- Run after v1–v4. Safe to re-run.
--
-- Each qualifier day now carries the same optional fields as an event:
-- description, registration link, start/end time. Tournaments also get a
-- description so the championship can carry overall context that pairs with
-- the per-day description.

ALTER TABLE tournaments
  ADD COLUMN IF NOT EXISTS description TEXT;

ALTER TABLE qualifier_days
  ADD COLUMN IF NOT EXISTS description  TEXT,
  ADD COLUMN IF NOT EXISTS link_url     TEXT,
  ADD COLUMN IF NOT EXISTS start_time   TIME,
  ADD COLUMN IF NOT EXISTS end_time     TIME;

-- Enforce time ordering when both are set.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.table_constraints
    WHERE table_name = 'qualifier_days'
      AND constraint_name = 'qualifier_days_time_range'
  ) THEN
    ALTER TABLE qualifier_days
      ADD CONSTRAINT qualifier_days_time_range
      CHECK (end_time IS NULL OR start_time IS NULL OR end_time >= start_time);
  END IF;
END $$;
