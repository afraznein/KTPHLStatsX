# Engine stats expansion plan (reconstructed)

**RECONSTRUCTED 2026-10-03. This is not the original document.**

Shipped code, migrations, tests and changelogs in KTPAMXX, KTPHLStatsX and KTPInfrastructure cite
`ENGINE_STATS_EXPANSION_PLAN_20260909.md` by section number as their spec. No repo holds that file.
This page rebuilds it from those citations, so a reader who follows one lands somewhere real.

Ground rules for everything below:

- **Section numbers come from the citations.** A section is listed only if something cites it. Numbers
  nothing cites are marked as gaps, and their content is not guessed.
- **Section content is what the shipped code does**, read from `origin/main`, with the sources named in
  each section. It is not the plan's original wording, and where the plan said more than the code does,
  that part is lost.
- **Intent is recorded only where a citation or the code states it.** Anything else is a gap.

Read from `origin/main` on 2026-10-03: KTPAMXX `a5cbec83b`, KTPHLStatsX `8e47b21a1`,
KTPInfrastructure `15eb4ccd2`. Line numbers are as of those commits.

## Where the original went

Searched on 2026-10-03, with no copy found:

- `git log --all --diff-filter=AD` and `git log --all -S'ENGINE_STATS_EXPANSION_PLAN'` in KTPHLStatsX,
  KTPInfrastructure and KTPAMXX: the name appears only in the commits that cite it, never as an added
  or deleted file. A `git grep` of every remote branch of all three repos turns up no section number that
  `origin/main` does not already cite.
- The operator's doc-set history, the `changes-archive/` ledgers, every local worktree, and PR search
  across the `afraznein` repos.
- The coordination repo's tree.

The best lead is the coordination repo's `state/infra-stat-capture.md`, whose goal line names the plan as
**`ktp_stats/handover/ENGINE_STATS_EXPANSION_PLAN_20260909.md`**. That is a working directory outside every
repo, not a repo path. KTPInfrastructure's
`docs/handover/SCHEMA_26_SHOT_HITGROUP_AND_REWIND.md` says the same: the plan "lives outside any repo".

If the original turns up, put it here and keep this page only as the citation index.

## Citation index

Every site on `origin/main` that cites the plan by name, or cites one of its section numbers next to
"wave" wording in the stats capture code.

