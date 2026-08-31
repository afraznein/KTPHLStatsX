# KTPHLStatsX - Claude Code Context

> **IPs here are placeholders** — this repo is public. Real addresses resolve in
> the private root context (`KTP Git Projects/CLAUDE.md` § IP Addresses),
> which is deliberately not in any git repository.
>
> **One deliberate exception:** `README.md`'s `logaddress_add <data-server>:27500`
> carries the real address, because it is the endpoint an operator has to type to
> ship logs. It stays an IP rather than a hostname — the directive is UDP and
> HLDS hostname resolution there is not guaranteed, so substituting a name risks
> silently breaking ingest. Note the listener accepts unauthenticated log lines,
> so publishing it is a small log-injection surface; revisit if that changes.

**REQUIRED: Before modifying or deploying this service, invoke the `service-dev` skill** (`.claude/skills/service-dev/SKILL.md`). It carries the fork-discipline boundary, the match-context staleness landmine, and the deploy/verify checklist; do not edit `hlstats.pl` without it loaded.

## Overview
Modified HLStatsX:CE Perl daemon with KTP Match Handler integration. Separates warmup/practice stats from official match stats by tagging events with match IDs.

## Branches

`preprod` is the integration branch: feature and fix work is based on it and
merges into it. `main` is the release branch, advanced only by a promotion PR
whose head is `preprod`. GitHub's *default* branch is `main`, which is why a new
PR opens with the wrong base — reset it to `preprod` unless you are deliberately
promoting.

So `main` trails `preprod` by whatever has not been promoted yet, and a fix
merged only to `preprod` is not visible from `main`. Read the branch you are
about to build from, never the default.

## Deployment
Deployed to `/opt/hlstatsx/` on the data server (<DATA_SERVER_IP>).

There is no compile step and no artifact — whatever Perl you copy is the build,
so the branch you have checked out *is* the deploy. Compare builds by normalised
diff, never by byte size: this tree checks out CRLF while the deployed copy is
LF, so a change that only adds lines can leave the file measurably smaller.

### Verifying which build is live

⚠️ **The startup banner does NOT tell you.** `HLstatsX:CE <version> starting…`
reads `hlstats_Options.version` from the database — the **upstream** number
(`1.7.0`), not this fork's `VERSION` (0.3.x). It does not change when you deploy.
**Identify a build by md5 of `/opt/hlstatsx/scripts/hlstats.pl`**, never by the
banner.

Two startup lines are worth reading after a restart, because both report a
condition nothing else surfaces:

```
UDP: Socket receive buffer: <N>KB
UDP: WARNING: asked for <N>KB ... but the kernel granted <M>KB
```

🔑 **A ceiling is not a request.** `net.core.rmem_max` caps what a process *may*
ask for and grants nothing on its own. Raising it to 25MB on 2026-08-12 changed
nothing measurable, because `$want_rcvbuf` stayed at 1MB and the socket kept
getting 2MB — the raised ceiling looked like a fix for two days. The request now
matches the ceiling (`51200KB` reported, no warning). If that warning line ever
appears, `rmem_max` is the lever; if it does not, the request is.

⚠️ **A restart drops UDP for the whole fleet** — this one daemon tags every
instance's events. Check for a live match before restarting: an open
`ktp_matches` row with a NULL `end_time`, or recent `hlstats_Events_Frags`.
Players merely connected are fine; a match in progress is not.

## Service Management
```bash
sudo systemctl status hlstatsx
sudo systemctl restart hlstatsx
sudo journalctl -u hlstatsx -f
```

## Database

### 🔑 Migrations land before the daemon, never after

