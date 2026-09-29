import Foundation
import GraphcodeKit
import Observation

/// The app's live view of `GraphcodeSettings`, saved the moment anything changes.
///
/// A shared instance rather than a TCA dependency: these are read by plain SwiftUI views
/// outside any feature's store (the Settings scene, and `AppView` for the window's
/// opacity), and every write has to reach `~/.graphcode/settings.json` because the
/// **daemon** is what actually acts on most of them.
///
/// No explicit "Save" button follows from that: a settings window whose changes only take
/// effect on OK would be lying about where the value lives, since the daemon reads the
/// file fresh for every session it starts.
@Observable
@MainActor
final class SettingsModel {
  static let shared = SettingsModel()

  /// The user's explicit Mailroom flip, kept apart from `settings` on purpose: the
  /// ramp decides what an install that has never chosen boots on, but once a human
  /// has flipped the switch the ramp never overrides them — the way `updateChannel`
  /// does for updates.
  static let mailroomChoiceDefaultsKey = "mailroomChoice"

  @ObservationIgnored private let daemonWriter = SettingsDaemonWriter()
  @ObservationIgnored private var applyingSnapshot = false

  private(set) var lastSaveError: String?

  var settings: GraphcodeSettings {
    didSet {
      guard settings != oldValue, !applyingSnapshot else { return }
      save(settings)
    }
  }

  /// The update channel as a switch (#36). It is persisted in the shared settings file
  /// and mirrored to the update client's legacy `UserDefaults` override.
  var betaUpdates: Bool {
    didSet {
      guard betaUpdates != oldValue else { return }
      settings.betaUpdates = betaUpdates
      UserDefaults.standard.set(betaUpdates ? "beta" : "stable", forKey: "updateChannel")
    }
  }

  /// The Mailroom as a switch, following `betaUpdates`' shape — but the daemon
  /// enforces this one, so a flip writes `mailroomEnabled` into `settings` (which
  /// saves the file the daemon reads) *and* records the explicit choice that then
  /// outranks the ramp for good.
  var mailroomEnabled: Bool {
    didSet {
      UserDefaults.standard.set(mailroomEnabled, forKey: Self.mailroomChoiceDefaultsKey)
      settings.mailroomEnabled = mailroomEnabled
    }
  }

  private init() {
    let loaded = GraphcodeSettingsStore.load()
    let mailroom = Self.resolvesMailroom(
      loaded: loaded.mailroomEnabled,
      explicitChoice:
        UserDefaults.standard.object(forKey: Self.mailroomChoiceDefaultsKey) as? Bool,
      rampedOn: FeatureRamps.isEnabled(.mailroom))
    var booted = loaded
    booted.mailroomEnabled = mailroom.enabled
    settings = booted
    mailroomEnabled = mailroom.enabled
    let version =
      Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    betaUpdates =
      booted.betaUpdates
      || UpdateChannel.channel(
        for: version, override: UserDefaults.standard.string(forKey: "updateChannel"))
        == .beta
    Task { await reload() }
  }

  func apply(_ snapshot: GraphcodeSettingsSnapshot) {
    applyingSnapshot = true
    settings = snapshot.settings
    betaUpdates = snapshot.settings.betaUpdates
    mailroomEnabled = snapshot.settings.mailroomEnabled
    applyingSnapshot = false
    lastSaveError = nil
    Task { await daemonWriter.observe(snapshot) }
  }

  func setDefaultBackend(_ backend: CLISessionBackendKind) {
    settings.defaultBackend = backend
  }

  func reload() async {
    do {
      let loaded = try await daemonWriter.load()
      let mailroom = Self.resolvesMailroom(
        loaded: loaded.settings.mailroomEnabled,
        explicitChoice:
          UserDefaults.standard.object(forKey: Self.mailroomChoiceDefaultsKey) as? Bool,
        rampedOn: FeatureRamps.isEnabled(.mailroom))
      guard mailroom.fileNeedsWrite else {
        apply(loaded)
        return
      }
      var migrated = loaded.settings
      migrated.mailroomEnabled = mailroom.enabled
      apply(try await daemonWriter.save(migrated))
    } catch {
      lastSaveError = error.localizedDescription
    }
  }

  private func save(_ desired: GraphcodeSettings) {
    Task {
      do {
        apply(try await daemonWriter.save(desired))
      } catch {
        lastSaveError = error.localizedDescription
      }
    }
  }

  /// The Mailroom's boot decision, separated so tests can pin it without touching
  /// `UserDefaults`, the settings file, or the bundle.
  ///
  /// An install that has never chosen boots on the ramp's answer — on everywhere since
  /// the board shipped, with `ramps.json` kept as the kill switch — and that answer has
  /// to reach `~/.graphcode/settings.json` when it differs, because the daemon enforces
  /// `mailroomEnabled` out of the file and cannot see ramps or `UserDefaults`. A
  /// recorded choice outranks the ramp from then on. The switch itself is always
  /// offered: it is a setting now, not a beta gate, and a person who finds the board
  /// too much turns it off here. Rewriting a file that already agrees is churn.
  static func resolvesMailroom(
    loaded: Bool, explicitChoice: Bool?, rampedOn: Bool
  ) -> MailroomResolution {
    let enabled = explicitChoice ?? rampedOn
    return MailroomResolution(enabled: enabled, fileNeedsWrite: enabled != loaded)
  }

  struct MailroomResolution: Equatable {
    var enabled: Bool
    var fileNeedsWrite: Bool
  }
}

private actor SettingsDaemonWriter {
  private var revision: String?

  func observe(_ snapshot: GraphcodeSettingsSnapshot) {
    revision = snapshot.revision
  }

  func load() throws -> GraphcodeSettingsSnapshot {
    let snapshot = try request(.loadSettings)
    revision = snapshot.revision
    return snapshot
  }

  func save(_ settings: GraphcodeSettings) throws -> GraphcodeSettingsSnapshot {
    let expectedRevision: String
    if let revision {
      expectedRevision = revision
    } else {
      expectedRevision = try load().revision
    }
    let snapshot = try request(
      .updateSettings(expectedRevision: expectedRevision, settings: settings))
    revision = snapshot.revision
    return snapshot
  }

  private func request(_ command: DaemonCommand) throws -> GraphcodeSettingsSnapshot {
    let client = try DaemonSocketClient()
    defer { client.closeConnection() }
    guard case .settingsChanged(let snapshot) = try client.request(command) else {
      throw DaemonSocketClient.ClientError.malformedResponse
    }
    return snapshot
  }
}
