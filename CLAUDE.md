# KTPHLStatsX - Claude Code Context

> **IPs here are placeholders** — this repo is public. Real addresses resolve in
> the private root context (`KTP Git Projects/CLAUDE.md` § IP Addresses),
> which is deliberately not in any git repository.

**REQUIRED: Before modifying or deploying this service, invoke the `service-dev` skill** (`.claude/skills/service-dev/SKILL.md`). It carries the fork-discipline boundary, the match-context staleness landmine, and the deploy/verify checklist; do not edit `hlstats.pl` without it loaded.

## Overview
Modified HLStatsX:CE Perl daemon with KTP Match Handler integration. Separates warmup/practice stats from official match stats by tagging events with match IDs.

## Deployment
Deployed to `/opt/hlstatsx/` on the data server (<DATA_SERVER_IP>).

## Service Management
```bash
sudo systemctl status hlstatsx
sudo systemctl restart hlstatsx
sudo journalctl -u hlstatsx -f
```

## Database
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
log_address_add <DATA_SERVER_IP>:27500
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

## File Locations
- **Daemon:** `/opt/hlstatsx/scripts/hlstats.pl` (authoritative KTP handlers)
- **Handlers:** `/opt/hlstatsx/scripts/HLstats_EventHandlers.plib` (base handlers, NOT KTP)
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
