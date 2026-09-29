import Foundation

public enum TranscriptEntryKind: String, Codable, Equatable, Sendable {
  case prompt
  case assistant
  case toolUse
  case toolResult
  case status
}
public enum TranscriptRedaction: String, Codable, Equatable, Sendable {
  case prompt
  case toolInput
  case toolResult
  case filesystemPath
  case secret
  case modelMetadata
}
public struct TranscriptEntry: Codable, Equatable, Sendable {
  public var sourceOffset: UInt64
  public var timestamp: String?
  public var kind: TranscriptEntryKind
  public var text: String
  public var toolName: String?
  public var redactions: [TranscriptRedaction]

  public init(
    sourceOffset: UInt64,
    timestamp: String? = nil,
    kind: TranscriptEntryKind,
    text: String,
    toolName: String? = nil,
    redactions: [TranscriptRedaction] = []
  ) {
    self.sourceOffset = sourceOffset
    self.timestamp = timestamp
    self.kind = kind
    self.text = text
    self.toolName = toolName
    self.redactions = Array(Set(redactions)).sorted { $0.rawValue < $1.rawValue }
  }
}
public struct TranscriptQuery: Codable, Equatable, Sendable {
  public static let defaultEntryLimit = 32
  public static let maximumEntryLimit = 64
  public static let defaultByteLimit = 64 * 1024
  public static let maximumByteLimit = 128 * 1024

  public var nodeID: UUID
  public var cursor: String?
  public var maxEntries: Int
  public var maxBytes: Int

  public init(
    nodeID: UUID,
    cursor: String? = nil,
    maxEntries: Int = defaultEntryLimit,
    maxBytes: Int = defaultByteLimit
  ) {
    self.nodeID = nodeID
    self.cursor = cursor
    self.maxEntries = maxEntries
    self.maxBytes = maxBytes
  }

  public func validated() throws -> Self {
    guard (1...Self.maximumEntryLimit).contains(maxEntries),
      (1...Self.maximumByteLimit).contains(maxBytes)
    else {
      throw TranscriptReadError.invalidBounds
    }
    return self
  }
}
public struct TranscriptPage: Codable, Equatable, Sendable {
  public var nodeID: UUID
  public var provider: CLISessionBackendKind
  public var entries: [TranscriptEntry]
  public var nextCursor: String?
  public var hasMore: Bool

  public init(
    nodeID: UUID,
    provider: CLISessionBackendKind,
    entries: [TranscriptEntry],
    nextCursor: String?,
    hasMore: Bool
  ) {
    self.nodeID = nodeID
    self.provider = provider
    self.entries = entries
    self.nextCursor = nextCursor
    self.hasMore = hasMore
  }
}
public enum TranscriptReadError: String, Error, Equatable, Sendable {
  case unauthorized
  case missing
  case corrupt
  case oversized
  case invalidBounds
  case invalidCursor
  case unsupportedProvider
  case transportFailure

  public var message: String {
    switch self {
    case .unauthorized: return "transcript access is not authorized for this connection"
    case .missing: return "the session transcript is missing"
    case .corrupt: return "the session transcript is corrupt"
    case .oversized: return "a transcript record or page exceeds the supported bound"
    case .invalidBounds: return "transcript bounds are outside the supported range"
    case .invalidCursor: return "the transcript cursor no longer matches the source"
    case .unsupportedProvider: return "this session provider has no transcript adapter"
    case .transportFailure: return "the transcript source could not be read"
    }
  }
}
struct TranscriptSourceChunk: Equatable, Sendable {
  var identity: String
  var totalBytes: UInt64
  var offset: UInt64
  var data: Data
}
struct TranscriptCursor: Codable, Equatable, Sendable {
  var version: Int
  var nodeID: UUID
  var provider: CLISessionBackendKind
  var sourceIdentity: String
  var nextOffset: UInt64
  var anchorLength: Int
  var anchorHash: String

