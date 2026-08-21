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
