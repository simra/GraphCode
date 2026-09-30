import Foundation

public enum NodeResourceKind: Codable, Equatable, Sendable {
  case memory
  case playbookCurrent
  case playbookHistory
  case unsupported(String)

  public init(from decoder: Decoder) throws {
    let value = try decoder.singleValueContainer().decode(String.self)
    switch value {
    case "memory": self = .memory
    case "playbookCurrent": self = .playbookCurrent
    case "playbookHistory": self = .playbookHistory
    default: self = .unsupported(value)
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .memory: try container.encode("memory")
    case .playbookCurrent: try container.encode("playbookCurrent")
    case .playbookHistory: try container.encode("playbookHistory")
    case .unsupported(let value): try container.encode(value)
    }
  }
}
public enum NodeResourceEntryKind: String, Codable, Equatable, Sendable {
  case memory
  case refinement
  case rollback
}
public enum NodeResourceRedaction: String, Codable, Equatable, Sendable {
  case filesystemPath
  case secret
}
public struct NodeResourceEntry: Codable, Equatable, Sendable {
  public var sequence: UInt64
  public var timestamp: String
  public var kind: NodeResourceEntryKind
  public var content: String
  public var redactions: [NodeResourceRedaction]
  public var rollbackAvailable: Bool?

  public init(
    sequence: UInt64,
    timestamp: String,
    kind: NodeResourceEntryKind,
    content: String,
    redactions: [NodeResourceRedaction] = [],
    rollbackAvailable: Bool? = nil
  ) {
    self.sequence = sequence
    self.timestamp = timestamp
    self.kind = kind
    self.content = content
    self.redactions = Array(Set(redactions)).sorted { $0.rawValue < $1.rawValue }
    self.rollbackAvailable = rollbackAvailable
  }
}
public struct CurrentPlaybookState: Codable, Equatable, Sendable {
  public var content: String?
  public var redactions: [NodeResourceRedaction]
  public var rollbackAvailable: Bool

  public init(
    content: String?,
    redactions: [NodeResourceRedaction] = [],
    rollbackAvailable: Bool
  ) {
    self.content = content
    self.redactions = Array(Set(redactions)).sorted { $0.rawValue < $1.rawValue }
    self.rollbackAvailable = rollbackAvailable
  }
}
public struct NodeResourceQuery: Codable, Equatable, Sendable {
  public static let defaultEntryLimit = 16
  public static let maximumEntryLimit = 32
  public static let defaultByteLimit = 64 * 1024
  public static let maximumByteLimit = 128 * 1024

  public var nodeID: UUID
  public var resource: NodeResourceKind
  public var cursor: String?
  public var maxEntries: Int
  public var maxBytes: Int

  public init(
    nodeID: UUID,
    resource: NodeResourceKind,
    cursor: String? = nil,
    maxEntries: Int = defaultEntryLimit,
    maxBytes: Int = defaultByteLimit
  ) {
    self.nodeID = nodeID
    self.resource = resource
    self.cursor = cursor
    self.maxEntries = maxEntries
    self.maxBytes = maxBytes
  }

  public func validated() throws -> Self {
    guard (1...Self.maximumEntryLimit).contains(maxEntries),
      (1...Self.maximumByteLimit).contains(maxBytes)
    else {
      throw NodeResourceReadError.invalidBounds
    }
    if case .playbookCurrent = resource, cursor != nil {
      throw NodeResourceReadError.invalidCursor
    }
    return self
  }
}
public struct NodeResourcePage: Codable, Equatable, Sendable {
  public var nodeID: UUID
  public var resource: NodeResourceKind
  public var entries: [NodeResourceEntry]
  public var currentPlaybook: CurrentPlaybookState?
  public var nextCursor: String?
  public var hasMore: Bool

