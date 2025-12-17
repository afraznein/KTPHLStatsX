# KTP HLStatsX

KTP-modified HLStatsX:CE Perl daemon for KTP Match Handler integration.

## Purpose

This fork adds KTP match tracking support to HLStatsX:CE, enabling:
- Separation of match stats vs warmup/practice stats
- Match ID tracking in event tables
- KTP match lifecycle events (KTP_MATCH_START, KTP_MATCH_END)

## Based On

- **HLStatsX Community Edition**: https://github.com/NomisCZ/hlstatsx-community-edition
- **Maintained Fork**: https://github.com/A1mDev/hlstatsx-community-edition

## Requirements

- Perl 5.x with DBI module
- MySQL database (HLStatsX schema)
- KTP Match Handler plugin (game server)
- DODX module with HLStatsX natives (game server)

## Installation

1. Replace your existing HLStatsX scripts with the files from this project
2. Run the SQL migration script to add KTP tables and columns
3. Restart the hlstats daemon

## KTP Events

The daemon recognizes these log events from KTP Match Handler:

```
KTP_MATCH_START (matchid "KTP-xxx") (map "mapname") (half "1st|2nd")
KTP_MATCH_END (matchid "KTP-xxx") (map "mapname")
```

When a match is active, all events (frags, weaponstats, etc.) will be tagged with the match ID.

## Files Modified

| File | Changes |
|------|---------|
| `scripts/hlstats.pl` | Add KTP match context tracking |
| `scripts/HLstats_EventHandlers.plib` | Add KTP event handlers |
| `sql/ktp_schema.sql` | MySQL schema for match tracking |

## Version

See [CHANGELOG.md](CHANGELOG.md) for version history.

## License

GPL v2 (same as HLStatsX:CE)
