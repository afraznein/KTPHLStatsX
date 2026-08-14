# KTP HLStatsX Changelog

## [0.3.5] - 2026-08-12

### Added
- **An action missing from `hlstats_Actions` now says so instead of vanishing.**
  The upstream handler tests `defined($g_games{...}{actions}{$action}) && ...{paction}`
  and, when that fails, simply does not record the event — no error, no counter, no log
  line. At the Philadelphia 2026 LAN the actions table was never seeded for `dod`, so
  **every `dod_control_point` and `dod_capture_area` of the weekend was parsed and
  discarded**, and nobody found out until the objective columns turned up empty days
  later. `ktpWarnUnresolvedAction()` now reports each distinct unresolved action once
  and tallies the rest, so a misconfiguration is loud on the first capture rather than
  silent for three days.
  The guard is deliberately additive — it sits *beside* the upstream test rather than
  restructuring it, so the base handler's control flow is untouched.
- **Startup assertion that the actions table is populated.** `ktpAssertActionsSeeded()`
  runs once per game at server discovery and reports the row count, or an error if it
  is zero. One line at startup against a weekend of lost objectives.
- **The UDP receive buffer now reports when the kernel did not grant what was asked.**
  The socket requests 1 MB; Linux silently clamps that to `net.core.rmem_max` and then
  reports back double whatever it granted. A request that was quietly cut is exactly
  the condition that drops log lines once several servers are busy, and nothing else
  in the daemon notices. Note the doubling when reading the number — a healthy 1 MB
  grant prints as 2048 KB.
- **Write-path health counters, surfaced every 5 minutes when non-zero** —
  `KTP_HEALTH sql_failed=N sql_retried=N unresolved_actions=N`. Silent when all three
  are zero, so it does not become noise to scroll past.

### Changed
- **`execNonQuery` retries once before giving up.** The common failure is a connection
  that died between the `ping()` and the write; a genuinely bad statement fails
  identically twice and is still reported, so the retry cannot turn a real error into
  a silent one. Retries that succeed are counted and logged too — a rising retry count
  is what a database connection dying under load looks like, and it otherwise looks
  like nothing at all.

### Fixed
- **`VERSION` said 0.3.3 while `CHANGELOG.md` and `README.md` both said 0.3.4.** The
  file was never bumped with the release; corrected here.

### Notes
- ⚠️ **None of this would have saved the LAN's 982 lost frags.** Those died in the UDP
  receive path before the daemon ever saw them — there is no copy to retry and no event
  to count. What is recoverable is *knowing*: the kernel's `RcvbufErrors` counter is the
  only signal, and on the production data server it currently reads **5,404**, so the
  fleet is dropping log lines today. Sampling that per half is tracked in
  KTPInfrastructure, not here — the daemon cannot see its own dropped packets.

---

## [0.3.4] - 2026-08-09

### Fixed
- **Accumulator flush was not time-gated, so it ran on nearly every housekeeping
  pass.** `flushEventTable()` two lines above its call site is gated on a 30-second
  interval; `flushAccumulators()` had no such gate at that site, so during a live
  match with a steady kill stream it drained and issued its `hlstats_Roles` /
  `hlstats_Weapons` / `hlstats_Maps_Counts` UPDATEs at roughly per-frag cadence —
  the exact MySQL round-trip pattern the batching rewrite exists to remove, on the
  one daemon serving the whole fleet. The in-source comment already claimed
  "flushed every 30s", so the gate was intended and simply never written. Now gated
  on its own `$g_accum_lastflush` timestamp with the same 30s interval.
  The shutdown (`flushAll`) and pre-aggregation call sites stay ungated — those
  must drain unconditionally.