Schema ahead of code is inert — a column nothing writes yet costs nothing. Code
ahead of schema loses data, and loses it quietly: the daemon builds its INSERTs
as strings, so a write to a table or column that does not exist fails inside
MySQL and the event is simply gone. A deployed daemon once carried write paths
for several `ktp_*` tables whose migrations had not been applied; only
`ktp_flag_captures` lost anything, because it was the only one whose triggering
events were firing. The rest were latent, not absent — which is the trap, since
nothing distinguishes them until the events start. That silence is why
`execNonQuery` returns DBI's affected-row count and the KTP write paths report
`KTP_NO_ROW_MATCHED`: a write that matched nothing is otherwise
indistinguishable from one that worked.

The ordering extends past this repo: seed `hlstats_Actions` and reload the daemon
*before* shipping the KTPAMXX plugin that emits those actions, never after.

⚠️ **`hlstats_Events_Frags` and `hlstats_Events_PlayerActions` are MyISAM**, so
`ADD COLUMN` is a full table rebuild under a write lock — never MySQL 8's instant
add — and Frags is the biggest table in the schema. The migration files here are
written one guarded `ALTER` per column for idempotency, which means running one
verbatim rebuilds the table once per column. **Combine every column and index
change for the same table into a single `ALTER` when you apply it**, and apply it
in an idle window — the same live-match check a restart calls for.

### Reloading vs restarting

`SIGHUP` (`systemctl kill -s HUP hlstatsx`) flushes and re-reads the database
config, which clears `%g_games` and therefore reloads each game's
`hlstats_Actions` cache. **Seeding actions needs only a HUP.** It does *not*
re-read `hlstats.pl` — Perl compiles the script once at startup, so a code or
`$want_rcvbuf` change needs a real restart, and so does anything that has to
re-bind the socket.

Prefer the HUP whenever it is sufficient. A restart drops in-flight UDP: log
delivery is fire-and-forget with no queue and no retry, so a restart mid-half
leaves the rest of that half with a NULL `match_id`.

### Reading the data

`half`, `match_id` and the timestamps each return a plausible wrong answer rather
than an error — the semantics are in `README.md` § Database Schema, and a query
that has not accounted for them is the usual explanation for a match that looks
empty.

⚠️ **`$g_sql_error_count` is cumulative and resets only at daemon start.** Alert
on a delta against a stored prior reading; alerting on the raw value fires
forever once anything has ever failed. It is also incremented in `HLstats.plib`,
not `hlstats.pl`, so a sweep scoped to `*.pl` reports it as never incremented.

- **Database:** `hlstatsx`
- **User:** `hlstatsx`
- **Password:** never in this repo (it is PUBLIC). The value that used to sit here
  was rotated 2026-05-31 precisely because it had been published; the live one is
  in the private root context, `N:\Nein_\KTP Git Projects\CLAUDE.md` § MySQL.

### Common Queries
```bash
# Add a game server
mysql -u root -p -e "INSERT INTO hlstatsx.hlstats_Servers (address, port, name, game, publicaddress, rcon_password) VALUES ('IP', PORT, 'Name', 'dod', 'IP:PORT', 'RCON');"

# List servers
mysql -u root -p -e "SELECT serverId, name, game, address, port FROM hlstatsx.hlstats_Servers;"

# Unhide DOD game
mysql -u root -p -e "UPDATE hlstatsx.hlstats_Games SET hidden = '0' WHERE code = 'dod';"
```

## Game Server Config
Add to `dodserver.cfg`:
```cfg
log on
sv_logbans 1
sv_logecho 1
sv_logfile 1
logaddress_add <DATA_SERVER_IP>:27500
```

## How It Works
1. Game server sends logs to HLStatsX daemon (UDP 27500)
2. Daemon parses log events and stores in MySQL
3. `KTP_MATCH_START` / `KTP_MATCH_END` events tag stats with match_id
4. Warmup stats have `match_id = NULL`, competitive stats have match ID

## Debug Logging (v0.2.2+)
KTP_MATCH event tracing is enabled in the daemon. View with:
```bash
sudo journalctl -u hlstatsx -f | grep KTP_DEBUG
```

