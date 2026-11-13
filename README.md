# MemStats

A lightweight macOS menu bar app focused on memory monitoring for multiple users: top users donut, top apps, top processes, memory pressure, swap and a short bounded history, all in one popover.

Website: [memstats.chungxon.dev](https://memstats.chungxon.dev/)

## Demo

![MemStats menu bar app showing memory usage, history and top users](assets/output.gif)

## Requirements

* macOS 14.0 (Sonoma) or later
* Apple Silicon or Intel Mac

## Install

1. Download `MemStats-<version>.zip` from [GitHub Releases](https://github.com/sown-oss/MemStats/releases).
2. Unzip it and drag `MemStats.app` into `/Applications`.
3. Open it once as described in [First launch](#first-launch).

MemStats is distributed outside the Mac App Store, because it needs the App Sandbox turned off to run `top` and read processes of other users.

## First Launch

MemStats is signed ad hoc and not notarized yet, so macOS blocks it the first time you open it. Use one of these:

* Open the app once, then go to System Settings > Privacy & Security and click "Open Anyway" next to the MemStats message.
* Or remove the quarantine flag in Terminal:

  ```bash
  xattr -dr com.apple.quarantine /Applications/MemStats.app
  ```

After that, MemStats opens normally. It lives in the menu bar only (no Dock icon). Right-click (or Option-click) the menu bar item for Open at Login, Show System Users, Settings, About and Quit. The gear in the popover opens the same options menu next to the gear without closing the popover.

## Quit Apps and Processes

Right-click an app in Top Apps or a process in Top Processes (list or treemap) and choose Quit or Force Quit. Quit asks the app to quit like the Dock does, so it can still ask to save your work. Force Quit stops it right away, and it asks first, right at the row (press Return to confirm or Esc to cancel). Quit of a background process asks first too. The row shows Quitting… until it exits, and tells you if it is still running after 10 seconds.

Only your own processes can be quit. Processes of other users and protected system processes (such as `WindowServer` and `loginwindow`) are shown but cannot be quit from MemStats.

## Settings

Settings (⌘, in the menu bar item's menu) lets you change:

* Update interval for RAM, pressure, swap, the menu bar and history (1 to 60s, default 5s)
* Update interval for top processes (3 to 60s, default 5s)
* Number of top apps and top processes shown (5 to 20, default 8)
* Which popover sections are shown (Top Users, History, Top Apps, Top Processes), their order and their style: line or heatmap for History, list or treemap for Top Apps and Top Processes
* Open at Login and Show System Users

Short intervals use more CPU, mostly the top processes interval, since each update runs `top` (about 1.4s of work). While the popover is closed, RAM updates at most every 15s and top processes at most every 60s.

## Update

There is no automatic update. Open Settings and click "Check for Updates…" to open the latest release on [GitHub Releases](https://github.com/sown-oss/MemStats/releases), compare it with the version shown in Settings, then download and replace the app.

## Report a Bug

Open Settings and click "Report a Bug…". It opens the GitHub bug report form with your MemStats version, macOS version, Mac model, language and main settings already filled in, so you only describe the problem. You can also [open the form](https://github.com/sown-oss/MemStats/issues/new?template=bug_report.yml) directly.

For a crash, attach the crash report: open Console > Crash Reports (or `~/Library/Logs/DiagnosticReports`), find `MemStats-*.ips`, zip it and drag the zip into the form.

## Build From Source

Requires Xcode 26 or later.

```bash
git clone https://github.com/sown-oss/MemStats.git
cd MemStats
xcodebuild -project MemStats/MemStats.xcodeproj -scheme MemStats -configuration Release -derivedDataPath build build
open build/Build/Products/Release/MemStats.app
```

Run the unit tests:

```bash
xcodebuild -project MemStats/MemStats.xcodeproj -scheme MemStats -destination 'platform=macOS' test
```

## Resource Usage

Measured on MemStats 1.3.1 (Release) on 2026-11-13: M1 MacBook Pro, 16 GB, macOS 26.6, memory every 3 s and processes every 5 s, popover closed, sampled once a minute for 30 minutes.

| Metric | Value | Notes |
| --- | --- | --- |
| Memory (footprint) | 35 MB, flat | The Memory column in Activity Monitor. A minimal SwiftUI + AppKit app usually sits at 30 to 60 MB |
| % CPU | 0.16 average | CPU time divided by run time. Shorter intervals, mostly the top processes one, use more |

Opening the popover builds its charts and lists, so memory rises while it is open and drops back when it closes. To check for leaks on your Mac, leave MemStats running with the popover closed and confirm `footprint MemStats` stays flat, then open and close the popover a few times and confirm it returns to the same level.

## License

Released under the [MIT License](LICENSE).