| repo | file:line | cites | what the citing site says it covers |
|---|---|---|---|
| KTPAMXX | `plugins/dod/ktp_stats_capture.inc:252` | §3.2, 3.5, 3.7 | wave 2: three low-volume streams appended to the event enum |
| KTPAMXX | `plugins/dod/ktp_stats_capture.inc:422` | §3.6a | wave 1 per-life shot counters |
| KTPAMXX | `plugins/dod/ktp_stats_capture.inc:429` | §3.5 | wave 2 per-pair dodx vstats snapshot at half activation |
| KTPAMXX | `plugins/dod/ktp_stats_capture.inc:452` | §3.7 | wave 2 last-polled bipod-deploy state |
| KTPAMXX | `plugins/dod/ktp_stats_capture.inc:487` | §3.4 | wave 1 last known health per victim |
| KTPAMXX | `plugins/dod/ktp_stats_capture.inc:1392` | §3.6a | wave 1 shot counters on every life boundary |
| KTPAMXX | `plugins/dod/ktp_stats_capture.inc:1907` | §3.1/§3.9 | wave 1 "how far the cap got, and where the half clock was" |
| KTPAMXX | `plugins/dod/ktp_stats_capture.inc:2560` | §3.8 | wave 1 map-authored flag values |
| KTPAMXX | `plugins/dod/ktp_stats_capture.inc:2760` | wave 0, §3.6b | shot-context stream |
| KTPAMXX | `plugins/dod/ktp_stats_capture.inc:2855` | §3.6a | life counters run whether or not the shot stream is on |
| KTPAMXX | `plugins/dod/ktp_stats_capture.inc:3030` | §3.4 | health actually removed |
| KTPAMXX | `plugins/dod/ktp_stats_capture.inc:3130` | §3.10 | facing at the kill |
| KTPAMXX | `plugins/dod/ktp_stats_capture.inc:3287`, `:3292`, `:3324`, `:3378` | §3.2 score, §3.5 duel, §3.7 player_state | wave 2 emitters |
| KTPAMXX | `scripts/test_stats_life_boundaries.py:1316` | wave 0, §3.6b | shot stream: own buffer, own cvar, own flush task |
| KTPAMXX | `scripts/test_stats_life_boundaries.py:1376` | wave 1 | additive fields, no new stream, no schema bump |
| KTPAMXX | `scripts/test_stats_life_boundaries.py:1424`, `:1439`, `:1452` | §3.2, §3.7, §3.5 | wave 2 contract assertions |
| KTPAMXX | `CHANGELOG.md:449`, `:454`, `:462` | §3.2, §3.5, §3.7 | wave 2 (1.22.0) |
| KTPAMXX | `CHANGELOG.md:468` | §3.3 | "Not taken: §3.3 detonations" |
| KTPAMXX | `CHANGELOG.md:502` | §3.1/3.4/3.6a/3.8/3.9/3.10 | wave 1 (1.21.0) "Design:" line |
| KTPAMXX | `CHANGELOG.md:721` | §3.7 | "Full deploy state wants a dodx accessor; see §3.7" (1.20.2) |
| KTPAMXX | `CHANGELOG.md:835`, `:840` | §3.6b, wave 0 | shot stream has no target/hitgroup field, "deferred, not dropped" |
| KTPHLStatsX | `sql/migrate_032_wave1_additive_fields.sql:4` | §3.1, 3.4, 3.6a, 3.8, 3.9, 3.10 | "Spec:" line for wave 1 |
| KTPHLStatsX | `sql/migrate_033_wave2_streams.sql:5` | §3.2, 3.5, 3.7 | "Spec:" line for wave 2 |
| KTPHLStatsX | `scripts/hlstats.pl:1620` | §4.2 | `ktp_shot_events` is the first `ktp_*` stream sized to need batching |
| KTPHLStatsX | `scripts/hlstats.pl:3843` | wave 0 | shot-context marker dispatch |
| KTPHLStatsX | `scripts/hlstats.pl:4569`, `:4581`, `:4603` | §3.2, §3.7, §3.5 | wave 2 marker dispatch |
| KTPHLStatsX | `scripts/hlstats.pl:5830` | wave 1 | optional numeric field helpers |
| KTPHLStatsX | `scripts/hlstats.pl:6847` | §4.2 | shot rows batched instead of one INSERT per row |
| KTPHLStatsX | `CHANGELOG.md:212` | §3.3 | "Not in this wave: §3.3 detonations" |
| KTPHLStatsX | `CHANGELOG.md:371` | wave 0 | shot-context stream, schema 24 |
| KTPInfrastructure | `changelog.d/2026-09-14-pre-fragment-backlog.md:1013` | wave 0 | Lane B coverage of the shot stream |
| KTPInfrastructure | `tests/e2e_stats/assertions.py:1004` | wave 0 | `check_shot_events` |
| KTPInfrastructure | `tests/e2e_stats/test_match_analytics_integration.py:43` | wave 0 | schema 24 adds `shot` |
| KTPInfrastructure | `docs/handover/SCHEMA_26_SHOT_HITGROUP_AND_REWIND.md:15` | (whole plan) | says the plan lives outside any repo |

Commit messages cite it too: KTPAMXX `851c67e51`, `4b51c50bb`, `4a331a296` and KTPHLStatsX `7748afd`,
`e552a4b`, `ca321a0`.

## Sections 1 and 2

**Gap.** Nothing cites them. Their content is unknown.

## Section 3: what the producer emits

