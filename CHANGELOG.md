# KTP HLStatsX Changelog

## [0.3.15] - Unreleased

### Added - schema-22 objective and grenade entity facts

- Accept only the paired stats producer schema 22 manifest at the audited
  two-second position interval, with `objective_attempt` and `grenade_entity`
  required in manifest capabilities and end-of-half capture health. Bare
  telemetry uses an exact, 1024-byte-bounded grammar; only a successfully
  persisted schema-22 manifest authorizes and allocates sequence state for its
  exact server/match/half. Authorization stores a canonical manifest
  fingerprint. Any non-identical same-context replacement revokes the prior
  authorization and sequence state before validation or SQL; failure leaves it
  revoked, while an exact accepted replay preserves accumulated health state.
- Parse bare `KTP_OBJECTIVE_ATTEMPT` start/complete/stop markers using their
  producer match, half, map, clocks, and sequence. Migration 022 creates the
  append-only `ktp_objective_attempt_events` ledger with one immutable start
  and at most one terminal per attempt. Identical replay is a no-op;
  conflicting lifecycle facts fail closed. A terminal whose start was lost is
  retained as left-censored rather than fabricating a start.
- Parse bare `KTP_GRENADE_ENTITY` tracked/removed markers for weapon IDs 13,
  14, and 36 only. Canonical weapon names and the cached owner identity must
  validate, the owner resolves through the side-effect-free durable identity
  path, and private XYZ coordinates remain in the database. Rockets, mortar,
  other weapon IDs, and `detonated`/`exploded` kinds are rejected.
- `removed` deliberately means only that a tracked `(entindex, serial)` entity
  was removed. There is no detonation/explosion cause and no grenade-to-damage
  correlation claim in this contract.
- Migration 022 adds replay/lifecycle uniqueness and match timeline,
  objective, entity, and owner indexes. It is rerunnable and repairs missing
  named indexes using the MySQL/MariaDB-compatible information-schema pattern.
  Existing named indexes must have the exact uniqueness and complete ordered
  columns, and extra required/no-default columns are rejected because daemon
  inserts could not populate them.
  A pre-existing partial/incompatible table now fails before index ALTERs with
  a ledger-specific actionable sentinel instead of being silently described as
  repaired. The executable migration selftest covers clean apply, rerun, index
  repair, wrong same-name index uniqueness, extra required columns, and both
  partial-table failures in Infrastructure's ephemeral MySQL. A dedicated CI
  job runs this entry point in the production-parity Lane B database image.
- A duplicate-key race now reselects and compares the complete immutable row:
  only an exact concurrent replay becomes a no-op; a differing row remains a
  rejected conflict.
- `scripts/selftest-telemetry22.pl` executes the shipped validators and ledger
  handlers for validation boundaries, context failure, replay, reordering,
  left-censored terminals, conflicting terminals, weapon rejection, and honest
  removal terminology. It is wired into `capture-contract-selftests`.

### Operations

- The daemon and migration do not purge the new ledgers. KTPInfrastructure's
  match-type retention job must include both tables before production rollout.

## [0.3.14] - Unreleased

### Fixed — an empty quoted field now parses as absent, not as a value

- **`getProperties` stored `("")` fields as a present empty string**, which
  defeated every `// default` downstream (defined-or sees `""` as defined) and
  then numified to `0`: a blank `k_prone` read as "standing", a blank `k_clip`
  as an empty magazine instead of the `-1` read-failed sentinel, and a half
  with no real data read as a complete one — a phantom record, with nothing
  erroring. Reachable without a malformed producer, because `formatex`
  truncates markers tail-first.
- An empty quoted field is now skipped: the key is absent from the returned
  hash, indistinguishable from an omitted property — which is what an empty
  field means. The frag-context certification path already renders this as
  `<absent>` rather than `''` in `KTP_BAD_PROPERTY`; certification outcomes do
  not change.
- `scripts/selftest-getproperties-empty.pl` executes the real sub extracted
  from `hlstats.pl` (no mirror), asserting the defect case, the consumer
  defaults, quoted `"0"` staying a value, and the DoD:S `player_a`/`player_b`
  rename surviving an empty first player. Fails 6 of 16 on the pre-fix code.
  Wired into `capture-contract-selftests`.

## [0.3.13] - Unreleased