  func encoded() throws -> String {
    try JSONEncoder().encode(self).base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  static func decode(_ value: String) throws -> Self {
    var base64 = value.replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
    guard let data = Data(base64Encoded: base64),
      let cursor = try? JSONDecoder().decode(Self.self, from: data),
      cursor.version == 1,
      cursor.anchorLength >= 0,
      cursor.anchorLength <= TranscriptReader.maximumSourceRecordBytes
    else {
      throw TranscriptReadError.invalidCursor
    }
    return cursor
  }
}
public enum TranscriptReader {
  static let maximumSourceRecordBytes = 256 * 1024
  static let maximumEntryBytes = 32 * 1024
  static let readWindowBytes =
    TranscriptQuery.maximumByteLimit + maximumSourceRecordBytes + 1
  static let remoteMarker = "graphcode-transcript:"

  public static func read(
    node: LoopNode,
    projectPath: String?,
    query: TranscriptQuery
  ) async -> Result<TranscriptPage, TranscriptReadError> {
    do {
      let query = try query.validated()
      guard query.nodeID == node.id else { throw TranscriptReadError.unauthorized }
      guard [.claudeCode, .copilotCLI, .codex].contains(node.backend) else {
        throw TranscriptReadError.unsupportedProvider
      }
      let cursor = try query.cursor.map(TranscriptCursor.decode)
      if let cursor {
        guard cursor.nodeID == node.id, cursor.provider == node.backend else {
          throw TranscriptReadError.invalidCursor
        }
      }
      let nextOffset = cursor?.nextOffset ?? 0
      let anchorLength = cursor?.anchorLength ?? 0
      guard nextOffset >= UInt64(anchorLength) else {
        throw TranscriptReadError.invalidCursor
      }
      let readOffset = nextOffset - UInt64(anchorLength)
      let readCount = readWindowBytes + anchorLength
      let chunk: TranscriptSourceChunk
      if let projectPath, let location = RemoteProjectLocation.parse(projectPath: projectPath) {
        chunk = try await remoteChunk(
          node: node, location: location, offset: readOffset, count: readCount)
      } else {
        chunk = try localChunk(
          node: node, projectPath: projectPath, offset: readOffset, count: readCount)
      }
      return .success(
        try page(
          nodeID: node.id,
          provider: node.backend,
          query: query,
          cursor: cursor,
          chunk: chunk))
    } catch let error as TranscriptReadError {
      return .failure(error)
    } catch {
      return .failure(.transportFailure)
    }
  }

  static func page(
    nodeID: UUID,
    provider: CLISessionBackendKind,
    query: TranscriptQuery,
    cursor: TranscriptCursor?,
    chunk: TranscriptSourceChunk
  ) throws -> TranscriptPage {
    guard chunk.offset <= chunk.totalBytes,
      cursor?.sourceIdentity == nil || cursor?.sourceIdentity == chunk.identity
    else {
      throw TranscriptReadError.invalidCursor
    }

    let anchorLength = cursor?.anchorLength ?? 0
    guard chunk.data.count >= anchorLength else { throw TranscriptReadError.invalidCursor }
    if let cursor {
      let anchor = chunk.data.prefix(anchorLength)
      guard hash(Data(anchor)) == cursor.anchorHash else {
        throw TranscriptReadError.invalidCursor
      }
    }

    let body = chunk.data.dropFirst(anchorLength)
    var entries: [TranscriptEntry] = []
    var encodedEntriesBytes = 2
    var consumed = 0
    var lastRecord = cursor.map { Data(chunk.data.prefix($0.anchorLength)) } ?? Data()
    var stoppedForBound = false

    while consumed < body.count {
      let remaining = body.dropFirst(consumed)
      guard let newline = remaining.firstIndex(of: 0x0a) else {
        if remaining.count > maximumSourceRecordBytes {
          throw TranscriptReadError.oversized
        }
        break
      }
      let length = remaining.distance(from: remaining.startIndex, to: newline) + 1
      guard length <= maximumSourceRecordBytes else { throw TranscriptReadError.oversized }
      let rawRecord = Data(remaining.prefix(length))
      let line = Data(rawRecord.dropLast())
      let sourceOffset = (cursor?.nextOffset ?? 0) + UInt64(consumed)
      let entry = try TranscriptNormalizer.entry(
        provider: provider, line: line, sourceOffset: sourceOffset)

      if let entry {
        let encodedEntryBytes = try JSONEncoder().encode(entry).count
        guard encodedEntryBytes <= maximumEntryBytes, encodedEntryBytes <= query.maxBytes else {
          throw TranscriptReadError.oversized
        }
        let separatorBytes = entries.isEmpty ? 0 : 1
        if entries.count == query.maxEntries
          || encodedEntriesBytes + separatorBytes + encodedEntryBytes > query.maxBytes
        {
          stoppedForBound = true
          break
        }
        entries.append(entry)
        encodedEntriesBytes += separatorBytes + encodedEntryBytes
      }

      consumed += length
      lastRecord = rawRecord
    }

    let nextOffset = (cursor?.nextOffset ?? 0) + UInt64(consumed)
    let hasMore = stoppedForBound || nextOffset < chunk.totalBytes
    let nextCursor: String?
    if hasMore {
      nextCursor = try TranscriptCursor(
        version: 1,
        nodeID: nodeID,
        provider: provider,
        sourceIdentity: chunk.identity,
        nextOffset: nextOffset,
        anchorLength: lastRecord.count,
        anchorHash: hash(lastRecord)
      ).encoded()
    } else {
      nextCursor = nil
    }
    return TranscriptPage(
      nodeID: nodeID,
      provider: provider,
      entries: entries,
      nextCursor: nextCursor,
      hasMore: hasMore)
  }

