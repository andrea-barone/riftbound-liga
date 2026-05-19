// Shared data + scoring helpers for the Riftbound Championship Tracker.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { SUPABASE_URL, SUPABASE_ANON_KEY } from "./config.js";

export const supabase = createClient(SUPABASE_URL, SUPABASE_ANON_KEY);

// ----------------------------------------------------------------------
// Data fetching
// ----------------------------------------------------------------------

export async function getTournaments() {
  const { data, error } = await supabase
    .from("tournaments")
    .select("*")
    .order("created_at", { ascending: true });
  if (error) throw error;
  return data;
}

export async function getTournament(id) {
  // If no id given, return the first tournament (back-compat).
  let query = supabase.from("tournaments").select("*");
  if (id) {
    query = query.eq("id", id).single();
  } else {
    query = query.order("created_at", { ascending: true }).limit(1).single();
  }
  const { data, error } = await query;
  if (error) throw error;
  return data;
}

export async function getDays(tournamentId) {
  const { data, error } = await supabase
    .from("qualifier_days")
    .select("*")
    .eq("tournament_id", tournamentId)
    .order("sort_order", { ascending: true })
    .order("created_at", { ascending: true });
  if (error) throw error;
  return data;
}

export async function getPlayers(tournamentId) {
  const { data, error } = await supabase
    .from("players")
    .select("*")
    .eq("tournament_id", tournamentId);
  if (error) throw error;
  return data;
}

export async function getStandings(tournamentId) {
  // Pull every standing for the tournament in one shot via the join key.
  // Supabase doesn't let us filter on a related table column without an
  // explicit foreign-key relationship name, so we fetch days first and
  // batch-IN on day_id.
  const days = await getDays(tournamentId);
  if (days.length === 0) return { days: [], standings: [] };
  const { data, error } = await supabase
    .from("standings")
    .select("*")
    .in("day_id", days.map(d => d.id));
  if (error) throw error;
  return { days, standings: data };
}

// ----------------------------------------------------------------------
// Scoring
// ----------------------------------------------------------------------

// Given a placement (1-indexed) and the scoring tiers JSON, return points.
// Tier shape: { min: int, max: int | null, points: int, label?: string }
// `max: null` means unbounded (open-ended last tier).
export function pointsForPlacement(placement, tiers) {
  if (!Number.isFinite(placement) || placement < 1) return 0;
  for (const tier of tiers) {
    const max = tier.max == null ? Infinity : tier.max;
    if (placement >= tier.min && placement <= max) return tier.points;
  }
  return 0;
}

// Build the championship leaderboard from raw data.
// Returns: [{ playerId, name, totalPoints, daysAttended, perDay: { dayId: { placement, points } }, placements: [int] }]
// Sorted by:
//   1) total points (desc)
//   2) lexicographic compare of sorted placements (best finishes first)
//   3) name (asc) as final tiebreaker
export function computeLeaderboard(players, standings) {
  const byPlayer = new Map();
  for (const p of players) {
    byPlayer.set(p.id, {
      playerId: p.id,
      name: p.name,
      totalPoints: 0,
      daysAttended: 0,
      perDay: {},
      placements: [],
    });
  }
  for (const s of standings) {
    const row = byPlayer.get(s.player_id);
    if (!row) continue;
    row.perDay[s.day_id] = { placement: s.placement, points: s.points };
    row.totalPoints += s.points;
    row.daysAttended += 1;
    row.placements.push(s.placement);
  }
  const rows = [...byPlayer.values()].filter(r => r.daysAttended > 0);
  rows.sort(comparePlayers);
  return rows;
}

export function comparePlayers(a, b) {
  if (b.totalPoints !== a.totalPoints) return b.totalPoints - a.totalPoints;
  const aP = [...a.placements].sort((x, y) => x - y);
  const bP = [...b.placements].sort((x, y) => x - y);
  const len = Math.max(aP.length, bP.length);
  for (let i = 0; i < len; i++) {
    const ax = aP[i] ?? Infinity;
    const bx = bP[i] ?? Infinity;
    if (ax !== bx) return ax - bx;
  }
  return a.name.localeCompare(b.name);
}

// ----------------------------------------------------------------------
// Parsing pasted standings
// ----------------------------------------------------------------------

// Accepts free-form text that the admin pasted from Carde.io.
// Each non-empty line becomes one entry. Tries hard to be forgiving:
//   "1. Alice"           → { placement: 1, name: "Alice" }
//   "1\tAlice"           → { placement: 1, name: "Alice" }
//   "1, Alice"           → { placement: 1, name: "Alice" }
//   "  2  Bob Smith  "   → { placement: 2, name: "Bob Smith" }
//   "Charlie"            → { placement: <line index>, name: "Charlie" }
//
// If a leading number is parseable as a placement (1–999), use it; otherwise
// fall back to line order.
export function parseStandings(text) {
  const lines = text.split(/\r?\n/).map(l => l.trim()).filter(Boolean);
  const out = [];
  lines.forEach((line, idx) => {
    // Strip a trailing extra column (some exports include record like 5-1 or points)
    // by only taking the first "placement + name" interpretation.
    const m = line.match(/^(\d{1,3})[\s.,)\-:|\t]+(.+?)\s*$/);
    let placement, name;
    if (m) {
      placement = parseInt(m[1], 10);
      name = m[2];
    } else {
      placement = idx + 1;
      name = line;
    }
    // If the "name" portion still has tab-separated extra columns, take the first.
    name = name.split("\t")[0].trim();
    if (name) out.push({ placement, name });
  });
  return out;
}

// ----------------------------------------------------------------------
// Rendering helpers used by both pages
// ----------------------------------------------------------------------

export function el(tag, attrs = {}, children = []) {
  const node = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs)) {
    if (k === "class") node.className = v;
    else if (k === "html") node.innerHTML = v;
    else if (k.startsWith("on") && typeof v === "function") node.addEventListener(k.slice(2), v);
    else if (v != null) node.setAttribute(k, v);
  }
  for (const c of [].concat(children)) {
    if (c == null) continue;
    node.appendChild(typeof c === "string" ? document.createTextNode(c) : c);
  }
  return node;
}

export function fmtDate(iso) {
  if (!iso) return "";
  const d = new Date(iso + "T00:00:00");
  if (isNaN(d)) return iso;
  return d.toLocaleDateString(undefined, { month: "short", day: "numeric" });
}