  public init(
    nodeID: UUID,
    resource: NodeResourceKind,
    entries: [NodeResourceEntry] = [],
    currentPlaybook: CurrentPlaybookState? = nil,
    nextCursor: String? = nil,
    hasMore: Bool = false
  ) {
    self.nodeID = nodeID
    self.resource = resource
    self.entries = entries
    self.currentPlaybook = currentPlaybook
    self.nextCursor = nextCursor
    self.hasMore = hasMore
  }
}
public enum NodeResourceReadError: String, Error, Equatable, Sendable {
  case unauthorized
  case missing
  case corrupt
  case oversized
  case invalidBounds
  case invalidCursor
  case unsupportedResource
  case transportFailure

  public var message: String {
    switch self {
    case .unauthorized: return "node memory access is not authorized for this connection"
    case .missing: return "the requested node memory resource is missing"
    case .corrupt: return "the requested node memory resource is corrupt"
    case .oversized: return "a node memory entry or page exceeds the supported bound"
    case .invalidBounds: return "node memory bounds are outside the supported range"
    case .invalidCursor: return "the node memory cursor no longer matches the resource"
    case .unsupportedResource: return "this node memory resource is not supported"
    case .transportFailure: return "the node memory resource could not be read"
    }
  }
}
struct PlaybookHistoryRecord: Codable, Equatable, Sendable {
  var version: Int
  var timestamp: String
  var kind: NodeResourceEntryKind
  var content: String
  var rollbackAvailable: Bool
}
struct NodeResourceCursor: Codable, Equatable, Sendable {
  var version: Int
  var projectIdentity: String
  var nodeID: UUID
  var resource: NodeResourceKind
  var sourceIdentity: String
  var snapshotExtent: UInt64
  var nextEnd: UInt64
  var snapshotHash: String

  func encoded(authenticationKey: Data) throws -> String {
    let payload = try JSONEncoder().encode(self)
    let signature = NodeResourceCursorAuthentication.hmacSHA256(
      key: authenticationKey, message: payload)
    let value =
      NodeResourceCursorAuthentication.base64URL(payload) + "."
      + NodeResourceCursorAuthentication.base64URL(signature)
    guard value.utf8.count <= NodeResourceReader.maximumEncodedCursorBytes else {
      throw NodeResourceReadError.oversized
    }
    return value
  }

  static func decode(_ value: String, authenticationKey: Data) throws -> Self {
    guard value.utf8.count <= NodeResourceReader.maximumEncodedCursorBytes else {
      throw NodeResourceReadError.invalidCursor
    }
    let parts = value.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 2,
      let payload = NodeResourceCursorAuthentication.decodeBase64URL(String(parts[0])),
      payload.count <= NodeResourceReader.maximumCursorPayloadBytes,
      let suppliedSignature = NodeResourceCursorAuthentication.decodeBase64URL(String(parts[1])),
      suppliedSignature.count == NodeResourceCursorAuthentication.signatureBytes
    else {
      throw NodeResourceReadError.invalidCursor
    }
    let expectedSignature = NodeResourceCursorAuthentication.hmacSHA256(
      key: authenticationKey, message: payload)
    guard
      NodeResourceCursorAuthentication.constantTimeEqual(
        suppliedSignature, expectedSignature
      ),
      let cursor = try? JSONDecoder().decode(Self.self, from: payload),
      cursor.version == 1,
      cursor.snapshotHash.count == 64,
      cursor.sourceIdentity.count == 64,
      cursor.projectIdentity.count == 64,
      cursor.nextEnd <= cursor.snapshotExtent,
      cursor.snapshotExtent <= UInt64(NodeResourceReader.maximumReadableExtentBytes)
    else {
      throw NodeResourceReadError.invalidCursor
    }
    return cursor
  }
}

enum NodeResourceCursorAuthentication {
  static let signatureBytes = 32

  static func hmacSHA256(key: Data, message: Data) -> Data {
    let blockSize = 64
    let sourceKey = Array(
      key.count > blockSize ? GraphcodeSHA256.digest(key) : key)
    var outer = [UInt8](repeating: 0x5c, count: blockSize)
    var inner = [UInt8](repeating: 0x36, count: blockSize)
    for index in sourceKey.indices {
      outer[index] ^= sourceKey[index]
      inner[index] ^= sourceKey[index]
    }
    let innerDigest = GraphcodeSHA256.digest(Data(inner + Array(message)))
    return GraphcodeSHA256.digest(Data(outer + Array(innerDigest)))
  }

