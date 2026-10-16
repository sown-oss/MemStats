# MemStats Feature Plan: Popover Section Layout

Let users choose which popover sections are shown and in which order, from Settings.

## Product decisions

| Item | Decision |
| --- | --- |
| Sections | Top Users, History, Top Apps, Top Processes |
| Default | All shown, in that order |
| Location | Settings > Popover sections |
| Controls | One toggle per section, its style picker, Move Up / Move Down buttons, Reset to Default |
| Empty popover | Not allowed: the last shown section cannot be turned off |
| Sampling | Hidden sections still sample, so the menu bar, history and hints keep working |

Rules:

- Order and hidden sections persist in `UserDefaults`. Unknown or duplicate values are dropped,
  and sections missing from a stored order are appended in default order.
- Refresh Now is an icon button in the popover header, next to the gear, so hiding sections never
  hides it.
- When Top Processes is hidden, the sampling error moves below the last section.
- Hiding Top Users clears its user filter, since that section is the only place to clear it.
- Buttons, not drag and drop: `Form` rows on macOS do not support `onMove` reliably, and buttons
  work with VoiceOver and the keyboard.

## Task checklist

- [x] Task 1 - `PopoverSection` model and `SettingsStore` persistence
- [x] Task 2 - Popover renders sections from the stored layout
- [x] Task 3 - Settings controls (toggle, move, reset)
- [x] Task 4 - Localization (de, es, fr, ja, ko, vi, zh-Hans)
- [x] Task 5 - Unit tests
- [x] Task 6 - Build, tests and swift-format lint
- [x] Task 7 - CHANGELOG and README
- [x] Task 8 - Code review
- [x] Task 9 - Move Refresh Now to the header, next to the gear
- [x] Task 10 - Merge the chart style pickers into the section rows

Suggested commits:

- `feat(popover): let users show, hide and reorder sections`
- `feat(popover): move Refresh Now to the header`
- `feat(settings): merge chart style pickers into popover section rows`