  private static func localChunk(
    node: LoopNode,
    projectPath: String?,
    offset: UInt64,
    count: Int
  ) throws -> TranscriptSourceChunk {
    let url = try localURL(node: node, projectPath: projectPath)
    let attributes: [FileAttributeKey: Any]
    do {
      attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    } catch {
      throw TranscriptReadError.missing
    }
    guard let size = (attributes[.size] as? NSNumber)?.uint64Value else {
      throw TranscriptReadError.corrupt
    }
    guard offset <= size else { throw TranscriptReadError.invalidCursor }
    let handle: FileHandle
    do {
      handle = try FileHandle(forReadingFrom: url)
    } catch {
      throw TranscriptReadError.missing
    }
    defer { try? handle.close() }
    do {
      try handle.seek(toOffset: offset)
      let data = try handle.read(upToCount: count) ?? Data()
      let finalAttributes = try FileManager.default.attributesOfItem(atPath: url.path)
      let identity = localIdentity(
        node: node, url: url, attributes: attributes)
      guard identity == localIdentity(node: node, url: url, attributes: finalAttributes),
        let finalSize = (finalAttributes[.size] as? NSNumber)?.uint64Value,
        offset <= finalSize
      else {
        throw TranscriptReadError.invalidCursor
      }
      return TranscriptSourceChunk(
        identity: identity,
        totalBytes: finalSize,
        offset: offset,
        data: data)
    } catch {
      throw TranscriptReadError.transportFailure
    }
  }

  private static func localIdentity(
    node: LoopNode,
    url: URL,
    attributes: [FileAttributeKey: Any]
  ) -> String {
    let parts = [
      node.backend.rawValue,
      node.id.uuidString,
      url.standardizedFileURL.path,
      String(describing: attributes[.systemNumber] ?? ""),
      String(describing: attributes[.systemFileNumber] ?? ""),
      String(describing: attributes[.creationDate] ?? ""),
    ]
    return hash(Data(parts.joined(separator: "|").utf8))
  }

  private static func localURL(node: LoopNode, projectPath: String?) throws -> URL {
    switch node.backend {
    case .claudeCode:
      guard let sessionID = SessionIDStore.load(forNodeID: node.id),
        let url = ClaudeSessionLog.transcript(forSessionID: sessionID)
      else { throw TranscriptReadError.missing }
      return url
    case .copilotCLI:
      let name = SurfaceRef(id: node.id, launchesClaudeCode: true).zmxSessionName
      guard let directory = CopilotSessionLog.directory(forSessionNamed: name) else {
        throw TranscriptReadError.missing
      }
      return directory.appendingPathComponent("events.jsonl")
    case .codex:
      guard
        let directory = ZmxSessionLauncher.workingDirectory(
          forNode: node, projectPath: projectPath),
        let rollout = CodexSessionLog.rollout(forWorkingDirectory: directory)
      else { throw TranscriptReadError.missing }
      return rollout
    case .openCode, .pi:
      throw TranscriptReadError.unsupportedProvider
    }
  }

