-- Riftbound Championship Tracker — v2 migration: multi-organization support
--
-- Run this AFTER schema.sql has already been applied. It is safe to re-run
-- (every change uses IF NOT EXISTS / DO blocks).
--
-- What it does:
--   1. Adds `organizations` and `organization_admins` tables.
--   2. Adds `tournaments.organization_id` and backfills existing rows under
--      a default org (slug "dasbrett").
--   3. Migrates the old global `admins` allowlist into that default org's
--      admin team.
--   4. Replaces the v1 RLS policies with org-scoped equivalents.
--   5. Adds a `create_organization()` RPC for the self-service signup flow.

-- =====================================================================
-- Organizations
-- =====================================================================

CREATE TABLE IF NOT EXISTS organizations (
  id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  slug       TEXT UNIQUE NOT NULL CHECK (slug ~ '^[a-z0-9][a-z0-9-]{1,30}[a-z0-9]$'),
  name       TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS organization_admins (
  organization_id UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  email           TEXT NOT NULL CHECK (email = lower(email)),
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (organization_id, email)
);
CREATE INDEX IF NOT EXISTS organization_admins_email_idx
  ON organization_admins (email);

-- =====================================================================
-- Link tournaments to organizations
-- =====================================================================

ALTER TABLE tournaments
  ADD COLUMN IF NOT EXISTS organization_id UUID
    REFERENCES organizations(id) ON DELETE CASCADE;

-- Backfill: create a default org for any pre-existing tournaments,
-- and import the old global `admins` list as its first admin team.
DO $$
DECLARE
  default_org_id UUID;
BEGIN
  IF EXISTS (SELECT 1 FROM tournaments WHERE organization_id IS NULL) THEN
    SELECT id INTO default_org_id FROM organizations WHERE slug = 'dasbrett';
    IF default_org_id IS NULL THEN
      INSERT INTO organizations (slug, name)
        VALUES ('dasbrett', 'Das Brett · Spielebar')
        RETURNING id INTO default_org_id;
    END IF;

    UPDATE tournaments
       SET organization_id = default_org_id
     WHERE organization_id IS NULL;

    -- Carry the old global admins over as org admins of the default org.
    INSERT INTO organization_admins (organization_id, email)
      SELECT default_org_id, email FROM admins
      ON CONFLICT DO NOTHING;
  END IF;
END $$;

-- Now require organization_id on tournaments going forward.
ALTER TABLE tournaments ALTER COLUMN organization_id SET NOT NULL;

CREATE INDEX IF NOT EXISTS tournaments_org_idx
  ON tournaments (organization_id);

-- =====================================================================
-- Helper: is the current caller an admin of a specific organization?
-- =====================================================================

CREATE OR REPLACE FUNCTION is_org_admin(org_id UUID) RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM organization_admins
    WHERE organization_id = org_id
      AND lower(email) = lower(coalesce(auth.jwt() ->> 'email', ''))
  );
$$;

-- Convenience: list of org IDs the caller can admin (used by the admin UI).
CREATE OR REPLACE FUNCTION my_org_ids() RETURNS SETOF UUID
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT organization_id
  FROM organization_admins
  WHERE lower(email) = lower(coalesce(auth.jwt() ->> 'email', ''));
$$;

-- =====================================================================
-- RPC: create an organization and atomically register the caller as its
-- first admin. The only way to insert into `organizations` directly —
-- the RLS policy below blocks raw INSERTs.
-- =====================================================================

CREATE OR REPLACE FUNCTION create_organization(p_slug TEXT, p_name TEXT)
RETURNS organizations
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  caller_email TEXT;
  new_org      organizations%ROWTYPE;
BEGIN
  caller_email := lower(coalesce(auth.jwt() ->> 'email', ''));
  IF caller_email = '' THEN
    RAISE EXCEPTION 'Must be authenticated to create an organization';
  END IF;

  INSERT INTO organizations (slug, name)
    VALUES (lower(trim(p_slug)), trim(p_name))
    RETURNING * INTO new_org;

  INSERT INTO organization_admins (organization_id, email)
    VALUES (new_org.id, caller_email);

  RETURN new_org;
END $$;

