import Foundation

/// Claude Code's narration, read out of the transcript it already writes.
///
/// Claude Code is the one backend that reports its activity *itself*, through the
/// `PreToolUse` hook `PresenceHooks` installs — which is why it never needed a log reader
/// the way Copilot and Codex did. That hook reports one phrase at a time into a label
/// store, though, and a summary rail needs the sentence *around* the phrase: what the
/// session said it was about to do, before it did it.
///
/// So this is the third reader in the shape of the other two. Every session appends
/// `~/.claude/projects/<encoded-cwd>/<session-id>.jsonl`, one record per message, and the
/// assistant's own text blocks are the narration. The session id is the one graphcode
/// already banks for `--resume` (`SessionIDStore`), so the file is found without guessing.
///
/// This is the "scanned" tier of docs/04-cli-backends.md#presence, same as the others: a
/// reading taken from outside, carrying no claim that the agent reported it.
public enum ClaudeSessionLog {
  /// Where Claude Code keeps one directory per project. A `var` only so tests can point it
  /// at a fixture; nothing in the app writes it.
  public static var projectsDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".claude/projects", isDirectory: true)

  public static func canonicalSessionID(_ sessionID: String) -> String? {
    guard sessionID.utf8.count == 36, let uuid = UUID(uuidString: sessionID) else { return nil }
    let canonical = uuid.uuidString.lowercased()
    return sessionID.lowercased() == canonical ? canonical : nil
  }

  /// The transcript GraphCode banked for this project, constrained to the exact Claude
  /// project directory and its immediate children.
  public static func transcript(forSessionID sessionID: String, projectPath: String) -> URL? {
    guard let sessionID = canonicalSessionID(sessionID) else { return nil }
    let manager = FileManager.default
    let root = projectsDirectory.standardizedFileURL.resolvingSymlinksInPath()
    let project =
      projectsDirectory
      .appendingPathComponent(
        SessionTransplant.claudeProjectSlug(forWorkingDirectory: projectPath),
        isDirectory: true
      )
      .standardizedFileURL
      .resolvingSymlinksInPath()
    guard project.deletingLastPathComponent() == root else { return nil }
    let candidate =
      project.appendingPathComponent("\(sessionID).jsonl").standardizedFileURL
      .resolvingSymlinksInPath()
    guard candidate.deletingLastPathComponent() == project,
      manager.fileExists(atPath: candidate.path)
    else { return nil }
    return candidate
  }

  static let remoteTranscriptResolverProgram = """
    import os, re, sys, uuid
    id_file, projects_root, working_directory = sys.argv[1:4]
    uuid_pattern = re.compile(r"^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$")

    try:
        with open(id_file, "r", encoding="ascii") as source:
            raw = source.read(128)
    except (OSError, UnicodeError):
        raise SystemExit
    if uuid_pattern.fullmatch(raw) is None:
        raise SystemExit
    try:
        session_id = str(uuid.UUID(raw))
    except ValueError:
        raise SystemExit

    root = os.path.realpath(projects_root)
    project_path = os.path.realpath(working_directory)
    slug = re.sub(r"[^A-Za-z0-9]", "-", project_path)
    project = os.path.realpath(os.path.join(root, slug))
    candidate = os.path.realpath(os.path.join(project, session_id + ".jsonl"))
    if (
        os.path.normcase(os.path.dirname(project)) != os.path.normcase(root)
        or os.path.normcase(os.path.dirname(candidate)) != os.path.normcase(project)
    ):
        raise SystemExit
    if os.path.isfile(candidate):
        print(candidate)
    """

  static func remoteFindExpression(for node: LoopNode, at location: RemoteProjectLocation) -> String
  {
    let idFile = PresenceHooks.remoteSessionIDExpression(forNodeID: node.id)
    let program = RemoteProjectLocation.shellQuoted(remoteTranscriptResolverProgram)
    let project = RemoteProjectLocation.shellQuoted(
      SessionTransplant.remoteWorkingDirectory(forNode: node, at: location))
    return
      "F=$(python3 -c \(program) \(idFile) \"$HOME/.claude/projects\" \(project) 2>/dev/null)"
  }

  /// What one `tool_use` block is doing, in the same voice as the other two readers.
  ///
  /// Deliberately a second copy of `PresenceHooks.activityScript`'s `case` rather than a
  /// shared table: that one is a `sed` pipeline that has to run inside a hook on a machine
  /// graphcode may not be on, and this one runs in-process over a parsed record. Sharing
  /// them would mean generating shell from Swift or parsing JSON in `sh`. They are checked
  /// against each other in `SummaryRailTests`.
  public static func phrase(forTool name: String, input: [String: Any]) -> String? {
    func text(_ key: String) -> String? {
      guard let raw = input[key] as? String else { return nil }
      let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : trimmed
    }
    func leaf(_ key: String) -> String? {
      text(key).map { String($0.split(separator: "/").last ?? Substring($0)) }
    }
    let specific: String?
    switch name {
    case "Edit", "Write", "MultiEdit", "NotebookEdit":
      specific = leaf("file_path").map { "editing \($0)" }
    case "Read":
      specific = leaf("file_path").map { "reading \($0)" }
    case "Bash", "BashOutput":
      specific = (text("description") ?? text("command")).map { "running \($0)" }
    case "Grep":
      specific = text("pattern").map { "searching for \($0)" }
    case "Glob":
      specific = text("pattern").map { "looking for \($0)" }
    case "WebSearch":
      specific = text("query").map { "searching the web for \($0)" }
    case "WebFetch":
      specific = text("url").map { url in
        let host = url.split(separator: "/").dropFirst(2).first.map(String.init) ?? url
        return "reading \(host)"
      }
    case "Task", "Agent":
      specific = text("description").map { "delegating \($0)" }
    case "Skill":
      specific = text("skill").map { "running the \($0) skill" }
    case "TodoWrite", "TaskCreate", "TaskUpdate":
      specific = "planning"
    default:
      specific =
        name.hasPrefix("mcp__")
        ? "using \(name.split(separator: "_").last.map(String.init) ?? name)" : nil
    }
    // A recognised tool whose input isn't the shape expected names itself rather than
    // going quiet — the same fallback the other two readers make.
    return specific ?? "using \(name)"
  }

  /// Every beat in a transcript's tail, oldest first.
  ///
  /// **Sidechains are skipped.** A `Task`/`Agent` sub-agent writes its whole conversation
  /// into the same file marked `isSidechain`, and folding that in would narrate the
  /// sub-agent's work as if it were the loop's — five beats deep in a file the human never
  /// asked about, while the loop's own beat says "delegating".
  public static func beats(inTranscriptAt url: URL) -> [SummaryBeat] {
    var builder = builder(inTranscriptAt: url)
    return builder.beats()
  }

  /// The same read, as the reading the store merges — beats, the turns that bound them,
  /// and where the metric got to.
  static func reading(inTranscriptAt url: URL, metricSamples: [MetricSample]) -> SummaryReading {
    var builder = builder(inTranscriptAt: url)
    return SummaryBeatBuilder.reading(
      from: builder.beats(), turns: builder.userTurns(), metricSamples: metricSamples,
      closing: builder.closingAnswer())
  }

  private static func builder(inTranscriptAt url: URL) -> SummaryBeatBuilder {
    builder(forLines: SummaryBeatBuilder.tailLines(of: url))
  }

  /// The same read over lines from anywhere — a local tail, or a remote one an ssh probe
  /// brought back (`RemoteTranscriptProbe`). Nothing below this line knows which.
  static func builder(forLines lines: [Data]) -> SummaryBeatBuilder {
    var builder = SummaryBeatBuilder()
    for line in lines {
      guard let object = try? JSONSerialization.jsonObject(with: line),
        let record = object as? [String: Any],
        record["isSidechain"] as? Bool != true,
        let type = record["type"] as? String
      else { continue }
      let at = SummaryBeatBuilder.date(fromTimestamp: record["timestamp"]) ?? Date()
      let message = record["message"] as? [String: Any] ?? [:]
      switch type {
      case "user":
        guard isUserTurn(message) else { continue }
        builder.noteUserTurn(at: at)
      case "assistant":
        // `end_turn` is the model saying it has finished and is handing back; `tool_use`
        // is it pausing for a call it is about to make. Read after the blocks, so it lands
        // on the beat this record opened.
        defer {
          if message["stop_reason"] as? String == "end_turn" { builder.noteTurnEnd() }
        }
        for block in message["content"] as? [[String: Any]] ?? [] {
          switch block["type"] as? String {
          case "text":
            builder.noteNarration(block["text"] as? String ?? "", at: at)
          case "tool_use":
            guard let name = block["name"] as? String,
              let phrase = phrase(
                forTool: name, input: block["input"] as? [String: Any] ?? [:])
            else { continue }
            builder.noteTool(phrase, at: at)
          default:
            continue
          }
        }
      default:
        continue
      }
    }
    return builder
  }

  /// Whether a `user` record is a turn or a tool result wearing the user role.
  ///
  /// Every tool result comes back as a `user` message whose content is an array of
  /// `tool_result` blocks, so counting those as passes would make a pass out of every
  /// `grep`. A turn is a plain string, or an array carrying real text.
  static func isUserTurn(_ message: [String: Any]) -> Bool {
    if let text = message["content"] as? String {
      return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    guard let blocks = message["content"] as? [[String: Any]] else { return false }
    return blocks.contains { block in
      guard block["type"] as? String == "text" else { return false }
      let text = block["text"] as? String ?? ""
      return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
  }

  /// The remote script's half: find the transcript the way this reader does locally, but
  /// on the other machine.
  ///
  /// The session id is read from the file the remote host banks itself — the same one
  /// `--resume` uses, written by the hooks graphcode installs there — so the lookup is the
  /// local one expressed in `sh`, not a second rule about where transcripts live.
  ///
  /// The filter drops tool *results*, keyed on `toolUseResult` rather than on the string
  /// `tool_result`: the second appears in prose the moment an agent talks about its own
  /// transcript, and dropping that line would drop a beat. Results are most of a
  /// transcript's bytes and are read by nothing here.
  static func remoteSummaryInvocation(
    forNode node: LoopNode, at location: RemoteProjectLocation, since stamp: String?
  ) -> [String] {
    let find = remoteFindExpression(for: node, at: location)
    let script = RemoteTranscriptProbe.script(
      findingFileWith: find, filter: "grep -av toolUseResult", since: stamp)
    return location.sshInvocation(remoteCommand: location.remoteLoginShellCommand(script))
  }

  static func remoteSummary(
    of node: LoopNode, at location: RemoteProjectLocation, metricSamples: [MetricSample]
  ) async -> SummaryReading? {
    let stamp = await TranscriptFreshness.shared.remoteStamp(forNode: node.id)
    let reply = await RemoteTranscriptProbe.run(
      remoteSummaryInvocation(forNode: node, at: location, since: stamp), at: location)
    guard case .lines(let newStamp, let lines) = reply else { return nil }
    await TranscriptFreshness.shared.recordRemoteStamp(newStamp, forNode: node.id)
    var builder = builder(forLines: lines)
    let reading = SummaryBeatBuilder.reading(
      from: builder.beats(), turns: builder.userTurns(), metricSamples: metricSamples,
      closing: builder.closingAnswer())
    return reading.isEmpty ? nil : reading
  }

  /// What this node's Claude Code session has been doing, or `nil` when nothing says.
  ///
  /// A remote loop's transcript is on the other machine, so the tail is fetched over the
  /// same multiplexed ssh connection every other reading uses — see
  /// `RemoteTranscriptProbe` for what that costs and why it is usually nothing.
  public static func summary(of node: LoopNode, projectPath: String? = nil) async
    -> SummaryReading?
  {
    if let projectPath, let remote = RemoteProjectLocation.parse(projectPath: projectPath) {
      return await remoteSummary(of: node, at: remote, metricSamples: node.metricHistory)
    }
    guard let projectPath,
      let sessionID = SessionIDStore.load(forNodeID: node.id),
      let transcript = transcript(
        forSessionID: sessionID,
        projectPath: node.worktreeBinding?.worktreePath ?? projectPath),
      await TranscriptFreshness.shared.hasChanged(transcript, forNode: node.id)
    else { return nil }
    let reading = reading(inTranscriptAt: transcript, metricSamples: node.metricHistory)
    return reading.isEmpty ? nil : reading
  }
}
