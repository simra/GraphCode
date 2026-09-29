import Foundation

public enum SettingsApplicationTiming: String, Codable, Equatable, Sendable {
  case live
  case nextLoop
  case nextSession
  case appRestart
  case daemonRestart
}
public struct SettingsFieldContract: Codable, Equatable, Sendable {
  public var field: String
  public var timing: SettingsApplicationTiming

  public init(field: String, timing: SettingsApplicationTiming) {
    self.field = field
    self.timing = timing
  }
}
public struct GraphcodeSettingsSnapshot: Codable, Equatable, Sendable {
  public var settings: GraphcodeSettings
  public var revision: String
  public var exists: Bool
  public var supportDirectory: String
  public var filePath: String
  public var fields: [SettingsFieldContract]

  public init(
    settings: GraphcodeSettings,
    revision: String,
    exists: Bool,
    supportDirectory: String = "",
    filePath: String = "",
    fields: [SettingsFieldContract] = GraphcodeSettingsContract.fields
  ) {
    self.settings = settings.protocolNormalized
    self.revision = revision
    self.exists = exists
    self.supportDirectory = supportDirectory
    self.filePath = filePath
    self.fields = fields
  }
}
public enum GraphcodeSettingsContract {
  /// The largest whole-minute value that remains exact after JSON decoding in JavaScript
  /// and after conversion to seconds in Swift.
  public static let maximumResolvedSessionGraceMinutes = 150_119_987_579_016

  public static let fields: [SettingsFieldContract] = [
    .init(field: "defaultBackend", timing: .nextLoop),
    .init(field: "defaultModelTier", timing: .nextLoop),
    .init(field: "codexApprovals", timing: .nextSession),
    .init(field: "openCodePermissions", timing: .nextSession),
    .init(field: "piProjectTrust", timing: .nextSession),
    .init(field: "claudePermissionMode", timing: .nextSession),
    .init(field: "copilotPermissions", timing: .nextSession),
    .init(field: "copilotPreferredVersion", timing: .nextSession),
    .init(field: "briefsSessionsAboutTheGraph", timing: .nextSession),
    .init(field: "endsResolvedSessionsAfterMinutes", timing: .live),
    .init(field: "autoSelectsModel", timing: .nextLoop),
    .init(field: "worktreePolicies", timing: .live),
    .init(field: "showsActivityStrip", timing: .live),
    .init(field: "betaUpdates", timing: .live),
    .init(field: "summarisesLoops", timing: .live),
    .init(field: "summaryUsesModel", timing: .live),
    .init(field: "visualisesSummaries", timing: .live),
    .init(field: "daemonHeartbeatEnabled", timing: .live),
    .init(field: "mailroomEnabled", timing: .live),
    .init(field: "keepsMacAwakeWhileLoopsRun", timing: .live),
  ]
}
