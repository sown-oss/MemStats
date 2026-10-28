# MemStats Feature Plan: Quit and Force Quit

Let users quit or force quit an app or a process from Top Apps and Top Processes, without
opening Activity Monitor.

## Product decisions

| Item | Decision |
| --- | --- |
| Where | Right-click a row (List) or a tile (Treemap) in Top Apps and Top Processes |
| Menu | Quit, Force Quit, Copy PID (Top Processes only) |
| Confirmation | Inline bar inside the section. Esc cancels it before closing the popup. Both Quit and Force Quit ask |
| Other users | Quit and Force Quit are disabled, and the menu shows the reason. No admin prompt, no privileged helper |
| Protected | PID 0 and 1, MemStats itself, `kernel_task`, `launchd`, `loginwindow`, `WindowServer` |
| Apps | Only the current user's processes of the app are signaled. Quit asks only the regular GUI app when there is one; otherwise, and always for Force Quit, every own process is signaled |
| Processes | Regular GUI apps use `NSRunningApplication`, agents, helpers and the rest get SIGTERM (Quit) or SIGKILL (Force Quit) |
| After | A process sample runs 0.5s later, so the list updates |

Rules:

- No `NSAlert`: the popup closes when a click lands in another window of the app, so the result
  would not be visible.
- A reused PID is never signaled: the process start time (from `sysctl`) must be older than the
  start of the sample that showed it, and must not change between the request and the confirmation.
- Ownership is checked again with the real uid at confirmation time, not only the `top` user name.
- The confirmation bar is dropped when its processes leave the snapshot or the popup closes.

## Task checklist

- [x] Task 1 - `ProcessTerminator` service (sysctl target, protected list, signal)
- [x] Task 2 - Keep app PIDs, sample time and ownership in `ProcessViewModel`
- [x] Task 3 - Quit request, confirmation and error state in `MemStatsAppState`
- [x] Task 4 - Context menus and inline confirmation bar (List and Treemap)
- [x] Task 5 - Localization (de, es, fr, ja, ko, vi, zh-Hans)
- [x] Task 6 - Unit tests
- [x] Task 7 - Build, tests and swift-format lint
- [x] Task 8 - CHANGELOG, README and DESCRIPTION
- [x] Task 9 - Code review
- [x] Task 10 - Review fixes: sample start time for the PID check, signals for agents, Force Quit
  signals the whole app, Esc cancels the confirmation first, VoiceOver actions
- [ ] Task 11 - Verify on device: right-click menu in List and Treemap, inline bar, Esc, Quit and
  Force Quit of a GUI app and a CLI process, disabled items for another user's process

Suggested commit:

- `feat(popover): quit and force quit apps and processes`