  static func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
    guard lhs.count == rhs.count else { return false }
    var difference: UInt8 = 0
    for index in lhs.indices {
      difference |= lhs[index] ^ rhs[index]
    }
    return difference == 0
  }

  static func base64URL(_ data: Data) -> String {
    data.base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  static func decodeBase64URL(_ value: String) -> Data? {
    guard !value.isEmpty,
      value.utf8.count % 4 != 1,
      value.utf8.allSatisfy({
        (0x30...0x39).contains($0)
          || (0x41...0x5a).contains($0)
          || (0x61...0x7a).contains($0)
          || $0 == 0x2d
          || $0 == 0x5f
      })
    else {
      return nil
    }
    var base64 = value.replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
    guard let decoded = Data(base64Encoded: base64),
      base64URL(decoded) == value
    else {
      return nil
    }
    return decoded
  }
}

struct NodeResourceFileAccess {
  var attributes: (URL) throws -> [FileAttributeKey: Any]
  var open: (URL) throws -> FileHandle
  var read: (FileHandle, Int) throws -> Data
  var close: (FileHandle) -> Void
  var contentsOfDirectory: (URL) throws -> [URL]

  static let live = NodeResourceFileAccess(
    attributes: { try FileManager.default.attributesOfItem(atPath: $0.path) },
    open: { try FileHandle(forReadingFrom: $0) },
    read: { try $0.read(upToCount: $1) ?? Data() },
    close: { try? $0.close() },
    contentsOfDirectory: {
      try FileManager.default.contentsOfDirectory(
        at: $0, includingPropertiesForKeys: nil)
    })
}

public enum NodeResourceReader {
  private static let posixNoSuchFile = 2
  static let maximumReadableExtentBytes = 512 * 1024
  static let maximumSourceWorkBytes = maximumReadableExtentBytes * 2
  static let maximumEntryBytes = 64 * 1024
  static let maximumCursorPayloadBytes = 4 * 1024
  static let maximumEncodedCursorBytes = 6 * 1024
  private static let processCursorAuthenticationKey: Data = {
    var generator = SystemRandomNumberGenerator()
    return Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
  }()

  public static func read(
    node: LoopNode,
    projectPath: String,
    query: NodeResourceQuery,
    baseURL: URL = SupportDirectory.url
  ) -> Result<NodeResourcePage, NodeResourceReadError> {
    read(
      node: node,
      projectPath: projectPath,
      query: query,
      baseURL: baseURL,
      fileAccess: .live,
      cursorAuthenticationKey: processCursorAuthenticationKey)
  }

  static func read(
    node: LoopNode,
    projectPath: String,
    query: NodeResourceQuery,
    baseURL: URL,
    fileAccess: NodeResourceFileAccess,
    cursorAuthenticationKey: Data
  ) -> Result<NodeResourcePage, NodeResourceReadError> {
    do {
      return .success(
        try NodeMemory.withStorageLock {
          let query = try query.validated()
          guard query.nodeID == node.id else { throw NodeResourceReadError.unauthorized }
          switch query.resource {
          case .memory:
            return try readEntries(
              nodeID: node.id,
              projectPath: projectPath,
              resource: .memory,
              url: NodeMemory.logURL(
                forProjectPath: projectPath, nodeID: node.id, baseURL: baseURL),
              query: query,
              fileAccess: fileAccess,
              cursorAuthenticationKey: cursorAuthenticationKey,
              decode: decodeMemoryEntry)
          case .playbookCurrent:
            return try readCurrentPlaybook(
              nodeID: node.id,
              projectPath: projectPath,
              query: query,
              baseURL: baseURL,
              fileAccess: fileAccess)
          case .playbookHistory:
            return try readEntries(
              nodeID: node.id,
              projectPath: projectPath,
              resource: .playbookHistory,
              url: NodeMemory.playbookHistoryURL(
                forProjectPath: projectPath, nodeID: node.id, baseURL: baseURL),
              query: query,
              missingIsEmpty: true,
              fileAccess: fileAccess,
              cursorAuthenticationKey: cursorAuthenticationKey,
              decode: decodeHistoryEntry)
          case .unsupported:
            throw NodeResourceReadError.unsupportedResource
          }
        })
    } catch let error as NodeResourceReadError {
      return .failure(error)
    } catch {
      return .failure(.transportFailure)
    }
  }

