-- Championship tracker — v3 migration: per-org game systems
--
-- Run after schema.sql and schema-v2-multi-org.sql. Safe to re-run.
--
-- Adds a per-organization list of "game systems" (Riftbound / MTG / Star Wars /
-- whatever the store runs), and tags each tournament with one.

-- =====================================================================
-- game_systems table (per-org configured)
-- =====================================================================

CREATE TABLE IF NOT EXISTS game_systems (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  key             TEXT NOT NULL CHECK (key ~ '^[a-z0-9][a-z0-9-]{0,30}[a-z0-9]$'),
  label           TEXT NOT NULL,
  sort_order      INTEGER NOT NULL DEFAULT 0,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (organization_id, key)
);

CREATE INDEX IF NOT EXISTS game_systems_org_idx
  ON game_systems (organization_id, sort_order);

-- =====================================================================
-- Tag tournaments with a game system
-- Nullable for back-compat; the admin UI requires it on new ligas.
-- =====================================================================

ALTER TABLE tournaments
  ADD COLUMN IF NOT EXISTS game_system_key TEXT;

CREATE INDEX IF NOT EXISTS tournaments_game_system_idx
  ON tournaments (organization_id, game_system_key);

-- =====================================================================
-- RLS: public can read, only org admins can write.
-- =====================================================================

ALTER TABLE game_systems ENABLE ROW LEVEL SECURITY;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE tablename='game_systems' AND policyname='public_read_game_systems') THEN
    CREATE POLICY public_read_game_systems ON game_systems FOR SELECT USING (true);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE tablename='game_systems' AND policyname='org_admin_write_game_systems') THEN
    CREATE POLICY org_admin_write_game_systems ON game_systems FOR ALL
      USING (is_org_admin(organization_id))
      WITH CHECK (is_org_admin(organization_id));
  END IF;
END $$;
