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

Right-click an app in Top Apps or a process in Top Processes (list or treemap) and choose Quit or Force Quit, then confirm in the bar that appears in the section. Quit asks the app to quit like the Dock does, so it can still ask to save your work. Force Quit stops it right away.

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

Open Settings and click "Report a Bug…". It opens a new GitHub issue with your MemStats version, macOS version and Mac model already filled in, so you only describe the problem. You can also [open an issue](https://github.com/sown-oss/MemStats/issues/new) directly.

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

Snapshot from Activity Monitor (Debug build, running under Xcode `debugserver`, on 2026-10-03):

| Metric | Value | Assessment |
| --- | --- | --- |
| Real Memory | 45.1 MB | Normal. A minimal SwiftUI + AppKit app usually sits at 30 to 60 MB. This is all resident pages, so it also includes clean file-backed pages (framework code, fonts, assets) and graphics memory, which is why it is larger than Private + Shared |
| Private Memory | 4.9 MB | Very low. This is the memory the app allocates itself and the most meaningful number |
| Shared Memory | 12.8 MB | Normal. Frameworks shared with other processes |
| Virtual Memory | 415.44 GB | Not a concern. Reserved address space (shared cache, GPU, malloc zones), not physical RAM. Typical for any app on Apple Silicon |
| % CPU | 0.20 | Good for an app that samples periodically |
| Recent hangs | 0 | Good |

Notes:

* A Release build is expected to be slightly lighter, since there is no debugger attached and optimizations are enabled.
* One snapshot is not enough to rule out leaks. To check long-running behavior:
  1. Leave the app running for 30 to 60 minutes and confirm Real/Private Memory stays stable.
  2. Open and close the popover several times and confirm memory returns to its previous level.
  3. If memory keeps growing, use Instruments (Leaks / Allocations) or the Xcode Memory Graph Debugger.

## License

Released under the [MIT License](LICENSE).