  private static func readCurrentPlaybook(
    nodeID: UUID,
    projectPath: String,
    query: NodeResourceQuery,
    baseURL: URL,
    fileAccess: NodeResourceFileAccess
  ) throws -> NodeResourcePage {
    let url = NodeMemory.playbookURL(
      forProjectPath: projectPath, nodeID: nodeID, baseURL: baseURL)
    let rollbackAvailable = try hasPlaybookSnapshot(
      beside: url, fileAccess: fileAccess)
    let data: Data
    do {
      data = try boundedData(
        at: url,
        maximumBytes: NodeMemory.maxPlaybookBytes,
        fileAccess: fileAccess)
    } catch NodeResourceReadError.missing {
      let page = NodeResourcePage(
        nodeID: nodeID,
        resource: query.resource,
        currentPlaybook: CurrentPlaybookState(
          content: nil, rollbackAvailable: rollbackAvailable))
      try validateCurrentPlaybookPage(page, maximumBytes: query.maxBytes)
      return page
    }
    guard data.count <= NodeMemory.maxPlaybookBytes,
      let text = String(data: data, encoding: .utf8)
    else {
      throw data.count > NodeMemory.maxPlaybookBytes
        ? NodeResourceReadError.oversized : NodeResourceReadError.corrupt
    }
    let normalized = normalize(text)
    let page = NodeResourcePage(
      nodeID: nodeID,
      resource: query.resource,
      currentPlaybook: CurrentPlaybookState(
        content: normalized.text.isEmpty ? nil : normalized.text,
        redactions: normalized.redactions,
        rollbackAvailable: rollbackAvailable))
    try validateCurrentPlaybookPage(page, maximumBytes: query.maxBytes)
    return page
  }

  private static func readEntries(
    nodeID: UUID,
    projectPath: String,
    resource: NodeResourceKind,
    url: URL,
    query: NodeResourceQuery,
    missingIsEmpty: Bool = false,
    fileAccess: NodeResourceFileAccess,
    cursorAuthenticationKey: Data,
    decode: (Data, UInt64) throws -> NodeResourceEntry
  ) throws -> NodeResourcePage {
    let projectIdentity = GraphcodeSHA256.hex(Data(projectPath.utf8))
    let cursor = try query.cursor.map {
      try NodeResourceCursor.decode(
        $0, authenticationKey: cursorAuthenticationKey)
    }
    if let cursor {
      guard cursor.projectIdentity == projectIdentity,
        cursor.nodeID == nodeID,
        cursor.resource == resource
      else {
        throw NodeResourceReadError.invalidCursor
      }
    }

    let snapshot: ResourceSnapshot
    do {
      snapshot = try resourceSnapshot(
        at: url,
        frozenExtent: cursor?.snapshotExtent,
        fileAccess: fileAccess)
    } catch NodeResourceReadError.missing where missingIsEmpty && cursor == nil {
      return NodeResourcePage(nodeID: nodeID, resource: resource)
    }
    if let cursor {
      guard cursor.sourceIdentity == snapshot.identity,
        cursor.snapshotExtent == UInt64(snapshot.data.count),
        GraphcodeSHA256.hex(snapshot.data) == cursor.snapshotHash
      else {
        throw NodeResourceReadError.invalidCursor
      }
    }

    let snapshotExtent = UInt64(snapshot.data.count)
    let nextEnd = cursor?.nextEnd ?? snapshotExtent
    guard nextEnd <= snapshotExtent else { throw NodeResourceReadError.invalidCursor }
    let ranges = completeLineRanges(in: snapshot.data, through: Int(nextEnd))
    var entries: [NodeResourceEntry] = []
    var encodedEntriesBytes = 2
    var next = nextEnd
    var stoppedForBound = false

    for range in ranges.reversed() {
      if entries.count == query.maxEntries {
        stoppedForBound = true
        break
      }
      let line = Data(snapshot.data[range])
      let entry = try decode(line, UInt64(range.lowerBound))
      let encodedEntryBytes = try JSONEncoder().encode(entry).count
      guard encodedEntryBytes <= maximumEntryBytes else {
        throw NodeResourceReadError.oversized
      }
      let separatorBytes = entries.isEmpty ? 0 : 1
      let candidateBytes = encodedEntriesBytes + separatorBytes + encodedEntryBytes
      if candidateBytes > query.maxBytes {
        guard !entries.isEmpty else { throw NodeResourceReadError.oversized }
        stoppedForBound = true
        break
      }
      entries.append(entry)
      encodedEntriesBytes = candidateBytes
      next = UInt64(range.lowerBound)
    }

    let hasMore = stoppedForBound || next > 0
    if hasMore {
      guard next < nextEnd else { throw NodeResourceReadError.oversized }
    }
    let nextCursor =
      hasMore
      ? try NodeResourceCursor(
        version: 1,
        projectIdentity: projectIdentity,
        nodeID: nodeID,
        resource: resource,
        sourceIdentity: snapshot.identity,
        snapshotExtent: snapshotExtent,
        nextEnd: next,
        snapshotHash: GraphcodeSHA256.hex(snapshot.data)
      ).encoded(authenticationKey: cursorAuthenticationKey)
      : nil
    return NodeResourcePage(
      nodeID: nodeID,
      resource: resource,
      entries: entries,
      nextCursor: nextCursor,
      hasMore: hasMore)
  }