  private static func remoteChunk(
    node: LoopNode,
    location: RemoteProjectLocation,
    offset: UInt64,
    count: Int
  ) async throws -> TranscriptSourceChunk {
    let find = remoteFind(node: node, location: location)
    let script = [
      find,
      "if [ -z \"$F\" ] || [ ! -f \"$F\" ]; then echo '\(remoteMarker) missing'; exit 0; fi",
      "I=$(stat -c '%d:%i' \"$F\" 2>/dev/null || stat -f '%d:%i' \"$F\" 2>/dev/null)",
      "N=$(wc -c < \"$F\" 2>/dev/null | tr -d ' ')",
      "if [ -z \"$I\" ] || [ -z \"$N\" ]; then echo '\(remoteMarker) corrupt'; exit 0; fi",
      "if [ \(offset) -gt \"$N\" ]; then echo '\(remoteMarker) cursor'; exit 0; fi",
      "D=$(dd if=\"$F\" bs=1 skip=\(offset) count=\(count) 2>/dev/null | base64 | tr -d '\\r\\n')",
      "I2=$(stat -c '%d:%i' \"$F\" 2>/dev/null || stat -f '%d:%i' \"$F\" 2>/dev/null)",
      "N2=$(wc -c < \"$F\" 2>/dev/null | tr -d ' ')",
      "if [ \"$I\" != \"$I2\" ] || [ -z \"$N2\" ]; then echo '\(remoteMarker) cursor'; exit 0; fi",
      "echo \"\(remoteMarker) data $I2 $N2 $D\"",
    ].joined(separator: "; ")
    let invocation = location.sshInvocation(
      remoteCommand: location.remoteLoginShellCommand(script))
    let result = await ZmxSessionLauncher.collectRemoteOutput(
      invocation, location: location)
    guard result.succeeded else { throw TranscriptReadError.transportFailure }
    let lines = result.output.split(whereSeparator: \.isNewline)
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    guard let marker = lines.last(where: { $0.hasPrefix(remoteMarker) }) else {
      throw TranscriptReadError.transportFailure
    }
    let fields = marker.dropFirst(remoteMarker.count).split(separator: " ", maxSplits: 4)
      .map(String.init)
    switch fields.first {
    case "missing": throw TranscriptReadError.missing
    case "corrupt": throw TranscriptReadError.corrupt
    case "cursor": throw TranscriptReadError.invalidCursor
    case "data":
      guard fields.count == 4, let total = UInt64(fields[2]),
        let data = Data(base64Encoded: fields[3])
      else { throw TranscriptReadError.corrupt }
      return TranscriptSourceChunk(
        identity: hash(Data("\(node.backend.rawValue)|\(node.id)|\(fields[1])".utf8)),
        totalBytes: total,
        offset: offset,
        data: data)
    default:
      throw TranscriptReadError.transportFailure
    }
  }

  private static func remoteFind(node: LoopNode, location: RemoteProjectLocation) -> String {
    switch node.backend {
    case .claudeCode:
      let idFile = PresenceHooks.remoteSessionIDExpression(forNodeID: node.id)
      return
        "S=$(cat \(idFile) 2>/dev/null); F=''; "
        + "[ -n \"$S\" ] && F=$(ls -t \"$HOME\"/.claude/projects/*/\"$S\".jsonl 2>/dev/null | head -1)"
    case .copilotCLI:
      let name = SurfaceRef(id: node.id, launchesClaudeCode: true).zmxSessionName
      return
        "F=''; for d in $(ls -t \"$HOME/.copilot/session-state/\" 2>/dev/null); do "
        + "if grep -qx 'name: \(name)' \"$HOME/.copilot/session-state/$d/workspace.yaml\" 2>/dev/null; "
        + "then F=\"$HOME/.copilot/session-state/$d/events.jsonl\"; break; fi; done"
    case .codex:
      let directory = node.worktreeBinding?.worktreePath ?? location.remotePath
      let quoted = RemoteProjectLocation.shellQuoted(directory)
      return
        "W=\(quoted); F=''; "
        + "for f in $(ls -t \"$HOME\"/.codex/sessions/*/*/*/rollout-*.jsonl 2>/dev/null | head -40); do "
        + "if head -c 65536 \"$f\" 2>/dev/null | grep -Fq \"\\\"cwd\\\":\\\"$W\\\"\"; "
        + "then F=\"$f\"; break; fi; done"
    case .openCode, .pi:
      return "F=''"
    }
  }

