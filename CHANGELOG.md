# KTP HLStatsX Changelog

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