REVOKE ALL ON FUNCTION create_organization(TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION create_organization(TEXT, TEXT) TO authenticated;

-- =====================================================================
-- Replace v1 RLS policies with org-scoped equivalents.
-- =====================================================================

ALTER TABLE organizations        ENABLE ROW LEVEL SECURITY;
ALTER TABLE organization_admins  ENABLE ROW LEVEL SECURITY;

-- Drop v1 policies that used the old global is_admin() helper.
DO $$
BEGIN
  -- tournaments
  EXECUTE 'DROP POLICY IF EXISTS admin_write_tournaments ON tournaments';
  -- qualifier_days
  EXECUTE 'DROP POLICY IF EXISTS admin_write_days ON qualifier_days';
  -- players
  EXECUTE 'DROP POLICY IF EXISTS admin_write_players ON players';
  -- standings
  EXECUTE 'DROP POLICY IF EXISTS admin_write_standings ON standings';
  -- admins (old global table) — keep read for backwards compatibility, no writes
  EXECUTE 'DROP POLICY IF EXISTS admin_write_admins ON admins';
END $$;

-- Organizations: public can read (for the directory and slug lookups).
-- Updates/deletes only by an admin of that org. INSERT is blocked — use
-- the create_organization() RPC.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE tablename='organizations' AND policyname='public_read_orgs') THEN
    CREATE POLICY public_read_orgs ON organizations FOR SELECT USING (true);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE tablename='organizations' AND policyname='no_direct_insert_orgs') THEN
    CREATE POLICY no_direct_insert_orgs ON organizations FOR INSERT WITH CHECK (false);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE tablename='organizations' AND policyname='org_admin_update_orgs') THEN
    CREATE POLICY org_admin_update_orgs ON organizations FOR UPDATE
      USING (is_org_admin(id)) WITH CHECK (is_org_admin(id));
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE tablename='organizations' AND policyname='org_admin_delete_orgs') THEN
    CREATE POLICY org_admin_delete_orgs ON organizations FOR DELETE USING (is_org_admin(id));
  END IF;
END $$;

-- organization_admins: only admins of the same org can see/manage the team.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE tablename='organization_admins' AND policyname='org_admin_read_team') THEN
    CREATE POLICY org_admin_read_team ON organization_admins FOR SELECT
      USING (is_org_admin(organization_id));
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE tablename='organization_admins' AND policyname='org_admin_write_team') THEN
    CREATE POLICY org_admin_write_team ON organization_admins FOR ALL
      USING (is_org_admin(organization_id))
      WITH CHECK (is_org_admin(organization_id));
  END IF;
END $$;

-- Tournaments: public read, admin-of-the-org write.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE tablename='tournaments' AND policyname='org_admin_write_tournaments') THEN
    CREATE POLICY org_admin_write_tournaments ON tournaments FOR ALL
      USING (is_org_admin(organization_id))
      WITH CHECK (is_org_admin(organization_id));
  END IF;
END $$;

-- Qualifier days: derive org via the parent tournament.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE tablename='qualifier_days' AND policyname='org_admin_write_days') THEN
    CREATE POLICY org_admin_write_days ON qualifier_days FOR ALL
      USING (is_org_admin((SELECT organization_id FROM tournaments WHERE id = tournament_id)))
      WITH CHECK (is_org_admin((SELECT organization_id FROM tournaments WHERE id = tournament_id)));
  END IF;
END $$;

-- Players: same path through tournaments.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE tablename='players' AND policyname='org_admin_write_players') THEN
    CREATE POLICY org_admin_write_players ON players FOR ALL
      USING (is_org_admin((SELECT organization_id FROM tournaments WHERE id = tournament_id)))
      WITH CHECK (is_org_admin((SELECT organization_id FROM tournaments WHERE id = tournament_id)));
  END IF;
END $$;

-- Standings: derive org via day → tournament.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE tablename='standings' AND policyname='org_admin_write_standings') THEN
    CREATE POLICY org_admin_write_standings ON standings FOR ALL
      USING (
        is_org_admin((
          SELECT t.organization_id
          FROM qualifier_days d
          JOIN tournaments t ON t.id = d.tournament_id
          WHERE d.id = day_id
        ))
      )
      WITH CHECK (
        is_org_admin((
          SELECT t.organization_id
          FROM qualifier_days d
          JOIN tournaments t ON t.id = d.tournament_id
          WHERE d.id = day_id
        ))
      );
  END IF;
END $$;

-- The old `admins` table is no longer consulted by RLS. It stays in place
-- (with v1 RLS) so the backfill above can read it. Drop it manually if you
-- want once you've confirmed v2 works:
--   DROP TABLE admins;
