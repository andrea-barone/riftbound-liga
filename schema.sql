-- Riftbound Championship Tracker — Supabase schema
-- Run this entire file in your Supabase project's SQL Editor.
-- It creates the tables, indexes, row-level security policies, and seeds
-- one tournament with the default scoring ramp.
--
-- After running, INSERT your email into the `admins` table to grant yourself
-- admin access:
--   INSERT INTO admins (email) VALUES ('your-email@example.com');

-- =====================================================================
-- Tables
-- =====================================================================

CREATE TABLE IF NOT EXISTS tournaments (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name        TEXT NOT NULL,
  cut_size    INTEGER NOT NULL DEFAULT 8 CHECK (cut_size > 0),
  scoring_tiers JSONB NOT NULL DEFAULT
    '[
      {"min": 1,  "max": 1,    "points": 15, "label": "1st"},
      {"min": 2,  "max": 2,    "points": 12, "label": "2nd"},
      {"min": 3,  "max": 4,    "points": 10, "label": "3rd–4th"},
      {"min": 5,  "max": 8,    "points": 7,  "label": "5th–8th"},
      {"min": 9,  "max": 16,   "points": 4,  "label": "9th–16th"},
      {"min": 17, "max": null, "points": 2,  "label": "17th+"}
    ]'::jsonb,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS qualifier_days (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tournament_id UUID NOT NULL REFERENCES tournaments(id) ON DELETE CASCADE,
  name          TEXT NOT NULL,
  event_date    DATE,
  sort_order    INTEGER NOT NULL DEFAULT 0,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS qualifier_days_tournament_idx
  ON qualifier_days(tournament_id, sort_order);

CREATE TABLE IF NOT EXISTS players (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tournament_id UUID NOT NULL REFERENCES tournaments(id) ON DELETE CASCADE,
  name          TEXT NOT NULL,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (tournament_id, name)
);
CREATE INDEX IF NOT EXISTS players_tournament_idx
  ON players(tournament_id);

CREATE TABLE IF NOT EXISTS standings (
  id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  day_id     UUID NOT NULL REFERENCES qualifier_days(id) ON DELETE CASCADE,
  player_id  UUID NOT NULL REFERENCES players(id) ON DELETE CASCADE,
  placement  INTEGER NOT NULL CHECK (placement > 0),
  points     INTEGER NOT NULL DEFAULT 0 CHECK (points >= 0),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (day_id, player_id)
);
CREATE INDEX IF NOT EXISTS standings_day_idx     ON standings(day_id);
CREATE INDEX IF NOT EXISTS standings_player_idx  ON standings(player_id);

CREATE TABLE IF NOT EXISTS admins (
  email      TEXT PRIMARY KEY,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- =====================================================================
-- Helper: is the current authenticated request an admin?
-- =====================================================================

CREATE OR REPLACE FUNCTION is_admin() RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM admins
    WHERE lower(email) = lower(coalesce(auth.jwt() ->> 'email', ''))
  );
$$;

-- =====================================================================
-- Row Level Security
-- Public can READ everything (it's a public leaderboard).
-- Only admins (email in `admins`) can write.
-- The `admins` table itself is admin-readable and admin-writable only.
-- =====================================================================

ALTER TABLE tournaments    ENABLE ROW LEVEL SECURITY;
ALTER TABLE qualifier_days ENABLE ROW LEVEL SECURITY;
ALTER TABLE players        ENABLE ROW LEVEL SECURITY;
ALTER TABLE standings      ENABLE ROW LEVEL SECURITY;
ALTER TABLE admins         ENABLE ROW LEVEL SECURITY;

-- Public read on the leaderboard tables
DO $$
BEGIN
  -- tournaments
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE tablename = 'tournaments' AND policyname = 'public_read_tournaments') THEN
    CREATE POLICY public_read_tournaments ON tournaments FOR SELECT USING (true);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE tablename = 'tournaments' AND policyname = 'admin_write_tournaments') THEN
    CREATE POLICY admin_write_tournaments ON tournaments FOR ALL
      USING (is_admin()) WITH CHECK (is_admin());
  END IF;

  -- qualifier_days
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE tablename = 'qualifier_days' AND policyname = 'public_read_days') THEN
    CREATE POLICY public_read_days ON qualifier_days FOR SELECT USING (true);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE tablename = 'qualifier_days' AND policyname = 'admin_write_days') THEN
    CREATE POLICY admin_write_days ON qualifier_days FOR ALL
      USING (is_admin()) WITH CHECK (is_admin());
  END IF;

  -- players
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE tablename = 'players' AND policyname = 'public_read_players') THEN
    CREATE POLICY public_read_players ON players FOR SELECT USING (true);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE tablename = 'players' AND policyname = 'admin_write_players') THEN
    CREATE POLICY admin_write_players ON players FOR ALL
      USING (is_admin()) WITH CHECK (is_admin());
  END IF;

  -- standings
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE tablename = 'standings' AND policyname = 'public_read_standings') THEN
    CREATE POLICY public_read_standings ON standings FOR SELECT USING (true);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE tablename = 'standings' AND policyname = 'admin_write_standings') THEN
    CREATE POLICY admin_write_standings ON standings FOR ALL
      USING (is_admin()) WITH CHECK (is_admin());
  END IF;

  -- admins: only admins read/write their own allowlist
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE tablename = 'admins' AND policyname = 'admin_read_admins') THEN
    CREATE POLICY admin_read_admins ON admins FOR SELECT USING (is_admin());
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE tablename = 'admins' AND policyname = 'admin_write_admins') THEN
    CREATE POLICY admin_write_admins ON admins FOR ALL
      USING (is_admin()) WITH CHECK (is_admin());
  END IF;
END $$;

-- =====================================================================
-- Seed: one default tournament so the leaderboard has something to point at.
-- Safe to re-run; only inserts if no tournament exists yet.
-- =====================================================================

INSERT INTO tournaments (name)
SELECT 'Riftbound Championship'
WHERE NOT EXISTS (SELECT 1 FROM tournaments);
