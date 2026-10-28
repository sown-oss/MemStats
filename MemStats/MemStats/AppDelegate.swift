import AppKit
import Combine
import ServiceManagement
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
  private var popupWindow: GlassPopoverWindow?
  private var outsideClickMonitor: Any?
  private var localClickMonitor: Any?
  private var statusItem: NSStatusItem?
  private weak var popoverOptionsMenuAnchor: NSView?
  private let appState = MemStatsAppState()
  private let loginItemService = LoginItemService()
  private var settingsWindow: NSWindow?
  private var cancellables: Set<AnyCancellable> = []
  private var lastDisplayedUsedBytes: UInt64?
  private var lastDisplayedPressureLevel: MemoryPressureLevel?
  private var lastDisplayedUsagePercent: Int?

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)

    loginItemService.syncWithSystem()
    observeTheme()
    observeLanguage()
    observeGlassBackground()
    applyTheme(appState.settings.theme)
    configureStatusItem()
    observeMemoryStats()
  }

  private func makePopupWindow() -> GlassPopoverWindow {
    let size = PopoverRootView.popoverSize
    let arrowHeight: CGFloat = 10
    let window = GlassPopoverWindow(
      contentRect: NSRect(x: 0, y: 0, width: size.width, height: size.height + arrowHeight),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    window.isOpaque = false
    window.backgroundColor = .clear
    window.hasShadow = true
    window.level = .popUpMenu
    window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    window.appearance = appState.settings.theme.nsAppearance
    window.onDismiss = { [weak self] in self?.closePopup() }
    window.onCancel = { [weak self] in
      guard let self else { return }
      // Esc cancels a Quit confirmation first, then closes the popup.
      if self.appState.pendingQuit != nil {
        self.appState.cancelQuit()
      } else {
        self.closePopup()
      }
    }
    window.onOpenSettings = { [weak self] in self?.showSettings() }

    let background = GlassBackgroundContainerView()
    background.material = .sidebar
    background.popoverArrowHeight = arrowHeight
    background.preferenceEnabled = appState.settings.glassBackground
    background.glassOpacity = appState.settings.glassOpacity
    window.contentView = background

    let content = NSHostingView(
      rootView: PopoverRootView(
        appState: appState,
        onOpenActivityMonitor: { [weak self] in self?.openActivityMonitor() },
        onOpenOptionsMenu: { [weak self] in self?.showContextMenuFromPopover() },
        onOptionsMenuAnchorAvailable: { [weak self] anchor in
          self?.popoverOptionsMenuAnchor = anchor
        }
      )
    )
    content.translatesAutoresizingMaskIntoConstraints = false
    background.addSubview(content)
    NSLayoutConstraint.activate([
      content.leadingAnchor.constraint(equalTo: background.leadingAnchor),
      content.trailingAnchor.constraint(equalTo: background.trailingAnchor),
      content.bottomAnchor.constraint(equalTo: background.bottomAnchor),
      content.topAnchor.constraint(equalTo: background.topAnchor, constant: arrowHeight),
    ])
    return window
  }

  private func configureStatusItem() {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    guard let button = item.button else { return }

    button.imagePosition = .imageLeading
    button.target = self
    button.action = #selector(handleStatusItemClick)
    button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    // No sample yet: show a neutral placeholder instead of a green 0%.
    applyStatusAppearance(to: button, usagePercent: nil, pressure: nil)

    statusItem = item
  }

  private func observeMemoryStats() {
    appState.memoryVM.$currentStats
      .compactMap { $0 }
      .sink { [weak self] stats in
        self?.updateStatusItemIfNeeded(with: stats)
      }
      .store(in: &cancellables)
  }

  private func observeTheme() {
    appState.settings.$theme
      .removeDuplicates()
      .sink { [weak self] theme in
        self?.applyTheme(theme)
      }
      .store(in: &cancellables)
  }

  private func observeLanguage() {
    appState.settings.$language
      .removeDuplicates()
      .sink { [weak self] _ in
        self?.refreshLocalizedStatusItem()
        self?.refreshLocalizedSettingsWindow()
      }
      .store(in: &cancellables)
  }

  private func observeGlassBackground() {
    GlassSettingsObservation.observe(appState.settings) { [weak self] isEnabled, opacity in
      self?.refreshGlassWindowConfiguration(isEnabled: isEnabled, opacity: opacity)
    }
    .store(in: &cancellables)
  }

  private func refreshLocalizedStatusItem() {
    guard let button = statusItem?.button else { return }
    applyStatusAppearance(
      to: button,
      usagePercent: lastDisplayedUsagePercent,
      pressure: lastDisplayedPressureLevel
    )
  }

  private func refreshLocalizedSettingsWindow() {
    settingsWindow?.title = AppLocalization.string(
      "MemStats Settings", language: appState.settings.language
    )
  }

  private func applyTheme(_ theme: AppTheme) {
    NSApp.appearance = theme.nsAppearance
    popupWindow?.appearance = theme.nsAppearance
    settingsWindow?.appearance = theme.nsAppearance
  }

  private func refreshGlassWindowConfiguration(isEnabled: Bool, opacity: Double) {
    for window in [popupWindow, settingsWindow] {
      guard let background = window?.contentView as? GlassBackgroundContainerView else { continue }
      background.preferenceEnabled = isEnabled
      background.glassOpacity = opacity
    }
  }

  private func updateStatusItemIfNeeded(with stats: MemoryStats) {
    guard let button = statusItem?.button else { return }

    let shouldUpdate = shouldRefreshStatus(
      currentUsedBytes: stats.usedBytes,
      totalBytes: stats.totalBytes,
      pressureLevel: stats.pressureLevel
    )

    guard shouldUpdate else { return }

    let usagePercent =
      stats.totalBytes > 0
      ? Int((Double(stats.usedBytes) / Double(stats.totalBytes) * 100).rounded())
      : 0
    applyStatusAppearance(to: button, usagePercent: usagePercent, pressure: stats.pressureLevel)

    lastDisplayedUsedBytes = stats.usedBytes
    lastDisplayedPressureLevel = stats.pressureLevel
    lastDisplayedUsagePercent = usagePercent
  }

  /// The menu bar on the active display renders template content and `contentTintColor`
  /// as monochrome, so the pressure color is baked into a non-template image and an
  /// attributed title instead. `nil` values mean no sample has arrived yet.
  private func applyStatusAppearance(
    to button: NSStatusBarButton,
    usagePercent: Int?,
    pressure: MemoryPressureLevel?
  ) {
    let tint = pressure?.color ?? .secondaryLabelColor
    let language = appState.settings.language
    let percentText = Self.percentText(usagePercent)
    let image = NSImage(systemSymbolName: "memorychip", accessibilityDescription: "RAM")?
      .withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [tint]))
    image?.isTemplate = false

    button.contentTintColor = nil
    button.image = image
    button.attributedTitle = NSAttributedString(
      string: "RAM \(percentText)",
      attributes: [
        .foregroundColor: tint,
        // Monospaced digits keep the width stable while the digit count stays the same.
        .font: NSFont.monospacedDigitSystemFont(
          ofSize: NSFont.menuBarFont(ofSize: 0).pointSize,
          weight: .regular
        ),
      ]
    )

    // The color alone does not tell VoiceOver or a hover what the pressure is.
    let description: String
    if let usagePercent, let pressure {
      description = AppLocalization.formatted(
        "Memory %lld%%, pressure %@",
        language: language,
        Int64(usagePercent),
        AppLocalization.string(pressure.displayName, language: language)
      )
    } else {
      description = AppLocalization.string(
        "Memory: waiting for the first sample", language: language
      )
    }
    button.toolTip = description
    button.setAccessibilityLabel(description)
  }

  /// No padding: the status item has a variable length, so it fits the text tightly.
  /// The placeholder uses figure dashes (as wide as a digit) to match a two-digit value.
  nonisolated static func percentText(_ percent: Int?) -> String {
    let digits = percent.map { String(min(max($0, 0), 100)) } ?? "\u{2012}\u{2012}"
    return digits + "%"
  }

  private func shouldRefreshStatus(
    currentUsedBytes: UInt64,
    totalBytes: UInt64,
    pressureLevel: MemoryPressureLevel
  ) -> Bool {
    if lastDisplayedUsedBytes == nil {
      return true
    }

    if lastDisplayedPressureLevel != pressureLevel {
      return true
    }

    guard let previousUsedBytes = lastDisplayedUsedBytes else {
      return true
    }

    let delta =
      currentUsedBytes > previousUsedBytes
      ? currentUsedBytes - previousUsedBytes
      : previousUsedBytes - currentUsedBytes

    let onePercentThreshold = totalBytes / 100
    let minimumThreshold = UInt64(100 * 1024 * 1024)
    let threshold = max(minimumThreshold, onePercentThreshold)

    return delta >= threshold
  }

  @objc
  private func handleStatusItemClick() {
    guard let button = statusItem?.button else { return }

    let currentEvent = NSApp.currentEvent
    let isOptionClick = currentEvent?.modifierFlags.contains(.option) == true
    let isRightClick = currentEvent?.type == .rightMouseUp

    if isRightClick || isOptionClick {
      showContextMenu(from: button)
      return
    }

    if popupWindow?.isVisible == true {
      closePopup()
    } else {
      showPopup(anchoredTo: button)
    }
  }

  private func showPopup(anchoredTo button: NSStatusBarButton) {
    let window = popupWindow ?? makePopupWindow()
    popupWindow = window
    refreshGlassWindowConfiguration(
      isEnabled: appState.settings.glassBackground,
      opacity: appState.settings.glassOpacity
    )

    guard let buttonWindow = button.window else { return }
    let buttonFrame = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
    let visibleFrame = buttonWindow.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
    let x = min(
      max(buttonFrame.midX - window.frame.width / 2, visibleFrame.minX),
      visibleFrame.maxX - window.frame.width
    )
    let y = max(buttonFrame.minY + 2 - window.frame.height, visibleFrame.minY)
    window.setFrameOrigin(NSPoint(x: x, y: y))
    window.makeKeyAndOrderFront(nil)
    appState.setPopoverPresented(true)
    installOutsideClickMonitors()
  }

  private func closePopup() {
    guard popupWindow?.isVisible == true else { return }
    popupWindow?.orderOut(nil)
    removeOutsideClickMonitors()
    appState.setPopoverPresented(false)
  }

  private func removeOutsideClickMonitors() {
    if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
    if let localClickMonitor { NSEvent.removeMonitor(localClickMonitor) }
    outsideClickMonitor = nil
    localClickMonitor = nil
  }

  private func installOutsideClickMonitors() {
    outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
      matching: [.leftMouseDown, .rightMouseDown]
    ) { [weak self] _ in self?.closePopup() }
    localClickMonitor = NSEvent.addLocalMonitorForEvents(
      matching: [.leftMouseDown, .rightMouseDown]
    ) { [weak self] event in
      guard let self else { return event }
      if event.window !== self.popupWindow && event.window !== self.statusItem?.button?.window {
        self.closePopup()
      }
      return event
    }
  }

  private func showContextMenuFromPopover() {
    guard
      let anchor = popoverOptionsMenuAnchor,
      anchor.window === popupWindow,
      popupWindow?.isVisible == true
    else {
      return
    }

    let menu = makeContextMenu()
    menu.update()
    // Keep the popover visible as the menu tracks, but prevent the outside-click monitor
    // from treating the menu's own window as a reason to dismiss its anchor.
    removeOutsideClickMonitors()
    popupWindow?.isContextMenuTracking = true
    defer {
      popupWindow?.isContextMenuTracking = false
      if popupWindow?.isVisible == true {
        installOutsideClickMonitors()
      }
    }
    menu.popUp(
      positioning: nil,
      at: NSPoint(
        x: anchor.bounds.maxX,
        y: anchor.bounds.minY
      ),
      in: anchor
    )
  }

  private func showContextMenu(from button: NSStatusBarButton) {
    closePopup()
    let menu = makeContextMenu()
    statusItem?.menu = menu
    button.performClick(nil)
    statusItem?.menu = nil
  }

  private func makeContextMenu() -> NSMenu {
    let menu = NSMenu()
    let language = appState.settings.language

    let openAtLogin = NSMenuItem(
      title: AppLocalization.string("Open at Login", language: language),
      action: #selector(toggleOpenAtLogin),
      keyEquivalent: ""
    )
    openAtLogin.target = self
    // The user can change login items in System Settings while the app runs.
    loginItemService.syncWithSystem()
    if loginItemService.requiresApproval {
      // Mixed state: registered, but macOS has not approved it yet. Clicking cancels it.
      openAtLogin.title = AppLocalization.string(
        "Open at Login (needs approval)", language: language
      )
      openAtLogin.state = .mixed
      openAtLogin.toolTip = AppLocalization.string(
        "Approve in System Settings > Login Items, or click to cancel", language: language
      )
    } else {
      openAtLogin.state = loginItemService.isEnabled ? .on : .off
    }

    let showSystemUsers = NSMenuItem(
      title: AppLocalization.string("Show System Users", language: language),
      action: #selector(toggleShowSystemUsers),
      keyEquivalent: ""
    )
    showSystemUsers.target = self
    showSystemUsers.state = appState.showsSystemUsers ? .on : .off
    showSystemUsers.toolTip = AppLocalization.string(
      "Include root and _* system accounts", language: language
    )

    let settings = NSMenuItem(
      title: AppLocalization.string("Settings…", language: language),
      action: #selector(showSettings),
      keyEquivalent: ","
    )
    settings.target = self

    let supportUs = NSMenuItem(
      title: AppLocalization.string("Support Us…", language: language),
      action: #selector(openSupportUs),
      keyEquivalent: ""
    )
    supportUs.target = self

    let about = NSMenuItem(
      title: AppLocalization.string("About", language: language),
      action: #selector(showAbout),
      keyEquivalent: ""
    )
    about.target = self

    let quit = NSMenuItem(
      title: AppLocalization.string("Quit", language: language),
      action: #selector(quitApp),
      keyEquivalent: "q"
    )
    quit.target = self

    menu.items = [openAtLogin, showSystemUsers, .separator(), settings, supportUs, about, quit]
    return menu
  }

  /// Shared by the context menu and the Settings window. The menu re-reads the state each
  /// time it opens, and Settings observes `loginItemService`.
  @objc
  private func toggleOpenAtLogin() {
    do {
      try loginItemService.toggle()
      if loginItemService.requiresApproval {
        // Present after the status item menu finishes tracking.
        DispatchQueue.main.async { [weak self] in
          self?.presentLoginItemApprovalPrompt()
        }
      }
    } catch {
      DispatchQueue.main.async { [weak self] in
        self?.presentLoginItemError(error)
      }
    }
  }

  @objc
  private func toggleShowSystemUsers(_ sender: NSMenuItem) {
    appState.setShowsSystemUsers(!appState.showsSystemUsers)
    sender.state = appState.showsSystemUsers ? .on : .off
  }

  /// A self-managed window, since opening a SwiftUI `Settings` scene from an accessory app's
  /// `NSMenu` is not reliable. Reopening reuses the same window.
  @objc
  private func showSettings() {
    loginItemService.syncWithSystem()
    closePopup()

    let window = settingsWindow ?? makeSettingsWindow()
    settingsWindow = window
    NSApp.activate()
    window.makeKeyAndOrderFront(nil)
  }

  private func makeSettingsWindow() -> NSWindow {
    let content = NSHostingView(
      rootView: SettingsView(
        appState: appState,
        loginItemService: loginItemService,
        onToggleOpenAtLogin: { [weak self] in
          self?.toggleOpenAtLogin()
        }
      )
    )
    let window = SettingsWindow(
      contentRect: NSRect(x: 0, y: 0, width: 440, height: 702),
      styleMask: [.titled, .closable],
      backing: .buffered,
      defer: false
    )
    window.title = AppLocalization.string(
      "MemStats Settings", language: appState.settings.language
    )
    window.appearance = appState.settings.theme.nsAppearance
    window.isReleasedWhenClosed = false
    window.isOpaque = false
    window.backgroundColor = .clear
    let background = GlassBackgroundContainerView()
    background.material = .sidebar
    background.preferenceEnabled = appState.settings.glassBackground
    background.glassOpacity = appState.settings.glassOpacity
    window.contentView = background
    content.translatesAutoresizingMaskIntoConstraints = false
    background.addSubview(content)
    NSLayoutConstraint.activate([
      content.leadingAnchor.constraint(equalTo: background.leadingAnchor),
      content.trailingAnchor.constraint(equalTo: background.trailingAnchor),
      content.topAnchor.constraint(equalTo: background.topAnchor),
      content.bottomAnchor.constraint(equalTo: background.bottomAnchor),
    ])
    window.setContentSize(NSSize(width: 440, height: 702))
    window.center()
    return window
  }

  @objc
  private func showAbout() {
    NSApp.orderFrontStandardAboutPanel(nil)
    NSApp.activate()
  }

  @objc
  private func openSupportUs() {
    NSWorkspace.shared.open(AppLinks.sponsorURL)
  }

  private func openActivityMonitor() {
    guard
      let activityMonitorURL = NSWorkspace.shared.urlForApplication(
        withBundleIdentifier: "com.apple.ActivityMonitor"
      )
    else {
      return
    }

    let configuration = NSWorkspace.OpenConfiguration()
    NSWorkspace.shared.openApplication(
      at: activityMonitorURL,
      configuration: configuration
    )
  }

  @objc
  private func quitApp() {
    NSApp.terminate(nil)
  }

  private func presentLoginItemError(_ error: Error) {
    let language = appState.settings.language
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = AppLocalization.string("Could not update Open at Login", language: language)
    alert.informativeText = error.localizedDescription
    alert.addButton(withTitle: AppLocalization.string("OK", language: language))
    NSApp.activate()
    alert.runModal()
  }

  private func presentLoginItemApprovalPrompt() {
    let language = appState.settings.language
    let alert = NSAlert()
    alert.alertStyle = .informational
    alert.messageText = AppLocalization.string(
      "Allow MemStats to open at login", language: language
    )
    alert.informativeText = AppLocalization.string(
      "macOS needs your approval. Turn on MemStats in System Settings > General > Login Items.",
      language: language
    )
    alert.addButton(withTitle: AppLocalization.string("Open System Settings", language: language))
    alert.addButton(withTitle: AppLocalization.string("Cancel", language: language))

    // Accessory apps are not active by default, so bring the alert to the front.
    NSApp.activate()
    if alert.runModal() == .alertFirstButtonReturn {
      SMAppService.openSystemSettingsLoginItems()
    }
  }
}

