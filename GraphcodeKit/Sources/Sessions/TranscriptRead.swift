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
  var data: Data
  var sourceWorkBytes: Int
  var remoteTransferBytes: Int
}
struct TranscriptCursor: Codable, Equatable, Sendable {
  var version: Int
  var nodeID: UUID
  var provider: CLISessionBackendKind
  var sourceIdentity: String
  var nextOffset: UInt64
  var prefixHash: String
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
      cursor.version == 2,
      cursor.prefixHash.count == 64,
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
  static let maximumReadableTranscriptBytes = 512 * 1024
  static let maximumSourceWorkBytes = maximumReadableTranscriptBytes * 2
  static let maximumRemoteTransferBytes =
    ((maximumReadableTranscriptBytes + 2) / 3) * 4 + 1024
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
      let chunk: TranscriptSourceChunk
      let localSource: LocalTranscriptSource?
      if let projectPath, let location = RemoteProjectLocation.parse(projectPath: projectPath) {
        chunk = try await remoteChunk(node: node, location: location)
        localSource = nil
      } else {
        let source = try localChunk(node: node, projectPath: projectPath)
        chunk = source.chunk
        localSource = source
      }
      let draft = try pageDraft(
        nodeID: node.id,
        provider: node.backend,
        query: query,
        cursor: cursor,
        chunk: chunk)
      var totalBytes = chunk.totalBytes
      if let localSource {
        totalBytes = try verifyLocalSnapshot(localSource)
      }
      return .success(try finalize(draft, source: chunk.data, totalBytes: totalBytes))
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
    let draft = try pageDraft(
      nodeID: nodeID, provider: provider, query: query, cursor: cursor, chunk: chunk)
    return try finalize(draft, source: chunk.data, totalBytes: chunk.totalBytes)
  }

  static func page(
    nodeID: UUID,
    provider: CLISessionBackendKind,
    query: TranscriptQuery,
    cursor: TranscriptCursor?,
    chunk: TranscriptSourceChunk,
    afterParse: () throws -> TranscriptSourceChunk
  ) throws -> TranscriptPage {
    let draft = try pageDraft(
      nodeID: nodeID, provider: provider, query: query, cursor: cursor, chunk: chunk)
    let current = try afterParse()
    try validateSnapshot(
      snapshot: chunk.data,
      currentPrefix: Data(current.data.prefix(chunk.data.count)),
      initialIdentity: chunk.identity,
      finalIdentity: current.identity,
      finalSize: current.totalBytes)
    guard chunk.sourceWorkBytes + current.sourceWorkBytes <= maximumSourceWorkBytes else {
      throw TranscriptReadError.oversized
    }
    return try finalize(draft, source: chunk.data, totalBytes: current.totalBytes)
  }

  private struct PageDraft {
    var nodeID: UUID
    var provider: CLISessionBackendKind
    var entries: [TranscriptEntry]
    var hasMore: Bool
    var nextOffset: UInt64
    var sourceIdentity: String
    var lastRecord: Data
  }

  private static func pageDraft(
    nodeID: UUID,
    provider: CLISessionBackendKind,
    query: TranscriptQuery,
    cursor: TranscriptCursor?,
    chunk: TranscriptSourceChunk
  ) throws -> PageDraft {
    guard chunk.data.count <= maximumReadableTranscriptBytes,
      chunk.sourceWorkBytes <= maximumSourceWorkBytes,
      chunk.remoteTransferBytes <= maximumRemoteTransferBytes
    else { throw TranscriptReadError.oversized }
    guard cursor?.sourceIdentity == nil || cursor?.sourceIdentity == chunk.identity
    else {
      throw TranscriptReadError.invalidCursor
    }

    let anchorLength = cursor?.anchorLength ?? 0
    let nextOffset = cursor?.nextOffset ?? 0
    guard nextOffset <= UInt64(chunk.data.count),
      nextOffset >= UInt64(anchorLength)
    else { throw TranscriptReadError.invalidCursor }
    if let cursor {
      let prefix = Data(chunk.data.prefix(Int(nextOffset)))
      let anchor = prefix.suffix(anchorLength)
      guard GraphcodeSHA256.hex(prefix) == cursor.prefixHash,
        hash(Data(anchor)) == cursor.anchorHash
      else {
        throw TranscriptReadError.invalidCursor
      }
    }

    let body = chunk.data.dropFirst(Int(nextOffset))
    var entries: [TranscriptEntry] = []
    var encodedEntriesBytes = 2
    var consumed = 0
    var lastRecord =
      cursor.map {
        Data(chunk.data.prefix(Int($0.nextOffset)).suffix($0.anchorLength))
      } ?? Data()
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
      let sourceOffset = nextOffset + UInt64(consumed)
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

    let servedThrough = nextOffset + UInt64(consumed)
    let hasMore = stoppedForBound || servedThrough < chunk.totalBytes
    return PageDraft(
      nodeID: nodeID,
      provider: provider,
      entries: entries,
      hasMore: hasMore,
      nextOffset: servedThrough,
      sourceIdentity: chunk.identity,
      lastRecord: lastRecord)
  }

  private static func finalize(
    _ draft: PageDraft,
    source: Data,
    totalBytes: UInt64
  ) throws -> TranscriptPage {
    let hasMore = draft.hasMore || draft.nextOffset < totalBytes
    let nextCursor: String?
    if hasMore {
      guard draft.nextOffset <= UInt64(source.count) else {
        throw TranscriptReadError.invalidCursor
      }
      let prefixHash = GraphcodeSHA256.hex(Data(source.prefix(Int(draft.nextOffset))))
      nextCursor = try TranscriptCursor(
        version: 2,
        nodeID: draft.nodeID,
        provider: draft.provider,
        sourceIdentity: draft.sourceIdentity,
        nextOffset: draft.nextOffset,
        prefixHash: prefixHash,
        anchorLength: draft.lastRecord.count,
        anchorHash: hash(draft.lastRecord)
      ).encoded()
    } else {
      nextCursor = nil
    }
    return TranscriptPage(
      nodeID: draft.nodeID,
      provider: draft.provider,
      entries: draft.entries,
      nextCursor: nextCursor,
      hasMore: hasMore)
  }

  private struct LocalTranscriptSource {
    var node: LoopNode
    var url: URL
    var identity: String
    var snapshot: Data
    var chunk: TranscriptSourceChunk
  }

  private static func localChunk(
    node: LoopNode,
    projectPath: String?
  ) throws -> LocalTranscriptSource {
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
    guard size <= UInt64(maximumReadableTranscriptBytes) else {
      throw TranscriptReadError.oversized
    }
    let handle: FileHandle
    do {
      handle = try FileHandle(forReadingFrom: url)
    } catch {
      throw TranscriptReadError.missing
    }
    defer { try? handle.close() }
    do {
      let data = try handle.read(upToCount: maximumReadableTranscriptBytes + 1) ?? Data()
      guard data.count <= maximumReadableTranscriptBytes else {
        throw TranscriptReadError.oversized
      }
      let identity = localIdentity(node: node, url: url, attributes: attributes)
      let chunk = TranscriptSourceChunk(
        identity: identity,
        totalBytes: UInt64(data.count),
        data: data,
        sourceWorkBytes: data.count,
        remoteTransferBytes: 0)
      return LocalTranscriptSource(
        node: node, url: url, identity: identity, snapshot: data, chunk: chunk)
    } catch let error as TranscriptReadError {
      throw error
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

  private static func verifyLocalSnapshot(_ source: LocalTranscriptSource) throws -> UInt64 {
    let handle = try FileHandle(forReadingFrom: source.url)
    defer { try? handle.close() }
    let prefix = try handle.read(upToCount: source.snapshot.count) ?? Data()
    let attributes = try FileManager.default.attributesOfItem(atPath: source.url.path)
    guard let size = (attributes[.size] as? NSNumber)?.uint64Value else {
      throw TranscriptReadError.corrupt
    }
    guard size <= UInt64(maximumReadableTranscriptBytes) else {
      throw TranscriptReadError.oversized
    }
    try validateSnapshot(
      snapshot: source.snapshot,
      currentPrefix: prefix,
      initialIdentity: source.identity,
      finalIdentity: localIdentity(node: source.node, url: source.url, attributes: attributes),
      finalSize: size)
    guard source.chunk.sourceWorkBytes + prefix.count <= maximumSourceWorkBytes else {
      throw TranscriptReadError.oversized
    }
    return size
  }

  static func validateSnapshot(
    snapshot: Data,
    currentPrefix: Data,
    initialIdentity: String,
    finalIdentity: String,
    finalSize: UInt64
  ) throws {
    guard finalSize <= UInt64(maximumReadableTranscriptBytes) else {
      throw TranscriptReadError.oversized
    }
    guard snapshot == currentPrefix,
      initialIdentity == finalIdentity,
      finalSize >= UInt64(snapshot.count)
    else { throw TranscriptReadError.invalidCursor }
  }

  private static func localURL(node: LoopNode, projectPath: String?) throws -> URL {
    switch node.backend {
    case .claudeCode:
      guard let projectPath,
        let sessionID = SessionIDStore.load(forNodeID: node.id),
        let url = ClaudeSessionLog.transcript(
          forSessionID: sessionID,
          projectPath: node.worktreeBinding?.worktreePath ?? projectPath)
      else { throw TranscriptReadError.missing }
      return url
    case .copilotCLI:
      let name = SurfaceRef(id: node.id, launchesClaudeCode: true).zmxSessionName
      guard let directory = CopilotSessionLog.directory(forSessionNamed: name) else {
        throw TranscriptReadError.missing
      }
      return directory.appendingPathComponent("events.jsonl")
    case .codex:
      guard let banked = SessionIDStore.load(forNodeID: node.id),
        let rollout = codexLocalURL(
          nodeID: node.id,
          banked: banked,
          projectPath: projectPath,
          database: CodexThreadResolver.stateDatabase())
      else { throw TranscriptReadError.missing }
      return rollout
    case .openCode, .pi:
      throw TranscriptReadError.unsupportedProvider
    }
  }

  static func codexLocalURL(
    nodeID: UUID,
    banked: String?,
    projectPath: String? = nil,
    database: URL?,
    rollouts: [URL]? = nil
  ) -> URL? {
    guard let banked else { return nil }
    let threadID =
      database.map {
        CodexThreadResolver.threadID(
          forNodeID: nodeID, banked: banked, projectPath: projectPath, database: $0)
      } ?? banked
    guard let threadID else { return nil }
    return CodexSessionLog.rollout(forThreadID: threadID, among: rollouts)
  }

  private static func remoteChunk(
    node: LoopNode,
    location: RemoteProjectLocation
  ) async throws -> TranscriptSourceChunk {
    let find = remoteFind(node: node, location: location)
    let program = RemoteProjectLocation.shellQuoted(remoteSnapshotProgram)
    let script = [
      find,
      "if [ -z \"$F\" ] || [ ! -f \"$F\" ]; then echo '\(remoteMarker) missing'; exit 0; fi",
      "python3 -c \(program) \"$F\" \(maximumReadableTranscriptBytes)",
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
    return try decodeRemoteSnapshotMarker(marker, node: node)
  }

  static func decodeRemoteSnapshotMarker(
    _ marker: String,
    node: LoopNode
  ) throws -> TranscriptSourceChunk {
    let fields = marker.dropFirst(remoteMarker.count).split(separator: " ", maxSplits: 5)
      .map(String.init)
    switch fields.first {
    case "missing": throw TranscriptReadError.missing
    case "oversized": throw TranscriptReadError.oversized
    case "corrupt": throw TranscriptReadError.corrupt
    case "cursor": throw TranscriptReadError.invalidCursor
    case "data":
      guard fields.count == 5,
        let total = UInt64(fields[2]),
        let work = Int(fields[3]),
        work <= maximumSourceWorkBytes,
        let data = Data(base64Encoded: fields[4]),
        data.count <= maximumReadableTranscriptBytes,
        marker.utf8.count <= maximumRemoteTransferBytes
      else { throw TranscriptReadError.corrupt }
      return TranscriptSourceChunk(
        identity: hash(Data("\(node.backend.rawValue)|\(node.id)|\(fields[1])".utf8)),
        totalBytes: total,
        data: data,
        sourceWorkBytes: work,
        remoteTransferBytes: marker.utf8.count)
    default:
      throw TranscriptReadError.transportFailure
    }
  }

  static func remoteFind(node: LoopNode, location: RemoteProjectLocation) -> String {
    switch node.backend {
    case .claudeCode:
      return ClaudeSessionLog.remoteFindExpression(for: node, at: location)
    case .copilotCLI:
      let name = SurfaceRef(id: node.id, launchesClaudeCode: true).zmxSessionName
      return
        "F=''; for d in $(ls -t \"$HOME/.copilot/session-state/\" 2>/dev/null); do "
        + "if grep -qx 'name: \(name)' \"$HOME/.copilot/session-state/$d/workspace.yaml\" 2>/dev/null; "
        + "then F=\"$HOME/.copilot/session-state/$d/events.jsonl\"; break; fi; done"
    case .codex:
      let idFile = PresenceHooks.remoteSessionIDExpression(forNodeID: node.id)
      let program = RemoteProjectLocation.shellQuoted(remoteCodexResolverProgram)
      let nodeID = RemoteProjectLocation.shellQuoted(node.id.uuidString.lowercased())
      let marker = RemoteProjectLocation.shellQuoted(
        RemoteGraphAccess.promptPath(forProjectPath: location.projectPath, nodeID: node.id))
      return
        "F=$(python3 -c \(program) \(idFile) \"$HOME/.codex\" "
        + "\"$HOME/.codex/sessions\" \(nodeID) \(marker) 2>/dev/null)"
    case .openCode, .pi:
      return "F=''"
    }
  }

  static let remoteCodexResolverProgram = """
    import os, re, sqlite3, sys, uuid
    id_file, codex_root, sessions_root, node_id, launch_marker = sys.argv[1:6]
    uuid_pattern = re.compile(r"^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$")

    def canonical(value):
        if not isinstance(value, str) or uuid_pattern.fullmatch(value) is None:
            return None
        try:
            return str(uuid.UUID(value))
        except ValueError:
            return None

    try:
        with open(id_file, "r", encoding="ascii") as source:
            banked = source.read(128)
    except (OSError, UnicodeError):
        raise SystemExit

    banked = canonical(banked)
    node_id = canonical(node_id)
    if banked is None or node_id is None:
        raise SystemExit

    versions = []
    try:
        for name in os.listdir(codex_root):
            match = re.fullmatch(r"state_([0-9]+)\\.sqlite", name)
            if match:
                versions.append((int(match.group(1)), os.path.join(codex_root, name)))
    except OSError:
        pass

    thread_id = banked
    if versions:
        database_path = max(versions)[1]
        try:
            with sqlite3.connect("file:" + database_path + "?mode=ro", uri=True) as database:
                row = database.execute(
                    "SELECT id FROM threads WHERE id = ? LIMIT 1", (banked,)
                ).fetchone()
                if row is None:
                    rows = database.execute(
                        "SELECT id FROM threads WHERE instr(first_user_message, ?) > 0 LIMIT 2",
                        (launch_marker,),
                    ).fetchall()
                    if len(rows) != 1:
                        raise SystemExit
                    row = rows[0]
                if row is None:
                    raise SystemExit
                thread_id = canonical(row[0])
        except (sqlite3.Error, TypeError, ValueError):
            raise SystemExit
        if thread_id is None:
            raise SystemExit

    suffix = "-" + thread_id + ".jsonl"
    try:
        for directory, _, names in os.walk(sessions_root):
            for name in names:
                if name.startswith("rollout-") and name.endswith(suffix):
                    print(os.path.join(directory, name))
                    raise SystemExit
    except OSError:
        pass
    """

  static let remoteSnapshotProgram = """
    import base64, os, sys
    marker = "\(remoteMarker)"
    path = sys.argv[1]
    limit = int(sys.argv[2])
    try:
        before = os.stat(path)
        if before.st_size > limit:
            print(marker + " oversized")
            raise SystemExit
        with open(path, "rb") as source:
            snapshot = source.read(limit + 1)
        if len(snapshot) > limit:
            print(marker + " oversized")
            raise SystemExit
        with open(path, "rb") as source:
            current = source.read(len(snapshot))
        after = os.stat(path)
        if (before.st_dev, before.st_ino) != (after.st_dev, after.st_ino):
            print(marker + " cursor")
        elif current != snapshot or after.st_size < len(snapshot):
            print(marker + " cursor")
        elif after.st_size > limit:
            print(marker + " oversized")
        else:
            identity = str(after.st_dev) + ":" + str(after.st_ino)
            work = len(snapshot) + len(current)
            encoded = base64.b64encode(snapshot).decode("ascii")
            print(marker + " data " + identity + " " + str(after.st_size) + " " + str(work) + " " + encoded)
    except (OSError, ValueError):
        print(marker + " corrupt")
    """

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
    let timestamp = sanitizedTimestamp(record["timestamp"])
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
        var reasons = redact(text).reasons
        if !tools.isEmpty { reasons.append(.toolInput) }
        if message["model"] != nil || record["model"] != nil {
          reasons.append(.modelMetadata)
        }
        return TranscriptEntry(
          sourceOffset: sourceOffset, timestamp: timestamp, kind: .assistant,
          text: tools.isEmpty
            ? "[redacted assistant text]"
            : "[redacted assistant text]\n[used tool with redacted input]",
          redactions: reasons + [.filesystemPath, .secret])
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
    let timestamp = sanitizedTimestamp(record["timestamp"] ?? data["timestamp"])
    switch type {
    case "user.message":
      return TranscriptEntry(
        sourceOffset: sourceOffset, timestamp: timestamp, kind: .prompt,
        text: "[redacted prompt]", redactions: [.prompt])
    case "assistant.message":
      let content = data["content"] as? String ?? ""
      let redacted = redact(content)
      let reasons =
        data["model"] == nil ? redacted.reasons : redacted.reasons + [.modelMetadata]
      return content.isEmpty
        ? nil
        : TranscriptEntry(
          sourceOffset: sourceOffset, timestamp: timestamp, kind: .assistant,
          text: "[redacted assistant text]",
          redactions: reasons + [.filesystemPath, .secret])
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
    let timestamp = sanitizedTimestamp(record["timestamp"])
    switch type {
    case "event_msg":
      switch payload["type"] as? String {
      case "user_message":
        return TranscriptEntry(
          sourceOffset: sourceOffset, timestamp: timestamp, kind: .prompt,
          text: "[redacted prompt]", redactions: [.prompt])
      case "agent_message", "agent_reasoning":
        let content = payload["text"] as? String ?? ""
        let redacted = redact(content)
        let reasons =
          payload["model"] == nil ? redacted.reasons : redacted.reasons + [.modelMetadata]
        return content.isEmpty
          ? nil
          : TranscriptEntry(
            sourceOffset: sourceOffset, timestamp: timestamp, kind: .assistant,
            text: "[redacted assistant text]",
            redactions: reasons + [.filesystemPath, .secret])
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
    let safeName = sanitizedToolName(name)
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
      #"-----BEGIN(?: [A-Z0-9]+)? PRIVATE KEY-----[\s\S]*?-----END(?: [A-Z0-9]+)? PRIVATE KEY-----"#,
      with: "[redacted secret]",
      reason: .secret)
    replace(
      #"(authorization\s*[:=]\s*(?:bearer|basic)?\s*|(?:api[_-]?key|access[_-]?key|secret(?:[_-]?access)?[_-]?key|session[_-]?token|token|secret|password)\s*[:=]\s*)[\"']?[^\s,;\"']+"#,
      with: "$1[redacted secret]",
      reason: .secret)
    replace(
      #"\b(?:AKIA|ASIA)[A-Z0-9]{16}\b|\b(?:gh[pousr]_[A-Za-z0-9_]{12,}|github_pat_[A-Za-z0-9_]{12,}|sk-[A-Za-z0-9_-]{12,}|(?:azd|ado|azure)[_-]?[A-Za-z0-9_-]{20,})\b|\b[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}\b"#,
      with: "[redacted secret]",
      reason: .secret)
    replace(
      #"(?i)\b[a-z][a-z0-9+.-]*://[^/\s:@]+:[^@\s/]+@"#,
      with: "[redacted secret]@",
      reason: .secret)
    replace(
      #"(?:(?:\"[A-Za-z]:\\[^\"\r\n]+\")|(?:'[A-Za-z]:\\[^'\r\n]+')|(?:[A-Za-z]:\\(?:[^\\\r\n]+\\)*[^\\\r\n]+)|(?:\"/(?:[^\"\r\n]+)\")|(?:'/(?:[^'\r\n]+)')|(?:~[/\\][^\r\n,;]+)|(?:/(?:[^/\r\n]+/)+[^/\r\n,;]+))"#,
      with: "[redacted path]",
      reason: .filesystemPath)
    return (text, Array(Set(reasons)).sorted { $0.rawValue < $1.rawValue })
  }

  private static func sanitizedTimestamp(_ value: Any?) -> String? {
    guard let value = value as? String,
      value.range(
        of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z$"#,
        options: .regularExpression) != nil
    else { return nil }
    return value
  }

  private static func sanitizedToolName(_ value: String) -> String {
    let allowed = Set([
      "Read", "Write", "Edit", "Glob", "Grep", "Bash", "Task", "WebFetch", "WebSearch",
      "view", "shell", "shell_command", "local_shell", "container.exec", "read_file",
      "update_plan", "apply_patch", "web_search",
    ])
    return allowed.contains(value) ? value : "tool"
  }
}
