# 🧭 MemStats

Similar to iStat Menus/Stats, but focused on **memory monitoring** for multiple users.

A **menu bar macOS app** that shows:

* Runs continuously with **minimal CPU + memory overhead**
* Shows **Top Users (donut)** with swap/pressure status context
* Shows **Top Apps** (helper processes grouped into their parent app)
* Provides **short-term history (bounded window)**
* Show **Top processes (global or per selected user)**
* Has **native macOS UX (no custom-heavy UI nonsense)**

All inside **one popup window**.

---

## 1. Architecture Overview

### Stack

* UI: SwiftUI
* Menu bar: `NSStatusBar` + `NSPopover`
* Data layer:

  * `host_statistics64` → memory stats
    * Used RAM = App Memory (`internal_page_count - purgeable_count`) + Wired + Compressed, matching Activity Monitor "Memory Used"
    * Free (available) = Total - Used, so file cache counts as available
  * `sysctl` → total RAM
  * `sysctl kern.memorystatus_vm_pressure_level` → memory pressure level (1 normal, 2 warning, 4 critical), same source as Activity Monitor
    * `vm.memory_pressure` is not used: it is a reclaim activity counter, not a level
    * Fallback when the sysctl is unavailable: used/total ratio (≥ 75% warning, ≥ 90% critical)
  * `top -l 1 -F -o mem -stats pid,user,mem,command` → processes
  * `proc_pidpath(pid)` → executable path, used to group processes by app
* State:

  * `ObservableObject` (single source of truth)

---

## 2. UI Layout (Single Popup)

```text
┌──────────────────────────────────┐
│ [|||]                        [⚙] |
├──────────────────────────────────┤
│                                  │
│          Donut Chart             │
│        (% total usage)           │
│                                  │
├──────────────────────────────────┤
│        History Chart             │
├──────────────────────────────────┤
│        Top Apps                  │
│   (filtered by selected user)    │
├──────────────────────────────────┤
│        Top Processes             │
│   (filtered by selected user)    │
└──────────────────────────────────┘
```

---

## 3. Menu Bar

### Menu Bar Item

* Default:

  * `memorychip` icon + title `RAM N%` (used RAM / total, rounded)
  * Color reflects **memory pressure**

    * 🟢 / 🟠 / 🔴 (system pressure level): green normal, orange warning, red critical
    * Orange instead of yellow, since yellow is hard to read on a light menu bar. The menu bar and the popover share one color source, and orange is used for nothing else (not swap, growth hints or user colors)
    * Color is baked into a non-template icon and an attributed title, because the active display's menu bar renders template content and `contentTintColor` as monochrome
    * Title uses monospaced digits with no padding; the item has a variable length and fits the text, so its width only changes when the digit count changes (for example 9% to 10%)
    * Before the first sample the title reads `RAM ‒‒%` (figure dashes) in a neutral color, instead of a green `RAM 0%`
  * Tooltip and VoiceOver label: `Memory 45%, pressure Normal`

* Click:
  → show **popover (main UI)**

* Right-click OR option-click:
  → show **context menu**

---

### Context Menu

```text
• Open at Login [✓]
• Show System Users [✓]
---
• Settings…   ⌘,
• About
• Quit
```

#### Implementation

* Use:

  * `SMAppService.mainApp.register()` → run at login
* Persist toggle via:

  * `UserDefaults`
* The checkmark always reflects `SMAppService.mainApp.status` (re-read after each change and each time the menu opens)
* If macOS needs approval (`.requiresApproval`), show an alert that opens System Settings > Login Items
* While approval is pending, the menu item reads `Open at Login (needs approval)` with a mixed checkmark, and the Settings toggle shows on with a note; clicking again unregisters, so a pending request can be cancelled
* `Show System Users`: see §14.5
* `Settings…`: opens the Settings window (§15)
* Open at Login and Show System Users are also in Settings and stay in sync both ways

---

## 4. Popup UI

### Header

```text
[Activity Monitor Icon]          [Options Icon (gear icon)]
```

