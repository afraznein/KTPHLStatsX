---
name: service-dev
description: Use BEFORE modifying or deploying KTPHLStatsX — fork-discipline boundary (KTP delta only, never refactor upstream), the match-context staleness landmine, the accumulator flush-gate pattern, and the data-server deploy/verify checklist.
---

# KTPHLStatsX Development

Perl/PHP HLStatsX:CE fork running as a single daemon on the data server,
consuming UDP log lines from all ~24 fleet game-server instances and writing
to MySQL `hlstatsx`. It is the sole place that tags kills/deaths/objective
events with a `match_id`, separating warmup noise from official match stats.

## Hard safety rules
- **Never restart any game server without explicit operator permission in the
  current conversation** — this repo doesn't run on game servers, but fixes
  here are frequently paired with a KTPMatchHandler change, and that side
  compiles to `.amxx` staged as `.new` for the 03:00 ET nightly swap. Don't
  short-circuit that with a manual restart.
- **The `hlstatsx` daemon itself is a single process serving the whole
  fleet.** `sudo systemctl restart hlstatsx` drops every server's stat
  tagging until it reconnects — treat it with the same respect as a game
  server restart: don't run it without the operator's go-ahead in this
  conversation, even mid-edit.
- Run the `ktp-code-review` agent before staging any nontrivial change,
  especially anything touching `recordEvent`'s match-id gate or the
  accumulator/flush housekeeping loop — both are hot path for every event
  from every instance.
- Comments: short, why-not-what, no ticket/finding IDs (translate review
  findings into plain statements), never delete a tripwire fact while
  trimming prose.

## Fork discipline — read this before touching anything
This is HLStatsX:CE with a KTP delta grafted on, not a from-scratch daemon.
- `scripts/hlstats.pl` — **the KTP-authoritative file.** All KTP-specific
  logic (`doEvent_KTPMatchStart`, `doEvent_KTPHalfEnd`, `doEvent_KTPMatchEnd`,
  `recordEvent`'s match-id tagging gate, the accumulator flush block) lives
  here.
- `scripts/HLstats_EventHandlers.plib` — **base upstream handlers, NOT KTP.**
  Only touch this file for KTP-specific event parsing that genuinely belongs
  there (e.g. accumulator increments feeding the KTP flush); don't refactor
  or "clean up" surrounding upstream logic while you're in there.
- Stay inside the KTP delta. If a fix looks like it wants to restructure
  general HLStatsX behavior, it's almost certainly out of scope — scope the
  fix to the KTP-specific code path instead.

## Known landmines (don't reintroduce these)

**Match context has no staleness bound.** `$g_ktpMatchContext{$s_addr}` is the
sole source of `match_id`/`half_num` tagging for every event `recordEvent`
processes. It's set unconditionally in `doEvent_KTPMatchStart` and cleared
*only* by `doEvent_KTPMatchEnd`/`doEvent_KTPHalfEnd` — both of which fire
solely off `KTP_MATCH_END`/`KTP_HALF_END` log lines. KTPMatchHandler's OT
paths (decisive win, MAX_OT_ROUNDS) do **not** emit those log lines — only
the regulation-end path does. That means an OT-decided match never clears
its context on the Perl side, and every event afterward (warmup, or even the
start of the next real match, until its own `KTP_MATCH_START` overwrites the
hash) gets silently tagged to the already-finished match. If you fix this
here, the right shape is defense-in-depth: stamp a `set_at` time when the
context is created and expire it on a generous ceiling from the existing
housekeeping block, checked alongside `flushAccumulators`. The root cause is
upstream in KTPMatchHandler's `process_ot_round_end_changelevel()` — flag
that asymmetry to whoever owns that repo rather than trying to fully paper
over it from this side alone.

**`flushAccumulators()` is not time-gated — don't let it become per-kill.**
`flushEventTable()`, two lines above its call site, is correctly gated on a
30-second interval (`lastflush + 30 < $ev_daemontime`) before running its
UPDATE queries. `flushAccumulators()` has no equivalent gate at any of its
call sites, so during a live match with a steady kill stream it can run on
nearly every outer-loop pass instead of once per 30s — reintroducing the
exact per-frag MySQL round-trip pattern the 0.3.0 batching rewrite existed to
eliminate, on the one daemon serving the whole fleet. If you touch this,
gate it the same way `flushEventTable` is gated. Leave `flushAll()` (used at
shutdown and `.KILL`) unconditional — that's intentional, not an oversight.

**Half-number parsing is duplicated, not shared.** The half-string parser
(`/^1/`, `/^2/`, `/^OT(\d+)/`) is copy-pasted identically in
`doEvent_KTPMatchStart` and `doEvent_KTPHalfEnd`. If you ever change the
half-numbering scheme, update both copies — nothing enforces they stay in
sync.

## Upstream event dependencies
This daemon parses log lines it doesn't control the format of:
- `KTP_MATCH_START` / `KTP_HALF_END` / `KTP_MATCH_END` — emitted by
  KTPMatchHandler via `log_message()`. Field order/names changing there
  breaks parsing here silently (regex just won't match — no error).
- Weaponstats / score properties — emitted by DODX (`dodx_set_match_id()`)
  and KTPScoreTracker. Check those repos' CHANGELOGs before assuming a log
  format is stable.
- When you need a KTPMatchHandler-side fix to close a gap found here (like
  the OT match-end asymmetry above), that's a cross-repo change: coordinate
  both sides, don't just patch around it unilaterally in Perl.

## Deploy workflow
There's no compile step — this is interpreted Perl. Path is:
1. Bump `VERSION`, add a `CHANGELOG.md` section, update the version line in
   `README.md`.
2. `deploy.ps1` copies `scripts/*.pl`, `*.plib`, `sql/*.sql`, and docs into
   the local staging tree `N:\Nein_\KTP DoD Server\hlstatsx` — this is a
   local staging copy, **not** a push to the data server.
3. Push the changed files to `/opt/hlstatsx/scripts/` on the data server
   (`<DATA_SERVER_IP>`) via SFTP/paramiko — see the SSH pattern in the root
   `CLAUDE.md`, which resolves the placeholder.
4. Apply any new `sql/*.sql` migration against the `hlstatsx` database
   *before* restarting the daemon (schema and code changes must land
   together — the daemon assumes the schema it was written against).
5. Restart `hlstatsx` (`sudo systemctl restart hlstatsx`) — **only with
   explicit operator permission in the current conversation.**
6. Verify: `sudo journalctl -u hlstatsx -f | grep KTP_DEBUG` during a live or
   test match to confirm events are being tagged with the expected
   `match_id`/`half_num`, and check for `SQL_ERROR` lines.
