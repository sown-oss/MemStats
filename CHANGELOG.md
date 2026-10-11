# Changelog

All notable changes to MemStats are documented here.

## [1.1.0] - 11/10/2026

New chart styles and app icons. The line chart and the lists stay the defaults.

### Added

- Optional GitHub-style heatmap for the History section. Green intensity shows how much RAM was used compared with the visible samples, and warning and critical samples use orange and red. Switch with the button in the History header or the History chart style setting.
- Optional treemap for Top Apps and Top Processes, switched separately with the button in each header or the Top apps style and Top processes style settings. Tile size is memory and tile color is the change since the previous sample (red higher, green lower). Tiles show the name, MEM, PID and, when the rows come from several users, the user.
- App icons in Top Apps and Top Processes, in both the lists and the treemap. Processes use the icon of the app they belong to.
- Sample counts in the section headers, for example History (120), Top Apps (8) and Top Processes (8).
- Localization of the new options in German, Spanish, French, Japanese, Korean, Simplified Chinese and Vietnamese.

### Changed

- Removed the History Samples row. The count now shows in the History header.
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