### Changed
- **Half-string parsing de-duplicated.** The `/^1/`, `/^2/`, `/^OT(\d+)/` ladder was
  copy-pasted identically into `doEvent_KTPMatchStart` and `doEvent_KTPHalfEnd`, with
  nothing keeping the two in step if the numbering scheme ever changed. Both now call
  `parseHalfNumber()`. Behaviour is unchanged — verified by differential test over 16
  inputs (including `undef`, empty, `OT10`, lowercase `ot1` and non-matching junk):
  0 mismatches.

---

## [Unreleased]

### Added
- **Periodic roster-position samples** (`sql/migrate_008_position_samples.sql`,
  `scripts/hlstats.pl`) — new `ktp_position_samples` table and
  `doEvent_KTPPosition` handler (event type 608) record every
  `position_sample` marker KTPAMXX's `ksc_position_broadcast_task` emits
  (every 30s per connected, alive player): player, team, `(x, y, z)`,
  `game_time`, and `match_id`/`half` from the same round-live gating
  `recordEvent()`/`doEvent_KTPDamage` use. Same dispatch shape as
  `break_context` — a single-action `"Player" triggered "position_sample"
  (props)` line, routed through the `$ev_verb eq "triggered"` branch — but
  a standalone direct `INSERT` like `doEvent_KTPDamage`, not an `UPDATE`
  onto an existing row, since there's no prior event to attach this to.
  Raw facts only, on purpose: no positional/"holding" judgment happens in
  this handler, that's entirely query-layer, reading this table plus
  `ktp_flag_positions`. Live-verified: 129 real samples in a short Lane B
  run, correct team/position/game_time, correct `match_id`/`half` gating
  (`NULL`/0 in warmup and halftime, tagged during live play).

- **Break context, flag positions, and last-flag-defense**
  (`sql/migrate_007_break_context.sql`, `scripts/hlstats.pl`).
  - `ktp_flag_positions` (new table) — static per-flag `(x, y)`, upserted from
    a `KTP_FLAG_POSITION` marker (event type 607, `doEvent_KTPFlagPosition`)
    on every map load. Keyed on `(server_id, map_name, flag_index)` so
    repeat loads (warmup, halftime reload) don't accumulate duplicates.
  - `hlstats_Events_PlayerActions` gains `contester_count`, `time_remaining`,
    `is_capout` — a follow-up `break_context` marker (event type 606) on
    every `cap_break`, same flush-then-UPDATE-most-recent-row technique
    `frag_context` uses on Frags, matched here by `(playerId, actionId)`
    with the `cap_break` action id read from the in-memory actions table
    rather than a DB round-trip.
  - `hlstats_Events_Frags` gains `is_last_flag_defense`; `frag_context`'s
    handler (901) extended to set it plus the row's *existing* (stock)
    `pos_x/y/z`/`pos_victim_x/y/z` columns from new `k_position`/`v_position`
    properties — no migration needed for those, verified against
    `base-schema.sql` before assuming a new column was required.
  - **Last-flag-defense keys off kill position relative to the defended
    flag, not the break queue** — per the operator's correction, a defender
    who kills a would-be ninja before they start capping is defending just
    as much, and the break queue structurally cannot see a kill that never
    touched a capture zone. Computed plugin-side (needs live flag-ownership
    state); `is_capout` and `is_last_flag_defense` share the same
    "does this team own exactly one flag" test, asked at two different
    event types.
  - `perl -c` verified inside the Lane B image.

- **Per-hit damage ledger** (`sql/migrate_006_damage_ledger.sql`,
  `scripts/hlstats.pl`) — new `ktp_damage_events` table and `doEvent_KTPDamage`
  handler (event type 605) record every `client_damage` hit KTPAMXX emits:
  attacker, victim, weapon, raw damage, a capped damage value, hitplace,
  `game_time`, and `match_id`/`half` from the same round-live gating
  `recordEvent()` uses. **Not** routed through the daemon's generic
  `recordEvent`/`hlstats_Events_*` batching — that machinery is config-driven
  around the stock event set, so this is a standalone table with a direct
  per-event `INSERT`, matching how `KTP_MATCH_*` is already handled.

  **`damage_capped` is the KTPR-facing column, not `damage`.** DoD's raw
  per-hit value is the nominal weapon value with multipliers applied
  (headshot, wallbang) and is not clamped to a player's actual 0-100 HP pool
  — a single hit can log 400+. `damage_capped` is `MIN(damage, 100)`,
  computed plugin-side, matching the convention CS2 uses for the same
  reason. Raw is kept for anyone who wants the uncapped weapon-power
  reading; nothing is discarded, but a rating or aggregate should sum the
  capped column, or one absurd wallbang could outweigh several clean kills.

