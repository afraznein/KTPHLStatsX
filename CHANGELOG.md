# KTP HLStatsX Changelog

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