### Added
- Persist per-half capture manifests from `stats_logging` 1.17.0 and reconcile
  producer attempted/enqueued/dropped/emitted counters against daemon receipts,
  accepted rows, rejected rows, correlation failures, duplicate/reordered
  markers, and global producer-sequence gaps (migration 021).
- Persist producer sequence numbers across frag context, damage, position,
  assist, life, objective-state, and cap-break facts. Cap breaks now retain the
  exact flag, stopped victim, and producer incident id instead of requiring a
  lower-bound grouping heuristic.
- Retain the match that most recently refreshed each idempotent static flag
  position, allowing objective metadata coverage to be verified per rollout.
### Fixed — an absent damage ledger no longer publishes as a measured zero

- **`ktp_match_stats.damage` was written as `0` for every player on every instance that does not
  produce `ktp_damage_events`.** `COALESCE(dmg.damage, 0)` cannot tell *this player dealt no damage*
  from *this half was never captured*, and the aggregate feeds the site, the export to ktpleague.gg,
  and anything weighting on damage — so an absence was being published as a measurement.
- The ledger is now probed per match/half before the aggregate is written. A half **with** ledger rows
  keeps `COALESCE(..., 0)`, so a player who dealt no damage still records `0`. A half **without** any
  ledger rows writes `NULL`, and a consumer can tell the two apart.
- No migration: `ktp_match_stats.damage` is already nullable.
- The decision is a named function (`ktpDamageExpr`) so it is testable in isolation;
  `scripts/selftest-damage-absence.pl` executes it out of the source between markers, so a revert
  fails the test rather than silently passing. Wired into `capture-contract-selftests`.

## [0.3.12] - Unreleased

### Added
- `frag_context_certified` (migration 020), separating "a marker consumed this
  row" from "the context on this row can be trusted". `frag_context_recorded`
  has to be set on every row a marker takes, or a second marker can rewrite one
  the first already claimed -- the defect migration 018 fixed on the break side.
  Certification asks the opposite question and the two answers diverge exactly
  when a property arrives absent, blank or malformed, so one column cannot carry
  both. Cutover and backfill queries want the new column.
  ⚠️ Migration 020 must be applied before this daemon starts: its
  frag_context UPDATE names the column, and a write to a column that does not
  exist fails inside MySQL with the whole statement lost.
  It ships no backfill. Certification is a claim made from what came off the
  wire, and no query over rows already written can re-derive it: every context
  default is also a legal reading -- `k_prone = 0` is standing, `k_clip = -1` is
  a failed read, `is_last_flag_defense = 0` is not defending -- so a defaulted
  column and a measured one are identical. The header carries the pre-flight and
  the conditions under which an operator may fill it in by hand.

### Fixed
- Validate every frag-context property against the producer's format instead of
  defaulting it with `//`. `getProperties` yields `""` for an empty field and
  this daemon runs without warnings, so a blank or non-numeric value numified
  silently into a measurement: `k_prone` became "standing", `k_clip` became an
  empty magazine rather than the reserved read-failed sentinel. This is the same
  false-default the break-context path was corrected for, still live on the path
  that writes the very column that case is named after. Values are bounded to
  the narrower of the column and the producer's own range, so a bad one cannot
  abort the UPDATE under strict mode; an unusable property is reported as
  `KTP_BAD_PROPERTY` naming the field; and the row is still written and still
  claimed, because a partial payload can carry a real headshot and that feeds
  the ladder. Only the certification is withheld.
  Positions are excluded: those columns are nullable, so NULL already reads as
  unknown.
- Keep the `headshot_kill` branch on FIFO, and record why, after nearly
  changing it. Its emitter buffers the marker and flushes on a timer while the
  engine's kill line reaches the daemon immediately, so the marker is
  systematically late: "newest unclaimed" is routinely a kill that happened
  *after* the one the marker describes. `ktp_stats_capture.inc`'s file header
  documents the technique as newest-first for both markers, which is what
  prompted the change and is not what the buffered emitter does. Neither
  ordering is exact -- this marker fires per headshot rather than per kill, so
  an earlier unmarked body shot can still absorb the flag, and no producer clock
  reaches this branch to settle it. The aggregate `SUM(headshot)` feeding the
  ladder is unaffected either way; what moves is which row carries the flag.
- Guard migration 019 on whether 020 has been applied, and make it a no-op once
  it has. 019 reads "flag set, every context column at its default" as proof the
  flag is false. That inference does not survive this release: the daemon now
  writes exactly that shape for an unusable payload while still claiming the
  row, and a genuinely certified kill can legitimately measure every default at
  once. Re-running it afterwards would withdraw live claims and re-open those
  rows to correlation.

