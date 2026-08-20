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
- `scripts/HLstats_EventHandlers.plib` and `scripts/HLstats.plib` — **upstream
  handlers carrying a grafted KTP delta.** The delta is small and load-bearing:
  per-half tagging, `ktpTrackMatchPlayer`, the accumulator increments, the
  unresolved-action report, and `execNonQuery`'s affected-row return. Deploying
  an upstream copy over either file removes those without erroring. Touch them
  only for KTP-specific parsing that genuinely belongs there; don't refactor or
  "clean up" surrounding upstream logic while you're in there.
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

**`flushAccumulators()` in the housekeeping loop is time-gated — keep it that
way.** It shares the 30-second interval `flushEventTable()` uses two lines
above (`$g_accum_lastflush`). Ungated, it runs on nearly every outer-loop pass
during a live match, which is the per-frag MySQL round-trip pattern the
accumulators exist to batch away, on the one daemon serving the whole fleet.
The direct calls from shutdown, `.KILL` and pre-aggregation are deliberately
ungated — don't "fix" those.

**Half-number parsing is shared — keep it that way.** `parseHalfNumber()` is
the single parser for the half string, called from both
`doEvent_KTPMatchStart` and `doEvent_KTPHalfEnd`. It used to be copy-pasted
into each, with nothing keeping the copies in step. Change the numbering in
one place or not at all.

**An unresolved action is discarded, and upstream discards it silently.** The
generic trigger dispatcher probes both action shapes, so a definition that is
deliberately PlayerAction-disabled (`assist`) must still be allowed to reject
that leg without being reported. A genuinely absent definition must stay loud:
that silence cost the Philly 2026 LAN every objective capture of the weekend,
because `hlstats_Actions` had never been seeded and nothing said so. Keep both
`ktpWarnUnresolvedAction` and the `ktpAssertActionsSeeded` startup check.

**`getProperties` carries two independent regex fixes and one harness that only
covers one of them.** The value branch must be `.*?` so `(matchid "")` matches
at all — with `.+?` the lazy match runs on to the next quote pair and returns
the rest of the line as the value, minting a phantom match id that propagates
into every table keyed on it, with nothing erroring. The key branch must be
`[^\s()]+` so a bare boolean key does not swallow the following property's
paren. `scripts/selftest-getproperties.pl` varies the *key* pattern only, so it
proves the second fix and would stay green if the first were reverted — assert
the value branch by hand when you touch that line.

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
Branch from and merge to `preprod` — `main` is the release branch, advanced by a
promotion PR, and GitHub defaults new PRs to the wrong base. A fix merged only to
`preprod` is invisible from `main`, so deploying from `main` silently reverts
whatever has not been promoted.

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
   *before* the daemon that writes to it. Schema ahead of code is inert; code
   ahead of schema loses data silently, because a write to a column or table
   that does not exist fails inside MySQL and the event is simply gone.
   The same ordering applies across repos: seed `hlstats_Actions` and reload
   here *before* shipping the KTPAMXX plugin that emits those actions.
   ⚠️ `hlstats_Events_Frags` and `hlstats_Events_PlayerActions` are MyISAM, so
   each `ADD COLUMN` is a full rebuild under a write lock. The migrations are
   written one guarded `ALTER` per column for idempotency — combine them per
   table when you apply them, in an idle window.
5. Reload or restart — **only with explicit operator permission in the current
   conversation.** `systemctl kill -s HUP hlstatsx` re-reads the database config
   and the per-game actions cache without dropping ingest, and is enough for a
   seeding or config change. A code change needs `systemctl restart`, which
   drops in-flight UDP: delivery is fire-and-forget, so a restart mid-half
   leaves the rest of that half untagged.
6. Verify: `sudo journalctl -u hlstatsx -f | grep KTP_DEBUG` during a live or
   test match to confirm events are being tagged with the expected
   `match_id`/`half_num`, and check for `SQL_ERROR` lines.