  private struct ResourceSnapshot {
    var identity: String
    var data: Data
  }

  private static func resourceSnapshot(
    at url: URL,
    frozenExtent: UInt64?,
    fileAccess: NodeResourceFileAccess
  ) throws -> ResourceSnapshot {
    let attributes: [FileAttributeKey: Any]
    do {
      attributes = try fileAccess.attributes(url)
    } catch {
      let classified = classifyFileError(error)
      throw frozenExtent != nil && classified == .missing ? .invalidCursor : classified
    }
    guard let size = (attributes[.size] as? NSNumber)?.uint64Value else {
      throw NodeResourceReadError.transportFailure
    }
    let requestedExtent = frozenExtent ?? size
    guard requestedExtent <= UInt64(maximumReadableExtentBytes) else {
      throw NodeResourceReadError.oversized
    }
    guard size >= requestedExtent else { throw NodeResourceReadError.invalidCursor }
    let handle: FileHandle
    do {
      handle = try fileAccess.open(url)
    } catch {
      let classified = classifyFileError(error)
      throw frozenExtent != nil && classified == .missing ? .invalidCursor : classified
    }
    defer { fileAccess.close(handle) }
    let raw: Data
    do {
      raw = try readUpToLimit(
        handle: handle,
        limit: Int(requestedExtent),
        fileAccess: fileAccess)
    } catch {
      throw NodeResourceReadError.transportFailure
    }
    guard raw.count == Int(requestedExtent) else {
      throw frozenExtent == nil
        ? NodeResourceReadError.transportFailure : NodeResourceReadError.invalidCursor
    }
    let completeExtent: Int
    if frozenExtent != nil {
      completeExtent = raw.count
    } else if raw.isEmpty {
      completeExtent = 0
    } else if raw.last == 0x0a {
      completeExtent = raw.count
    } else if let newline = raw.lastIndex(of: 0x0a) {
      _ = newline
      throw NodeResourceReadError.corrupt
    } else {
      throw NodeResourceReadError.corrupt
    }
    let data = Data(raw.prefix(completeExtent))
    let identityParts = [
      url.standardizedFileURL.path,
      String(describing: attributes[.systemNumber] ?? ""),
      String(describing: attributes[.systemFileNumber] ?? ""),
      String(describing: attributes[.creationDate] ?? ""),
    ]
    let identity = GraphcodeSHA256.hex(Data(identityParts.joined(separator: "|").utf8))

    let verification: Data
    do {
      verification = try boundedPrefix(
        at: url, count: data.count, fileAccess: fileAccess)
    } catch NodeResourceReadError.missing where frozenExtent != nil {
      throw NodeResourceReadError.invalidCursor
    }
    let finalAttributes: [FileAttributeKey: Any]
    do {
      finalAttributes = try fileAccess.attributes(url)
    } catch {
      let classified = classifyFileError(error)
      throw frozenExtent != nil && classified == .missing ? .invalidCursor : classified
    }
    guard let finalSize = (finalAttributes[.size] as? NSNumber)?.uint64Value else {
      throw NodeResourceReadError.transportFailure
    }
    guard finalSize >= UInt64(data.count), verification == data else {
      throw frozenExtent == nil
        ? NodeResourceReadError.transportFailure : NodeResourceReadError.invalidCursor
    }
    let finalIdentityParts = [
      url.standardizedFileURL.path,
      String(describing: finalAttributes[.systemNumber] ?? ""),
      String(describing: finalAttributes[.systemFileNumber] ?? ""),
      String(describing: finalAttributes[.creationDate] ?? ""),
    ]
    guard
      identity
        == GraphcodeSHA256.hex(Data(finalIdentityParts.joined(separator: "|").utf8))
    else {
      throw frozenExtent == nil
        ? NodeResourceReadError.transportFailure : NodeResourceReadError.invalidCursor
    }
    guard raw.count + verification.count <= maximumSourceWorkBytes else {
      throw NodeResourceReadError.oversized
    }
    return ResourceSnapshot(identity: identity, data: data)
  }