- **Frag context recorded on every kill** (`sql/migrate_005_frag_context_columns.sql`,
  `scripts/hlstats.pl`) — headshot, killer/victim prone state, killer/victim
  scope state, and killer/victim clip/ammo now land on `hlstats_Events_Frags`
  for every kill, not just headshots. New `frag_context` handler (event type
  901) in `hlstats.pl`, same flush-then-UPDATE-most-recent-row technique the
  old `headshot_kill` handler (900) used — that handler is left in place as
  dead code, since KTPAMXX no longer emits the line it matches, but nothing
  needs it removed either. Eight new columns, all guarded/idempotent on both
  MySQL and MariaDB per `ktp_schema.sql`'s pattern; `headshot` itself is not
  new, it already existed from the marker this retires.
- **DoD cap breaks are now recorded** (`sql/migrate_004_cap_break_action.sql`) —
  seeds the `hlstats_Actions` row for the `cap_break` lines KTPAMXX's
  `ktp_stats_capture.inc` emits when a player kills an enemy off a point their
  team was capturing. No daemon code change; same single-player action path the
  existing DoD capture actions use. `reward_player` is 0 (see the assist entry).
  Records *that* a break happened, not *which* point — the `(flag "...")`
  property is dropped by `doEvent_PlayerAction` until the break-context phase
  teaches it to parse one.
- **DoD assists are now recorded** (`sql/migrate_003_assist_action.sql`) —
  `hlstats_Events_PlayerPlayerActions` has been empty since it was created,
  because nothing ever emitted a player-vs-player action for DoD and the engine
  logs no damage events for the daemon to derive assists from. KTPAMXX's
  `ktp_stats_capture.inc` now emits `triggered "assist" against` lines; this
  seeds the `hlstats_Actions` row that lets the existing dispatcher record them.
  **No daemon code change** — the line rides the same generic player-vs-player
  path KTP's own `headshot_kill` marker already uses.

  `reward_player` is 0 on purpose: assists must not move HLStatsX's `skill` ELO,
  or adding a stat would silently re-rate the whole ladder. `for_PlayerActions`
  is `'0'` on purpose too — the dispatcher calls both action handlers for one
  line, so enabling both flags would record the assist twice (once without the
  victim) and double-apply the reward.

