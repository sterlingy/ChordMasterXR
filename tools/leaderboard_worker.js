// Chord Defense global leaderboard — a Cloudflare Worker (not deployed).
//
// Deploy:
//   1. npm create cloudflare@latest chord-defense-scores  (choose "Hello World" Worker)
//   2. Replace src/index.js with this file.
//   3. Create a KV namespace and bind it as SCORES in wrangler.toml:
//        [[kv_namespaces]]
//        binding = "SCORES"
//        id = "<your namespace id>"
//   4. npx wrangler deploy
//   5. In Chord Master XR: Settings → Progress → Global leaderboard address
//      = https://chord-defense-scores.<you>.workers.dev
//
// Protocol (matches scripts/defense/defense_leaderboard.gd):
//   POST /scores           {board, name, score, wave, kills, accuracy, best_combo, version}
//                          -> {rank, total}
//   GET  /scores?board=…   -> [{name, score, wave, t}] best first (top 50)
//
// Each board is one KV key holding the top 200 entries. There is no
// anti-cheat: anyone with the address can post a score.

const KEEP = 200;
const SHOW = 50;
const BOARD_RE = /^stations_[1-8]$/;

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const cors = {
      "Access-Control-Allow-Origin": "*",
      "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
      "Access-Control-Allow-Headers": "Content-Type",
      "Content-Type": "application/json",
    };
    if (request.method === "OPTIONS") return new Response(null, { headers: cors });
    if (url.pathname !== "/scores") return new Response("{}", { status: 404, headers: cors });

    if (request.method === "GET") {
      const board = url.searchParams.get("board") || "";
      if (!BOARD_RE.test(board)) return new Response("[]", { status: 400, headers: cors });
      const rows = (await env.SCORES.get(board, "json")) || [];
      return new Response(JSON.stringify(rows.slice(0, SHOW)), { headers: cors });
    }

    if (request.method === "POST") {
      let g;
      try { g = await request.json(); } catch { return new Response("{}", { status: 400, headers: cors }); }
      const board = String(g.board || "");
      const score = Math.floor(Number(g.score));
      if (!BOARD_RE.test(board) || !Number.isFinite(score) || score < 0 || score > 10_000_000) {
        return new Response("{}", { status: 400, headers: cors });
      }
      const entry = {
        name: String(g.name || "Player").replace(/[^\p{L}\p{N} _.-]/gu, "").slice(0, 16) || "Player",
        score,
        wave: Math.max(0, Math.floor(Number(g.wave) || 0)),
        t: Date.now(),
      };
      const rows = (await env.SCORES.get(board, "json")) || [];
      rows.push(entry);
      rows.sort((a, b) => b.score - a.score);
      const rank = rows.indexOf(entry) + 1;
      await env.SCORES.put(board, JSON.stringify(rows.slice(0, KEEP)));
      return new Response(JSON.stringify({ rank, total: rows.length }), { headers: cors });
    }
    return new Response("{}", { status: 405, headers: cors });
  },
};