* Left: **Open Activity Monitor**

  * launched by bundle id `com.apple.ActivityMonitor` through `NSWorkspace.urlForApplication(withBundleIdentifier:)` + `openApplication(at:configuration:)`, so it works regardless of the app name or language

* Right: **Open Options** (the same menu as right-clicking the menu bar item, anchored to this gear)
* The header stays fixed above the scrolling content, with a divider; both buttons have a 24x24pt click area
* The popover is 380x540pt; the content below the header scrolls with a visible scroll indicator

---

## 5. Performance-first Design (VERY IMPORTANT)

This is where most people mess up.

### 5.1 Sampling Strategy

DO NOT run everything every second.

#### Two timers

```text
Memory timer  (host_statistics64 + sysctl): default every 5s, setting 1-60s
Process timer (top):                        default every 5s, setting 3-60s
```

👉 Process parsing is the expensive part (`top` snapshot + parse), so it has its own interval with a 3s minimum.

* Memory timer: updates the menu bar, history and donut (using the latest process snapshot).
* Process timer: updates Top Apps, Top Processes, the donut and the growth hints.
* Each timer samples on its own serial queue, so a slow `top` run never delays a memory sample.
* While the popover is open each timer uses its setting; while it is closed the memory timer uses `max(setting, 15s)` and the process timer `max(setting, 60s)` (§14.1).
* The rules below apply to each timer separately:
  * Opening the popover switches to the active interval and samples right away, unless a sample started less than 2s ago; then the next one waits for the new interval.
  * Closing the popover only switches to the idle interval. It never samples right away: the next sample runs one interval after the last one.
  * Changing an interval in Settings works the same way: the new interval counts from the last sample.
  * Only one sample of a kind runs at a time. An immediate request while one is running marks one follow-up sample instead of queueing another run, so repeated `Refresh Now` clicks run `top` at most once more. A timer tick that lands during a running sample is skipped.
* `Refresh Now` samples memory and processes immediately and pushes each timer's next tick a full interval out.
* `top` gets 6s for the normal 500-process snapshot (it takes about 1.4s on an idle machine). If
  that run times out, it is stopped and retried with 150 processes for up to 4s, so the process
  section can still update during a busy system. Only a primary timeout triggers this fallback;
  if the fallback fails, its error is surfaced. Other launch/read errors are surfaced directly.
  Including the one-second stop grace period, the worst-case retry path is about 12s. Output is
  only read after both pipe readers finish.
* The `top` mem column can end with `+` or `-` (changed since the last sample); the marker is ignored, and values are clamped before converting to bytes.

---

### 5.2 Avoid heavy SwiftUI redraw

* Use:

  * `@Published` minimal fields
* Split ViewModels:

  * `MemoryVM`
  * `ProcessVM`

---

### 5.3 Limit process list size

* Runtime snapshot:

  * keep a broader process set (for example top 500 from `top`) to support donut/user aggregation accurately
* UI list:

  * show the top N processes in the popover (Settings, default 8)

---

### 5.4 Avoid constant grouping

* Cache last result
* Only recompute when process list updates
* Donut slices are built once per sample in `MemStatsAppState` and published only when they change, so hover never regroups processes

---

## 6. Donut Chart

### Data

* Each slice = **user total RAM**
* Last slice = **Free memory**
* If slice < 2% → merge into "Others"
* Memory not covered by sampled processes → "Unattributed Used"
* Sort users by memory DESC
* User colors are picked with a stable hash (FNV-1a) so a user keeps the same color across launches
* "Others" is system gray; "Unattributed Used" is an opaque gray that is darker in light mode and lighter in dark mode, so it stays distinct from "Others" and keeps at least 3:1 contrast with the background

### Center label

* Default: `% used RAM`
* Focused slice (hover or selected): slice label + `%`

### Info row (below the donut)

* Left: `All Users`, or the focused slice label
* Right:
  * nothing focused: system `Used X / Total Y`
  * user, "Others" or "Unattributed Used" slice focused: `<slice size> / Used X`, which replaces the system summary while focused
  * "Free" slice focused: `<free size> / Total Y`, since free memory is not part of used RAM
