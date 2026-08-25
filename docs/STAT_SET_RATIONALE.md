# Stat Set Rationale — why each stat is or is not logged

Written before the Season 10 stat set is frozen, against the operator's standing
directive: *"The one thing worse than a missing stat is a missing stat nobody
decided to omit — that is how `k_prone` sat at zero through nine seasons with a
comment implying it was handled."*

The purpose of this document is the **reason**, not the number. Every stat below
is either traced to a recorded decision or explicitly marked **no recorded
decision**; nothing is given an invented rationale. Where a stat is absent, the
entry says whether that absence is *honest* (readable as unknown) or *disguised*
(readable as a measured false).

**Counts are deliberately not written into the prose here.** Every measured
figure in the draft this document replaces had drifted within hours of being
written. Each claim below states a property instead, and § How to re-measure
carries the queries that re-derive it.

> **Companion change.** The three marker-handler correlation fixes and
> migrations 018 and 019 (`afraznein/KTPHLStatsX`#27) have landed, and this document has been
> re-read against them — see the correction in § Class 2. The entry on what
> certifies frag context now depends on migration 020 instead, which is not yet
> applied; it says so where it appears.

## Citations

Line references are pinned to a commit, because they move:

| Repo | Ref pinned |
|---|---|
| `KTPHLStatsX` | `origin/main` @ `b34636a` (plus this PR's own changes, called out where relevant) |
| `KTPAMXX` | `origin/main` @ `0d5a58fec` |

Schema claims cite table and column and are re-derivable from
`information_schema`; they do not depend on any pinned line.

## The one fact that governs how to read every absence below

`hlstats_Events_Frags`, verified from `information_schema.COLUMNS`:

| column | type | nullable | default |
|---|---|---|---|
| `pos_x`/`pos_y`/`pos_z`, `pos_victim_x/y/z` | `mediumint` | **YES** | `NULL` |
| `k_prone`, `v_prone`, `k_scope`, `v_scope` | `tinyint` | **NO** | `0` |
| `k_clip`, `k_ammo`, `v_clip`, `v_ammo` | `smallint` | **NO** | `-1` |
| `is_last_flag_defense` | `tinyint(1)` | **NO** | `0` |
| `headshot` | `tinyint(1)` | **NO** | `0` |
| `killerRole` | `varchar(64)` | **NO** | `''` |
| `frag_context_recorded` | `tinyint(1)` | **NO** | `0` |
| `frag_context_certified` | `tinyint(1)` | **NO** | `0` |

**Position is honest.** It is nullable, so "never written" reads as `NULL`, which
no query can mistake for a measurement.

**Prone, scope and last-flag-defense are not.** They are `NOT NULL DEFAULT 0`, so
a row nothing ever touched reads *identically* to a row that was checked and came
back false. A query for "kills while prone" against untouched data returns zero
and looks like a result. This is the exact trap the operator's directive names.

**Clip and ammo dodge that trap with a reserved sentinel, and are NOT the same
class.** `-1` is not a reachable ammo reading: `ksc_weapon_state`
(`ktp_stats_capture.inc:771`) initialises both to `-1` and overwrites them only
for a connected player, and its own comment records that a melee weapon returns a
real `clip=0, ammo=0` through the same native — so `-1` means "could not read",
never "no clip". Absence is therefore honest here, exactly as it is for position.
Do not group clip/ammo with prone/scope; only the latter pair is ambiguous.

## Class 1 — emitted and captured today

None of these were part of the audit gap this document exists to close. They are
long-standing and were not the subject of any recent ruling.

| Stat | Column / table | Reason it is live |
|---|---|---|
| Headshot | `hlstats_Events_Frags.headshot` | Written by the `headshot_kill` marker branch in `scripts/hlstats.pl`. The default-0 ambiguity is moot here because both values are demonstrably written at scale. ⚠️ This is a **KTP** marker emitted by `stats_logging`, not stock HLStatsX behaviour. |
| Killer class per kill | `hlstats_Events_Frags.killerRole` | Stock DoD kill-line parsing; populated for the large majority of rows. |
| Teamkills | `hlstats_Events_Teamkills` | Stock HLStatsX event table, unrelated to the S10 gap. |
| Suicides | `hlstats_Events_Suicides` | Stock HLStatsX event table. |
| Kill streaks | `hlstats_Actions` codes `kill_streak_2`…`kill_streak_12` → `hlstats_Events_PlayerActions` | Stock HLStatsX streak detection. Their `reward_player` values are graduated and pre-date KTPR, so that weighting is already baked into historical skill values. |
| Flag captures | `hlstats_Actions` code `dod_control_point` | Stock DoD capture event, pre-dates KTPR. Carries a non-zero `reward_player`, deliberately unlike the KTP actions — see Class 3. |
| Flag zone presence | `hlstats_Actions` code `dod_capture_area` | As above. |
| Per-weapon shots/hits/kills/headshots/TKs/damage/deaths/score and hitzone breakdown | `weaponstats`/`weaponstats2` lines → `hlstats_Weapons` etc. | `stats_logging.sma`'s player-stats flush, unchanged stock behaviour. **Deliberately excludes bots** — see Class 3. |
| Playtime and average ping on disconnect | `time`/`latency` lines → `hlstats_Events_Connects` | `stats_logging.sma`'s disconnect path, unchanged stock behaviour. |
| KTP flag-capture ledger | `ktp_flag_captures` | Populated through the daemon's existing capture path; pre-dates the frozen-set question. |

## Class 2 — will be captured from S10 (emitter writes it, not yet fleet-wide)

**Rollout status.** The daemon side is deployed and current: `/opt/hlstatsx/scripts/hlstats.pl`
is byte-identical to `KTPHLStatsX` `origin/main`, confirmed by md5 against the
blob. ⚠️ **Identify that build by md5, never by a commit named in a document or by
the startup banner** — the banner reports the upstream version from the database
and does not change on deploy (`CLAUDE.md` § Verifying which build is live).

The **plugin** side is the gap. The fleet's `stats_logging.amxx` is the older
March build on **23 of the 24** instances; a build carrying
`ktp_stats_capture.inc` runs on **Denver 27018 only**, shipped as an
operator-authorised standalone test at the 2026-08-21 restart. The remaining 23
have not been scheduled. Deadline is the last nightly restart before the first
S10 match (2026-09-13).

The two builds are distinguishable from the logs, which is how the split above
was measured: the old build emits `headshot_kill` and never `frag_context`; the
new build emits `frag_context` (with headshot as a *field*, not its own event),
plus `position_sample`, and never `headshot_kill`.

🔻 **`frag_context_recorded` is a claim guard, not a quality signal — read
`frag_context_certified` instead.** The first column exists so exactly one
marker can consume a given frag row, which means it has to be set even when the
marker's payload arrived incomplete. The second, added in migration 020, is the
one that says every context property on the row was present and well-formed. A
cutover query wants the second.

⚠️ **Neither column's `= 0` says which of three things happened** — no marker
was emitted (the stock build, on most of the fleet), a marker was emitted and
lost, or a marker arrived unusable. All three leave the context columns holding
defaults, and every default is a legal reading, so nothing in a row's content
separates them. That is why certification is recorded at write time, cannot be
reconstructed afterwards, and why migration 020 ships no backfill.

🔻 **This block used to say the flagged rows all came from instances running the
old build, on a server id that was not Denver 27018.** That described the defect
`afraznein/KTPHLStatsX`#27 fixed — the `headshot_kill` branch setting the flag while writing no
context — and stopped being true the moment that fix and migration 019 were
applied. Do not carry either shape forward: re-derive the split with the
`frag_context_recorded` query in § How to re-measure, which now also breaks out
certification.

| Stat | Column / table | Why it is not live yet |
|---|---|---|
| Killer/victim prone state | `k_prone`/`v_prone` — **false-zero risk** | Emitter (`ksc_emit_frag_context`, `ktp_stats_capture.inc:865`) and the daemon's `frag_context` branch both exist and agree; the plugin is not on 23 of 24 instances. **Operator ruled 2026-08-20: emit it.** |
| Killer/victim scope state | `k_scope`/`v_scope` — **false-zero risk** | Same ruling, same rollout gap. |
| Killer/victim kill position | `pos_x/y/z`, `pos_victim_x/y/z` — nullable, honest | Same rollout gap. Absent, not falsely zero. |
| Killer/victim clip and ammo | `k_clip`/`k_ammo`/`v_clip`/`v_ammo` — `-1` sentinel, honest | Same rollout gap. |
| Last-flag-defense | `is_last_flag_defense` — **false-zero risk** | Same rollout gap. Keys off **kill position** relative to the defended flag, not off the break queue, per an operator correction recorded at `ktp_stats_capture.inc:822-828`: a defender who kills a would-be ninja before they start capping is defending just as much, and the break queue structurally cannot see a kill that never touched a capture zone. |
| Assists | `hlstats_Actions` code `assist` → `hlstats_Events_PlayerPlayerActions` | Emitter and daemon path exist and the action is seeded (`sql/migrate_003_assist_action.sql`). Plugin not yet on 23 of 24. `reward_player = 0` is a deliberate weighting choice, not a capture gap — see Class 3. |
| Cap breaks | `hlstats_Actions` code `cap_break` → `hlstats_Events_PlayerActions` | Emitter (`ksc_emit_break`, `ktp_stats_capture.inc:434`) and daemon path exist, action seeded (`sql/migrate_004_cap_break_action.sql`). Same rollout gap. |
| Break context — contester count, time remaining, capout | `hlstats_Events_PlayerActions.contester_count`/`time_remaining`/`is_capout` | Same rollout gap; a follow-up marker (`ksc_emit_break_context`, `ktp_stats_capture.inc:485`) UPDATEs the `cap_break` row through the `break_context` branch of `scripts/hlstats.pl`. ⚠️ `is_capout` was `NOT NULL DEFAULT 0` — the same false-zero class as prone/scope, being introduced fresh on a table that did not have it. Made nullable in migration 018 before any row was written; see below. |
| Flag-ownership timeline | `ktp_flag_state_events` | Migration 015 applied, table exists, no rows yet — including on Denver 27018. The emitter needs a live KTP `match_id` to baseline (`ksc_ensure_ownership_baseline`, `ktp_stats_capture.inc:403`), and that instance's traffic so far appears to have been warmup rather than a tagged match. |
| Static flag positions | `ktp_flag_positions` | Working where the plugin runs; confirms the rollout path. |
| Roster position samples | `ktp_position_samples` | Working where the plugin runs. Raw facts only, by design — see the ninja-cap entry in Class 3. |
| Per-hit damage ledger | `ktp_damage_events` | Working where the plugin runs. Stores the capped and the raw value, and includes self and team hits deliberately — see Class 3. |

**The break-context timing is the one piece of luck here.** `cap_break` has no
rows in its entire history, so the two correlation defects found in its handler
(no exactly-once guard; `is_capout` unable to say "unknown") were fixed before
they could corrupt anything. Had the plugin rolled out first, neither would have
been visible in the data — the guard defect in particular produced a successful
UPDATE and no diagnostic.

## Class 3 — deliberately not captured, reason found and cited

| Stat / behaviour | What is omitted | Reason (source) |
|---|---|---|
| Bot weapon stats | `weaponstats`/`weaponstats2`/StatsMe rows for bots | `stats_logging.sma:102-113`: production has **always** excluded bots from StatsMe weapon summaries. Confirmed intentional rather than an oversight by the existence of a narrow compile-time override (`KTP_LANE_B_BOT_WEAPONSTATS`) that additionally requires `sv_lan 1` **and** `ktp_testmatch_enabled 1` at runtime, built so an all-bot regression can exercise the path without changing production behaviour. The same bot gate guards the disconnect path at `:185`. |
| Self- and team-damage toward assist eligibility | Friendly-fire and self-damage never accrue toward the assist damage threshold | `ktp_stats_capture.inc:296-310`: *"Enemy damage only from here down — self-damage and team hits earn no assist credit."* The damage itself is **not lost**: `ksc_emit_damage` is called unconditionally, before that gate, so the ledger keeps every hit and only assist eligibility excludes them. |
| Assist / cap-break skill-point reward | `hlstats_Actions.reward_player = 0` for both | `sql/migrate_003_assist_action.sql` and `migrate_004_cap_break_action.sql`, verified live against the stock capture actions, which carry a non-zero reward. HLStatsX's skill column is its own ELO and KTPR does not read it — it computes its own rating from the raw event rows — so a non-zero reward here *"would silently re-rate every player on the ladder as a side effect of adding a stat."* A deliberate **weighting** decision, entirely separate from whether the events are captured. **This is not a gap.** |
| Assist double-write across two tables | `assist` is `for_PlayerActions='0'` / `for_PlayerPlayerActions='1'`; `cap_break` is the reverse | Same migration files. The dispatcher calls both `doEvent_PlayerPlayerAction` and `doEvent_PlayerAction` for one line, each gated on its own flag; setting both for `assist` would write the event twice — once with victim attribution, once without — and apply the reward twice. Load-bearing, not cosmetic. |
| Raw uncapped per-hit damage as the consumer-facing figure | KTPR-facing consumers read `damage_capped`, not `damage` | `ktp_stats_capture.inc:44-52` (`KSC_DAMAGE_CAP`): DoD's raw per-hit value is the nominal weapon value with headshot and wallbang multipliers applied and is **not** clamped to a body's real 0–100 pool, so a single hit can log 400+. Uncapped it measures how strong a weapon-and-hitzone combination is on paper, not how much the hit mattered — the wrong quantity for a per-player stat, and the same convention CS2 uses. **Nothing is lost**: the raw value is stored alongside the capped one. A derived-metric shaping choice, not an omission. |
| Control-point Z coordinate | Flag positions and the last-flag-defense proximity check are 2D only | `ktp_stats_capture.inc:828`: `dodx.inc` exposes no `CP_origin_z` native. An **engine/include limitation**, not a policy choice — listed apart from the operator decisions so it is not mistaken for one. |
| Ninja-cap classification | Not computed anywhere, and will not be once `position_sample` is fleet-wide | `KTPInfrastructure/tests/e2e_stats/NEXT_PHASES.md` § Ninja-cap detection: explicit operator direction that capture stays *"raw facts only"* and classification happens entirely in the query layer, never judged in the engine. Deliberately deferred; no owner assigned. |
| `dod_object_goal` | The action row itself, deleted from `hlstats_Actions` | ✅ **RULED 2026-08-22 — DELETED, not retired-in-place.** Measured at source before staging: **0** player-action events and **0** team-bonus events across its entire history, against controls of **142,213** for `dod_control_point` and **102,270** for `dod_capture_area` — a zero next to two six-figure siblings is a fact about the action, not about the query. Nothing in `KTPAMXX` or `KTPHLStatsX` emits it, and no migration created it: it is inherited stock seed data. Keeping it "known-dormant for schema compatibility" was the alternative and was rejected — a dormant row is indistinguishable from a stat we meant to collect and lost, which is the exact failure this document exists to prevent. Dropped by `migrations-to-apply/28_drop_dod_object_goal.sql`, which re-checks the event counts at run time and refuses rather than orphaning rows if any arrived after staging. |

## Open risks this document does not resolve

**The cutover is still unhandled.** Once `k_prone`, `v_prone`, `k_scope`,
`v_scope` and `is_last_flag_defense` start carrying real values fleet-wide, the
pre-emission `0` and a genuine measured `0` become indistinguishable *in the same
column*, and nothing recorded anywhere marks where emission began. `TODO.md`'s
own card calls for a logging-start marker — match id, date, or plugin version —
so a cross-season query can exclude the pre-emission era instead of averaging a
default into a rate. Not implemented. Flagged here so it is not lost when the set
is otherwise declared frozen.

**`is_capout` is fixed going forward but not backward.** Migration 018 makes the
column nullable and the daemon now writes `NULL` when the property is absent.
Rows written before that keep a `0` that is genuinely ambiguous, and are
deliberately not backfilled — nothing in the row distinguishes the two cases, so
a backfill would invent a fact. The ambiguity is currently bounded by the fact
that `cap_break` has no history at all.

**One stale comment, recorded rather than silently fixed.** `scripts/hlstats.pl`'s
`position_sample` branch describes `KSC_POSITION_BROADCAST_SECS` as *"currently
30s"*. The emitter defines it as `5.0` (`ktp_stats_capture.inc:83`), raised from
30 on an operator call because 30s left too few samples per life. The emitter's
own comment is explicit that 5s is a **reasoned** value derived from measured
production volume, **not** one profiled against live EPS — and that it should be
validated the same way before being trusted, specifically by watching the
buffer's dropped-line counter on a real run.

## How to re-measure

Anything stated as a property above is re-derivable from these. Run against
`hlstatsx` on the data server. Read-only.

```sql
-- The nullability table at the top of this document.
SELECT COLUMN_NAME, COLUMN_TYPE, IS_NULLABLE, COLUMN_DEFAULT
FROM information_schema.COLUMNS
WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'hlstats_Events_Frags'
ORDER BY COLUMN_NAME;

-- Is any Class 2 frag context actually landing yet? All of these are expected
-- to be zero until the plugin is fleet-wide; a non-zero is the rollout working.
SELECT 'k_prone_1'   k, COUNT(*) v FROM hlstats_Events_Frags WHERE k_prone = 1
UNION ALL SELECT 'k_scope_1',       COUNT(*) FROM hlstats_Events_Frags WHERE k_scope = 1
UNION ALL SELECT 'last_flag_def_1', COUNT(*) FROM hlstats_Events_Frags WHERE is_last_flag_defense = 1
UNION ALL SELECT 'pos_x_notnull',   COUNT(*) FROM hlstats_Events_Frags WHERE pos_x IS NOT NULL
UNION ALL SELECT 'k_clip_measured', COUNT(*) FROM hlstats_Events_Frags WHERE k_clip <> -1
-- Positive control: must be large, or the probe itself is broken.
UNION ALL SELECT 'CONTROL_frags',   COUNT(*) FROM hlstats_Events_Frags;

-- Which server ids carry claimed frag rows, and how many of those claims are
-- certified. claimed > certified is the daemon reporting unusable properties;
-- pair it with KTP_BAD_PROPERTY in the journal, which names the fields.
SELECT serverId,
       COUNT(*)                                    AS claimed,
       SUM(frag_context_certified = 1)             AS certified,
       SUM(headshot = 1)                           AS headshot,
       SUM(pos_x IS NOT NULL)                      AS with_position,
       SUM(k_prone = 1 OR k_scope = 1)             AS with_prone_or_scope
FROM hlstats_Events_Frags
WHERE frag_context_recorded = 1
GROUP BY serverId;

-- Class 1 / Class 2 action state, including the dod_object_goal finding.
SELECT a.code, a.reward_player, a.for_PlayerActions, a.for_PlayerPlayerActions,
       COUNT(pa.id) AS playeraction_rows
FROM hlstats_Actions a
LEFT JOIN hlstats_Events_PlayerActions pa ON pa.actionId = a.id
WHERE a.game = 'dod'
  AND a.code IN ('assist','cap_break','dod_control_point','dod_capture_area','dod_object_goal')
GROUP BY a.code, a.reward_player, a.for_PlayerActions, a.for_PlayerPlayerActions;

-- Assists live in the player-vs-player table, not the one above.
SELECT COUNT(*) AS assist_events
FROM hlstats_Events_PlayerPlayerActions ppa
JOIN hlstats_Actions a ON a.id = ppa.actionId
WHERE a.code = 'assist';

-- The KTP tables the new plugin feeds.
SELECT 'ktp_position_samples'  k, COUNT(*) v FROM ktp_position_samples
UNION ALL SELECT 'ktp_damage_events',     COUNT(*) FROM ktp_damage_events
UNION ALL SELECT 'ktp_flag_positions',    COUNT(*) FROM ktp_flag_positions
UNION ALL SELECT 'ktp_flag_state_events', COUNT(*) FROM ktp_flag_state_events
UNION ALL SELECT 'ktp_flag_captures',     COUNT(*) FROM ktp_flag_captures;
```

Which plugin build an instance runs, and which marker it emits, is measured on
the game hosts rather than in SQL:

```bash
md5sum ~/dod-<port>/serverfiles/dod/addons/ktpamx/plugins/stats_logging.amxx

# Old build emits headshot_kill and never frag_context; new build the reverse.
# __nonsense__ is a negative control and must return 0. A low `triggered` count
# means the instance was idle, NOT that it emits nothing -- do not read an idle
# instance's zeros as evidence either way.
for m in headshot_kill frag_context cap_break break_context triggered __nonsense__; do
  printf '%s: ' "$m"
  grep -h "$m" $(ls -t ~/dod-<port>/serverfiles/dod/logs/L$(date +%m%d)*.log) 2>/dev/null | wc -l
done
```