### Fixed
- **`frag_context`/`break_context`/`headshot_kill` markers could silently
  corrupt a stale row when a frag or cap_break line was dropped.** Found by
  an independent production-rollout audit, not by this project's own Lane B
  testing (which never simulates dropped UDP lines). GoldSrc log delivery
  is fire-and-forget UDP; the marker+UPDATE technique used throughout the
  frag-context/break-context/damage-ledger phases matched on
  `serverId + killerId + victimId + weapon` (or `playerId + actionId` for
  breaks), `ORDER BY id DESC LIMIT 1`, with no time bound and no rowcount
  check. If the primary event line was lost but its follow-up marker
  survived, the UPDATE silently rewrote the *previous* matching row —
  potentially from an earlier match — with the new kill's context. Fixed by
  bounding every one of these UPDATEs to `eventTime >=
  FROM_UNIXTIME($ev_unixtime - 60)` (the event's own parsed-log-time clock
  basis, not SQL `NOW()` — the two diverge by design during offline replay,
  and by drift under any live processing backlog) and logging a
  `KTP_NO_ROW_MATCHED` line whenever the bound legitimately finds nothing to
  update. Validated with two Lane B replay controls: (a) frag + context
  together still updates correctly (verified column-by-column against the
  source log's own properties); (b) a synthetic dropped-frag-line replay,
  built specifically to have a genuinely older matching row available to
  corrupt, first reproduced the exact silent-corruption defect against the
  pre-fix code (old row's `headshot`/`k_clip`/`k_ammo`/position all
  overwritten from an unrelated, later marker), then confirmed the fix
  leaves that old row untouched and logs the warning instead. `execNonQuery`
  (`HLstats.plib`) now returns its own affected-row count so callers can
  check it directly — additive only, every existing caller already ignores
  the return value.

  **Third validation, from a real bot-driven Lane B match (2026-08-13), not
  just the two synthetic replay controls above.** A 16-bot, 156-kill match
  organically tripped `KTP_NO_ROW_MATCHED` 5 times on `frag_context` — not
  from a dropped frag line (the match's own `kills`/`frags` counts matched
  156/156 exactly) but from a genuine ordering race: the daemon's own log
  showed a `KTP_NO_ROW_MATCHED` timestamped *between* two successful
  `frag_context` UPDATEs from the same second, i.e. the buffered context
  marker (flushes on its own 5s cycle) reached the daemon before its primary
  kill line had been inserted into `Frags` yet — UDP does not guarantee send
  order, and Lane B's bots sustain a far higher kills/sec rate than real
  human play. The fix's bound correctly discarded each of the 5 rather than
  risking a wrong-row match; net effect was 5 kills (~3.2% of this
  artificially bot-dense run) missing their `frag_context` properties
  (headshot/prone/scope/clip/position), not corrupted data. Accepted as
  correct, documented behavior — discard-over-corrupt was always the goal,
  and the real-match rate is expected to be lower than this synthetic
  ceiling. Not pursuing a retry/requeue for the race; see
  `docs/handover/` in KTPInfrastructure for the full Lane B run writeup.
- **DoD suicides are now recorded** — `hlstats_Events_Suicides` had been empty
  fleet-wide, and `ktp_match_stats.suicides` therefore always 0, since the table
  was introduced. The cause was dispatch, not handling: the only branch in
  `hlstats.pl` that called `doEvent_Suicide` sat inside the regex that requires a
  bracketed `[x y z]` coordinate block, which is CS:GO's log format. DoD emits
  `"Player<uid><steamid><team>" committed suicide with "weapon"` with no
  coordinates, so it fell through to the generic `"player" verb "obj_a"` branch —
  which lists suicides in its own comment header but never actually checked for
  the verb. Added that check. `doEvent_Suicide`, the `Suicides` schema, the `half`
  and `match_id` tagging, and the `ktp_match_stats` aggregation were all already
  correct and needed no changes, so the fix is purely additive.

### Schema
- **`ktp_schema.sql` now RUNS on MySQL, and is idempotent in both directions**
  (2026-08-11). Eight statements used MariaDB-only `ADD COLUMN IF NOT EXISTS` /
  `CREATE INDEX IF NOT EXISTS`; MySQL rejects those with ERROR 1064 at any
  version, and because the file applies as one batch the first rejection
  aborted everything after it. Nothing failed in production only because the
  live database was built incrementally and nobody re-runs the file — the
  exposure was the next fresh provision or DR rebuild, which would have come up
  missing `match_id` on four event tables and all three `ktp_*` tables while
  the daemon ran against it happily, writing rows that silently lose their
  match attribution. Each change is now guarded by an `information_schema`
  lookup executed through a prepared statement: plain SQL, no privilege the
  migration did not already need, and no change to the operator runbook.
  Bare `ALTER` was not an option — it is ERROR 1060 on an already-applied
  database, which is the path production takes.
  Gated on a disposable MySQL 8.0.46: fresh install applies everything,
  a second run is a clean no-op, a production-shaped database is a no-op, and
  running with no database selected aborts at ERROR 1046 rather than silently
  guarding to "nothing to do". The control that makes those meaningful — the
  old file on the same fresh database — fails at 1064 and applies nothing.
  ⚠️ The file is declarative, so it is **not** a guaranteed no-op on the live
  database: `idx_match_id` is currently present only on `hlstats_Events_Frags`,
  never having been created on `_Teamkills`, `_Suicides` or `_PlayerActions`.
- **`ktp_schema.sql` now loads on MySQL 8.x** (2026-06-21) — `ktp_matches.server_id` was
  `INT` with a FOREIGN KEY to `hlstats_Servers(serverId)`, but `serverId` is `INT UNSIGNED`
  and the HLStatsX base tables are MyISAM (no FK support). Both the InnoDB-FK-to-MyISAM and
  the signedness mismatch fail with errno 1824, so the KTP match tables were never created.
  Dropped the FK (`server_id` stays an indexed column; integrity is enforced app-side) and
  made `server_id` `INT UNSIGNED`. Surfaced provisioning the July LAN box.

### Documentation
- README brought up to 0.3.3: round-state filtering was shipped without any doc
  change, so the README still described 0.3.2 semantics. Added event types 603/604,
  the two new untagged-inside-a-match contexts (freeze time, inter-half gap), and a
  note that those NULLs are deliberate — the previous "all events tagged" claim was
  a wrong-diagnosis trap for anyone investigating low match frag counts.
- Documented the `half` column on the event tables, split fresh-install vs. upgrade
  SQL paths, added the missing `hlstats.conf` DB-config step (`DBName` must be
  overridden to `hlstatsx` — the built-in default is `hlstats`), and corrected the
  MySQL prerequisite to 8.0+ to match `migrate_002` and the deployed servers.
- `CLAUDE.md`: relabeled `HLstats_EventHandlers.plib` as containing KTP delta (it was
  marked "NOT KTP", which would lose `ktpTrackMatchPlayer` on a fork-rebase), and
  appended the three 0.3.3 `KTP_DEBUG` trace points.
- `deploy.ps1`: corrected the staging path to `N:\Nein_\KTP Git Projects\KTP DoD Server\hlstatsx`
  (the old path does not exist, and `New-Item -Force` silently created a bogus tree
  one level too high and reported success), and corrected the header comment — the
  script stages locally, it never reaches the data server.

## [0.3.3] - 2026-03-24

Companion to KTPMatchHandler v0.10.101 round-state filtering.

### Added
- **`KTP_ROUND_FREEZE` handler (event type 603)** — sets `round_live = 0` on the match
  context, pausing `match_id` tagging.
- **`KTP_ROUND_LIVE` handler (event type 604)** — sets `round_live = 1`, resuming tagging.

### Changed
- **`recordEvent` gated on the `round_live` flag** — freeze-time kills get
  `match_id = NULL` and are excluded from match stats.
- **`doEvent_KTPMatchStart` initializes `round_live = 1`** by default.
- **`doEvent_KTPHalfEnd` clears the match context entirely** so inter-half kills
  aren't tagged.

---

## [0.3.2] - 2026-03-09

### Fixed
- **Headshots never recorded (all zeros)** — The `headshot_kill` handler was dead code. It was in an `elsif` branch at line 2832 that could never execute because the generic `triggered` regex at line 2753 matched first and routed all `triggered` events through `PlayerPlayerAction`. Moved the `headshot_kill` check inside the `triggered` block as the first condition, before generic action handling. Removed the unreachable `elsif` branch.

---

## [0.3.1] - 2026-03-04

### Added
- **Per-half stat breakdown** — Event tables (`Frags`, `Teamkills`, `Suicides`, `Statsme`) now record `half` column (1=1st half, 2=2nd half, 3+=OT rounds). `ktp_match_stats` aggregates per-half rows plus a `half=0` total row per player.
- **Damage aggregation** — `doEvent_KTPMatchEnd` now JOINs `hlstats_Events_Statsme` to aggregate total damage dealt per player per half. Previously the `damage` column existed but was never populated.
- **Score (objective) tracking** — Weaponstats parser accumulates `score` property from `stats_logging.sma` into `%g_ktpScoreAccum` in-memory hash, applied to `ktp_match_stats` at match end.
- **Statsme event queue flush** — `doEvent_KTPMatchEnd` now flushes the `Statsme` event queue before aggregation (was missing — only Frags, Teamkills, Suicides were flushed).
- **`%g_ktpScoreAccum` global** — Three-level hash `{match_id}{player_id}{half_num}` for accumulating objective scores across weaponstats events. Cleared per-match on match end and globally on daemon shutdown.

### Changed
- **`doEvent_KTPMatchEnd` rewritten** — Queries `ktp_matches` for all halves, aggregates stats per-half in a loop, then inserts a `half=0` total row by summing per-half data. Replaces the single flat aggregation query.
- **`doEvent_KTPMatchStart` stores `half_num`** — Integer half number now stored in `$g_ktpMatchContext{$s_addr}{half_num}` for use by event handlers.
- **Event handlers pass `half_num` to `recordEvent`** — `doEvent_Frag`, `doEvent_Suicide`, and `doEvent_Statsme` look up `half_num` from match context and pass it as the last argument to their `recordEvent` calls (Frags, Teamkills, Suicides, Statsme).

### Schema
- Added `half TINYINT NOT NULL DEFAULT 0` to `hlstats_Events_Frags`, `hlstats_Events_Teamkills`, `hlstats_Events_Suicides`, `hlstats_Events_Statsme`
- Added `half TINYINT NOT NULL DEFAULT 0` to `ktp_match_stats` (after `player_id`)
- Replaced `uk_match_player` unique key with `uk_match_player_half (match_id, player_id, half)`
- Updated `ktp_match_leaderboard` and `ktp_recent_matches` views to filter on `half=0` and include `damage`/`score`
- Existing data preserved: all prior rows default to `half=0` (full match total)
- **Migration:** `sql/migrate_002_half_damage_score.sql`

---

## [0.3.0] - 2026-03-03

### Performance
- **Drain-then-process UDP architecture** - Main loop now drains all available packets (up to 500) into a queue before processing any, preventing kernel buffer overflow during burst periods. Per-packet peer address captured via `sockaddr_in()` instead of stale `peerhost/peerport`.
- **Batched frag UPDATEs via in-memory accumulators** - Roles, Weapons, and Maps_Counts UPDATEs replaced with hash increments flushed every 30 seconds, reducing per-frag MySQL round-trips from 4 to 0.
- **Event queue size increased 10 to 100** - Reduces multi-row INSERT frequency, cutting MySQL round-trips further. 30-second timer flush remains as staleness bound.
- **IO::Select created once and reused** - Eliminated per-iteration `IO::Select->new()` allocation.
- **1MB socket receive buffer** - Explicit `SO_RCVBUF` request as backup to system-level sysctl defaults.
- **Chat command regex chain replaced with hash lookup** - 30+ individual regex matches for `hlx_auto` command validation replaced with O(1) hash lookup.
- **`get_fav_weapon()` query reduction** - Reduced from 4 sequential queries to 2 using correlated subqueries.
- **Host group patterns cached at startup** - `loadHostGroups()` loads patterns once from DB into `@g_hostgroups_cache`, refreshed on SIGHUP. Eliminates per-connect DB query.

### Fixed
- **Match stats flush before aggregation** - `doEvent_KTPMatchEnd` now flushes Frags, Teamkills, Suicides event queues and accumulators before running aggregation query. With queue size 100, up to 100 kills could be in-memory when match ends.
- **Action hash access ignored map-specific variant** - `doEvent_TeamAction` and `doEvent_WorldAction` checked for both `$action` and `$map."_$action"` in an OR condition, but always accessed the non-prefixed key. Now determines which key matched and uses it consistently.
- **`$cmd_str` sent as empty RCON command** - Three `dorcon()` calls were outside the `display_events` conditional, sending undefined RCON commands when display was off. Moved inside the guard.
- **`printEvent()` missing argument separator in proxy handler** - Three calls passed a single concatenated string instead of separate `(code, description)` arguments, producing malformed log output.
- **`$g_lan_noplayerinfo` hash/hashref mismatch** - Write used `->{}` (hashref) syntax while reads used `%{}` (hash) syntax, making LAN mode player tracking non-functional.
- **Pre-connect timeout used stale timestamp** - Used `$ev_unixtime` (from last parsed event) instead of `$ev_daemontime` (current clock) for pre-connect cleanup.
- **`$pointvalue` undefined in `calcL4DSkill()`** - Variable was used but never defined. Changed to `$modifier` (the weapon skill modifier). Also added `my` declaration to `$diffweight`.
- **Proxy regex greedy mismatch** - `(.+)` greedily consumed spaces in proxy key matching, potentially swallowing part of the address capture. Changed to `(.+?)`.
- **"STEANBANS" typo** - Fixed to "STEAMBANS" in disconnect handler log string.
- **"KD-Radio" typo** - Fixed to "KD-Ratio" in player stats chat output.
- **Duplicate URL parameter** - `/load` command URL had `mode=status&server_id=%s&mode=load` with redundant first `mode=`. Removed.
- **Commas instead of semicolons** - Three hash assignments in server config defaults used comma operator instead of semicolons.
- **`execNonQuery` silent error dropping** - Failed queries now logged via `printEvent("SQL_ERROR", ...)` instead of silently discarded.
- **Shell injection in `error()` mail handler** - Replaced `system("... | $mailpath ...")` with safe list-form `open` pipe.
- **`$SIG{ALRM}` handler leaked after DNS timeout** - Changed to `local $SIG{ALRM}` for automatic restoration after eval block.
- **`$d_debug` typo** - Fixed to `$g_debug` in drain cap logging.
- **`$g_gloabl_chat` typo** - Fixed to `$g_global_chat`.
- **`nextkillzvic` hash key typo** - Fixed to `nextkillvicz`.
- **`$killer` used instead of `$player`** - Fixed bot check in `doEvent_PlayerPlayerAction`.
- **Stale `$s_addr` in housekeeping map check** - Replaced single-server check with iteration over all servers.
- **Missing `KTP_HALF_END` handler** - Added elsif branch in AMXX wrapper handler for half-end events.

### Removed
- Dead geo parsing block in `hlx_set` handler (parsed variables but never used them)
- Commented-out idle detection code (superseded by active `$ev_daemontime` version)

---

## [0.2.7] - 2026-02-25

### Fixed
- **Headshot flush used wrong table key** - `flushEventTable("hlstats_Events_Frags")` was a no-op because event queue keys use short names (`"Frags"`). Headshot UPDATE ran before the frag was actually flushed to the database, silently losing headshot attribution. Changed to `flushEventTable("Frags")`.
- **Duplicate players in match stats** - `ktp_match_players` had no unique constraint on `(match_id, player_id)`, so `INSERT IGNORE` never prevented duplicates. Players appearing in both halves got two rows, causing double-counted stats in the aggregation query. Added `UNIQUE KEY uk_match_player` to schema and changed to `ON DUPLICATE KEY UPDATE` to update team/name on re-appearance.
- **Match start_time overwritten by duplicate UDP packets** - `doEvent_KTPMatchStart` used `ON DUPLICATE KEY UPDATE start_time = NOW()` which overwrote the original timestamp if a duplicate log line arrived. Changed to no-op (`id = id`) on duplicate.
- **Team kills and suicides not aggregated** - `doEvent_KTPMatchEnd` hardcoded `team_kills = 0` and `suicides = 0` instead of querying `hlstats_Events_Teamkills` and `hlstats_Events_Suicides` tables. Added LEFT JOINs for both tables.

### Schema
- Added `UNIQUE KEY uk_match_player (match_id, player_id)` to `ktp_match_players` table
- **Migration required:** `ALTER TABLE ktp_match_players ADD UNIQUE KEY uk_match_player (match_id, player_id);`

---

## [0.2.6] - 2026-02-19

### Added
- **Headshot kill tracking** - New `headshot_kill` triggered event handler parses log lines from stats_logging.sma's `client_death` forward. Flushes pending frags then UPDATEs the most recent matching frag row to `headshot=1`. Enables per-frag headshot data without double-counting kills.
- **Map tracking restoration on match start** - `doEvent_KTPMatchStart` now sets `$g_servers{$s_addr}->{map}` from the match event's map property. Ensures correct map attribution after daemon restarts where the "Started map" log event was missed.

### Fixed
- **MySQL encoding crash resilience** - `execCached()` in `HLstats.plib` now catches "Incorrect string value" MySQL errors (from non-UTF8 player names) and logs a warning instead of dying. All other query errors still fatal.

---

## [0.2.5] - 2026-02-05

### Added
- **KTP_HALF_END event handler** - Sets accurate `end_time` at actual gameplay end
  - Fires when scoreboard appears, BEFORE map change/warmup
  - Prevents warmup kills from being incorrectly attributed to the previous half
  - Works with KTPMatchHandler v0.10.69+

### Fixed
- **Half end_time accuracy** - Previously set when next half started (after warmup)
  - Now set at actual gameplay end via KTP_HALF_END event
  - Eliminates ~1-2 minutes of warmup kills being counted in H1 stats

---

## [0.2.4] - 2026-02-04

### Fixed
- First half `end_time` now recorded in `ktp_matches` table when second half starts
  - Previously only the final half had `end_time` set (via KTP_MATCH_END)
  - Now each half's `end_time` is set when the next half begins
  - **Note:** This was later improved in v0.2.5 to set end_time at actual gameplay end

---

## [0.2.3] - 2026-02-03

### Added
- Debug logging for match context cleanup in `doEvent_KTPMatchEnd`
  - Logs match_id being cleared when match ends for troubleshooting

---

## [0.2.2] - 2026-01-23

### Added
- Debug logging for KTP_MATCH event tracing (`KTP_DEBUG` messages in journal)
- Traces raw lines containing KTP_MATCH, parsed properties, and function entry

### Changed
- Removed dead code from `HLstats_EventHandlers.plib` (duplicate event handlers)
- Added clarifying comment explaining authoritative handlers are in `hlstats.pl`

### Fixed
- Half detection now supports all formats: "1st", "2nd", OT halves (regex-based matching)

## [0.2.1] - 2026-01-22

### Fixed
- Half number detection now uses regex (`/^2/`) instead of exact string match to handle different half format variations (e.g., "2nd", "2", "2nd_half")

## [0.2.0] - 2026-01-16

### Added
- Track participating players in `ktp_match_players` table on each frag event
- Aggregate player stats to `ktp_match_stats` table on match end
- Auto-populate `ktp_matches` table on match start
- Parse `KTP_MATCH_START`/`KTP_MATCH_END` events from plugin log lines

### Changed
- Use NULL instead of empty string for `match_id` when no match is active
- Enhanced match context tracking per server

## [0.1.0] - 2025-12-17

### Added
- Initial fork from HLStatsX:CE (NomisCZ/hlstatsx-community-edition)
- KTP match context tracking (`%g_ktpMatchContext` hash)
- KTP_MATCH_START event handler
- KTP_MATCH_END event handler
- match_id column support in event recording
- SQL schema for ktp_matches table

### Changed
- Modified event recording to include match_id when context is active

## [0.0.0] - 2025-12-17

### Base
- Original HLStatsX:CE files from https://github.com/NomisCZ/hlstatsx-community-edition
