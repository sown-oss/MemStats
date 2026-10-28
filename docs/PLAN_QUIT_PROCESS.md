# MemStats Feature Plan: Quit and Force Quit

Let users quit or force quit an app or a process from Top Apps and Top Processes, without
opening Activity Monitor.

## Product decisions

| Item | Decision |
| --- | --- |
| Where | Right-click a row (List) or a tile (Treemap) in Top Apps and Top Processes |
| Menu | Quit, Force Quit, Copy PID (Top Processes only) |
| Confirmation | Quit of an app runs right away, like the Dock. Force Quit and Quit of a background process ask in a bar that replaces the row (List) or covers the treemap (Treemap). Return confirms, Esc cancels it before closing the popup |
| Other users | Quit and Force Quit are disabled, and the menu shows the reason. No admin prompt, no privileged helper |
| Protected | PID 0 and 1, MemStats itself, `kernel_task`, `launchd`, `loginwindow`, `WindowServer` |
| Apps | Only the current user's processes of the app are signaled. Quit asks only the regular GUI app when there is one, or the app of the same bundle that launched them; otherwise, and always for Force Quit, every own process is signaled |
| Processes | Regular GUI apps use `NSRunningApplication`, agents, helpers and the rest get SIGTERM (Quit) or SIGKILL (Force Quit) |
| After | The row dims with `Quitting…` until the processes exit. Still running after 10s shows an error at the row. A process sample runs 0.5s later, so the list updates |

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
- [ ] Task 11 - Verify on device: right-click menu in List and Treemap, bar at the row and over
  the treemap, Return and Esc, `Quitting…` and the 10s error (an app asking to save), Quit and
  Force Quit of a GUI app and a CLI process, disabled items for another user's process
- [x] Task 12 - Fix: Quit on an app that updated itself while running crashed its helpers
  (SIGTERM) and left the app running. Its executable was deleted, so `proc_pidpath` failed and
  the app was grouped apart from its helpers. The launch path now comes from `KERN_PROCARGS2`,
  and Quit adds the parent app of the same bundle when the group has no regular app
- [x] Task 13 - Confirmation at the row: the bar at the top of the section was easy to miss, so
  Quit looked done when it was still waiting. Quit of an app now runs right away, the bar
  replaces the row (or covers the treemap) with Return to confirm, and the row shows
  `Quitting…` until the app exits, or an error after 10s

Suggested commit:

- `feat(popover): quit and force quit apps and processes`