* Both texts stay on one line; the right side keeps priority, so a long user name truncates instead of the numbers
* Percentages (center label, VoiceOver value) are rounded to the nearest whole number, the same way as the total

### Interaction

* Hover on slice:

  * highlight slice (larger radius)
  * dim others
  * show slice info in the center label and in the info row (no floating tooltip):

    * user name (center label and info row)
    * memory (MB/GB) (info row only)
    * % (center label only)

* Click slice:

  * only user slices can be selected; "Free", "Others" and "Unattributed Used" respond to hover only
  * set `selectedUser`
  * filter process list
  * show a "Clear Filter" button in the Top Users header (overlaid, so it does not shift the layout)

* Click again:

  * reset filter

* Auto reset: the filter clears itself when the selected user no longer has its own slice on the donut, either because it was merged into "Others" (< 2%) or because it has no processes left. This keeps the highlighted slice, center label and info row in sync with the filtered lists.

* VoiceOver: the donut is one element with a value listing every slice, plus actions to filter or clear each user
* VoiceOver elsewhere in the popover:
  * the history chart is one element, "Memory history", whose value reads used RAM of total, pressure, swap, the selected user's memory (when filtered) and the sample count
  * table column headers are one header element per table
  * each Top Apps / Top Processes row is one element, e.g. `Safari, 12 processes, 1.20 GB` or `WindowServer, user _windowserver, PID 152, 512 MB`

---

## 6a. App Icons

* Top Apps rows show the app's icon before its name, and Top Processes rows show the icon of the app a process belongs to (helpers share their app's icon) before the process name. A process with no resolved path, or an app without a bundle, shows the generic executable icon
* Icons come from `NSWorkspace` by path and are cached (`AppIconProvider`), 16 pt, hidden from VoiceOver since the row text names the app
* The treemap shows the icon beside the name on wide tiles, and alone on tiles too small for text

## 6b. Top Lists Treemap

* `Top Apps` and `Top Processes` each have their own style setting (`topAppsStyle`, `topProcessesStyle`): `List` (default) or `Treemap`. A bordered button in each header and the `Top apps style` / `Top processes style` pickers in Settings change it; the header button is overlaid so the header height does not change
* Squarified treemap of the rows the list would show (same user filter and row count). Tile area is memory (app total, or process RSS)
* Tile text, most important first: name, MEM, then `PID n` (processes) or process count (apps), then the user. The user line only shows for processes when the visible rows come from more than one user. Lines that do not fit are dropped from the least important end; tiles too small for any text show color only. No percentage is printed on tiles
* Tile color is the change since the previous sample: red = higher, green = lower, gray = within 0.5% or no earlier reading (new process). Strength has 3 steps, at 0.5%, 2% and 5%. For apps the earlier value is measured inside the current user filter. The key under the chart is one `Lower` to `Higher` scale with a short caption; the tooltip and VoiceOver label give name, PID, memory and user
* Empty and loading states are the same as the list

## 7. History Chart

### Status rows

* `Sampling`: current mode and the intervals the timers run at, for example `Active (5s)` while the popover is open and `Idle (15s, processes 60s)` while it is closed. When the two timers differ the process interval is listed too: `Active (2s, processes 10s)`
* The sample count shows in the section headers instead of a row: `History (120)`, `Top Apps (8)`, `Top Processes (8)`

### Chart style

* Two styles: `Line` (default, described below) and `Heatmap`
* A small bordered button in the History header (same placement as Clear Filter in Top Users, overlaid so it does not shift the layout) switches style; Settings has a matching `History chart style` picker. Both write the same persisted setting (`historyChartStyle`), so they never disagree
* Heatmap is a GitHub-style grid of 7 rows, filled column by column, newest sample in the last column; slots without a sample stay empty. It shows as many of the newest samples as fit the width
* Green intensity has 4 levels, scaled to the lowest and highest used RAM in the visible samples (a flat window shows one mid level). Warning and critical samples use their pressure color instead
* The heatmap is not scrollable and has no selected user series; its legend shows one Less to More key (4 green levels, then orange for warning and red for critical), used RAM and the pressure badge. VoiceOver reads the same "Memory history" summary as the line chart