Producer: `plugins/dod/ktp_stats_capture.inc` in KTPAMXX (`stats_logging`). Receiver: `scripts/hlstats.pl`
in KTPHLStatsX. Every §3 subsection that shipped adds either fields to an existing stream or a new
stream.

### 3.1 Cap progress on objective attempts

Wave 1. `KTP_OBJECTIVE_ATTEMPT` gains `progress` (% of `CA_timetocap` elapsed), `peak_progress` (highest
reading in the attempt, tracked on the existing 0.5 s poll) and `timetocap`. `progress` is `-1` when the
point has no capture area, never `0`, so "no area" and "0 %" stay apart. Stored on
`ktp_objective_attempt_events` by migration 032, with `-1` written as NULL.

The stated reason (032 header, KTPAMXX changelog): "Broken at 73 %" becomes a column instead of an
inference.

⚠️ The one citation that names §3.1 for this code also names §3.9 (`ktp_stats_capture.inc:1907`). Which
field belongs to which number is inferred from that comment's word order, "how far the cap got, and where
the half clock was".

Sources: `ktp_stats_capture.inc:1907`, `migrate_032` (first block), KTPAMXX `CHANGELOG.md:502`.

### 3.2 Engine score attribution (`score` stream)

Wave 2. `KTP_SCORE_EVENT` from the `dod_score_event` forward: who the engine credited, per player, on each
cap and each territorial tick. Stored in `ktp_score_events` by migration 033. The stated reason (033
header) is to stop inferring credit from zone occupancy.

Index space fails closed. `cp_index` arrives in the game DLL's order and becomes `flag_index` only when
`dodx_cp_identity_resolved()` says DLL order equals dodx order. Otherwise `flag_index` is `-1` and
`dll_index` keeps the raw value. There is no remap table, on either side.

Later, outside any plan citation: schema 25 / migration 039 added `round_time_left` to these rows.

Sources: `ktp_stats_capture.inc:3292`, `migrate_033`, `hlstats.pl:4569`,
`test_stats_life_boundaries.py:1424`, KTPAMXX `CHANGELOG.md:449`.

### 3.3 Grenade detonations

**Not built, on purpose.** Both changelogs say detonations were already captured: the TraceLine that fires
`dod_grenade_explosion` and starts the entity tracker is `CGrenade::Detonate`'s own downward trace, so the
`tracked` row in `ktp_grenade_entity_events` is the burst, and an `exploded` kind would duplicate it.

⚠️ The record contradicts itself. The wave-2 commit messages (KTPAMXX `4a331a296`, KTPHLStatsX `ca321a0`)
say the forward "fires on the throw". Both changelogs were corrected on 2026-09-16 to say it does not. The
corrected version is the one the later throw stream (migration 034) was built on, since that stream reads the
throw off AmmoX because no module forward fires at the throw. That throw stream is not attributed to the
plan by any citation.

What §3.3 originally proposed beyond "capture detonations" is a **gap**.

Sources: KTPAMXX `CHANGELOG.md:468`, KTPHLStatsX `CHANGELOG.md:212`.

### 3.4 Applied damage

Wave 1. Damage rows gain `health_before`, `health_after` and `damage_applied` (health actually removed,
clamped to `damage`). Per-victim health is seeded from `get_user_health` at life start and updated after
every hit. `client_damage` fires after the hit lands, so "after" is read live and "before" is the tracked
value. The stated reason is that this column differs from `damage` on overkill and armour. Stored on
`ktp_damage_events` by migration 032.

Sources: `ktp_stats_capture.inc:487`, `:3030`, `migrate_032` (second block).

### 3.5 Per-pair duel matrix (`duel` stream)

Wave 2. `KTP_DUEL` is the per-(attacker, victim) `get_user_vstats` matrix the module already keeps (kills,
deaths, headshots, teamkills, shots, hits, damage, eight hit groups). It is snapshotted when the producer
context activates and emitted as a per-half delta at half close, before that half's health row. It goes out
as a direct `log_message` because the shared ring is smaller than the burst, so its health counters are kept
by hand. The base is invalidated after emission so an overtime double-close cannot re-emit, and a slot's base
is cleared on disconnect because the module's counters restart with the slot. Stored in `ktp_duel_stats` by
migration 033.

