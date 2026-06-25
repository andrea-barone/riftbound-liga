# Riftbound Championship Tracker

A lightweight, multi-tenant web tracker that sits on top of Carde.io to
manage Riftbound TCG ligas. Carde.io runs the Swiss day; this app
aggregates the final standings from each qualifier day into a season-points
leaderboard and shows the cut line for the final day.

The app supports multiple **organizations** (e.g. game stores) on the same
backend. Each organization has its own admin team, its own ligas, and its
own public URL (`?org=<slug>`). Within an organization, admins can run
multiple parallel ligas; the public page shows a separate leaderboard for
each.

- **Public** — read-only, `?org=<slug>` shows that organization's
  leaderboards; the root URL shows a directory of all organizations.
- **Admin** — magic-link login. First-time users create their own
  organization on the next screen; existing admins are auto-routed to the
  org they belong to. Admins of one org cannot see or edit data from
  another org.
- **Hosted backend** — Supabase (Postgres + auth) on the free tier.
- **No build step** — static files only.

## Files

| File | What it is |
| --- | --- |
| `schema.sql` | Base schema (v1). Run this once in Supabase. |
| `schema-v2-multi-org.sql` | Multi-organization migration. Run after v1. |
| `schema-v3-game-systems.sql` | Game-system tag migration. Run after v2. |
| `schema-v4-events.sql` | Events table (one-off + recurring). Run after v3. |
| `config.js` | Your Supabase URL + anon key. **You edit this.** |
| `index.html` | Public leaderboard / org directory / calendar. |
| `admin.html` | Admin login + per-org management. |
| `app.js` | Shared data, scoring, parsing helpers. |
| `style.css` | Styling. |

## Setup (one-time, ~10 minutes)

### 1. Create a Supabase project

