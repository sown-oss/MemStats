# Changelog

All notable changes to MemStats are documented here.

## [Unreleased]

### Added

- Optional GitHub-style heatmap for the History section. Switch with the button in the History header or the new History chart style setting; the line chart stays the default.
- Optional treemap for Top Apps and Top Processes, switched separately by the button in each header or by the Top apps style and Top processes style settings. Tile size is memory, color is the change since the previous sample, and tiles show the name, MEM, PID and, with several users, the user. The list stays the default.

### Changed

- Moved the repository to `sown-oss/MemStats`. Check for Updates, Report a Bug and Support now open the new location. Old `chungxon/MemStats` links still redirect.

## [1.0.0] - 06/10/2026

Prepared initial public release of the macOS menu bar memory monitor.

### Added

- RAM usage by user with a donut chart, including free and unattributed memory.
- Memory pressure, swap usage and a bounded history chart.
- Top applications and top processes from `top`, with process growth hints.
- Configurable update intervals and row counts in Settings.
- Open at Login and optional system-user visibility.
- Check for Updates and Report a Bug links in Settings.
- English, German, Spanish, French, Japanese, Korean, Simplified Chinese and Vietnamese localization.

### Distribution

- Supports macOS 14.0 or later on Apple Silicon and Intel.
- Distributed outside the Mac App Store as an ad hoc signed, not notarized zip.
- First launch may require Open Anyway in System Settings > Privacy & Security.