Sources: `ktp_stats_capture.inc:429`, `:3378`, `migrate_033`, `hlstats.pl:4603`,
`test_stats_life_boundaries.py:1452`, KTPAMXX `CHANGELOG.md:454`.

### 3.6 Shots

The citations split this section in two.

#### 3.6a Per-life shot counters

Wave 1. Life-boundary rows gain `shots`, `shots_hitscan` and `first_shot_delay` (seconds from spawn to first
shot, `-1` if the life never fired). They are counted in `dod_client_weapon_fire` before the shot-stream cvar
gate, because they are life stats and do not depend on the shot stream being on. Stored on `ktp_life_events`
by migration 032, with `-1` written as NULL.

Sources: `ktp_stats_capture.inc:422`, `:1392`, `:2855`, `migrate_032` (third block).

#### 3.6b Shot-context stream (`shot`)

Wave 0, schema contract 23 to 24. One row per weapon actuation with the shooter's position, facing and
stance, from `dod_client_weapon_fire`. Stored in `ktp_shot_events` (migration 027 onward).

What the citations say about it:

- It does not duplicate KTPMatchHandler's per-shot ledger (`ktp_ac_weapon_fires`). It adds the one thing
  that ledger lacks, where the shooter stood and faced, and joins to it by player, weapon and nearest clock.
- It has its own ring buffer, flush task and kill-switch cvar (`ktp_stats_shots`), so a burst of shots can
  never evict a damage, break or frag-context line.
- It runs no shot detection of its own.
- **No target or hitgroup field.** That read belongs to the AC ledger's destructive, single-consumer
  `dodx_get_shot_geom`. The citations call it "deferred, not dropped". The follow-up is designed in
  KTPInfrastructure `docs/handover/SCHEMA_26_SHOT_HITGROUP_AND_REWIND.md`, which is a separate document.
- The shipped `deployed` field never compiled (`dod_is_deployed` is a dodfun native) and was removed in
  1.20.2. `prone` carries 2 for prone-and-deployed. Full deploy state points at §3.7.

Sources: `ktp_stats_capture.inc:2760`, `test_stats_life_boundaries.py:1316`, KTPAMXX
`CHANGELOG.md:721`, `:835`, `:840`, KTPHLStatsX `CHANGELOG.md:371`.

### 3.7 Prone and bipod-deploy edges (`player_state` stream)

Wave 2. `KTP_PLAYER_STATE` emits `prone`/`unprone` from `dod_client_prone`, and `deploy`/`undeploy` edges from
`dodx_is_deployed` on the existing 0.5 s poll, for bipod classes only (BAR, 30cal, FG42, MG34, MG42, Bren).
`dodx_is_deployed` had no caller before this. The class gate keeps any offset garbage off the wire for
everyone else. Each row carries position and yaw. Stored in `ktp_player_state_events` by migration 033.
The stated reason (033 header) is that it is "the prerequisite for any suppression or lane-control measure".

This is also where the 1.20.2 changelog pointed for "full deploy state", the field the shot row lost.

Sources: `ktp_stats_capture.inc:452`, `:3324`, `migrate_033`, `hlstats.pl:4581`,
`test_stats_life_boundaries.py:1439`, KTPAMXX `CHANGELOG.md:462`, `:721`.

### 3.8 Map-authored flag values

Wave 1. `KTP_FLAG_POSITION` gains `default_owner`, `points_for_cap`, `team_points`, `timetocap` and
`identity_resolved`, read from the module (`dodx_objective_get_data`, `dodx_area_get_data`,
`dodx_cp_identity_resolved`) rather than inferred from play. Stored on `ktp_flag_positions` by migration 032,
which refreshes them on the upsert path too. The KTPAMXX changelog says this is what the spawn-ownership table
now reads from BSPs.