Debug points:
- `KTP_DEBUG RAW LINE RECEIVED` - All lines containing KTP_MATCH
- `KTP_DEBUG KTP_MATCH_START parsed` - Parsed match start properties
- `KTP_DEBUG KTP_MATCH_END parsed` - Parsed match end properties
- `KTP_DEBUG doEvent_KTPMatchStart CALLED` - Function entry with args
- `KTP_DEBUG doEvent_KTPMatchStart: half_num=` - Parsed half number and server_id
- `KTP_DEBUG KTP_ROUND_FREEZE: match=` - Round went to freeze; match_id tagging paused (0.3.3+)
- `KTP_DEBUG KTP_ROUND_LIVE: match=` - Round went live; match_id tagging resumed (0.3.3+)
- `KTP_DEBUG doEvent_KTPHalfEnd: Clearing match context for inter-half gap` (0.3.3+)

## File Locations
- **Daemon:** `/opt/hlstatsx/scripts/hlstats.pl` (authoritative KTP handlers)
- **Handlers:** `/opt/hlstatsx/scripts/HLstats_EventHandlers.plib` (base handlers **plus KTP delta**: `ktpTrackMatchPlayer` calls in `doEvent_Frag`, per-half lookups — do not overwrite from upstream)
- **Config:** `/opt/hlstatsx/scripts/hlstats.conf`

## SSH Access

For data server management, use Python/Paramiko:

**Server Credentials:**
| Server | Host | User | Password |
|--------|------|------|----------|
| Data Server | <DATA_SERVER_IP> | root | (SSH key auth) |

See `N:\Nein_\KTP Git Projects\CLAUDE.md` for paramiko SSH documentation.
See `N:\Nein_\KTP Git Projects\KTPAmxxCurl\scripts\check_hlstatsx.py` for working example.

## Related
- KTPMatchHandler generates `KTP_MATCH_START` / `KTP_MATCH_END` events
- DODX module calls `dodx_set_match_id()` to log match context

# Data traps — measured, keep them

*Relocated from session memory 2026-08-26 so they load with this repo rather than only in one
assistant's recall. Each was measured; the date it was measured is stated inline.*

## "hlstatsx ran six migrations behind its own daemon and silently dropped every flag capture fleet-wide; schema ahead of code is harmless, code ahead of schema is data loss"

**2026-08-15: hlstatsx had been deployed six migrations ahead of its schema and was losing every DoD flag
capture, fleet-wide, for ~19 hours.** `hlstats.pl:4407` ran `INSERT INTO ktp_flag_captures` against a table
that did not exist. 301 of 302 SQL errors were that one shape. The daemon is a UDP listener with no replay,
so those captures are unrecoverable — and flag captures are a distinct number from frags that crowns a
different club in several matches.

Production sat at migrations 002/003/004 while the running daemon expected 005–011.

**Why the asymmetry matters:** the AC API refuses to start on a pending migration (`SchemaSelfCheck`), so
code-ahead-of-schema fails *loudly* there. hlstatsx has no such gate — it just logs and drops. **Extra
tables are invisible to a running binary; missing tables are silent data loss.** Apply schema first,
always.

**How to apply:**
- Before trusting any hlstatsx feature, check applied-vs-expected migrations — the repo is `KTPHLStatsX`,
  and it builds from **`preprod`**, never `main` (`origin/main` was six migrations behind).
- ⛔ **`CREATE TABLE IF NOT EXISTS` makes a "fix by re-running the migration" a silent no-op** over a
  hand-made table with the wrong schema. Drop or `ALTER` to converge, then verify columns *and* indexes
  against the migration file.
- The base tables are **MyISAM**, so `ADD COLUMN` is a full table rebuild under a write lock, never MySQL
  8's instant add. `hlstats_Events_Frags` is ~1.29M rows / ~209MB. Batch all columns into **one** ALTER
  (the migrations issue them separately — nine rebuilds instead of one) and run it against an idle fleet.
