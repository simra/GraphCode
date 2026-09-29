import Foundation

#if canImport(SQLite3)
  import SQLite3
#endif

/// Reads the goal verdict each backend records for the `/goal` graphcode launched it with.
///
/// | Backend | Record |
/// |---|---|
/// | Claude Code | transcript `goal_status` attachment, `met: true` without `sentinel` |
/// | Codex | `~/.codex/goals_1.sqlite` `thread_goals.status = 'complete'` |
/// | Copilot CLI | `events.jsonl` `session.autopilot_objective_changed`, `status: "completed"` |
///
/// OpenCode and pi record nothing goal-specific, so they have no reading here. Remote
/// projects have none yet either: their records live on the other machine.
public enum GoalVerdictReader {
  public static var codexGoalsDatabase: URL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".codex/goals_1.sqlite")

  public static func verdict(of node: LoopNode, projectPath: String?) -> GoalVerdict? {
    guard node.loopType == .goalBased, let goal = node.goal else { return nil }
    if let projectPath, RemoteProjectLocation.parse(projectPath: projectPath) != nil {
      return nil
    }
    switch node.backend {
    case .claudeCode:
      guard let projectPath,
        let sessionID = SessionIDStore.load(forNodeID: node.id),
        let transcript = ClaudeSessionLog.transcript(
          forSessionID: sessionID,
          projectPath: node.worktreeBinding?.worktreePath ?? projectPath)
      else { return nil }
      return claudeVerdict(
        lines: CopilotSessionLog.tailLines(ofLogAt: transcript), goalSummary: goal.summary)
    case .codex:
      guard
        let threadID = CodexThreadResolver.threadID(
          forNodeID: node.id, banked: SessionIDStore.load(forNodeID: node.id),
          projectPath: projectPath)
      else { return nil }
      return codexVerdict(threadID: threadID, database: codexGoalsDatabase)
    case .copilotCLI:
      let name = SurfaceRef(id: node.id, launchesClaudeCode: true).zmxSessionName
      guard let directory = CopilotSessionLog.directory(forSessionNamed: name) else { return nil }
      return copilotVerdict(
        lines: CopilotSessionLog.tailLines(
          ofLogAt: directory.appendingPathComponent("events.jsonl")))
    case .openCode, .pi:
      return nil
    }
  }

  /// The newest `goal_status` decides. A `sentinel` record is Claude Code setting or
  /// clearing a goal — a user's `/goal clear` writes `met: true` with the sentinel — so it
  /// is never a verdict. The condition must be this loop's goal: a human can type a
  /// different `/goal` into the same session.
  static func claudeVerdict(lines: [Substring], goalSummary: String) -> GoalVerdict? {
    for line in lines.reversed() where line.contains("\"goal_status\"") {
      guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)),
        let record = object as? [String: Any],
        let attachment = record["attachment"] as? [String: Any],
        attachment["type"] as? String == "goal_status"
      else { continue }
      if attachment["sentinel"] as? Bool == true { return nil }
      guard let condition = attachment["condition"] as? String,
        conditionNamesGoal(condition, goalSummary: goalSummary)
      else { return nil }
      let recordedAt = timestamp(record["timestamp"])
      guard attachment["met"] as? Bool == true else {
        return GoalVerdict(met: false, recordedAt: recordedAt)
      }
      return GoalVerdict(
        met: true, detail: attachment["reason"] as? String, recordedAt: recordedAt)
    }
    return nil
  }

  static func timestamp(_ value: Any?) -> Date? {
    guard let text = value as? String else { return nil }
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text)
  }

  /// The condition is the summary plus whatever the launch appended, and a long one may be
  /// cut to the backend's length cap — so a prefix of the summary is what is compared.
  static func conditionNamesGoal(_ condition: String, goalSummary: String) -> Bool {
    func normalized(_ text: String) -> String {
      text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
    let summary = String(normalized(goalSummary).prefix(80))
    return !summary.isEmpty && normalized(condition).contains(summary)
  }

  /// The newest objective status decides; an objective reopened after completing is
  /// active again.
  static func copilotVerdict(lines: [Substring]) -> GoalVerdict? {
    for line in lines.reversed()
    where line.contains("\"session.autopilot_objective_changed\"") {
      guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)),
        let event = object as? [String: Any],
        let data = event["data"] as? [String: Any],
        let status = data["status"] as? String
      else { continue }
      return GoalVerdict(met: status == "completed", recordedAt: timestamp(event["timestamp"]))
    }
    return nil
  }

  static func codexVerdict(threadID: String, database: URL) -> GoalVerdict? {
    #if canImport(SQLite3)
      guard FileManager.default.fileExists(atPath: database.path) else { return nil }
      var handle: OpaquePointer?
      guard sqlite3_open_v2(database.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK
      else {
        sqlite3_close(handle)
        return nil
      }
      defer { sqlite3_close(handle) }
      sqlite3_busy_timeout(handle, 500)
      var statement: OpaquePointer?
      guard
        sqlite3_prepare_v2(
          handle, "SELECT status, updated_at_ms FROM thread_goals WHERE thread_id = ?", -1,
          &statement, nil)
          == SQLITE_OK
      else { return nil }
      defer { sqlite3_finalize(statement) }
      let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
      sqlite3_bind_text(statement, 1, threadID, -1, transient)
      guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0)
      else { return nil }
      let updatedAt = Date(
        timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, 1)) / 1000)
      return GoalVerdict(met: String(cString: text) == "complete", recordedAt: updatedAt)
    #else
      return nil
    #endif
  }
}
