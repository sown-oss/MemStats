import SwiftUI

struct SettingsView: View {
  @ObservedObject private var settings: SettingsStore
  @ObservedObject private var appState: MemStatsAppState
  @ObservedObject private var loginItemService: LoginItemService
  @Environment(\.openURL) private var openURL

  /// Goes through the same path as the context menu, so approval prompts and errors match.
  private let onToggleOpenAtLogin: () -> Void

  init(
    appState: MemStatsAppState,
    loginItemService: LoginItemService,
    onToggleOpenAtLogin: @escaping () -> Void
  ) {
    self._settings = ObservedObject(wrappedValue: appState.settings)
    self._appState = ObservedObject(wrappedValue: appState)
    self._loginItemService = ObservedObject(wrappedValue: loginItemService)
    self.onToggleOpenAtLogin = onToggleOpenAtLogin
  }

  var body: some View {
    Form {
      Section {
        Picker("Theme", selection: $settings.theme) {
          ForEach(AppTheme.allCases) { theme in
            Text(LocalizedStringKey(theme.displayName)).tag(theme)
          }
        }
        Picker("Language", selection: $settings.language) {
          ForEach(AppLanguage.allCases) { language in
            Text(language.displayName).tag(language)
          }
        }
      }

      Section {
        ForEach(settings.sectionOrder) { section in
          sectionRow(section)
        }
        HStack {
          Spacer()
          Button("Reset to Default") {
            settings.resetSectionLayout()
          }
          .disabled(settings.isDefaultSectionLayout)
        }
      } header: {
        Text("Popover sections")
      } footer: {
        Text("Choose which sections the popover shows and their order. At least one stays shown.")
          .font(.footnote)
          .foregroundStyle(.secondary)
      }

      Section {
        Picker("History chart style", selection: $settings.historyChartStyle) {
          ForEach(HistoryChartStyle.allCases) { style in
            Text(LocalizedStringKey(style.displayName)).tag(style)
          }
        }
      }

      Section {
        Picker("Top apps style", selection: $settings.topAppsStyle) {
          ForEach(TopListStyle.allCases) { style in
            Text(LocalizedStringKey(style.displayName)).tag(style)
          }
        }
        Picker("Top processes style", selection: $settings.topProcessesStyle) {
          ForEach(TopListStyle.allCases) { style in
            Text(LocalizedStringKey(style.displayName)).tag(style)
          }
        }
      }

      Section {
        Toggle("Glass background", isOn: $settings.glassBackground)
        if settings.glassBackground {
          HStack {
            Text("Glass opacity")
            Spacer()
            Text(verbatim: "\(Int((settings.glassOpacity * 100).rounded()))%")
              .foregroundStyle(.secondary)
          }
          Slider(
            value: $settings.glassOpacity,
            in: SettingsStore.minimumGlassOpacity...SettingsStore.maximumGlassOpacity,
            step: 0.01
          )
          .labelsHidden()
        }
      } footer: {
        Text(
          "Uses a translucent native material that reveals the desktop behind the window. Reduce Transparency in Accessibility keeps the solid background for readability."
        )
        .font(.footnote)
        .foregroundStyle(.secondary)
      }

      Section {
        Picker("Update interval", selection: $settings.memoryInterval) {
          ForEach(SettingsStore.memoryIntervalOptions, id: \.self) { seconds in
            Text(intervalLabel(seconds, language: settings.language)).tag(seconds)
          }
        }
        Picker("Update interval for top processes", selection: $settings.processInterval) {
          ForEach(SettingsStore.processIntervalOptions, id: \.self) { seconds in
            Text(intervalLabel(seconds, language: settings.language)).tag(seconds)
          }
        }
      } footer: {
        Text(
          "While the popover is closed, RAM updates at most every \(MemStatsAppState.SamplingKind.memory.idleMinimumInterval) seconds and top processes at most every \(MemStatsAppState.SamplingKind.process.idleMinimumInterval) seconds. Short intervals use more CPU, mostly for top processes."
        )
        .font(.footnote)
        .foregroundStyle(.secondary)
      }

      Section {
        Picker("Number of top apps", selection: $settings.topAppsCount) {
          ForEach(SettingsStore.rowCountOptions, id: \.self) { count in
            Text(verbatim: String(count)).tag(count)
          }
        }
        Picker("Number of top processes", selection: $settings.topProcessesCount) {
          ForEach(SettingsStore.rowCountOptions, id: \.self) { count in
            Text(verbatim: String(count)).tag(count)
          }
        }
      }

      Section {
        Toggle("Open at Login", isOn: openAtLoginBinding)
        Toggle("Show System Users", isOn: showSystemUsersBinding)
          .help("Include root and _* system accounts")
      } footer: {
        if loginItemService.requiresApproval {
          Text(
            "Open at Login needs approval in System Settings > General > Login Items. Turn it off to cancel."
          )
          .font(.footnote)
          .foregroundStyle(.secondary)
        }
      }

      // HStack rows, not LabeledContent: with this window's preferred-content-size sizing,
      // LabeledContent makes AppKit loop on Update Constraints and raise an exception.
      Section {
        HStack {
          Text("Version")
          Spacer()
          Text(verbatim: "\(AppLinks.appVersion) (\(AppLinks.appBuild))")
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
        HStack {
          Text("Updates")
          Spacer()
          Button("Check for Updates…") {
            openURL(AppLinks.latestReleaseURL)
          }
        }
        HStack {
          Text("Feedback")
          Spacer()
          Button("Report a Bug…") {
            openURL(AppLinks.bugReportURL())
          }
        }
      } footer: {
        Text(
          "Check for Updates opens the latest release on GitHub. Report a Bug opens a new GitHub issue with your app and macOS versions filled in."
        )
        .font(.footnote)
        .foregroundStyle(.secondary)
      }

      Section {
        HStack {
          Text("Support Us")
          Spacer()
          Button("Sponsor this project") {
            openURL(AppLinks.sponsorURL)
          }
        }
      } footer: {
        Text("Support MemStats development on GitHub Sponsors.")
          .font(.footnote)
          .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
    .pickerStyle(.menu)
    .scrollContentBackground(.hidden)
    .preferredColorScheme(settings.theme.swiftUIColorScheme)
    .environment(\.locale, settings.language.locale)
    .frame(width: 440)
  }

  private func sectionRow(_ section: PopoverSection) -> some View {
    let isVisible = settings.isSectionVisible(section)
    let name = AppLocalization.string(section.displayName, language: settings.language)
    return HStack {
      Toggle(
        isOn: Binding(
          get: { isVisible },
          set: { settings.setSection(section, visible: $0) }
        )
      ) {
        Text(LocalizedStringKey(section.displayName))
      }
      .toggleStyle(.checkbox)
      // The last shown section stays on, so the popover is never empty.
      .disabled(isVisible && settings.visibleSections.count == 1)

      Spacer()

      moveButton(section, name: name, offset: -1)
      moveButton(section, name: name, offset: 1)
    }
  }

  private func moveButton(_ section: PopoverSection, name: String, offset: Int) -> some View {
    let isUp = offset < 0
    return Button {
      settings.moveSection(section, by: offset)
    } label: {
      Image(systemName: isUp ? "chevron.up" : "chevron.down")
        .frame(width: 16, height: 16)
        .contentShape(Rectangle())
    }
    .buttonStyle(.borderless)
    .disabled(!settings.canMoveSection(section, by: offset))
    .help(AppLocalization.string(isUp ? "Move Up" : "Move Down", language: settings.language))
    .accessibilityLabel(
      AppLocalization.formatted(
        isUp ? "Move %@ up" : "Move %@ down", language: settings.language, name)
    )
  }

  private var openAtLoginBinding: Binding<Bool> {
    Binding(
      get: { loginItemService.isRequested },
      set: { _ in onToggleOpenAtLogin() }
    )
  }

  private var showSystemUsersBinding: Binding<Bool> {
    Binding(
      get: { appState.showsSystemUsers },
      set: { appState.setShowsSystemUsers($0) }
    )
  }

  private func intervalLabel(_ seconds: Int, language: AppLanguage) -> String {
    if seconds == 60 {
      return AppLocalization.string("1 minute", language: language)
    }
    if seconds == 1 {
      return AppLocalization.string("1 second", language: language)
    }
    return AppLocalization.formatted(
      "%lld seconds", language: language, Int64(seconds)
    )
  }
}