### Metrics (In-memory)

* Total used RAM (primary plotted series)
* Selected user series (optional when a user is selected), scaled the same way as the donut so it matches the donut value and stays within the used RAM range; drawn as a dashed line in that user's donut color, with a matching "Selected" legend swatch
* Swap used + memory pressure shown as latest status badges (swap uses a neutral gray swatch)
* Used RAM chart segment color follows memory pressure at that sample:
  * Green = normal
  * Orange = warning
  * Red = critical
  * Each pair of adjacent samples is its own chart series, colored by the later sample's pressure, so the line never joins non-adjacent samples
  * The "Used" legend swatch uses the current pressure color
  * Legend items never wrap internally; when the row is full, only the overflowing items move to the next row
* Memory growth hints (see §14.3) are shown below the badges
* Y axis: about four ticks from `0 GB` to total RAM, 1, 2, 4, 8... GB apart; the top tick is always total RAM, and a step tick too close to it is dropped

### Time ranges

* Keep about 10 minutes of samples at the configured interval. While the popover is closed and samples come less often (every 15s for memory, 60s for processes), the same buffer covers a longer stretch:

```swift
maxSamples = min(600, ceil(600 / memoryInterval)) // 120 at the default 5s
```

* The selected user series uses the same rule with the process interval setting. While the popover is closed it gets one point per 60s, so that stretch of the line is coarser
* Changing the interval trims the oldest samples that no longer fit
* The chart shows the last 2 minutes at a time, like Activity Monitor; older samples are reached by scrolling horizontally
  * The X axis is never shorter than 2 minutes, so short history grows in from the right
  * The window follows the newest sample; scrolling back pauses that, and scrolling back to the end or reopening the popover resumes it
  * The X axis labels the time every 30 seconds so a scrolled-back view shows when it is

### Behavior

* Auto-drop old data
* No persistence (MVP)

👉 DO NOT store long-term → keeps app light

---

## 8. Process List

### Default

* Runtime keeps all sampled processes (all users by default)
* UI shows the **top N processes** in descending memory order (N from Settings, default 8)
* Changing N re-slices the current snapshot right away, without a new sample

### When user selected

* Filter instantly (no recompute)

  ```swift
  process.user == selectedUser
  ```

### Columns

* In display order: `USER`, `PID`, `PROCESS`, `MEM`
* `USER` truncates at the end when long; hovering shows the full name
* `PROCESS` is the executable name parsed from the command (quotes and escapes handled), truncated in the middle when long; hovering shows the full command line
* `MEM`: `%.0f MB` below 1 GB, `%.2f GB` from 1 GB (binary units, like Activity Monitor). The same format is used everywhere memory is shown in the popover

### Empty state

* Top Apps and Top Processes show `Loading…` until the first process sample lands
* After that (or once the process sample fails, with the error shown below; a memory error alone keeps `Loading…`), an empty list shows "No app data available" / "No process data available"

### Footer

* The last sampling error (if any) shows in red below the list
* `Refresh Now` samples immediately (see §5.1 for how repeated clicks are coalesced)

### Sorting

* Always by memory DESC

---

## 8.1 Top Apps

### Grouping

* Resolve executable path per PID with `proc_pidpath` (public libproc API)
* Path inside an `.app` bundle → group by the **outermost** `.app` bundle
  * e.g. `Visual Studio Code.app/.../Code Helper (Renderer).app/...` → `Visual Studio Code`
* Path outside any bundle → group by executable path (name = executable file name)
* Path not resolvable → fallback to the `top` command name

### Display

* Top N apps in descending memory order (N from Settings, default 8, separate from the process count)
* Columns: App (truncated in the middle when long), process count, Memory (MB/GB, as in §8)
* Hover an app row → tooltip with bundle/executable path
* When a user is selected, only that user's processes are aggregated
* Top Apps and Top Processes each have one section title with the row count; when filtered it reads `Top Apps · <user>`