Sources: `ktp_stats_capture.inc:2560`, `migrate_032` (fifth block).

### 3.9 Half clock on objective rows

Wave 1. `round_time_left` (`dodx_get_round_time()` seconds) on objective attempts and on flag-state ownership
changes. Stored on `ktp_objective_attempt_events` and `ktp_flag_state_events` by migration 032.

⚠️ Inferred, two ways. Only the objective-attempt half is cited, and only jointly with §3.1 (see 3.1).
Placing the flag-state column here as well is inference: no citation names a section for it. Migration 039
later gave score rows the same clock, describing it as the clock "wave 1 already gave objective_attempt and
flag_state rows".

Sources: `ktp_stats_capture.inc:1907`, `migrate_032` (first and fourth blocks), `migrate_039` header.

### 3.10 Facing at the kill

Wave 1. Frag context gains `k_yaw`, `k_pitch`, `v_yaw` and `v_pitch` from `dodx_get_user_angles`, with `-999`
meaning unreadable and never `0`, because 0 is a real heading. `KSC_BUF_LINE_LEN` went from 832 to 1024 for
the wider line. Stored on `hlstats_Events_Frags` by migration 032. They sit outside the integer-only
frag-context certification, so an unreadable angle never withholds `frag_context_certified`.

Sources: `ktp_stats_capture.inc:3130`, `migrate_032` (last block), KTPHLStatsX commit `e552a4b`.

### Section 3 items the plan held that never shipped

The KTPAMXX 1.21.0 changelog lists these as "Skipped from the plan, deliberately ... Add when a consumer asks":
burst counters on life rows, `CP_pointvalue` (reads 0 on every CP), `CP_can_touch`, `score_tick_in`, angles at
attempt start, movetype at death, and grenade-tracker occupancy (needs a module gauge).

**Gap:** which subsection each belonged to is not recorded.

## Section 4: what the daemon does

### 4.1

**Gap.** Nothing cites it.

### 4.2 Batched inserts for high-volume streams

Wave 0. `ktp_shot_events` is the first `ktp_*` stream batched into multi-row INSERTs (`g_ktpShotQueue`,
flushed at a row threshold or on the next `KTP_CAPTURE_HEALTH` marker) instead of one INSERT per row. The
stated reason: the measured shot rate is about an order of magnitude above every other `ktp_*` stream, and a
synchronous per-row INSERT at that rate risks stalling UDP intake for every stream on the daemon's single
thread. `position` was later moved onto the same path for a separately measured reason (see the note at
`hlstats.pl:1620`). That move is not attributed to the plan.

Sources: `hlstats.pl:1620`, `:6847`, KTPHLStatsX `CHANGELOG.md:371`, KTPHLStatsX commit `7748afd`.

### Anything after 4.2

**Gap.**

## Waves

| wave | sections | schema contract | producer | daemon | migration | when |
|---|---|---|---|---|---|---|
| 0 | 3.6b, 4.2 | 23 to 24 | KTPAMXX `851c67e51`, stats_logging 1.20.0 | KTPHLStatsX `7748afd` | 027 | 2026-09-09. Compressed to ship before the S10 first match day (2026-09-13) at the operator's request |
| 1 | 3.1, 3.4, 3.6a, 3.8, 3.9, 3.10 | none (stays 24) | KTPAMXX `4b51c50bb`, 1.21.0 | KTPHLStatsX `e552a4b` | 032 | 2026-09-16 |
| 2 | 3.2, 3.5, 3.7 (3.3 not taken) | none (stays 24) | KTPAMXX `4a331a296`, 1.22.0 | KTPHLStatsX `ca321a0` | 033 | 2026-09-16 |

Waves 1 and 2 take no schema bump because a daemon that does not know the new fields or markers ignores them
and nothing else changes. Every new field is NULL from an older producer, and every new stream is declared in
`KSC_CAPABILITIES` with its own per-type sequence and health row.

Whether the plan defined more waves is a **gap**.