private final class GlassPopoverWindow: NSPanel {
  var onDismiss: (() -> Void)?
  var onCancel: (() -> Void)?
  var onOpenSettings: (() -> Void)?
  var isContextMenuTracking = false

  override var canBecomeKey: Bool { true }

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    if WindowDismissShortcut.matchesSettings(event) {
      onOpenSettings?()
      return true
    }
    if WindowDismissShortcut.matches(event, menuIsTracking: isContextMenuTracking) {
      onDismiss?()
      return true
    }
    return super.performKeyEquivalent(with: event)
  }

  override func cancelOperation(_ sender: Any?) {
    onCancel?()
  }
}

/// Window-local handling keeps Cmd+Q/Cmd+W from reaching the application's Quit action.
/// The context menu still owns Cmd+Q while it is being tracked.
enum WindowDismissShortcut {
  static func matchesSettings(_ event: NSEvent) -> Bool {
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    guard flags == .command else { return false }

    return event.charactersIgnoringModifiers == ","
  }

  static func matches(_ event: NSEvent, menuIsTracking: Bool = false) -> Bool {
    guard !menuIsTracking else { return false }

    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    guard flags == .command else { return false }

    let key = event.charactersIgnoringModifiers?.lowercased()
    return key == "q" || key == "w"
  }
}

private final class SettingsWindow: NSWindow {
  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    if WindowDismissShortcut.matches(event) {
      performClose(nil)
      return true
    }
    return super.performKeyEquivalent(with: event)
  }
}