1. Go to [supabase.com](https://supabase.com), sign up, and create a new
   project. The free tier is more than enough.
2. Wait for it to provision (a minute or two).

### 2. Run the schema

1. In your Supabase dashboard, open **SQL Editor** → **New query**.
2. Paste the contents of `schema.sql` and run it.
3. In a second query, paste `schema-v2-multi-org.sql` and run it. This adds
   the organization layer on top of v1 and migrates any existing v1 data
   under a placeholder default org. You'll rename that org on first sign-in.
4. In a third query, paste `schema-v3-game-systems.sql` and run it. This
   adds the per-org "game systems" table (Riftbound / MTG / Star Wars /
   etc.) and tags each liga with one. Existing ligas stay untagged until
   you edit them in the admin.
5. In a fourth query, paste `schema-v4-events.sql` and run it. This adds
   the events table (one-off and recurring weekly events) so the calendar
   can show pre-releases, casual nights, and recurring play sessions
   alongside championship qualifier days.

(Both scripts are safe to re-run.)

### 3. Sign in and create your organization

Skip this step if you already had data in v1 — the migration handled it.
For a fresh install:

1. Open `/admin.html` (after you've completed the rest of setup below).
2. Enter your email; click the magic link.
3. You'll be prompted to create your organization. Pick a name and a
   URL slug (e.g. `acme-games`).
4. You're now the first admin of that org. From the **Team** card you can
   invite additional staff emails to manage the same org.

### 4. (Optional) Configure email auth

By default Supabase sends magic-link emails from a Supabase-branded address,
which works fine for a small store. If you want to customize the sender:

- **Authentication → Email Templates** to change the email body.
- **Authentication → Providers → Email** to confirm "Enable email signups"
  and "Enable email confirmations" are on.
- **Authentication → URL Configuration** → add your deployed admin URL to
  the **Redirect URLs** allowlist (e.g. `https://your-site.netlify.app/admin.html`).
  If you skip this, the magic link will only work from `localhost`.

### 5. Fill in `config.js`

In `config.js`, replace the placeholders with the values from your Supabase
project:

- **Supabase URL** — Project Settings → API → "Project URL"
- **Anon public key** — Project Settings → API → "Project API keys" → `anon` `public`

The anon key is safe to commit to a public repo — it only allows what RLS
allows.

### 6. Test locally (optional but recommended)

The app uses ES module imports, so opening `index.html` directly with `file://`
will fail with a CORS error in modern browsers. Run any tiny static server:

```bash
cd path/to/riftbound-tracker
python3 -m http.server 8000
# then open http://localhost:8000/
```

Alternative if you have Node: `npx serve` in the folder.

While testing locally, add `http://localhost:8000/admin.html` to **Authentication
→ URL Configuration → Redirect URLs** in Supabase, or the magic-link login won't
redirect back.

### 7. Deploy the frontend

The whole thing is static — pick whichever host you prefer:

#### Option A: Netlify drop (no Git, easiest)

1. Zip the folder (or just drag the folder onto [app.netlify.com/drop](https://app.netlify.com/drop)).
2. You'll get a URL like `https://your-site.netlify.app/`.
3. The leaderboard is at `/` and admin is at `/admin.html`.
4. Add that admin URL to your Supabase redirect allowlist (step 4).

#### Option B: GitHub Pages

1. Push these files to a public GitHub repo.
2. Repo → Settings → Pages → deploy from `main` branch, `/` root.
3. URL will be `https://YOUR-USER.github.io/YOUR-REPO/`.

#### Option C: Vercel

1. Push to GitHub, import the repo into Vercel as a "Other" static site.
2. No build command, output directory is `/`.

## Day-of-tournament workflow

For each qualifier day:

1. Run the day on Carde.io as usual (Swiss pairings, timer, match reports).
2. When the day is over, copy the final standings from Carde.io.
3. Open `/admin.html`, sign in. (If you admin multiple orgs you'll see a
   picker; otherwise you're routed straight to your org.)
4. From the **Ligas** card, click **Manage** on the liga you're updating.
5. Under **Qualifier days**, click **Add a new qualifier day** with the
   name (e.g. "Qualifier 3") and date.
6. On the new day, click **Import standings**.
6. Paste the standings into the textarea. Each line is one player, in
   placement order. The importer accepts a bunch of formats:

   ```text
   1. Alice
   2. Bob
   3. Charlie
   ```
   or
   ```text
   1   Alice
   2   Bob
   3   Charlie
   ```
   or just names if they're already in order:
   ```text
   Alice
   Bob
   Charlie
   ```

7. Click **Preview** to confirm the parser got placements and points right.
8. Click **Save standings**.
9. The public leaderboard updates instantly — anyone with the public URL
   sees the new totals on next page load.

## Scoring

The default ramp matches the brief:

| Placement | Points |
| --- | --- |
| 1st | 15 |
| 2nd | 12 |
| 3rd–4th | 10 |
| 5th–8th | 7 |
| 9th–16th | 4 |
| 17th+ | 2 |

A player's championship score is the sum of points from every qualifier day
they attended. The leaderboard sorts by total points, with ties broken by
best single-day finish (then second-best, then name).

You can edit the tiers in the admin view. **Editing tiers retroactively
recomputes points for all existing standings** — you'll see a confirmation
message after saving.

## Cut line

Set the cut size in the admin view (defaults to 8). The public leaderboard
shows a gold dashed line after the Nth player, with a label like
*"Cut line — top 8 advance to finals"*.

## Updating

To update the app: edit the files locally and redeploy (drag-drop on Netlify,
push to Git for Pages/Vercel). The schema only needs to change if you add
new database columns — the SQL is written to be re-runnable.

## Costs

Supabase free tier: 500 MB Postgres, 50,000 monthly active users, unlimited
API requests. A multi-day TCG championship with ~60 players will use
~1/10000th of that. Netlify and GitHub Pages free tiers are fine for the
frontend.

## Future improvements (not built)

- Direct Carde.io API import (the brief flagged this as ideal but
  out-of-scope for v1). If Carde.io adds a standings export endpoint, the
  importer can call it instead of parsing pasted text.
- Per-player profile pages with head-to-head history.
- Filter the leaderboard to a date range (useful if a single season spans
  multiple championships).