- `eventTime` is **not indexed**; `match_id` and `id` are. Window by `id` or a date-bounded query times out.
- `EMPTY` is reserved in MySQL 8 — `AS empty` fails with a 1064 that looks like a broken predicate.

Related: `cumulative-counter-under-windowed-headline`, `hlstatsx-udp-rcvbuf-too-small`,
`abandoned-pending-empty-matchid-hlstats-corruption`

## "hlstats_Events_PlayerActions has no `half` column; WHERE pa.half=N errors to stderr and returns empty, reading as \"this match has no captures\""

`hlstats_Events_PlayerActions` has **no `half` column**. A query with `WHERE pa.half = 1` fails with
MySQL **1054 `Unknown column`** on **stderr** and returns an empty set — which reads exactly like
*"this match recorded no captures"*.

⚠️ **Half attribution is not exclusive to `hlstats_Events_Frags`** — measured against the live schema
2026-08-27. `hlstats_Events_PlayerActions` carries **`producer_half`** (`tinyint unsigned`, nullable),
written only for rows ingested since the schema-22 producer telemetry landed; older rows are NULL. So
it is a real column but not yet a usable half key — re-derive its coverage
(`SELECT producer_half, COUNT(*) FROM hlstats_Events_PlayerActions GROUP BY producer_half`) before
relying on it, and join to `hlstats_Events_Frags` on `match_id` for anything historical.

**Why:** same shape as `wrong-game-event-name-reads-as-no-emission` and the `hlstats_Events_Deaths`
trap (that table does not exist at all; frags ARE the death record). A nonexistent column and a
genuinely empty result are indistinguishable at the call site unless stderr is read.

**How to apply:** carry a positive control on every hlstatsx query — reproduce a known-good figure
before believing a new one. Known-good: `hlstats_Servers` = 25 rows, and match `1773018654-ATL4`
has 234 frags in h1 / 250 in h2. Never suppress stderr on a mysql call.

Related: hlstatsx stores timestamps in **America/New_York**, not UTC (`timedatectl` on the data
server reports EDT; MySQL `time_zone = SYSTEM`) — so anything loaded must carry ET, and an apparent
skew is your own session's `time_zone`, per `ac-timestamps-are-et-not-utc`.

## Dropped log packets produce rows that look like a real finding — hlstatsx role/map data before 2026-08-14 is forensically unusable

Investigating how a restricted German MG was fired, the smoking gun looked perfect: five `mg42` frags
whose `killerRole` read **`#class_allied_sniper`** — an *Allied* class credited with an *Axis* weapon.
That reads as a class-limit bypass.

**It was packet loss.** On that server that day `hlstats_Events_ChangeRole` has **0** rows while
`hlstats_Events_Frags` logged **1,134**, and **653 of those 1,134** carry a corrupted `map` field.
Cause is `hlstatsx-udp-rcvbuf-too-small` — postmortem in `KTP Git Projects/ENGINE_BUG_POSTMORTEMS.md`
at the private project root, **not in this repo**, so a clone will not have it. A 1 MB UDP receive buffer
that silently dropped log lines under any daemon stall. **Fixed 2026-08-14.**

🔑 **So any forensic conclusion drawn from `killerRole` / `ChangeRole` before 2026-08-14 is unsafe** —
the stale value simply persists on the row, and a *wrong* value is indistinguishable from a *missing*
one. The corruption is partial, so most rows look fine.

**Why this generalises:** a dropped write does not leave a gap you can see. It leaves whatever was
there before, which reads as data. That is worse than a null, because a null prompts a question and a
stale value answers one — wrongly.

**How to apply:** before treating an anomalous row as a finding, check whether the *pipeline* was
healthy in that window. Cheap tests: does a sibling table have rows for the same server/day? Is a
field that should always be well-formed (a map name, an enum) well-formed across that window? Compare
against a day you know was healthy.

