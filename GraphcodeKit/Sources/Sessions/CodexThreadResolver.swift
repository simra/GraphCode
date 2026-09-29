import Foundation

#if canImport(SQLite3)
  import SQLite3
#endif

/// The Codex thread a loop's session really runs on.
///
/// The `notify` hook banks the `thread-id` of the event it is handed, and once a session
/// opens on `/goal` that id names a thread Codex never persists: no rollout, no row in its
/// own `threads` table, no goal. Resuming it fails, and its goal verdict cannot be read
/// (#346). Codex does persist the real thread, and its first message is the launch line.
/// GraphCode binds that line through the exact project-scoped prompt path it controls.
public enum CodexThreadResolver {
  public static var codexDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".codex", isDirectory: true)

  public static func launchMarker(forNodeID nodeID: UUID, projectPath: String) -> String {
    NodeMemory.directory(forProjectPath: projectPath, nodeID: nodeID)
      .appendingPathComponent(NodeMemory.promptFileName).path
  }

  /// The canonical banked id when Codex knows it as a thread; otherwise the sole thread
  /// whose first message contains GraphCode's exact project-scoped launch marker.
  public static func threadID(forNodeID nodeID: UUID, banked: String?, projectPath: String?)
    -> String?
  {
    guard let database = stateDatabase() else { return canonicalID(banked) }
    return threadID(
      forNodeID: nodeID, banked: banked, projectPath: projectPath, database: database)
  }

  static func threadID(
    forNodeID nodeID: UUID,
    banked: String?,
    projectPath: String?,
    database: URL
  ) -> String? {
    #if canImport(SQLite3)
      guard let banked = canonicalID(banked) else { return nil }
      var handle: OpaquePointer?
      guard sqlite3_open_v2(database.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK
      else {
        sqlite3_close(handle)
        return nil
      }
      defer { sqlite3_close(handle) }
      sqlite3_busy_timeout(handle, 500)
      if canonicalID(firstText(handle, "SELECT id FROM threads WHERE id = ?", banked)) == banked {
        return banked
      }
      guard let projectPath else { return nil }
      let matches = texts(
        handle,
        "SELECT id FROM threads WHERE instr(first_user_message, ?) > 0 LIMIT 2",
        launchMarker(forNodeID: nodeID, projectPath: projectPath))
      guard matches.count == 1 else { return nil }
      return canonicalID(matches[0])
    #else
      return nil
    #endif
  }

  private static func canonicalID(_ value: String?) -> String? {
    guard let value, value.utf8.count == 36, let uuid = UUID(uuidString: value) else { return nil }
    let canonical = uuid.uuidString.lowercased()
    return value.lowercased() == canonical ? canonical : nil
  }

  /// Codex versions its state database in the file name (`state_5.sqlite`), so the newest
  /// version present is the one in use.
  static func stateDatabase() -> URL? {
    guard
      let names = try? FileManager.default.contentsOfDirectory(atPath: codexDirectory.path)
    else { return nil }
    let versions = names.compactMap { name -> (Int, String)? in
      guard name.hasPrefix("state_"), name.hasSuffix(".sqlite"),
        let version = Int(name.dropFirst("state_".count).dropLast(".sqlite".count))
      else { return nil }
      return (version, name)
    }
    return versions.max { $0.0 < $1.0 }.map { codexDirectory.appendingPathComponent($0.1) }
  }

  #if canImport(SQLite3)
    private static func firstText(_ handle: OpaquePointer?, _ sql: String, _ value: String)
      -> String?
    {
      var statement: OpaquePointer?
      guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
        return nil
      }
      defer { sqlite3_finalize(statement) }
      let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
      sqlite3_bind_text(statement, 1, value, -1, transient)
      guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0)
      else { return nil }
      return String(cString: text)
    }

    private static func texts(_ handle: OpaquePointer?, _ sql: String, _ value: String) -> [String]
    {
      var statement: OpaquePointer?
      guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
      defer { sqlite3_finalize(statement) }
      let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
      sqlite3_bind_text(statement, 1, value, -1, transient)
      var result: [String] = []
      while sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) {
        result.append(String(cString: text))
      }
      return result
    }
  #endif
}
