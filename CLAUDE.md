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

