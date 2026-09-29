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
      data.count <= NodeResourceReader.maximumCursorBytes,
      let cursor = try? JSONDecoder().decode(Self.self, from: data),
      cursor.version == 1,
      cursor.snapshotHash.count == 64,
      cursor.nextEnd <= cursor.snapshotExtent,
      cursor.snapshotExtent <= UInt64(NodeResourceReader.maximumReadableExtentBytes)
    else {
      throw NodeResourceReadError.invalidCursor
    }
    return cursor
  }
}
public enum NodeResourceReader {
  static let maximumReadableExtentBytes = 512 * 1024
  static let maximumSourceWorkBytes = maximumReadableExtentBytes * 2
  static let maximumEntryBytes = 64 * 1024
  static let maximumCursorBytes = 4 * 1024

  public static func read(
    node: LoopNode,
    projectPath: String,
    query: NodeResourceQuery,
    baseURL: URL = SupportDirectory.url
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
              decode: decodeMemoryEntry)
          case .playbookCurrent:
            return try readCurrentPlaybook(
              nodeID: node.id, projectPath: projectPath, query: query, baseURL: baseURL)
          case .playbookHistory:
            return try readEntries(
              nodeID: node.id,
              projectPath: projectPath,
              resource: .playbookHistory,
              url: NodeMemory.playbookHistoryURL(
                forProjectPath: projectPath, nodeID: node.id, baseURL: baseURL),
              query: query,
              missingIsEmpty: true,
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
    baseURL: URL
  ) throws -> NodeResourcePage {
    let url = NodeMemory.playbookURL(
      forProjectPath: projectPath, nodeID: nodeID, baseURL: baseURL)
    let snapshots = try NodeMemory.playbookSnapshotURLs(
      forProjectPath: projectPath, nodeID: nodeID, baseURL: baseURL)
    guard FileManager.default.fileExists(atPath: url.path) else {
      return NodeResourcePage(
        nodeID: nodeID,
        resource: query.resource,
        currentPlaybook: CurrentPlaybookState(
          content: nil, rollbackAvailable: !snapshots.isEmpty))
    }
    let data = try boundedData(at: url, maximumBytes: NodeMemory.maxPlaybookBytes + 1)
    guard data.count <= NodeMemory.maxPlaybookBytes,
      let text = String(data: data, encoding: .utf8)
    else {
      throw data.count > NodeMemory.maxPlaybookBytes
        ? NodeResourceReadError.oversized : NodeResourceReadError.corrupt
    }
    let normalized = normalize(text)
    guard normalized.text.utf8.count <= query.maxBytes else {
      throw NodeResourceReadError.oversized
    }
    return NodeResourcePage(
      nodeID: nodeID,
      resource: query.resource,
      currentPlaybook: CurrentPlaybookState(
        content: normalized.text.isEmpty ? nil : normalized.text,
        redactions: normalized.redactions,
        rollbackAvailable: !snapshots.isEmpty))
  }

  private static func readEntries(
    nodeID: UUID,
    projectPath: String,
    resource: NodeResourceKind,
    url: URL,
    query: NodeResourceQuery,
    missingIsEmpty: Bool = false,
    decode: (Data, UInt64) throws -> NodeResourceEntry
  ) throws -> NodeResourcePage {
    let projectIdentity = GraphcodeSHA256.hex(Data(projectPath.utf8))
    let cursor = try query.cursor.map(NodeResourceCursor.decode)
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
      snapshot = try resourceSnapshot(at: url, frozenExtent: cursor?.snapshotExtent)
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
      let line = Data(snapshot.data[range])
      let entry = try decode(line, UInt64(range.lowerBound))
      let encodedEntryBytes = try JSONEncoder().encode(entry).count
      guard encodedEntryBytes <= maximumEntryBytes, encodedEntryBytes <= query.maxBytes else {
        throw NodeResourceReadError.oversized
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
      next = UInt64(range.lowerBound)
    }

    let hasMore = stoppedForBound || next > 0
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
      ).encoded()
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
    frozenExtent: UInt64?
  ) throws -> ResourceSnapshot {
    let attributes: [FileAttributeKey: Any]
    do {
      attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    } catch {
      throw NodeResourceReadError.missing
    }
    guard let size = (attributes[.size] as? NSNumber)?.uint64Value else {
      throw NodeResourceReadError.corrupt
    }
    let requestedExtent = frozenExtent ?? size
    guard requestedExtent <= UInt64(maximumReadableExtentBytes) else {
      throw NodeResourceReadError.oversized
    }
    guard size >= requestedExtent else { throw NodeResourceReadError.invalidCursor }
    let handle: FileHandle
    do {
      handle = try FileHandle(forReadingFrom: url)
    } catch {
      throw NodeResourceReadError.missing
    }
    defer { try? handle.close() }
    let raw: Data
    do {
      raw = try handle.read(upToCount: Int(requestedExtent)) ?? Data()
    } catch {
      throw NodeResourceReadError.transportFailure
    }
    guard raw.count == Int(requestedExtent) else {
      throw NodeResourceReadError.invalidCursor
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

    let verification = try boundedPrefix(at: url, count: data.count)
    let finalAttributes = try FileManager.default.attributesOfItem(atPath: url.path)
    guard let finalSize = (finalAttributes[.size] as? NSNumber)?.uint64Value,
      finalSize >= UInt64(data.count),
      verification == data
    else {
      throw NodeResourceReadError.invalidCursor
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
      throw NodeResourceReadError.invalidCursor
    }
    guard raw.count + verification.count <= maximumSourceWorkBytes else {
      throw NodeResourceReadError.oversized
    }
    return ResourceSnapshot(identity: identity, data: data)
  }

  private static func boundedPrefix(at url: URL, count: Int) throws -> Data {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    return try handle.read(upToCount: count) ?? Data()
  }

  private static func boundedData(at url: URL, maximumBytes: Int) throws -> Data {
    let handle: FileHandle
    do {
      handle = try FileHandle(forReadingFrom: url)
    } catch {
      throw NodeResourceReadError.missing
    }
    defer { try? handle.close() }
    do {
      return try handle.read(upToCount: maximumBytes + 1) ?? Data()
    } catch {
      throw NodeResourceReadError.transportFailure
    }
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