---

## 9. Native macOS Design Rules

### Follow Apple style strictly

* Surfaces: solid semantic system colors instead of materials (project rule: solid colors, few gradients)

  * popover background: `windowBackgroundColor`
  * sections: native `GroupBox` on `controlBackgroundColor`
  * both adapt to light/dark mode automatically
* Font:

  * system text styles (`.headline`, `.footnote`, `.caption`)
  * live numbers use monospaced digits
* Spacing:

  * 8pt grid as the base, with small optical adjustments
* Icons: SF Symbols only, kept to a minimum (header buttons, menu bar)

### Avoid UI

* flashy gradients
* custom UI libraries
* over-animation

---

## 10. Charts Implementation

## Donut Chart

* Native `Charts` framework: `SectorMark` with `innerRadius: .ratio(0.62)`
* Each arc = user %
* Hover/click hit-testing is done in a `chartOverlay` by converting the pointer angle into a slice

---

## History Chart

* Use:

  * native `Charts` framework
* Primary plotted series:

  * total usage
  * selected user usage (optional)
* Swap + pressure:

  * shown as latest-value badges below chart for readability

---

## 11. Power & Resource Optimization

Critical for long-running app

### 11.1 Use background QoS

```swift
DispatchQueue.global(qos: .utility)
```

---

### 11.2 Debounce updates

* Applies to the menu bar title only: it is redrawn when used RAM moved by at least max(100 MB, 1% of total RAM) since the last redraw, or when the pressure level changed
* The popover updates on every sample (it is only sampled at the active interval while open)

---

### 11.3 Lazy load UI sections (not implemented)

* Not lazy: the popover is small and always shows every section, so the charts render with the popover. Nothing is rendered while the popover is closed.

### 11.4 Keep rendering cheap

* Donut hover state lives in its own subview and changes only when the hovered slice changes, so moving the mouse never redraws the history chart or the tables
* History segments are built once per memory sample in `MemoryViewModel`; history is already in time order, so nothing is sorted while rendering
* Visible apps and processes are rebuilt only on a new sample, a filter change or new row counts, and the PROCESS column names are parsed once per visible command

---

## 12. Permissions & Stability

### Avoid API

* private APIs → App Store rejection

---

## 13. Project Structure

* Clean Architecture:

* MVVM pattern:

---

## 14. Additional Improvements (Recommended)

### 14.1 Idle mode optimization

* When popup closed:

  * reduce sampling per timer:

    ```text
    Memory stats: every 15s (or the setting if it is longer)
    Process list: every 60s (or the setting if it is longer)
    ```

  * memory keeps 15s because it drives the menu bar and the main history chart; processes run `top`, the expensive part, and only feed the popover lists, the per-user history and growth hints
  * opening the popover samples processes right away (§5.1), so the lists are fresh when shown

### 14.2 Smart highlighting (dropped)

* Not implemented: the donut already shows which user uses the most RAM (sorted, largest slice first).

### 14.3 Memory leak hint

* Detect per user (only users in the current snapshot):

  * continuous growth: memory rises on each of the last 12 process samples, with at least 100 MB total growth. The time this covers follows the process interval: 1 minute at the default 5s, about 12 minutes while the popover is closed (processes every 60s). History keeps `ceil(600 / process interval setting)` samples, so with the 60s process setting it holds only 10 and this hint cannot fire
  * sudden jump: growth between the last two samples > max(500 MB, 5% of total RAM)
* A user missing from a snapshot loses its history, so coming back is not counted as a jump
* Up to 2 hints show as secondary caption lines in the History section, each with a swatch in the user's stable palette color, the same one its donut slice uses when it has its own slice (orange is reserved for the warning pressure level)
* Copy: `<user> grew by <size> over the last N samples` / `<user> jumped by <size> since the last sample`

### 14.4 Alert system (dropped)

* No notifications: memory pressure is already shown by the menu bar color (🟢 / 🟠 / 🔴) and swap by the history badges.

### 14.5 Show/Hide system users