  static func hash(_ data: Data) -> String {
    var value: UInt64 = 14_695_981_039_346_656_037
    for byte in data {
      value ^= UInt64(byte)
      value &*= 1_099_511_628_211
    }
    return String(value, radix: 16)
  }
}
enum TranscriptNormalizer {
  static func entry(
    provider: CLISessionBackendKind,
    line: Data,
    sourceOffset: UInt64
  ) throws -> TranscriptEntry? {
    guard !line.isEmpty else { return nil }
    guard let object = try? JSONSerialization.jsonObject(with: line),
      let record = object as? [String: Any]
    else {
      throw TranscriptReadError.corrupt
    }
    switch provider {
    case .claudeCode:
      return claude(record, sourceOffset: sourceOffset)
    case .copilotCLI:
      return try copilot(record, sourceOffset: sourceOffset)
    case .codex:
      return try codex(record, sourceOffset: sourceOffset)
    case .openCode, .pi:
      throw TranscriptReadError.unsupportedProvider
    }
  }

  private static func claude(
    _ record: [String: Any], sourceOffset: UInt64
  ) -> TranscriptEntry? {
    guard record["isSidechain"] as? Bool != true,
      let type = record["type"] as? String
    else { return nil }
    let timestamp = record["timestamp"] as? String
    let message = record["message"] as? [String: Any] ?? [:]
    switch type {
    case "user":
      if let blocks = message["content"] as? [[String: Any]],
        blocks.allSatisfy({ $0["type"] as? String == "tool_result" })
      {
        return TranscriptEntry(
          sourceOffset: sourceOffset, timestamp: timestamp, kind: .toolResult,
          text: "[redacted tool result]", redactions: [.toolResult])
      }
      return TranscriptEntry(
        sourceOffset: sourceOffset, timestamp: timestamp, kind: .prompt,
        text: "[redacted prompt]", redactions: [.prompt])
    case "assistant":
      let blocks = message["content"] as? [[String: Any]] ?? []
      let tools = blocks.compactMap { block -> String? in
        guard block["type"] as? String == "tool_use" else { return nil }
        return block["name"] as? String
      }
      let text = blocks.compactMap { block -> String? in
        guard block["type"] as? String == "text" else { return nil }
        return block["text"] as? String
      }.joined(separator: "\n")
      if !text.isEmpty {
        let redacted = redact(text)
        var reasons = redacted.reasons
        if !tools.isEmpty { reasons.append(.toolInput) }
        if message["model"] != nil || record["model"] != nil {
          reasons.append(.modelMetadata)
        }
        let suffix =
          tools.isEmpty ? "" : "\n[used \(tools.joined(separator: ", ")) with redacted input]"
        return TranscriptEntry(
          sourceOffset: sourceOffset, timestamp: timestamp, kind: .assistant,
          text: redacted.text + suffix, redactions: reasons)
      }
      guard let tool = tools.first else { return nil }
      return toolEntry(tool, sourceOffset: sourceOffset, timestamp: timestamp)
    default:
      return nil
    }
  }

  private static func copilot(
    _ record: [String: Any], sourceOffset: UInt64
  ) throws -> TranscriptEntry? {
    guard let type = record["type"] as? String else { return nil }
    let data = record["data"] as? [String: Any] ?? [:]
    let timestamp = (record["timestamp"] ?? data["timestamp"]) as? String
    switch type {
    case "user.message":
      return TranscriptEntry(
        sourceOffset: sourceOffset, timestamp: timestamp, kind: .prompt,
        text: "[redacted prompt]", redactions: [.prompt])
    case "assistant.message":
      let redacted = redact(data["content"] as? String ?? "")
      let reasons =
        data["model"] == nil ? redacted.reasons : redacted.reasons + [.modelMetadata]
      return redacted.text.isEmpty
        ? nil
        : TranscriptEntry(
          sourceOffset: sourceOffset, timestamp: timestamp, kind: .assistant,
          text: redacted.text, redactions: reasons)
    case "tool.execution_start":
      guard let name = data["toolName"] as? String else {
        throw TranscriptReadError.corrupt
      }
      return toolEntry(name, sourceOffset: sourceOffset, timestamp: timestamp)
    case "tool.execution_complete":
      return TranscriptEntry(
        sourceOffset: sourceOffset, timestamp: timestamp, kind: .toolResult,
        text: "[redacted tool result]", redactions: [.toolResult])
    case "assistant.turn_start", "assistant.turn_end", "permission.requested",
      "permission.completed", "session.start", "session.resume", "session.shutdown":
      return TranscriptEntry(
        sourceOffset: sourceOffset, timestamp: timestamp, kind: .status,
        text: type)
    default:
      return nil
    }
  }