## [0.3.11] - Unreleased

### Fixed
- Correlate DODX's precise DoD alternate-fire names (rifle butts, bayonets,
  folding/scoped variants, and the British knife) with the owning weapon name
  emitted by the stock game log. Correlation remains fail-closed on the exact
  server, killer, victim, and producer second; only an explicit one-way weapon
  alias is accepted, so a missing ordinary frag cannot shift context onto an
  unrelated row.

## [0.3.10] - Unreleased

### Fixed
- Correlate `break_context` markers exactly once. The UPDATE that attaches
  contester count, time remaining and capout state to a `cap_break` had no claim
  guard, so a dropped `cap_break` UDP line whose context marker still arrived
  would rewrite the player's PREVIOUS break inside the 60-second receipt window
  with the new break's numbers. That UPDATE matched a row, so it reported
  success and the existing `KTP_NO_ROW_MATCHED` diagnostic never fired -- wrong
  data was indistinguishable from right data. Migration 018 adds
  `break_context_recorded`, mirroring the Frags-side guard from migration 012.
  Ordering stays newest-first rather than adopting the frag path's FIFO: that
  path narrows to the exact producer second, this one has only the receipt
  window, where the newest unclaimed break is the better pairing.
- Record an unknown `is_capout` as NULL instead of 0. Migration 007 gave the
  column `NOT NULL DEFAULT 0` while its two siblings defaulted to NULL, so a
  break whose context marker never arrived was stored identically to a break
  the plugin measured and found was not a capout. Migration 018 makes it
  nullable. The column default is what resolves the ambiguity for a row that
  was never correlated; the daemon's matching NULL write is defensive, since
  the current producer emits all three properties unconditionally and only a
  truncated datagram reaches that branch. ⚠️ Note the `MODIFY` changes the
  default for **every** row of the table, not just `cap_break` -- the generic
  event insert does not name `is_capout`, so all future action rows take NULL
  where they took 0.
- Treat a malformed or empty break-context property as unknown rather than
  zero. `contester_count`, `time_remaining` and `is_capout` are validated
  against the producer's own formats and bounded to their columns; anything
  else is stored NULL and logged as `KTP_BAD_PROPERTY`. Previously a bare
  `defined` test let `getProperties`' empty-field `""` -- and any non-numeric
  value, via Perl numification -- land as a measured 0, silently, since this
  daemon runs without warnings enabled. Bounding also stops an out-of-range
  value aborting the whole UPDATE under strict mode.
- Withdraw `frag_context_recorded` from rows that carry no context
  (migration 019). Rows the `headshot_kill` branch flagged assert that their
  context columns are real measurements when every one of them is still at its
  default. The correction keys on that contradiction rather than on a date or a
  server, so it stays correct whenever it runs; `headshot` is left untouched,
  because it is the one thing those rows did measure and it feeds the ladder.
  ⏳ Time-sensitive: today every flagged row came from the defective path, and
  that stops being true once any instance emits `frag_context`.
- Stop the `headshot_kill` branch setting `frag_context_recorded`. That flag is
  read as "the context columns hold real measurements", but this marker carries
  only killer, victim and weapon, so every row it touched certified context that
  was never collected. The branch now sets `headshot` alone and uses
  `headshot = 0` as its own claim guard -- in DoD the stock kill line never
  carries a headshot property, so these markers are the column's only writer.
  The neighbouring comment calling the branch dead code is corrected with it:
  `headshot_kill` was retired in the plugin SOURCE only, and instances still
  running the older `stats_logging` build emit it and never emit `frag_context`.
- Do not report a false `Unresolved action` SQL error when a known action is
  deliberately disabled for the PlayerAction leg. The generic trigger
  dispatcher probes both action shapes, so victim-aware actions such as
  `assist` must be allowed to reject PlayerActions while still recording once
  in PlayerPlayerActions. Truly absent action definitions remain loud.

### Fixed
- Do not report a false `Unresolved action` SQL error when a known action is
  deliberately disabled for the PlayerAction leg. The generic trigger
  dispatcher probes both action shapes, so victim-aware actions such as
  `assist` must be allowed to reject PlayerActions while still recording once
  in PlayerPlayerActions. Truly absent action definitions remain loud.

