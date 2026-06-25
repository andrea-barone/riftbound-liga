-- Championship tracker — v4 migration: events
--
-- Run after schema.sql, schema-v2-multi-org.sql, schema-v3-game-systems.sql.
-- Safe to re-run.
--
-- Adds a single `events` table that holds both one-off events
-- (kind='oneoff' + event_date) and recurring weekly events
-- (kind='recurring' + day_of_week, optional starts_on/ends_on bounds).

CREATE TABLE IF NOT EXISTS events (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  game_system_key TEXT,                          -- optional system tag
  kind            TEXT NOT NULL CHECK (kind IN ('oneoff', 'recurring')),
  name            TEXT NOT NULL,
  description     TEXT,
  link_url        TEXT,

  -- For kind='oneoff':
  event_date      DATE,

  -- For kind='recurring' (weekly schedule):
  day_of_week     SMALLINT CHECK (day_of_week IS NULL OR day_of_week BETWEEN 0 AND 6),  -- 0=Mon ... 6=Sun
  starts_on       DATE,                          -- optional lower bound (recurring)
  ends_on         DATE,                          -- optional upper bound (recurring)

  -- Both kinds, both optional:
  start_time      TIME,
  end_time        TIME,

  active          BOOLEAN NOT NULL DEFAULT TRUE,
  sort_order      INTEGER NOT NULL DEFAULT 0,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  -- Shape constraints: a row must have exactly the fields for its kind.
  CONSTRAINT events_kind_shape CHECK (
    (kind = 'oneoff'    AND event_date IS NOT NULL AND day_of_week IS NULL)
    OR
    (kind = 'recurring' AND day_of_week IS NOT NULL AND event_date IS NULL)
  ),
  CONSTRAINT events_time_range CHECK (
    end_time IS NULL OR start_time IS NULL OR end_time >= start_time
  ),
  CONSTRAINT events_recurring_range CHECK (
    ends_on IS NULL OR starts_on IS NULL OR ends_on >= starts_on
  )
);

CREATE INDEX IF NOT EXISTS events_org_idx
  ON events (organization_id, kind);
CREATE INDEX IF NOT EXISTS events_org_date_idx
  ON events (organization_id, event_date);

-- RLS: public read, only org admins write.
ALTER TABLE events ENABLE ROW LEVEL SECURITY;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE tablename='events' AND policyname='public_read_events') THEN
    CREATE POLICY public_read_events ON events FOR SELECT USING (true);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE tablename='events' AND policyname='org_admin_write_events') THEN
    CREATE POLICY org_admin_write_events ON events FOR ALL
      USING (is_org_admin(organization_id))
      WITH CHECK (is_org_admin(organization_id));
  END IF;
END $$;