⚠️ Two independent signals agreed here and both were symptoms, not evidence — the role mismatch and
the absent `Statsme` row for the same burst. **Corroboration between two outputs of the same broken
pipe is not corroboration.** Related: `a-killed-probe-reads-as-a-clean-zero`,
`durable-record-outranks-banner-and-log`.


## A death-rate query that skips `hlstats_Events_Teamkills` returns a uniformly-low number that reads as a baseline difference, not a bug

*(Moved 2026-08-30 from the KTP board's `TODO.md`, which was a second, drifting copy of schema
knowledge that belongs here instead.)*

**A player's true death count is `hlstats_Events_Frags` (killed by an opponent) UNION
`hlstats_Events_Teamkills` (killed by a teammate), both keyed on `victimId`.** Querying deaths from
`hlstats_Events_Frags` alone omits every teamkill death. Verified against production 2026-08-30:
`hlstats_Events_Teamkills` is roughly **2%** the size of `hlstats_Events_Frags`, so the omission
skews every derived death rate (and therefore K/D) low by roughly that same margin, **uniformly
across players** — because every player takes teamkill deaths at roughly the same background rate.

**Why it is dangerous:** a uniform skew does not fail a sanity check. It looks like a plausible
baseline difference between two datasets rather than a missing UNION, so it survives review that
only checks for outliers.

**How to apply:** any query computing deaths, K/D, or a per-player death rate must union both
tables on `victimId`. A K/D or death-rate figure computed against `hlstats_Events_Frags` alone is
wrong, not approximately right.

Related: `ktp_match_stats.half = 0` is the correct match-total row on that table (see the callout in
`README.md` § Database Schema) — the two traps were found on the same afternoon rebuilding an
external leaderboard tool, but they are independent: one is a wrong filter, this one is a missing
UNION.

## DoD log event names — a wrong-game grep reads as "the engine emits nothing"