System users can add noise, so they can be hidden with the `Show System Users` option in the context menu or in Settings.

* System users: `root` and `_*`
* Default: shown, to match Activity Monitor's all-users view
* When hidden: excluded from the sampled processes, so they disappear from the donut, history (selected user series), Top Apps and Top Processes. Their memory is still part of the system "Used" total, so it shows up in the "Unattributed Used" donut slice.
* The choice persists via `UserDefaults` and triggers an immediate resample

---

## 15. Settings

Opened from `Settings…` (⌘,) in the context menu, or from the popover gear. The gear opens this
same options menu at the gear position and keeps the popover open; it does not open a different
Settings flow. Selecting `Settings…` is the exception: it opens the separate Settings window and
closes the popover. When the popup is open, ⌘, opens Settings directly and closes the popup.

| Setting | Options | Default |
| --- | --- | --- |
| Update interval (RAM, pressure, swap, menu bar, history) | 1, 2, 3, 5, 10, 15, 30, 60s | 5s |
| Update interval for top processes (`top`) | 3, 5, 10, 15, 30, 60s | 5s |
| History chart style | Line / Heatmap | Line |
| Top apps style | List / Treemap | List |
| Top processes style | List / Treemap | List |
| Number of top apps | 5, 8, 10, 15, 20 | 8 |
| Number of top processes | 5, 8, 10, 15, 20 | 8 |
| Open at Login | on / off | off |
| Show System Users | on / off | on |

* Stored in `UserDefaults`, applied right away. A stored value outside the options falls back to the default.
* `top` takes about 1.4s per run, so the process interval starts at 3s. Short intervals cost more CPU, mostly for the process timer.
* Window: a self-managed `NSWindow` + `NSHostingController` (the app is an `LSUIElement` accessory, and opening a SwiftUI `Settings` scene from an `NSMenu` is not reliable). Opening it activates the app and brings the window to the front; reopening reuses the same window. ⌘Q and ⌘W close Settings only, without terminating the app. The popup handles the same shortcuts locally. The app is terminated from the context menu's Quit item, including its ⌘Q equivalent while the menu is open.
* Layout: `Form` with `.formStyle(.grouped)` and `.menu` pickers in four sections (intervals, row counts, Open at Login + Show System Users, About).
* About section: the app version and build, plus two buttons that only open the browser (the app makes no network request):
  * Check for Updates… opens `github.com/sown-oss/MemStats/releases/latest`. There is no version check; the user compares it with the version shown above.
  * Report a Bug… opens `issues/new` with a `[Bug] ` title, the `bug` label and a body template (description, steps, expected behavior) whose Environment part is filled in: app version and build, macOS version, Mac model and architecture.
* Links live in `Services/AppLinks.swift`.
* Rows in the About section are plain `HStack`s, not `LabeledContent`: inside this grouped `Form` with `.preferredContentSize` sizing, `LabeledContent` makes AppKit loop on Update Constraints and crash when the window opens. A unit test hosts the window to catch this.
* The app has no SwiftUI `Settings` scene (its scene is a `MenuBarExtra` that is never inserted), so ⌘, is handled by the popup or context menu instead of opening an empty window.

---

## 🚀 Final Scope (Clean & Sharp)

### Core

* Menu bar app
* Donut (Top Users + free)
* Top apps (helpers grouped, filterable)
* Memory pressure + swap
* Short history (bounded) + memory growth hints
* Top processes (filterable)

### System

* Lightweight sampling
* Run at login
* Context menu (Open at Login, Show System Users, Settings…, About, Quit)
* Settings window (§15)

### Note

* Process memory comes from `top` (`mem`) snapshot and is best-effort relative to Activity Monitor
* `top` stays the process source because it can read every user's processes: without special privileges `proc_pid_rusage` only reads the processes of the user running the app, and the app targets Macs shared by several users
* Memory pressure prefers system pressure signals from `sysctl` and only falls back to usage-ratio heuristic if unavailable
* Shared memory may still be accounted differently than Activity Monitor internals
* Values are indicative and optimized for lightweight monitoring
