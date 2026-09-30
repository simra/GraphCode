import Foundation
import XCTest

@testable import GraphcodeKit

final class NodeResourceReadTests: XCTestCase {
  private let cursorAuthenticationKey = Data(repeating: 0x5a, count: 32)

  private func temporaryBase() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("node-resource-\(UUID())", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func node(_ id: UUID = UUID()) -> LoopNode {
    LoopNode(id: id, title: "Synthetic", loopType: .turnBased, firstInstruction: "test")
  }

  private func page(
    node: LoopNode,
    projectPath: String,
    resource: NodeResourceKind,
    baseURL: URL,
    cursor: String? = nil,
    maxEntries: Int = NodeResourceQuery.defaultEntryLimit,
    maxBytes: Int = NodeResourceQuery.defaultByteLimit,
    fileAccess: NodeResourceFileAccess = .live
  ) throws -> NodeResourcePage {
    switch NodeResourceReader.read(
      node: node,
      projectPath: projectPath,
      query: NodeResourceQuery(
        nodeID: node.id,
        resource: resource,
        cursor: cursor,
        maxEntries: maxEntries,
        maxBytes: maxBytes),
      baseURL: baseURL,
      fileAccess: fileAccess,
      cursorAuthenticationKey: cursorAuthenticationKey)
    {
    case .success(let page): return page
    case .failure(let error): throw error
    }
  }

  private func tamperingCursor(
    _ cursor: String,
    field: String,
    value: Any
  ) throws -> String {
    let parts = cursor.split(separator: ".", omittingEmptySubsequences: false)
    XCTAssertEqual(parts.count, 2)
    let payload = try XCTUnwrap(
      NodeResourceCursorAuthentication.decodeBase64URL(String(parts[0])))
    var object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: payload) as? [String: Any])
    object[field] = value
    let tamperedPayload = try JSONSerialization.data(withJSONObject: object)
    return NodeResourceCursorAuthentication.base64URL(tamperedPayload) + "."
      + String(parts[1])
  }

  private func data(hex: String) throws -> Data {
    guard hex.count.isMultiple(of: 2) else {
      throw NodeResourceReadError.corrupt
    }
    return try Data(
      stride(from: 0, to: hex.count, by: 2).map { offset in
        let start = hex.index(hex.startIndex, offsetBy: offset)
        let end = hex.index(start, offsetBy: 2)
        return try XCTUnwrap(UInt8(hex[start..<end], radix: 16))
      })
  }

  private func noncanonicalBase64URL(_ value: String) throws -> String {
    let alphabet = Array(
      "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
    let character = try XCTUnwrap(value.last)
    let index = try XCTUnwrap(alphabet.firstIndex(of: character))
    let replacementIndex = (index & ~3) | ((index + 1) & 3)
    XCTAssertNotEqual(index, replacementIndex)
    return String(value.dropLast()) + String(alphabet[replacementIndex])
  }

  private func assertInvalidCursor(
    _ cursor: String,
    node: LoopNode,
    projectPath: String,
    baseURL: URL,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    XCTAssertThrowsError(
      try page(
        node: node,
        projectPath: projectPath,
        resource: .memory,
        baseURL: baseURL,
        cursor: cursor),
      file: file,
      line: line
    ) {
      XCTAssertEqual(
        $0 as? NodeResourceReadError, .invalidCursor, file: file, line: line)
    }
  }

  func testNewestPagesFreezeExtentAcrossConcurrentAppend() throws {
    let base = try temporaryBase()
    defer { try? FileManager.default.removeItem(at: base) }
    let project = #"C:\synthetic\project"#
    let node = node()
    for value in 1...5 {
      NodeMemory.append(
        "entry-\(value)", projectPath: project, nodeID: node.id, baseURL: base)
    }

    let newest = try page(
      node: node,
      projectPath: project,
      resource: .memory,
      baseURL: base,
      maxEntries: 2)
    XCTAssertEqual(newest.entries.map(\.content), ["entry-5", "entry-4"])
    let cursor = try XCTUnwrap(newest.nextCursor)

    NodeMemory.append(
      "entry-6", projectPath: project, nodeID: node.id, baseURL: base)
    let older = try page(
      node: node,
      projectPath: project,
      resource: .memory,
      baseURL: base,
      cursor: cursor,
      maxEntries: 2)
    XCTAssertEqual(older.entries.map(\.content), ["entry-3", "entry-2"])
    let oldest = try page(
      node: node,
      projectPath: project,
      resource: .memory,
      baseURL: base,
      cursor: try XCTUnwrap(older.nextCursor),
      maxEntries: 2)
    XCTAssertEqual(oldest.entries.map(\.content), ["entry-1"])
    XCTAssertFalse(oldest.hasMore)

    let refreshed = try page(
      node: node, projectPath: project, resource: .memory, baseURL: base, maxEntries: 1)
    XCTAssertEqual(refreshed.entries.map(\.content), ["entry-6"])
  }

  func testCursorRejectsRewriteTruncateRegrowReplacementAndCrossResourceUse() throws {
    let base = try temporaryBase()
    defer { try? FileManager.default.removeItem(at: base) }
    let project = "/synthetic/project"
    let node = node()
    for value in 1...3 {
      NodeMemory.append(
        "entry-\(value)", projectPath: project, nodeID: node.id, baseURL: base)
    }
    let first = try page(
      node: node,
      projectPath: project,
      resource: .memory,
      baseURL: base,
      maxEntries: 1)
    let cursor = try XCTUnwrap(first.nextCursor)
    let log = NodeMemory.logURL(
      forProjectPath: project, nodeID: node.id, baseURL: base)
    var rewritten = try Data(contentsOf: log)
    rewritten[rewritten.startIndex + 30] ^= 1
    try rewritten.write(to: log, options: .atomic)
    XCTAssertThrowsError(
      try page(
        node: node,
        projectPath: project,
        resource: .memory,
        baseURL: base,
        cursor: cursor)
    ) { XCTAssertEqual($0 as? NodeResourceReadError, .invalidCursor) }

    try Data(rewritten.prefix(rewritten.count / 2)).write(to: log, options: .atomic)
    try rewritten.write(to: log, options: .atomic)
    XCTAssertThrowsError(
      try page(
        node: node,
        projectPath: project,
        resource: .memory,
        baseURL: base,
        cursor: cursor)
    ) { XCTAssertEqual($0 as? NodeResourceReadError, .invalidCursor) }

    XCTAssertThrowsError(
      try page(
        node: node,
        projectPath: project,
        resource: .playbookHistory,
        baseURL: base,
        cursor: cursor)
    ) { XCTAssertEqual($0 as? NodeResourceReadError, .invalidCursor) }
  }

  func testCursorAuthenticationRejectsEveryFieldAndSignatureTampering() throws {
    XCTAssertEqual(
      NodeResourceCursorAuthentication.hmacSHA256(
        key: Data(repeating: 0x0b, count: 20),
        message: Data("Hi There".utf8)),
      try data(
        hex: "b0344c61d8db38535ca8afceaf0bf12b"
          + "881dc200c9833da726e9376c2e32cff7"))
    XCTAssertEqual(
      GraphcodeSHA256.hex(Data(repeating: 0x61, count: 100)),
      "2816597888e4a0d3a36b82b83316ab32"
        + "680eb8f00f8cd3b904d681246d285a0e")

    let base = try temporaryBase()
    defer { try? FileManager.default.removeItem(at: base) }
    let project = "/synthetic/cursor-authentication"
    let node = node()
    for value in 1...3 {
      NodeMemory.append(
        "entry-\(value)", projectPath: project, nodeID: node.id, baseURL: base)
    }
    let first = try page(
      node: node,
      projectPath: project,
      resource: .memory,
      baseURL: base,
      maxEntries: 1)
    let cursor = try XCTUnwrap(first.nextCursor)
    let decoded = try NodeResourceCursor.decode(
      cursor, authenticationKey: cursorAuthenticationKey)

    let tamperedFields: [(String, Any)] = [
      ("version", 2),
      ("projectIdentity", String(repeating: "0", count: 64)),
      ("nodeID", UUID().uuidString),
      ("resource", "playbookHistory"),
      ("sourceIdentity", String(repeating: "1", count: 64)),
      ("snapshotExtent", decoded.snapshotExtent - 1),
      ("snapshotHash", String(repeating: "2", count: 64)),
    ]
    for (field, value) in tamperedFields {
      assertInvalidCursor(
        try tamperingCursor(cursor, field: field, value: value),
        node: node,
        projectPath: project,
        baseURL: base)
    }
    assertInvalidCursor(
      try tamperingCursor(cursor, field: "nextEnd", value: decoded.snapshotExtent),
      node: node,
      projectPath: project,
      baseURL: base)
    assertInvalidCursor(
      try tamperingCursor(cursor, field: "nextEnd", value: 0),
      node: node,
      projectPath: project,
      baseURL: base)

    let originalParts =
      cursor.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
    var parts = originalParts
    var signature = try XCTUnwrap(
      NodeResourceCursorAuthentication.decodeBase64URL(parts[1]))
    signature[signature.startIndex] ^= 1
    parts[1] = NodeResourceCursorAuthentication.base64URL(signature)
    assertInvalidCursor(
      parts.joined(separator: "."),
      node: node,
      projectPath: project,
      baseURL: base)
    parts = originalParts
    parts[1] = try noncanonicalBase64URL(parts[1])
    assertInvalidCursor(
      parts.joined(separator: "."),
      node: node,
      projectPath: project,
      baseURL: base)

    var payload = try XCTUnwrap(
      NodeResourceCursorAuthentication.decodeBase64URL(originalParts[0]))
    payload[payload.startIndex] ^= 1
    assertInvalidCursor(
      NodeResourceCursorAuthentication.base64URL(payload) + "." + originalParts[1],
      node: node,
      projectPath: project,
      baseURL: base)

    XCTAssertThrowsError(
      try NodeResourceCursor.decode(
        cursor, authenticationKey: Data(repeating: 0xa5, count: 32))
    ) { XCTAssertEqual($0 as? NodeResourceReadError, .invalidCursor) }
    XCTAssertLessThanOrEqual(
      cursor.utf8.count, NodeResourceReader.maximumEncodedCursorBytes)
  }

  func testEntryByteBoundsIncludeArrayOverheadAndAlwaysAdvanceCursor() throws {
    let base = try temporaryBase()
    defer { try? FileManager.default.removeItem(at: base) }
    let project = "/synthetic/page-byte-boundary"
    let node = node()
    NodeMemory.append(
      #"older "quoted" \ escaped 🧪漢字"#,
      projectPath: project,
      nodeID: node.id,
      baseURL: base)
    NodeMemory.append(
      #"newer "quoted" \ escaped 🧪漢字"#,
      projectPath: project,
      nodeID: node.id,
      baseURL: base)

    let complete = try page(
      node: node,
      projectPath: project,
      resource: .memory,
      baseURL: base)
    XCTAssertEqual(complete.entries.count, 2)
    let newestOnlyBytes = try JSONEncoder().encode([complete.entries[0]]).count
    let bothBytes = try JSONEncoder().encode(complete.entries).count
    XCTAssertGreaterThan(bothBytes, newestOnlyBytes)

    let bounded = try page(
      node: node,
      projectPath: project,
      resource: .memory,
      baseURL: base,
      maxBytes: newestOnlyBytes)
    XCTAssertEqual(bounded.entries, [complete.entries[0]])
    XCTAssertTrue(bounded.hasMore)
    let cursor = try XCTUnwrap(bounded.nextCursor)
    let cursorState = try NodeResourceCursor.decode(
      cursor, authenticationKey: cursorAuthenticationKey)
    XCTAssertLessThan(cursorState.nextEnd, cursorState.snapshotExtent)

    let older = try page(
      node: node,
      projectPath: project,
      resource: .memory,
      baseURL: base,
      cursor: cursor,
      maxBytes: newestOnlyBytes)
    XCTAssertEqual(older.entries, [complete.entries[1]])
    XCTAssertFalse(older.hasMore)

    let exactComplete = try page(
      node: node,
      projectPath: project,
      resource: .memory,
      baseURL: base,
      maxBytes: bothBytes)
    XCTAssertEqual(exactComplete.entries, complete.entries)
    XCTAssertFalse(exactComplete.hasMore)

    let oneByteTransition = try page(
      node: node,
      projectPath: project,
      resource: .memory,
      baseURL: base,
      maxBytes: bothBytes - 1)
    XCTAssertEqual(oneByteTransition.entries, [complete.entries[0]])
    XCTAssertTrue(oneByteTransition.hasMore)

    XCTAssertThrowsError(
      try page(
        node: node,
        projectPath: project,
        resource: .memory,
        baseURL: base,
        maxBytes: newestOnlyBytes - 1)
    ) { XCTAssertEqual($0 as? NodeResourceReadError, .oversized) }
  }

  func testEntryCountBoundaryDoesNotDecodeTheNextPage() throws {
    let base = try temporaryBase()
    defer { try? FileManager.default.removeItem(at: base) }
    let project = "/synthetic/count-boundary"
    let node = node()
    let log = NodeMemory.logURL(
      forProjectPath: project, nodeID: node.id, baseURL: base)
    try FileManager.default.createDirectory(
      at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
    let valid = "2026-09-30T16:00:00Z  newest\n"
    try Data(("not-a-memory-entry\n" + valid).utf8).write(to: log)

    let first = try page(
      node: node,
      projectPath: project,
      resource: .memory,
      baseURL: base,
      maxEntries: 1)
    XCTAssertEqual(first.entries.map(\.content), ["newest"])
    XCTAssertTrue(first.hasMore)
    XCTAssertThrowsError(
      try page(
        node: node,
        projectPath: project,
        resource: .memory,
        baseURL: base,
        cursor: try XCTUnwrap(first.nextCursor),
        maxEntries: 1)
    ) { XCTAssertEqual($0 as? NodeResourceReadError, .corrupt) }
  }

  func testCurrentPlaybookBoundsUseEncodedStateAtOneByteBoundary() throws {
    let base = try temporaryBase()
    defer { try? FileManager.default.removeItem(at: base) }
    let project = "/synthetic/current-playbook-boundary"
    let node = node()
    let content = """
      Keep "quotes", \\slashes,	tabs, and 🧪漢字.
      token=ghp_abcdefghijklmnopqrstuvwxyz123456 /Users/synthetic/private
      """
    XCTAssertTrue(
      NodeMemory.refinePlaybook(
        "Earlier", projectPath: project, nodeID: node.id, baseURL: base))
    XCTAssertTrue(
      NodeMemory.refinePlaybook(
        content, projectPath: project, nodeID: node.id, baseURL: base))

    let complete = try page(
      node: node,
      projectPath: project,
      resource: .playbookCurrent,
      baseURL: base)
    let state = try XCTUnwrap(complete.currentPlaybook)
    XCTAssertTrue(state.rollbackAvailable)
    XCTAssertFalse(state.redactions.isEmpty)
    let encodedStateBytes = try JSONEncoder().encode(state).count

    let exact = try page(
      node: node,
      projectPath: project,
      resource: .playbookCurrent,
      baseURL: base,
      maxBytes: encodedStateBytes)
    XCTAssertEqual(exact.currentPlaybook, state)
    XCTAssertThrowsError(
      try page(
        node: node,
        projectPath: project,
        resource: .playbookCurrent,
        baseURL: base,
        maxBytes: encodedStateBytes - 1)
    ) { XCTAssertEqual($0 as? NodeResourceReadError, .oversized) }
    XCTAssertLessThanOrEqual(
      try JSONEncoder().encode(
        DaemonWireEnvelope.response(
          id: UUID(), event: .nodeResourcePage(exact))
      ).count,
      FramedMessageIO.v2MaxPayloadBytes)
  }

  func testCurrentPlaybookAndRefinementRollbackHistoryAreDistinct() throws {
    let base = try temporaryBase()
    defer { try? FileManager.default.removeItem(at: base) }
    let project = "/synthetic/playbook"
    let node = node()

    let empty = try page(
      node: node,
      projectPath: project,
      resource: .playbookCurrent,
      baseURL: base)
    XCTAssertNil(empty.currentPlaybook?.content)
    XCTAssertFalse(try XCTUnwrap(empty.currentPlaybook).rollbackAvailable)

    XCTAssertTrue(
      NodeMemory.refinePlaybook(
        "First method", projectPath: project, nodeID: node.id, baseURL: base))
    XCTAssertTrue(
      NodeMemory.refinePlaybook(
        "Second method", projectPath: project, nodeID: node.id, baseURL: base))
    XCTAssertTrue(
      NodeMemory.rollbackPlaybook(
        projectPath: project, nodeID: node.id, baseURL: base))

    let current = try page(
      node: node,
      projectPath: project,
      resource: .playbookCurrent,
      baseURL: base)
    XCTAssertEqual(current.currentPlaybook?.content, "First method")
    XCTAssertFalse(try XCTUnwrap(current.currentPlaybook).rollbackAvailable)

    let history = try page(
      node: node,
      projectPath: project,
      resource: .playbookHistory,
      baseURL: base)
    XCTAssertEqual(history.entries.map(\.kind), [.rollback, .refinement, .refinement])
    XCTAssertEqual(
      history.entries.map(\.content),
      [
        "First method", "Second method", "First method",
      ])
    XCTAssertEqual(history.entries.first?.rollbackAvailable, false)
  }

  func testUnicodeRedactionAndFrameCeilingsStayBounded() throws {
    let base = try temporaryBase()
    defer { try? FileManager.default.removeItem(at: base) }
    let project = "/synthetic/unicode"
    let node = node()
    let unicode = String(repeating: "🧪漢字", count: 300)
    NodeMemory.append(
      "token=ghp_abcdefghijklmnopqrstuvwxyz123456 /Users/synthetic/private \(unicode)",
      projectPath: project,
      nodeID: node.id,
      baseURL: base)
    let memory = try page(
      node: node, projectPath: project, resource: .memory, baseURL: base)
    XCTAssertTrue(memory.entries[0].content.contains("[redacted secret]"))
    XCTAssertTrue(memory.entries[0].content.contains("[redacted path]"))
    XCTAssertLessThanOrEqual(
      try JSONEncoder().encode(
        DaemonWireEnvelope.response(
          id: UUID(), event: .nodeResourcePage(memory))
      ).count,
      FramedMessageIO.v2MaxPayloadBytes)

    let maximumPlaybook = String(
      repeating: "界", count: NodeMemory.maxPlaybookBytes / "界".utf8.count)
    XCTAssertTrue(
      NodeMemory.refinePlaybook(
        maximumPlaybook, projectPath: project, nodeID: node.id, baseURL: base))
    let current = try page(
      node: node,
      projectPath: project,
      resource: .playbookCurrent,
      baseURL: base,
      maxBytes: NodeResourceQuery.maximumByteLimit)
    XCTAssertLessThanOrEqual(
      try JSONEncoder().encode(
        DaemonWireEnvelope.response(
          id: UUID(), event: .nodeResourcePage(current))
      ).count,
      FramedMessageIO.v2MaxPayloadBytes)
  }

  func testMissingCorruptOversizedInvalidBoundsAndUnsupportedAreExplicit() throws {
    let base = try temporaryBase()
    defer { try? FileManager.default.removeItem(at: base) }
    let project = "/synthetic/errors"
    let node = node()

    XCTAssertThrowsError(
      try page(node: node, projectPath: project, resource: .memory, baseURL: base)
    ) { XCTAssertEqual($0 as? NodeResourceReadError, .missing) }

    let log = NodeMemory.logURL(
      forProjectPath: project, nodeID: node.id, baseURL: base)
    try FileManager.default.createDirectory(
      at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data([0xff, 0x0a]).write(to: log)
    XCTAssertThrowsError(
      try page(node: node, projectPath: project, resource: .memory, baseURL: base)
    ) { XCTAssertEqual($0 as? NodeResourceReadError, .corrupt) }

    try Data(repeating: 0x61, count: NodeResourceReader.maximumReadableExtentBytes + 1)
      .write(to: log)
    XCTAssertThrowsError(
      try page(node: node, projectPath: project, resource: .memory, baseURL: base)
    ) { XCTAssertEqual($0 as? NodeResourceReadError, .oversized) }

    let playbook = NodeMemory.playbookURL(
      forProjectPath: project, nodeID: node.id, baseURL: base)
    try Data([0xff]).write(to: playbook)
    XCTAssertThrowsError(
      try page(
        node: node,
        projectPath: project,
        resource: .playbookCurrent,
        baseURL: base)
    ) { XCTAssertEqual($0 as? NodeResourceReadError, .corrupt) }
    try Data(repeating: 0x61, count: NodeMemory.maxPlaybookBytes + 1).write(to: playbook)
    XCTAssertThrowsError(
      try page(
        node: node,
        projectPath: project,
        resource: .playbookCurrent,
        baseURL: base)
    ) { XCTAssertEqual($0 as? NodeResourceReadError, .oversized) }

    let history = NodeMemory.playbookHistoryURL(
      forProjectPath: project, nodeID: node.id, baseURL: base)
    try Data("not-json\n".utf8).write(to: history)
    XCTAssertThrowsError(
      try page(
        node: node,
        projectPath: project,
        resource: .playbookHistory,
        baseURL: base)
    ) { XCTAssertEqual($0 as? NodeResourceReadError, .corrupt) }

    XCTAssertThrowsError(
      try page(
        node: node,
        projectPath: project,
        resource: .playbookCurrent,
        baseURL: base,
        maxEntries: 0)
    ) { XCTAssertEqual($0 as? NodeResourceReadError, .invalidBounds) }
    XCTAssertThrowsError(
      try page(
        node: node,
        projectPath: project,
        resource: .unsupported("future"),
        baseURL: base)
    ) { XCTAssertEqual($0 as? NodeResourceReadError, .unsupportedResource) }
  }

  func testFileFailuresDistinguishConfirmedMissingFromTransportErrors() throws {
    enum SyntheticIOError: Error {
      case denied
      case sharingViolation
      case timeout
    }

    let base = try temporaryBase()
    defer { try? FileManager.default.removeItem(at: base) }
    let project = "/synthetic/io-errors"
    let node = node()
    NodeMemory.append(
      "fixture", projectPath: project, nodeID: node.id, baseURL: base)

    var missingStat = NodeResourceFileAccess.live
    missingStat.attributes = { _ in throw CocoaError(.fileNoSuchFile) }
    XCTAssertThrowsError(
      try page(
        node: node,
        projectPath: project,
        resource: .memory,
        baseURL: base,
        fileAccess: missingStat)
    ) { XCTAssertEqual($0 as? NodeResourceReadError, .missing) }

    var deniedStat = NodeResourceFileAccess.live
    deniedStat.attributes = { _ in throw SyntheticIOError.denied }
    XCTAssertThrowsError(
      try page(
        node: node,
        projectPath: project,
        resource: .memory,
        baseURL: base,
        fileAccess: deniedStat)
    ) { XCTAssertEqual($0 as? NodeResourceReadError, .transportFailure) }

    var missingMetadata = NodeResourceFileAccess.live
    missingMetadata.attributes = { _ in [:] }
    XCTAssertThrowsError(
      try page(
        node: node,
        projectPath: project,
        resource: .memory,
        baseURL: base,
        fileAccess: missingMetadata)
    ) { XCTAssertEqual($0 as? NodeResourceReadError, .transportFailure) }

    var deniedOpen = NodeResourceFileAccess.live
    deniedOpen.open = { _ in throw SyntheticIOError.sharingViolation }
    XCTAssertThrowsError(
      try page(
        node: node,
        projectPath: project,
        resource: .memory,
        baseURL: base,
        fileAccess: deniedOpen)
    ) { XCTAssertEqual($0 as? NodeResourceReadError, .transportFailure) }

    var failedRead = NodeResourceFileAccess.live
    failedRead.read = { _, _ in throw SyntheticIOError.timeout }
    XCTAssertThrowsError(
      try page(
        node: node,
        projectPath: project,
        resource: .memory,
        baseURL: base,
        fileAccess: failedRead)
    ) { XCTAssertEqual($0 as? NodeResourceReadError, .transportFailure) }

    var shortRead = NodeResourceFileAccess.live
    shortRead.read = { _, _ in Data() }
    XCTAssertThrowsError(
      try page(
        node: node,
        projectPath: project,
        resource: .memory,
        baseURL: base,
        fileAccess: shortRead)
    ) { XCTAssertEqual($0 as? NodeResourceReadError, .transportFailure) }

    var chunkedRead = NodeResourceFileAccess.live
    chunkedRead.read = { handle, count in
      try NodeResourceFileAccess.live.read(handle, min(count, 3))
    }
    XCTAssertEqual(
      try page(
        node: node,
        projectPath: project,
        resource: .memory,
        baseURL: base,
        fileAccess: chunkedRead
      ).entries.map(\.content),
      ["fixture"])

    var failedSnapshotListing = NodeResourceFileAccess.live
    failedSnapshotListing.contentsOfDirectory = { _ in throw SyntheticIOError.denied }
    XCTAssertThrowsError(
      try page(
        node: node,
        projectPath: project,
        resource: .playbookCurrent,
        baseURL: base,
        fileAccess: failedSnapshotListing)
    ) { XCTAssertEqual($0 as? NodeResourceReadError, .transportFailure) }
  }

  func testProjectTextCannotEscapeStorageAndLocationDoesNotChangeSemantics() throws {
    let base = try temporaryBase()
    defer { try? FileManager.default.removeItem(at: base) }
    let node = node()
    let projects = [
      #"C:\same-looking\project"#,
      #"ssh://user@host/C:\same-looking\project"#,
      #"codespace://fixture/C:\same-looking\project"#,
      #"../../';$(touch injected);*.txt"#,
    ]
    for (index, project) in projects.enumerated() {
      NodeMemory.append(
        "fixture-\(index)", projectPath: project, nodeID: node.id, baseURL: base)
      let result = try page(
        node: node, projectPath: project, resource: .memory, baseURL: base)
      XCTAssertEqual(result.entries.map(\.content), ["fixture-\(index)"])
      let directory = NodeMemory.directory(
        forProjectPath: project, nodeID: node.id, baseURL: base
      )
      .standardizedFileURL.path
      XCTAssertTrue(directory.hasPrefix(base.standardizedFileURL.path))
    }

    let collidingNode = self.node()
    let firstCollision = "/synthetic/a/b"
    let secondCollision = "/synthetic/a-b"
    XCTAssertEqual(
      SessionBriefing.slug(for: firstCollision),
      SessionBriefing.slug(for: secondCollision))
    NodeMemory.append(
      "first", projectPath: firstCollision, nodeID: collidingNode.id, baseURL: base)
    NodeMemory.append(
      "second", projectPath: secondCollision, nodeID: collidingNode.id, baseURL: base)
    XCTAssertEqual(
      try page(
        node: collidingNode,
        projectPath: firstCollision,
        resource: .memory,
        baseURL: base
      ).entries.map(\.content),
      ["first"])
    XCTAssertEqual(
      try page(
        node: collidingNode,
        projectPath: secondCollision,
        resource: .memory,
        baseURL: base
      ).entries.map(\.content),
      ["second"])
  }

  func testProtocolRoundTripsAndLegacyFramesRemainCompatible() throws {
    let query = NodeResourceQuery(
      nodeID: UUID(),
      resource: .playbookHistory,
      cursor: "opaque",
      maxEntries: 7,
      maxBytes: 32_000)
    let command = DaemonCommand.nodeResource(
      projectPath: #"C:\synthetic\project"#,
      query: query)
    let requestID = UUID()
    let encoded = try JSONEncoder().encode(
      DaemonWireEnvelope.request(id: requestID, command: command))
    guard case .v2(let decoded) = try DaemonWireProtocol.decodeClientFrame(encoded) else {
      return XCTFail("node resource request did not decode as v2")
    }
    XCTAssertEqual(decoded.requestID, requestID)
    XCTAssertEqual(decoded.command, command)

    let legacy = try JSONEncoder().encode(DaemonCommand.listRecentProjects)
    guard case .v1(let legacyCommand) = try DaemonWireProtocol.decodeClientFrame(legacy) else {
      return XCTFail("legacy command no longer decodes")
    }
    XCTAssertEqual(legacyCommand, .listRecentProjects)
  }

  func testRegistryFailsClosedOnAuthorityAndKeepsResponseNonBroadcast() async throws {
    let root = try temporaryBase()
    defer { try? FileManager.default.removeItem(at: root) }
    let project = root.appendingPathComponent("project", isDirectory: true)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    let reads = LockedValue(0)
    let registry = ProjectRegistry(
      persistenceDirectory: root.appendingPathComponent("support"),
      ensureSession: nil,
      terminateSession: nil,
      restartSession: nil,
      evaluatePredicate: nil,
      checkPredicate: nil,
      deliverMessage: nil,
      captureScript: nil,
      readUsage: nil,
      readGoalVerdict: nil,
      readActivity: nil,
      readSummary: nil,
      readPresence: nil,
      sessionAlive: nil,
      composeBoard: nil,
      readNodeResource: { node, _, query in
        reads.withValue { $0 += 1 }
        switch query.cursor {
        case "missing": return .failure(.missing)
        case "corrupt": return .failure(.corrupt)
        case "oversized": return .failure(.oversized)
        case "bounds": return .failure(.invalidBounds)
        case "cursor": return .failure(.invalidCursor)
        case "unsupported": return .failure(.unsupportedResource)
        case "transport": return .failure(.transportFailure)
        default: break
        }
        return .success(NodeResourcePage(nodeID: node.id, resource: query.resource))
      },
      persistsSynchronously: true)
    let owner = NodeResourceRecordingConnection()
    let replay = DaemonReplayStore(capacity: 8)
    let channel = DaemonConnectionChannel(
      connection: owner, mode: .v2(version: 2), clientID: UUID(), replayStore: replay)
    await registry.addConnection(id: owner.id, channel: channel)
    _ = await registry.apply(.openProject(path: project.path), connectionID: owner.id)
    let nodeID = UUID()
    _ = await registry.apply(
      .graphCommand(
        projectPath: project.path,
        command: .createNode(
          NodeDraft(
            id: nodeID,
            title: "Synthetic",
            loopType: .turnBased,
            firstInstruction: "test"))),
      connectionID: owner.id)

    let framesBefore = owner.frames.count
    let result = await registry.apply(
      .nodeResource(
        projectPath: project.path,
        query: NodeResourceQuery(nodeID: nodeID, resource: .memory)),
      connectionID: owner.id)
    guard case .nodeResourcePage = result?.response else {
      return XCTFail("authorized request did not return a page")
    }
    XCTAssertEqual(owner.frames.count, framesBefore)
    XCTAssertEqual(reads.value, 1)

    let stranger = NodeResourceRecordingConnection()
    await registry.addConnection(
      id: stranger.id,
      channel: DaemonConnectionChannel(
        connection: stranger, mode: .v2(version: 2), clientID: UUID()))
    let denied = await registry.apply(
      .nodeResource(
        projectPath: project.path,
        query: NodeResourceQuery(nodeID: nodeID, resource: .memory)),
      connectionID: stranger.id)
    XCTAssertEqual(denied?.errorCode, .nodeResourceUnauthorized)

    let wrongNode = await registry.apply(
      .nodeResource(
        projectPath: project.path,
        query: NodeResourceQuery(nodeID: UUID(), resource: .memory)),
      connectionID: owner.id)
    XCTAssertEqual(wrongNode?.errorCode, .nodeResourceUnauthorized)

    for (cursor, code) in [
      ("missing", DaemonWireErrorCode.nodeResourceMissing),
      ("corrupt", .nodeResourceCorrupt),
      ("oversized", .nodeResourceOversized),
      ("bounds", .nodeResourceInvalidBounds),
      ("cursor", .nodeResourceInvalidCursor),
      ("unsupported", .nodeResourceUnsupportedResource),
      ("transport", .nodeResourceTransportFailure),
    ] {
      let failure = await registry.apply(
        .nodeResource(
          projectPath: project.path,
          query: NodeResourceQuery(
            nodeID: nodeID,
            resource: .memory,
            cursor: cursor)),
        connectionID: owner.id)
      XCTAssertEqual(failure?.errorCode, code)
    }

    let requestID = UUID()
    try await channel.sendResponse(
      requestID: requestID,
      event: try XCTUnwrap(result?.response))
    let response = try JSONDecoder().decode(
      DaemonWireEnvelope.self, from: try XCTUnwrap(owner.frames.last))
    XCTAssertEqual(response.kind, .response)
    XCTAssertEqual(response.requestID, requestID)
    XCTAssertNil(response.sequence)
    let replayCursor =
      owner.frames.compactMap {
        (try? JSONDecoder().decode(DaemonWireEnvelope.self, from: $0))?.sequence
      }.max() ?? 0

    await registry.removeConnection(owner.id)
    let reconnect = NodeResourceRecordingConnection()
    let reconnectChannel = DaemonConnectionChannel(
      connection: reconnect,
      mode: .v2(version: 2),
      clientID: await channel.clientID,
      replayStore: replay)
    try await reconnectChannel.replay(after: replayCursor)
    XCTAssertTrue(reconnect.frames.isEmpty)
  }

  func testAuthoritativeCapabilityAndRootGraphOwnershipCannotBeForged() async throws {
    let root = try temporaryBase()
    defer { try? FileManager.default.removeItem(at: root) }
    let project = root.appendingPathComponent("same-looking", isDirectory: true)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    let support = root.appendingPathComponent("support", isDirectory: true)
    let childID = UUID()
    let forged = ProjectMetadata.local
    let nested = LoopGraph(
      project: ProjectRef(path: "/forged/nested", name: "Nested", metadata: forged),
      nodes: [
        LoopNode(
          id: childID,
          title: "Child",
          loopType: .turnBased,
          firstInstruction: "test")
      ])
    let rootRef = ProjectRef(path: project.path, name: "Root", metadata: forged)
    ProjectPersistence(baseDirectory: support).saveGraph(
      LoopGraph(
        project: rootRef,
        nodes: [LoopNode(title: "Composite", loopType: .composite, subGraph: nested)]))
    let calls = LockedValue(0)
    let deniedMetadata = ProjectMetadata(
      location: .ssh,
      capabilities: ProjectCapabilities(diagnostics: true, memoryReads: false))
    let registry = ProjectRegistry(
      persistenceDirectory: support,
      ensureSession: nil,
      terminateSession: nil,
      restartSession: nil,
      evaluatePredicate: nil,
      checkPredicate: nil,
      deliverMessage: nil,
      captureScript: nil,
      readUsage: nil,
      readGoalVerdict: nil,
      readActivity: nil,
      readSummary: nil,
      readPresence: nil,
      sessionAlive: nil,
      composeBoard: nil,
      readNodeResource: { node, _, query in
        calls.withValue { $0 += 1 }
        return .success(NodeResourcePage(nodeID: node.id, resource: query.resource))
      },
      persistsSynchronously: true,
      classifyProject: { _ in deniedMetadata })
    let connection = NodeResourceRecordingConnection()
    await registry.addConnection(
      id: connection.id,
      channel: DaemonConnectionChannel(
        connection: connection, mode: .v2(version: 2), clientID: UUID()))
    let opened = await registry.apply(.openProject(path: project.path), connectionID: connection.id)
    guard case .graphChanged(let graph) = opened?.response else {
      return XCTFail("project did not open")
    }
    XCTAssertEqual(graph.project.metadata, deniedMetadata)
    XCTAssertEqual(graph.nodes.first?.subGraph?.project.path, graph.project.path)
    XCTAssertEqual(graph.nodes.first?.subGraph?.project.metadata, deniedMetadata)

    let denied = await registry.apply(
      .nodeResource(
        projectPath: project.path,
        query: NodeResourceQuery(nodeID: childID, resource: .memory)),
      connectionID: connection.id)
    XCTAssertEqual(denied?.errorCode, .nodeResourceUnauthorized)
    XCTAssertEqual(calls.value, 0)
  }

  func testRemoteClassificationUsesTheSameTransportFailureMapping() async throws {
    let root = try temporaryBase()
    defer { try? FileManager.default.removeItem(at: root) }
    let project = root.appendingPathComponent("remote-fixture", isDirectory: true)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    let registry = ProjectRegistry(
      persistenceDirectory: root.appendingPathComponent("support"),
      ensureSession: nil,
      terminateSession: nil,
      restartSession: nil,
      evaluatePredicate: nil,
      checkPredicate: nil,
      deliverMessage: nil,
      captureScript: nil,
      readUsage: nil,
      readGoalVerdict: nil,
      readActivity: nil,
      readSummary: nil,
      readPresence: nil,
      sessionAlive: nil,
      composeBoard: nil,
      readNodeResource: { _, _, _ in .failure(.transportFailure) },
      persistsSynchronously: true,
      classifyProject: { _ in .ssh })
    let connection = NodeResourceRecordingConnection()
    await registry.addConnection(
      id: connection.id,
      channel: DaemonConnectionChannel(
        connection: connection, mode: .v2(version: 2), clientID: UUID()))
    _ = await registry.apply(.openProject(path: project.path), connectionID: connection.id)
    let nodeID = UUID()
    _ = await registry.apply(
      .graphCommand(
        projectPath: project.path,
        command: .createNode(
          NodeDraft(
            id: nodeID,
            title: "Remote synthetic",
            loopType: .turnBased,
            firstInstruction: "test"))),
      connectionID: connection.id)

    let failure = await registry.apply(
      .nodeResource(
        projectPath: project.path,
        query: NodeResourceQuery(nodeID: nodeID, resource: .memory)),
      connectionID: connection.id)
    XCTAssertEqual(failure?.errorCode, .nodeResourceTransportFailure)
  }
}
private final class LockedValue<Value>: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: Value

  init(_ value: Value) {
    stored = value
  }

  var value: Value {
    lock.withLock { stored }
  }

  func withValue(_ operation: (inout Value) -> Void) {
    lock.withLock { operation(&stored) }
  }
}
private final class NodeResourceRecordingConnection: @unchecked Sendable, DaemonConnection {
  let id = UUID()
  let endpoint: DaemonEndpoint = .namedPipe("node-resource-test")
  private let lock = NSLock()
  private var storedFrames: [Data] = []

  var frames: [Data] {
    lock.withLock { storedFrames }
  }

  func receiveFrame() async throws -> Data {
    throw FramedMessageIO.IOError.connectionClosed
  }

  func sendFrame(_ data: Data) async throws {
    lock.withLock { storedFrames.append(data) }
  }

  func close() async throws {}
}