  private static func boundedPrefix(
    at url: URL,
    count: Int,
    fileAccess: NodeResourceFileAccess
  ) throws -> Data {
    let handle: FileHandle
    do {
      handle = try fileAccess.open(url)
    } catch {
      throw classifyFileError(error)
    }
    defer { fileAccess.close(handle) }
    do {
      return try readUpToLimit(
        handle: handle,
        limit: count,
        fileAccess: fileAccess)
    } catch {
      throw NodeResourceReadError.transportFailure
    }
  }

  private static func boundedData(
    at url: URL,
    maximumBytes: Int,
    fileAccess: NodeResourceFileAccess
  ) throws -> Data {
    let attributes: [FileAttributeKey: Any]
    do {
      attributes = try fileAccess.attributes(url)
    } catch {
      throw classifyFileError(error)
    }
    guard let size = (attributes[.size] as? NSNumber)?.uint64Value else {
      throw NodeResourceReadError.transportFailure
    }
    guard size <= UInt64(maximumBytes) else {
      throw NodeResourceReadError.oversized
    }
    let handle: FileHandle
    do {
      handle = try fileAccess.open(url)
    } catch {
      throw classifyFileError(error)
    }
    defer { fileAccess.close(handle) }
    do {
      let data = try readUpToLimit(
        handle: handle,
        limit: Int(size),
        fileAccess: fileAccess)
      guard data.count == Int(size) else {
        throw NodeResourceReadError.transportFailure
      }
      return data
    } catch {
      if let error = error as? NodeResourceReadError {
        throw error
      }
      throw NodeResourceReadError.transportFailure
    }
  }

  private static func readUpToLimit(
    handle: FileHandle,
    limit: Int,
    fileAccess: NodeResourceFileAccess
  ) throws -> Data {
    var data = Data()
    while data.count < limit {
      let remaining = limit - data.count
      let chunk = try fileAccess.read(handle, remaining)
      guard chunk.count <= remaining else {
        throw NodeResourceReadError.transportFailure
      }
      guard !chunk.isEmpty else { break }
      data.append(chunk)
    }
    return data
  }