### Added
- Persist validated per-player life starts and ends through event type 611 and
  migration 016. The new ledger records spawn/context-live starts and
  death/disconnect ends with explicit producer match, half, team, class, engine-time,
  and player correlation context. Live/freeze state remains NULL because the
  emitter cannot observe MatchHandler's private stats-pause flag; receipt-time
  daemon state is deliberately not substituted. Duplicate/replayed markers are
  idempotent, and match/half attribution must resolve to exactly one persisted
  `ktp_matches` start/end interval containing producer `event_epoch`. Zero,
  overlap, explicit-half disagreement, and match-id case mismatch all fail closed.
- Migration `017_capture_clocks_and_assists` adds nullable producer match/half
  and clocks to frag/damage facts, changes new damage rows' `event_time` to the
  producer epoch (with receipt time only as an old-emitter fallback), and creates
  the canonical `ktp_assist_events` companion ledger. The existing generic
  `assist` PlayerPlayerAction remains intact and rating-neutral. Timed analytics
  must use `producer_match_id`/`producer_half`, never the legacy receipt-time
  match fields.
- Every AMXX-buffered player marker (life, assist, frag, damage, cap break,
  break context, and position sample) uses side-effect-free identity parsing
  and durable player ids. The upstream `getPlayerInfo` path can disconnect an
  in-memory player when the same Steam identity appears under an older userid;
  a delayed marker can therefore no longer disconnect a legitimate reconnect.
  Generic assist/cap-break actions retain their rating-neutral stock handlers
  through a copied exact-live tuple. The focused Perl regression is wired into
  pull-request CI.
- Authoritative frag clocks are attached only to a same-tuple frag in the exact
  producer `event_epoch` second, FIFO within that second. Missing UDP markers
  cannot shift a later clock onto an older frag. Frag and damage producer clocks
  require one exact DB match interval and explicit half agreement; a bounded
  interval cache prevents per-hit DB queries. Old/warmup emitters silently keep
  their legacy facts with producer fields NULL, while genuine proof failures are
  aggregated rather than flooding the journal.
- Persist a compact per-match flag-ownership timeline through
  `KTP_FLAG_STATE` markers and migration 015. Each half starts with one
  baseline row per flag and records only subsequent owner changes, allowing
  positional samples to be classified as attacking, holding, or defending.
  A natural unique key makes retry or duplicate-log delivery idempotent.
- Persist KTPMatchHandler's numeric match type on each `ktp_matches` half via
  migration 014. Missing or invalid classifications remain NULL and are never
  eligible for type-based retention.
- Accept the backward-compatible `(type "N")` property on `KTP_MATCH_START`
  markers and fill a previously NULL classification without overwriting an
  existing value.

## [0.3.8] - 2026-08-16

### Fixed
- **KTP-owned tables now use the same collation as the existing HLStatsX
  event tables.** MySQL 8 can otherwise create new `utf8mb4` tables with
  `utf8mb4_0900_ai_ci`, while the existing schema uses
  `utf8mb4_unicode_ci`. A late frag-context cache refresh then fails when it
  joins the differently collated `match_id` columns. Migration 013 normalizes
  existing KTP tables and the create scripts now pin the compatible collation.
  Migration 013 must run before this daemon.

## [0.3.7] - 2026-08-16

### Fixed
- **A frag context arriving just after `KTP_MATCH_END` now refreshes the
  affected headshot cache row.** Canonical frag rows were correct, but the
  already-aggregated per-half and total `ktp_match_stats` rows could remain
  one headshot behind. The refresh runs only with no active match context and
  only for the affected killer in matches ended within 30 seconds, keeping it
  off the live per-kill path.

## [0.3.6] - 2026-08-16

### Fixed
- **Frag context can no longer rewrite a previously enriched kill.** Every frag
  row is now claimed once via `frag_context_recorded`, in FIFO order, within a
  ten-second window. This closes the observed case where the stock UDP frag line
  was lost but its later `frag_context` marker survived and overwrote an older
  same-killer/victim/weapon row. Migration 012 must run before this daemon.