  private static func codex(
    _ record: [String: Any], sourceOffset: UInt64
  ) throws -> TranscriptEntry? {
    guard let type = record["type"] as? String else { return nil }
    let payload = record["payload"] as? [String: Any] ?? [:]
    let timestamp = record["timestamp"] as? String
    switch type {
    case "event_msg":
      switch payload["type"] as? String {
      case "user_message":
        return TranscriptEntry(
          sourceOffset: sourceOffset, timestamp: timestamp, kind: .prompt,
          text: "[redacted prompt]", redactions: [.prompt])
      case "agent_message", "agent_reasoning":
        let redacted = redact(payload["text"] as? String ?? "")
        let reasons =
          payload["model"] == nil ? redacted.reasons : redacted.reasons + [.modelMetadata]
        return redacted.text.isEmpty
          ? nil
          : TranscriptEntry(
            sourceOffset: sourceOffset, timestamp: timestamp, kind: .assistant,
            text: redacted.text, redactions: reasons)
      case "task_complete":
        return TranscriptEntry(
          sourceOffset: sourceOffset, timestamp: timestamp, kind: .status,
          text: "task_complete")
      default:
        return nil
      }
    case "response_item":
      switch payload["type"] as? String {
      case "function_call", "custom_tool_call", "web_search_call":
        let name =
          payload["name"] as? String
          ?? (payload["type"] as? String == "web_search_call" ? "web_search" : nil)
        guard let name else { throw TranscriptReadError.corrupt }
        return toolEntry(name, sourceOffset: sourceOffset, timestamp: timestamp)
      case "function_call_output", "custom_tool_call_output":
        return TranscriptEntry(
          sourceOffset: sourceOffset, timestamp: timestamp, kind: .toolResult,
          text: "[redacted tool result]", redactions: [.toolResult])
      default:
        return nil
      }
    default:
      return nil
    }
  }

  private static func toolEntry(
    _ name: String, sourceOffset: UInt64, timestamp: String?
  ) -> TranscriptEntry {
    let safeName = name.isEmpty ? "tool" : name
    return TranscriptEntry(
      sourceOffset: sourceOffset, timestamp: timestamp, kind: .toolUse,
      text: "Used \(safeName) with redacted input",
      toolName: safeName,
      redactions: [.toolInput, .filesystemPath, .secret, .modelMetadata])
  }

  static func redact(_ value: String) -> (text: String, reasons: [TranscriptRedaction]) {
    var text = value
    var reasons: [TranscriptRedaction] = []
    func replace(_ pattern: String, with replacement: String, reason: TranscriptRedaction) {
      let updated = text.replacingOccurrences(
        of: pattern, with: replacement, options: [.regularExpression, .caseInsensitive])
      if updated != text {
        text = updated
        reasons.append(reason)
      }
    }
    replace(
      #"(authorization\s*[:=]\s*(?:bearer\s+)?|(?:api[_-]?key|token|secret|password)\s*[:=]\s*)[^\s,;]+"#,
      with: "$1[redacted secret]",
      reason: .secret)
    replace(
      #"\b(?:gh[pousr]_[A-Za-z0-9_]{12,}|github_pat_[A-Za-z0-9_]{12,}|sk-[A-Za-z0-9_-]{12,})\b"#,
      with: "[redacted secret]",
      reason: .secret)
    replace(
      #"(?:[A-Za-z]:\\(?:[^\\\r\n\t ]+\\)*[^\\\r\n\t ]+|~[/\\][^\s\"']+|/(?:[^/\s\"']+/)*[^/\s\"']+)"#,
      with: "[redacted path]",
      reason: .filesystemPath)
    return (text, Array(Set(reasons)).sorted { $0.rawValue < $1.rawValue })
  }
}