  private static func validateCurrentPlaybookPage(
    _ page: NodeResourcePage,
    maximumBytes: Int
  ) throws {
    guard let state = page.currentPlaybook,
      try JSONEncoder().encode(state).count <= maximumBytes
    else {
      throw NodeResourceReadError.oversized
    }
  }

  private static func hasPlaybookSnapshot(
    beside playbookURL: URL,
    fileAccess: NodeResourceFileAccess
  ) throws -> Bool {
    do {
      return try fileAccess.contentsOfDirectory(playbookURL.deletingLastPathComponent())
        .contains { url in
          let name = url.lastPathComponent
          guard name.hasPrefix("PLAYBOOK."), name.hasSuffix(".md") else { return false }
          return Int(name.dropFirst("PLAYBOOK.".count).dropLast(".md".count)) != nil
        }
    } catch {
      if classifyFileError(error) == .missing {
        return false
      }
      throw NodeResourceReadError.transportFailure
    }
  }

  private static func classifyFileError(_ error: Error) -> NodeResourceReadError {
    let value = error as NSError
    if value.domain == NSCocoaErrorDomain
      && (value.code == NSFileNoSuchFileError || value.code == NSFileReadNoSuchFileError)
    {
      return .missing
    }
    if value.domain == NSPOSIXErrorDomain && value.code == posixNoSuchFile {
      return .missing
    }
    return .transportFailure
  }

  private static func completeLineRanges(
    in data: Data,
    through end: Int
  ) -> [Range<Int>] {
    guard end > 0 else { return [] }
    var ranges: [Range<Int>] = []
    var start = 0
    for index in 0..<min(end, data.count) where data[index] == 0x0a {
      ranges.append(start..<index)
      start = index + 1
    }
    return ranges
  }

  private static func decodeMemoryEntry(
    _ line: Data,
    sequence: UInt64
  ) throws -> NodeResourceEntry {
    guard line.count <= NodeMemory.maxEntryBytes + 64,
      let value = String(data: line, encoding: .utf8),
      let separator = value.range(of: "  ")
    else {
      throw line.count > NodeMemory.maxEntryBytes + 64
        ? NodeResourceReadError.oversized : NodeResourceReadError.corrupt
    }
    let timestamp = String(value[..<separator.lowerBound])
    guard ISO8601DateFormatter().date(from: timestamp) != nil else {
      throw NodeResourceReadError.corrupt
    }
    let normalized = normalize(String(value[separator.upperBound...]))
    return NodeResourceEntry(
      sequence: sequence,
      timestamp: timestamp,
      kind: .memory,
      content: normalized.text,
      redactions: normalized.redactions)
  }

  private static func decodeHistoryEntry(
    _ line: Data,
    sequence: UInt64
  ) throws -> NodeResourceEntry {
    guard line.count <= maximumEntryBytes,
      let record = try? JSONDecoder().decode(PlaybookHistoryRecord.self, from: line),
      record.version == 1,
      [.refinement, .rollback].contains(record.kind),
      ISO8601DateFormatter().date(from: record.timestamp) != nil
    else {
      throw line.count > maximumEntryBytes
        ? NodeResourceReadError.oversized : NodeResourceReadError.corrupt
    }
    let normalized = normalize(record.content)
    return NodeResourceEntry(
      sequence: sequence,
      timestamp: record.timestamp,
      kind: record.kind,
      content: normalized.text,
      redactions: normalized.redactions,
      rollbackAvailable: record.rollbackAvailable)
  }

  private static func normalize(
    _ value: String
  ) -> (text: String, redactions: [NodeResourceRedaction]) {
    let clean =
      value.unicodeScalars
      .filter { scalar in
        scalar == "\n" || scalar == "\t" || !CharacterSet.controlCharacters.contains(scalar)
      }
      .map(String.init)
      .joined()
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let redacted = TranscriptNormalizer.redact(clean)
    return (
      redacted.text,
      redacted.reasons.compactMap {
        switch $0 {
        case .filesystemPath: return .filesystemPath
        case .secret: return .secret
        case .prompt, .toolInput, .toolResult, .modelMetadata: return nil
        }
      }
    )
  }
}
