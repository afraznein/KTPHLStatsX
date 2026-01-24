# KTP HLStatsX

**Version 0.2.2** - Modified HLStatsX:CE Perl daemon with KTP Match Handler integration

A specialized fork of [HLStatsX:CE](https://github.com/NomisCZ/hlstatsx-community-edition) that enables match-based statistics tracking for competitive play. Separates warmup/practice stats from official match stats by tagging events with match IDs from KTP Match Handler.

Part of the [KTP Competitive Infrastructure](https://github.com/afraznein).

---

## 🎯 Purpose

Standard HLStatsX tracks **all player activity** regardless of context - warmup kills, practice rounds, and competitive matches are all mixed together. This makes it impossible to:

- Generate accurate per-match statistics
- Compare player performance across matches
- Distinguish practice stats from competitive stats
- Correlate stats with specific match IDs

**KTP HLStatsX solves this** by:

1. Listening for `KTP_MATCH_START` and `KTP_MATCH_END` log events
2. Tracking match context per server
3. Tagging all events with `match_id` when a match is active
4. Storing match metadata in dedicated tables

---

## 🏗️ Architecture Position

KTP HLStatsX is the **stats processing layer** of the KTP competitive stack:

```
┌─────────────────────────────────────────────────────────────┐
│  Layer 5: KTP HLStatsX Web (PHP) ← Future                   │
│  Match-aware leaderboards and statistics display            │
└─────────────────────────────────────────────────────────────┘
                     ↑ Reads from MySQL
┌─────────────────────────────────────────────────────────────┐
│  Layer 4: KTP HLStatsX Daemon (Perl) ← YOU ARE HERE         │
│  - Processes KTP_MATCH_START/END events                     │
│  - Tags events with match_id                                │
│  - Stores match metadata                                    │
└─────────────────────────────────────────────────────────────┘
                     ↑ Receives log events via UDP
┌─────────────────────────────────────────────────────────────┐
│  Layer 3: DODX Module (KTPAMXX)                             │
│  - Flushes stats on match end                               │
│  - Logs KTP_MATCH_START/END to server log                   │
└─────────────────────────────────────────────────────────────┘
                     ↑ Plugin natives
┌─────────────────────────────────────────────────────────────┐
│  Layer 2: KTP Match Handler (AMX Plugin)                    │
│  - Triggers match start/end                                 │
│  - Generates unique match IDs                               │
│  - Calls dodx_set_match_id(), dodx_flush_all_stats()        │
└─────────────────────────────────────────────────────────────┘
                     ↑ Uses
┌─────────────────────────────────────────────────────────────┐
│  Layer 1: KTP-ReHLDS + KTP-ReAPI                            │
│  - Engine and API layer                                     │
└─────────────────────────────────────────────────────────────┘
```

---

## ✨ Key Features

### Match Context Tracking

**Per-server match state:**
```perl
# Global hash tracking active matches per server address
%g_ktpMatchContext = ();

# When match starts, context is set:
$g_ktpMatchContext{$s_addr} = {
    match_id => "KTP-1734355200-dod_charlie",
    map => "dod_charlie",
    half => "1st",
    start_time => 1734355200
};

# All events now tagged with match_id
# When match ends, context is cleared
```

### Event Tagging

**Modified event recording:**
```perl
# Before: Events recorded without match context
INSERT INTO hlstats_Events_Frags (eventTime, serverId, map, ...)

# After: Events tagged with match_id when active
INSERT INTO hlstats_Events_Frags (eventTime, serverId, map, match_id, ...)
```

**Tables with match_id support:**
- `hlstats_Events_Frags` - Kill events
- `hlstats_Events_Teamkills` - Team kill events
- `hlstats_Events_Suicides` - Suicide events
- `hlstats_Events_PlayerActions` - Player action events

### Stats Separation

| Context | match_id Value | Example |
|---------|---------------|---------|
| Warmup / Practice | `NULL` | Pre-match kills not tracked |
| Competitive Match | `KTP-xxx-mapname` | All events tagged |
| Between Matches | `NULL` | Post-match activity not tracked |

### Match Metadata Storage

**Dedicated tables for match tracking:**
- `ktp_matches` - Match boundaries (start/end times, map, half)
- `ktp_match_players` - Players participating in each match
- `ktp_match_stats` - Aggregated stats per player per match

---

## 🔬 Technical Implementation

### KTP Event Handlers

**Event Type 600: KTP_MATCH_START**
```perl
sub doEvent_KTPMatchStart {
    my ($matchId, $mapName, $half) = @_;

    # Set match context for this server
    $g_ktpMatchContext{$s_addr} = {
        match_id => $matchId,
        map => $mapName,
        half => $half,
        start_time => time()
    };

    # Insert match record into database
    INSERT INTO ktp_matches (match_id, server_id, map_name, half, start_time)
    VALUES ('$matchId', $serverId, '$mapName', $halfNum, NOW())
    ON DUPLICATE KEY UPDATE start_time = NOW()
}
```

**Event Type 601: KTP_MATCH_END**
```perl
sub doEvent_KTPMatchEnd {
    my ($matchId, $mapName) = @_;

    # Update match end time
    UPDATE ktp_matches SET end_time = NOW()
    WHERE match_id = '$matchId'

    # Clear match context for this server
    delete $g_ktpMatchContext{$s_addr};
}
```

### Modified Event Recording

**In `hlstats.pl`, the `recordEvent` function now includes match_id:**
```perl
sub recordEvent {
    my $table = shift;
    my @coldata = @_;

    # KTP: Get match_id from context if active for this server
    my $ktp_match_id = "";
    if (defined($g_ktpMatchContext{$s_addr}) &&
        $g_ktpMatchContext{$s_addr}{match_id} ne "") {
        $ktp_match_id = $g_ktpMatchContext{$s_addr}{match_id};
    }

    # Include match_id in INSERT statement
    my $value = "(FROM_UNIXTIME($::ev_unixtime), $serverId, '$map', '$ktp_match_id', ...)";
}
```

### Log Event Format

**From KTP Match Handler (via DODX module):**
```
L 12/17/2025 - 14:30:00: KTP_MATCH_START (matchid "KTP-1734355200-dod_charlie") (map "dod_charlie") (half "1st")
L 12/17/2025 - 15:05:00: KTP_MATCH_END (matchid "KTP-1734355200-dod_charlie") (map "dod_charlie")
```

**Parsed properties:**
- `matchid` - Unique match identifier (format: `KTP-{timestamp}-{mapname}`)
- `map` - Current map name
- `half` - "1st" or "2nd" half indicator

---

## 📊 Database Schema

### Schema Migration (`sql/ktp_schema.sql`)

**Add match_id to existing event tables:**
```sql
-- Add match_id column to event tables
ALTER TABLE hlstats_Events_Frags
ADD COLUMN IF NOT EXISTS match_id VARCHAR(64) DEFAULT NULL AFTER map;

CREATE INDEX IF NOT EXISTS idx_match_id ON hlstats_Events_Frags (match_id);

-- Same for: hlstats_Events_Teamkills, hlstats_Events_Suicides, hlstats_Events_PlayerActions
```

**Create KTP match tables:**
```sql
-- Match metadata
CREATE TABLE IF NOT EXISTS ktp_matches (
    id INT AUTO_INCREMENT,
    match_id VARCHAR(64) NOT NULL,
    server_id INT NOT NULL,
    map_name VARCHAR(32) NOT NULL,
    half TINYINT DEFAULT 1,           -- 1=first half, 2=second half
    start_time DATETIME NOT NULL,
    end_time DATETIME DEFAULT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,

    PRIMARY KEY (id),
    UNIQUE KEY uk_match_id_half (match_id, half),
    KEY idx_server (server_id),
    KEY idx_start_time (start_time)
);

-- Match participants
CREATE TABLE IF NOT EXISTS ktp_match_players (
    id INT AUTO_INCREMENT,
    match_id VARCHAR(64) NOT NULL,
    player_id INT NOT NULL,
    steam_id VARCHAR(32) NOT NULL,
    player_name VARCHAR(64) NOT NULL,
    team TINYINT NOT NULL,            -- 1=Allies, 2=Axis
    joined_at DATETIME NOT NULL,

    PRIMARY KEY (id),
    KEY idx_match (match_id),
    KEY idx_player (player_id)
);

-- Aggregated match stats
CREATE TABLE IF NOT EXISTS ktp_match_stats (
    id INT AUTO_INCREMENT,
    match_id VARCHAR(64) NOT NULL,
    player_id INT NOT NULL,
    kills INT DEFAULT 0,
    deaths INT DEFAULT 0,
    headshots INT DEFAULT 0,
    team_kills INT DEFAULT 0,
    suicides INT DEFAULT 0,
    damage INT DEFAULT 0,
    score INT DEFAULT 0,

    PRIMARY KEY (id),
    UNIQUE KEY uk_match_player (match_id, player_id)
);
```

### SQL Views

**Match leaderboard with K/D ratio:**
```sql
CREATE OR REPLACE VIEW ktp_match_leaderboard AS
SELECT
    m.match_id,
    m.map_name,
    m.start_time,
    p.lastName AS player_name,
    mp.steam_id,
    mp.team,
    COALESCE(ms.kills, 0) AS kills,
    COALESCE(ms.deaths, 0) AS deaths,
    CASE WHEN COALESCE(ms.deaths, 0) > 0
         THEN ROUND(COALESCE(ms.kills, 0) / ms.deaths, 2)
         ELSE COALESCE(ms.kills, 0) END AS kd_ratio
FROM ktp_matches m
JOIN ktp_match_players mp ON m.match_id = mp.match_id
JOIN hlstats_Players p ON mp.player_id = p.playerId
LEFT JOIN ktp_match_stats ms ON m.match_id = ms.match_id AND mp.player_id = ms.player_id
ORDER BY m.start_time DESC, ms.kills DESC;
```

**Recent matches summary:**
```sql
CREATE OR REPLACE VIEW ktp_recent_matches AS
SELECT
    m.match_id,
    m.map_name,
    m.start_time,
    m.end_time,
    TIMEDIFF(m.end_time, m.start_time) AS duration,
    (SELECT COUNT(*) FROM ktp_match_players WHERE match_id = m.match_id) AS player_count,
    (SELECT SUM(kills) FROM ktp_match_stats WHERE match_id = m.match_id) AS total_kills,
    s.name AS server_name
FROM ktp_matches m
JOIN hlstats_Servers s ON m.server_id = s.serverId
WHERE m.half = 1
ORDER BY m.start_time DESC
LIMIT 50;
```

---

## 🚀 Installation

### Prerequisites

**Required:**
- Perl 5.x with DBI module
- MySQL 5.7+ or MariaDB 10.2+
- Existing HLStatsX:CE installation
- KTP Match Handler plugin (game server)
- DODX module with HLStatsX natives (KTPAMXX)

### Step-by-Step Installation

**1. Backup existing installation:**
```bash
# Backup scripts
cp -r /path/to/hlstats/scripts /path/to/hlstats/scripts.backup

# Backup database
mysqldump -u hlstats -p hlstats > hlstats_backup.sql
```

**2. Clone KTP HLStatsX:**
```bash
git clone https://github.com/afraznein/KTPHLStatsX.git
cd KTPHLStatsX
```

**3. Replace daemon scripts:**
```bash
# Copy modified scripts
cp scripts/hlstats.pl /path/to/hlstats/scripts/
cp scripts/HLstats_EventHandlers.plib /path/to/hlstats/scripts/
cp scripts/HLstats.plib /path/to/hlstats/scripts/
```

**4. Run schema migration:**
```bash
mysql -u hlstats -p hlstats < sql/ktp_schema.sql
```

**5. Restart HLStatsX daemon:**
```bash
# Stop existing daemon
pkill -f hlstats.pl

# Start daemon
cd /path/to/hlstats/scripts
perl hlstats.pl
```

**6. Verify installation:**
```bash
# Check daemon logs for KTP handler registration
tail -f /path/to/hlstats/logs/hlstats.log

# Should see:
# [HLSTATSX] HLstatsX:CE is now running (Normal mode, debug level 1)
```

---

## 🔧 Configuration

### Game Server Setup

**1. Install KTP Match Handler:**
- See [KTPMatchHandler](https://github.com/afraznein/KTPMatchHandler) for installation

**2. Verify DODX module has HLStatsX natives:**
- Requires KTPAMXX with HLStatsX integration (v2.5.0+)
- Natives: `dodx_flush_all_stats()`, `dodx_reset_all_stats()`, `dodx_set_match_id()`

**3. HLStatsX logging must be enabled:**
```
// server.cfg
logaddress_add <hlstatsx_ip>:<port>
log on
```

### Database Connection

No changes required - uses existing HLStatsX database configuration in `hlstats.conf`.

---

## 📋 Sample Queries

**Count match vs non-match kills:**
```sql
SELECT
    CASE WHEN match_id IS NULL THEN 'Warmup/Practice' ELSE 'Match' END AS type,
    COUNT(*) AS kill_count
FROM hlstats_Events_Frags
WHERE eventTime > DATE_SUB(NOW(), INTERVAL 7 DAY)
GROUP BY (match_id IS NULL);
```

**Get specific match stats:**
```sql
SELECT
    p.lastName AS player,
    COUNT(*) AS kills,
    SUM(headshot) AS headshots
FROM hlstats_Events_Frags f
JOIN hlstats_Players p ON f.killerId = p.playerId
WHERE f.match_id = 'KTP-1734355200-dod_charlie'
GROUP BY f.killerId
ORDER BY kills DESC;
```

**Recent matches with duration:**
```sql
SELECT
    match_id,
    map_name,
    start_time,
    end_time,
    TIMEDIFF(end_time, start_time) AS duration
FROM ktp_matches
WHERE half = 1
ORDER BY start_time DESC
LIMIT 10;
```

---

## 📁 Files Modified

| File | Purpose | Changes |
|------|---------|---------|
| `scripts/hlstats.pl` | Main daemon | Added `%g_ktpMatchContext` hash, match_id in event recording, KTP event parsing |
| `scripts/HLstats_EventHandlers.plib` | Event handlers | Added `doEvent_KTPMatchStart()`, `doEvent_KTPMatchEnd()` functions |
| `sql/ktp_schema.sql` | Database schema | Added match_id columns, ktp_* tables, views |

---

## 🔗 Related KTP Projects

### **KTP Competitive Infrastructure Stack:**

**🔧 Engine Layer:**
- **[KTP-ReHLDS](https://github.com/afraznein/KTP-ReHLDS)** - Custom ReHLDS fork with pause system

**🔌 Module Layer:**
- **[KTP-ReAPI](https://github.com/afraznein/KTP-ReAPI)** - ReAPI fork with KTP hooks
- **[KTPAMXX](https://github.com/afraznein/KTPAMXX)** - AMX Mod X fork with DODX HLStatsX natives

**🎮 Plugin Layer:**
- **[KTP Match Handler](https://github.com/afraznein/KTPMatchHandler)** - Match management (generates KTP events)
- **[KTP Cvar Checker](https://github.com/afraznein/KTPCvarChecker)** - Anti-cheat cvar enforcement

**📊 Stats Layer:**
- **[KTP HLStatsX](https://github.com/afraznein/KTPHLStatsX)** - This project

### **Upstream Projects:**
- **[HLStatsX:CE](https://github.com/NomisCZ/hlstatsx-community-edition)** - Original HLStatsX Community Edition
- **[A1mDev Fork](https://github.com/A1mDev/hlstatsx-community-edition)** - Actively maintained fork

---

## 📋 Version History

### [0.2.2] - 2026-01-23

**Added:**
- Debug logging for KTP_MATCH event tracing (`KTP_DEBUG` messages in journal)

**Changed:**
- Removed dead code from `HLstats_EventHandlers.plib` (duplicate event handlers were overwritten by `hlstats.pl`)

**Fixed:**
- Half detection now supports all formats: "1st", "2nd", OT halves (regex-based matching)

### [0.2.1] - 2026-01-22

**Fixed:**
- Half number detection now uses regex (`/^2/`) instead of exact string match (`eq "2nd"`) to handle different half format variations

### [0.2.0] - 2026-01-16

**Added:**
- Track participating players in `ktp_match_players` table on each frag event
- Aggregate player stats to `ktp_match_stats` table on match end
- Auto-populate `ktp_matches` table on match start
- Parse `KTP_MATCH_START`/`KTP_MATCH_END` events from plugin log lines

**Changed:**
- Use NULL instead of empty string for `match_id` when no match is active
- Enhanced match context tracking per server

### [0.1.0] - 2025-12-17

**Added:**
- Initial fork from HLStatsX:CE (NomisCZ/hlstatsx-community-edition)
- KTP match context tracking (`%g_ktpMatchContext` hash)
- `KTP_MATCH_START` event handler (event type 600)
- `KTP_MATCH_END` event handler (event type 601)
- `match_id` column support in event recording
- SQL schema for `ktp_matches`, `ktp_match_players`, `ktp_match_stats` tables
- SQL views: `ktp_match_leaderboard`, `ktp_recent_matches`

**Changed:**
- Modified event recording to include `match_id` when context is active
- Added indexes on `match_id` columns for query performance

### [0.0.0] - 2025-12-17

**Base:**
- Original HLStatsX:CE files from upstream

---

## 🙏 Acknowledgments

**KTP Fork:**
- **Nein_** ([@afraznein](https://github.com/afraznein)) - KTP HLStatsX fork maintainer

**Upstream HLStatsX:CE:**
- **NomisCZ** - HLStatsX Community Edition maintainer
- **A1mDev** - Active fork maintainer
- **HLStatsX Team** - Original HLStatsX development
- **Valve Software** - Half-Life log format

---

## 📝 License

**GPL v2** - Same as upstream HLStatsX:CE

This fork maintains GPL v2 licensing from the upstream project.

See [LICENSE](LICENSE) file for full text.

---

## 🤝 Contributing

### For KTP-Specific Features

**KTP contributions welcome:**
- Match aggregation improvements
- Web panel integration
- Additional match metadata tracking
- Performance optimizations

**Submit issues/PRs at:**
- https://github.com/afraznein/KTPHLStatsX/issues

### For General HLStatsX Features

For **general HLStatsX improvements** (not KTP-specific):
- **[HLStatsX:CE](https://github.com/NomisCZ/hlstatsx-community-edition)**
- **[A1mDev Fork](https://github.com/A1mDev/hlstatsx-community-edition)**

---

## 💬 Support

**For KTP HLStatsX help:**
- Open an issue: https://github.com/afraznein/KTPHLStatsX/issues
- Check KTP Match Handler docs: https://github.com/afraznein/KTPMatchHandler

**For general HLStatsX questions:**
- Upstream: https://github.com/NomisCZ/hlstatsx-community-edition

---

## 🐛 Troubleshooting

### Events Not Tagged with match_id

**Problem:** Kill events don't have match_id even during active match

**Solutions:**
- ✅ Verify KTP Match Handler is installed and running
- ✅ Check DODX module has HLStatsX natives (`dodx_set_match_id`)
- ✅ Verify log forwarding: `logaddress_add <hlstatsx_ip>:<port>`
- ✅ Check daemon logs for `KTP_MATCH_START` events
- ✅ Restart HLStatsX daemon after script updates

### Schema Migration Errors

**Problem:** SQL errors when running `ktp_schema.sql`

**Solutions:**
- ✅ Verify MySQL 5.7+ or MariaDB 10.2+ (required for `IF NOT EXISTS`)
- ✅ Check database user has ALTER, CREATE, INDEX permissions
- ✅ Run each ALTER statement individually if bulk fails

### Match Context Not Clearing

**Problem:** Events still tagged with old match_id after match ends

**Solutions:**
- ✅ Verify `KTP_MATCH_END` event is being sent
- ✅ Check daemon logs for match end processing
- ✅ Verify no errors in `doEvent_KTPMatchEnd()` execution

---

**KTP HLStatsX** - Bringing match-based statistics to competitive Half-Life. 📊
