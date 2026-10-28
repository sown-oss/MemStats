# Changelog

All notable changes to MemStats are documented here.

## [Unreleased]

### Added

- Quit and Force Quit from the popover: right-click an app in Top Apps or a process in Top Processes, in the list or the treemap, then confirm in the bar shown in that section. Only your own processes can be quit; other users' processes and protected system processes are shown with the reason instead. Top Processes also has Copy PID.

## [1.2.0] - 19/10/2026

Customizable popover sections. All sections stay shown in the original order by default.

### Added

- Popover sections in Settings: show or hide Top Users, History, Top Apps and Top Processes, and move them up or down. At least one section stays shown, and Reset to Default restores the original layout. Hiding Top Users clears its user filter, and hiding Top Processes moves the sampling error below the last section.

### Changed

- Moved Refresh Now from Top Processes to an icon button in the popover header, next to the gear, so it stays reachable without scrolling.
- Moved the History, Top apps and Top processes style pickers into the matching rows of Popover sections in Settings, so each section is set up in one place.

### Fixed

- Labels that did not follow the language chosen in Settings now do: update intervals, the Settings window title, the right-click menu, popover legends, tooltips and VoiceOver labels showed the macOS language instead.
- About, Settings and bug reports now show the real build number. Earlier releases always showed build 1.

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