- **An empty quoted field no longer swallows the rest of the line.** `getProperties`
  matched a quoted value with `"(.+?)"`, which requires at least one character — so
  `(matchid "")` could not match the quoted branch at all, and the lazy match ran on to
  the *next* quote pair. `(matchid "") (map "dod_harrington") (half "2nd half")` parsed
  as `match_id = ") (map "dod_harrington`, a phantom id that spread across **13 tables
  and 721 rows** at the Philadelphia 2026 LAN before anyone noticed. `.+?` is now `.*?`.

  The upstream trigger is already fixed — KTPMatchHandler no longer starts a half with
  an empty match id — so this is the amplifier rather than the cause. It is worth
  closing anyway: it fails **silently**, it corrupts across every table an event
  touches, and any future emitter writing an empty field re-opens it.

  ⚠️ **Test this with an EMPTY quoted field.** A malformed-input suite passes while this
  case still breaks, which is precisely how it survived.

  Verified by extracting the regex from the edited file and parsing the original
  corrupting line: `matchid` now yields the empty string, with `map` and `half` intact.
  Normal values, values containing spaces, bare unquoted values and a trailing empty
  field all parse unchanged.

- **The UDP receive buffer now asks for what the box is configured to give.**
  `net.core.rmem_max` was raised to 25MB and provisioned, but the request here stayed
  at 1MB — so the socket got 1MB on a box configured for 25, and the raised ceiling
  looked like a fix while changing nothing. Measured on the live daemon: it logged
  `Socket receive buffer: 2048KB`, the kernel's doubled view of 1MB. `$want_rcvbuf` now
  matches the ceiling.

  ⚠️ **A ceiling is not a request.** `rmem_max` caps what a process may ask for; it
  never grants anything on its own. The warning block below the request already reports
  a shortfall, so a future mismatch says so at startup instead of being inferred from
  lost log lines.

### Known, not fixed here
- **A bare boolean key followed by ` (` still mis-parses.** `(flagindex) (map "dod_anzio")`
  yields key `flagindex)` with the remainder as its value, because `\S+` is greedy and
  `)` is not whitespace — so the `# boolean property` branch is unreachable whenever a
  space follows. Present before this change and after it. Fixing it means altering
  `\S+`, which changes how every other line parses, and no real log sample carrying a
  bare boolean was available to test that against.

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
- **Per-player flag-capture completions** (`sql/migrate_010_flag_captures.sql`,
  `scripts/hlstats.pl`) — new `ktp_flag_captures` table and
  `doEvent_KTPFlagCapture` handler (event type 609) record DoD 1.3's own
  `dod_capture_area` engine event, previously discarded silently (no
  `hlstats_Actions` row existed for it — the same failure mode the 0.3.5
  entry below describes for the Philly LAN) and only ever explored ad hoc
  from raw logs (KTPInfrastructure's `composite_v2.py`).
  - The real GoldSrc log line is `"Player<uid><steamid><Team>" triggered a
    "dod_capture_area" - "POINT_NAME"` — a bare dash-suffixed quoted string,
    **not** the parenthesized `(key "val")` shape `getProperties()` expects.
    That function's own DoD-specific `$dods_flag`/`flagindex` handling is
    for DoD:**Source**'s different log format and never matches these
    GoldSrc 1.3 lines — confirmed by checking our own captured Lane B log
    against it, not assumed. The point name is parsed directly out of the
    raw trailing text instead of routing through the generic properties
    parser.
  - Deliberately a direct `INSERT` (same shape as `ktp_position_samples`/
    `ktp_damage_events`), not a generic-dispatcher `hlstats_Actions` seed —
    seeding one would have meant fighting the parser for a shape it wasn't
    built for, for a table (`hlstats_Events_PlayerActions`) with no columns
    for the data that actually matters here (which flag, how many cappers).
  - One row per capping player, on purpose. DoD 1.3's own capture mechanic
    requires some points to have two players standing on them
    simultaneously to complete a cap, others need only one — the engine
    emits one line per capping player plus a redundant team-level line
    carrying no information the per-player rows don't already have (team is
    on every row). That team-level line is left unhandled rather than
    double-recorded. Multi-capper detection is a query-time
    `GROUP BY (flag_name, event_time) HAVING COUNT(*) > 1`, not a stored
    column — same "raw facts, classify at query time" convention
    `ktp_position_samples` already established.
  - Live-verified against the 2026-08-13 Lane B run's captured log before
    writing the migration: 5 real two-player captures observed (a
    `Team "..."` line followed by exactly 2 per-player lines, same
    timestamp, same flag), confirming the row shape and the multi-capper
    query pattern both hold against real DoD 1.3 engine output.

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