*(Relocated 2026-08-29 from the operator's memory set — this repo is where the trap fires.)*

A finding claimed **"objective events are not logged fleet-wide"** and stood for weeks. It was false.
Production `hlstatsx` held **543,163** `Events_PlayerActions` and **1,645,086** `Events_TeamBonuses`
rows; in one week `dod_capture_area` (28,311) and `dod_control_point` (21,844) fired on 9 distinct
`serverId`s.

**The probe grepped the wrong game's event names.** `Captured` and `Round_Win` are Counter-Strike/TFC
strings. DoD writes:

```
"Player<66><STEAM_0:1:24850><Allies>" triggered a "dod_control_point" - "the cliffs"
Team "Allies" triggered a "dod_capture_area" - "the alley"
```

Note the **`a`** — so even a generic `triggered "[^"]+"` census misses it.

**Why it matters:** the finding would have sent someone to make DoD emit events it had been emitting
all along. A grep for a string the engine never writes returns 0 and looks exactly like an engine that
produces nothing.

**How to apply:** when a census says a game engine emits nothing, confirm the *exact literal* against a
raw log file before believing it. Also: `mp_logdetail` being unset is TRUE but governs
**weapon-damage** detail, not objectives — two true facts sitting next to each other were read as a
causal chain.

## Stat columns lie about absence two different ways — `NOT NULL DEFAULT 0` vs a reserved sentinel

*(Moved 2026-08-30 from the KTP board's `TODO.md`. The full derivation — the nullability table and the
Class 1/2/3 rollout rationale — already lives in `docs/STAT_SET_RATIONALE.md`; this entry is a pointer,
not a restatement.)*

`hlstats_Events_Frags.k_prone`, `k_scope` and `is_last_flag_defense` are `NOT NULL DEFAULT 0`, so a row
nothing ever measured reads identically to a row that was checked and came back false — a query for
"kills while prone" against untouched data returns a clean zero and looks like a result.
`k_clip`/`k_ammo` dodge that trap with a reserved `-1` sentinel (a real empty magazine reads `clip=0`
through the same native, so `-1` unambiguously means "could not read"), and `pos_x`/`pos_victim_x` are
nullable. Both of those are honest: absence reads as absence, never as a measured zero. Do not group the
sentinel/nullable columns with the `DEFAULT 0` ones — only the latter are ambiguous.

Related: the teamkills-union trap above and `ktp_match_stats.half = 0` in `README.md` are the same
"a default reads as a real measurement" shape, on different tables.

## Spine rows support per-half rates, never per-half splits — there is no `half` column to split on

*(Moved 2026-08-30 from the KTP board's `TODO.md`.)* Verified against `information_schema` 2026-08-30:
`hlstats_Events_PlayerPlayerActions` (assists) and `hlstats_Events_PlayerActions` (cap-breaks,
objectives — see the entry above on its missing `half`) both carry `match_id` but no `half` column.
`ktp_assist_events` has the `half` column a per-half split would actually need, and **zero rows** —
schema-ahead, no writer yet.

**So a match-sum ÷ number-of-halves RATE is safe to compute from these tables; a per-half SPLIT is not
achievable from them at all.** A consumer that accepts a `by="half"` parameter against spine data must
**raise**, not silently return the per-match total relabeled as one half — a relabeled total reads
exactly like a real per-half number and is not one.

**How to apply:** before building a per-half breakdown on top of `PlayerPlayerActions` or
`PlayerActions`, check whether the split is actually stored anywhere (`ktp_assist_events`,
`PlayerActions.producer_half`) rather than assuming `WHERE half = N` will work.

## `ktpDamageExpr`'s `COALESCE(dmg.damage, 0)` is the fix, not the bug

*(Moved 2026-08-30 from the KTP board's `TODO.md`.)* `scripts/hlstats.pl`'s `ktpDamageExpr` is one line:

```perl
sub ktpDamageExpr
{
	my ($ledger_has_rows) = @_;
	return $ledger_has_rows ? 'COALESCE(dmg.damage, 0)' : 'NULL';
}
```

It returns `NULL` — not `0` — when the per-hit damage ledger has no rows for the match, so "damage not
captured for this era" and "captured, and it measured zero" stay distinguishable downstream. ⛔ A
string grep for `COALESCE(dmg.damage, 0)` cannot tell this fix from the bug it replaced — read the
whole sub, including the branch that returns `NULL`.

**The probe for whether this is working is `SUM(damage IS NULL)`, never `SUM(damage > 0)`.** The `> 0`
form cannot distinguish "the expression correctly returned NULL for an uncaptured match" from "the
expression is broken and returning 0 for everything" — both read as zero rows with `damage > 0`. Count
the `NULL`s instead.

## The Perl footgun behind the `k_prone`/`k_clip` false-zero risk — already fixed, still worth knowing

*(Moved 2026-08-30 from the KTP board's `TODO.md`.)* `hlstats.pl` has `use strict` but no
`use warnings`, and its `//` (defined-or) defaulting reads an **empty string** the same as a present
value. `getProperties` used to store `""` for an empty quoted property, which numifies to `0` on the
next `//`-defaulted read — `k_prone ""` read as "standing", `k_clip ""` as "empty magazine" instead of
the `-1` read-failed sentinel.

**This is already fixed, and the fix documents itself.** `getProperties`'s parsing loop drops an empty
quoted value instead of storing it (the `if ($2 eq "")` branch), with an inline comment naming this
exact failure mode. Nothing to change here; keep the comment if this code ever moves. The general shape
— defined-or plus no `use warnings` — is still live everywhere else in the file, so a *new*
frag-context-style field added without the same "empty means absent" handling would reintroduce this
class of bug.

## The headshot marker's `ORDER BY id ASC` is FIFO and must stay — the producer's own header says the opposite, and is wrong

*(Moved 2026-08-30 from the KTP board's `TODO.md`.)* `hlstats.pl`'s `headshot_kill` branch and its
`frag_context` branch both claim the **oldest** unclaimed frag (`ORDER BY id ASC LIMIT 1`), not the
newest. That is deliberate: the emitting plugin buffers the marker and flushes it from a repeating task
— `client_death` runs inside `SV_RunCmd` postthink, where synchronous log I/O would stall the frame —
while the engine's own kill log line is not buffered. The marker therefore arrives systematically
**late**, so "newest unclaimed frag" is routinely a *later*, unrelated kill; the oldest unclaimed one is
the better match. `scripts/selftest-frag-context.pl` pins this with the reason in the assertion name
(`'headshot_kill stays FIFO -- its emitter buffers the marker, so the newest unclaimed frag is
routinely a later kill'`) so a future reader does not "fix" it back to `DESC`.

⚠️ **KTPAMXX's own header comment is wrong about this.** `plugins/dod/ktp_stats_capture.inc`'s header
describes the shared headshot_kill/frag_context technique as "the daemon flushes and UPDATEs the
just-inserted Frags row … `ORDER BY id DESC LIMIT 1`" — the daemon does no such thing for either
marker; both use `ASC`. Confirmed against `KTPAMXX` `origin/main` 2026-08-30. Do not use that comment
as a spec when changing either side; fix the comment instead if you're in there.

## Migration 019 self-disables on purpose — never remove the guard to "make it run"

*(Moved 2026-08-30 from the KTP board's `TODO.md`.)* `sql/migrate_019_clear_uncertified_frag_context.sql`
clears `frag_context_recorded` on rows whose context columns are all still at their defaults, on the
inference that a flag set with no real context is a false claim. That inference stopped being sound
once migration 020 (`frag_context_certified`) shipped: from daemon 0.3.12 the daemon can legitimately
write "flag set, every context column at default" for a **certified** kill (standing killer, standing
victim, neither scoped, all four ammo reads failed, no last-flag defense, position unreadable) — those
are real measurements, not absence. Re-running 019 after 020 is applied would withdraw those live
claims.

The file guards itself: it checks `information_schema.COLUMNS` for `frag_context_certified` and
degrades to `DO 0` (no-op) once that column exists, rather than re-running its old predicate. **Do not
remove that guard** — the migration's own header explains the full reasoning; this entry exists so the
guard is not "cleaned up" by someone who has not read it first.

## Any headshot rate over the whole table is silently wrong — scope `headshot_observed = 1`

*(Moved 2026-08-30 from the KTP board's `TODO.md`.)* `hlstats_Events_Frags` carries a
`headshot_observed` column (`sql/migrate_023_headshot_observed_provenance.sql` on `main` — see the
migration-numbering note below) recording whether the frag stream actually carried headshot
information for that row, as opposed to `headshot` simply defaulting to `0` for "never checked".
Re-verified live against production 2026-08-30 (figures move slightly as the table grows; the shape
does not):

| | |
|---|---|
| total `hlstats_Events_Frags` rows | 1,439,027 |
| `headshot_observed = 0` | 730,645 (~51%) |
| headshot rate, scoped to `headshot_observed = 1` | ~14.9% |
| headshot rate, unscoped (whole table) | ~8.3% |

**Every headshot rate, leaderboard, or per-player split must scope `headshot_observed = 1`** — over
half the table has no observation at all, and folding those rows in as "not a headshot" understates the
true rate by roughly 44%.

**The cheapest regression tripwire:** an hourly `SUM(headshot = 1)` (better yet, scoped to
`headshot_observed = 1`) is the cheapest "capture emitter not loaded" check — it drops to a clean 0
while raw frag counts look completely normal, because a missing emitter does not stop kills from
happening, only from being annotated.

## `corpus-regression` / Lane B tests parsing of committed fixtures, not emission — and its gate checks fewer fields than it reports

*(Moved 2026-08-30 from the KTP board's `TODO.md`; the board's supporting figures — `'headshot': 0,
'damage': 0` — do **not** reproduce against the current fixtures and are corrected below. Verify the
mechanism, not an old quote.)*

The `corpus` lane of `KTPInfrastructure`'s `lane-b-stats-e2e.yml` (called from this repo's
`corpus-regression.yml`) replays three committed, gzipped, real match logs through `hlstats.pl` in a
disposable database — no game server, no bots, and (`build_stats_lane_artifacts.py --no-plugin`) the
**capture plugin is never built or run** for this lane. Green means "the daemon parses this fixed input
the same way it always has," not "the current plugin/daemon pair actually emits and captures these
markers."

⚠️ **And the comparison it runs is narrower than what it reports.** `scripts/replay_corpus.py`'s
`_COMPARED` tuple only diffs `emitted.{kills,assist,cap_break,suicide}` and
`rows.{frags,players,suicides,assist.ppa,cap_break.pa}` against
`tests/e2e_stats/corpus/expected.json`. The current baseline's `emitted.headshot` (47/48/45 across the
three fixtures) is computed and printed but **never compared** — a daemon regression that zeroed out
headshot marking entirely would not fail this gate. There is no `damage` field anywhere in the report,
so the per-hit damage ledger has no coverage here at all.

**How to apply:** treat a green `corpus-regression / Lane B` as evidence only for the fields actually
listed in `_COMPARED`. To make it mean more, widen `_COMPARED` (and the baseline) rather than trusting a
field just because the report happens to print it.

## Adding a Lane-B migration is six edits, not two

*(Moved 2026-08-30 from the KTP board's `TODO.md`.)* A new `sql/migrate_0NN_*.sql` file in this repo is
invisible to Lane B until three other places in `KTPInfrastructure` name it too (its own
`tests/unit/test_lane_b_schema_list_drift.py` documents this as the reason it exists):

1. `tests/e2e_stats/artifacts.py`'s `DEFAULT_SCHEMA_FILES` tuple (which files get extracted into
   `artifacts/sql/` from the daemon commit under test)
2. `.github/workflows/lane-b-stats-e2e.yml`'s **full**-lane `--schema` block
3. the same workflow's **corpus**-lane `--schema` block

...plus two test pins in `tests/e2e_stats/test_artifacts.py` that hard-code the tuple's tail and will
fail — correctly — until updated: `test_default_schema_sequence_includes_retention_through_telemetry22`'s
`DEFAULT_SCHEMA_FILES[-9:] == (...)` literal, and a hard-coded `assert len(arts.schema_sql) == 19`
elsewhere in the same file. So: the `sql/` file itself, plus those five, is six edits for one migration.
`test_lane_b_schema_list_drift.py` catches (1)-(3) drifting from each other, but it cannot see a
migration that exists in this repo and nowhere in `KTPInfrastructure` — that half of the change still
has to be done by hand, and `cap_break` has zero production rows, so the corpus lane is the *only*
place that code path is exercised at all if the list quietly trails.

## `migrate_020` is not the headshot migration — and migration numbers are not stable across branches either

*(Moved 2026-08-30 from the KTP board's `TODO.md`, and re-verified the same day because the fact moved
under it.)* `afraznein/KTPHLStatsX`#57's *branch* was named `feat/migrate-020-headshot-observed`, but
the file it actually landed is `sql/migrate_023_headshot_observed_provenance.sql`. `migrate_020` is,
and has always been, `migrate_020_frag_context_certified.sql`. A reference to "migrate_020 headshot"
points at a branch name that was never accurate, not at a file.

⚠️ **Freshly discovered while verifying this, 2026-08-30: `migrate_023` is not even a stable name
across this repo's own branches.** #57 based on and merged directly into `main` — not `preprod`, the
usual integration branch (see § Branches) — landing `migrate_023_headshot_observed_provenance.sql`
there. `preprod` already had its own, unrelated `migrate_023_team_membership_intervals.sql` (#58) at
the same time. So as of this writing, `main`'s `migrate_023` and `preprod`'s `migrate_023` are two
different migrations. Identify a migration here by its descriptive filename suffix and state which
branch, never by number alone.
