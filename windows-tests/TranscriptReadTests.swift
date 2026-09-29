import Foundation
import XCTest

@testable import GraphcodeKit

#if canImport(SQLite3)
  import SQLite3
#endif

final class TranscriptReadTests: XCTestCase {
  private func fixture(_ name: String) throws -> Data {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    return try Data(
      contentsOf: root.appendingPathComponent(
        "graphcode-windows/fixtures/\(name)"))
  }

  private func page(
    data: Data,
    provider: CLISessionBackendKind,
    nodeID: UUID = UUID(),
    cursor: String? = nil,
    maxEntries: Int = TranscriptQuery.defaultEntryLimit,
    maxBytes: Int = TranscriptQuery.defaultByteLimit,
    identity: String = "synthetic-source"
  ) throws -> TranscriptPage {
    let decoded = try cursor.map(TranscriptCursor.decode)
    let anchorLength = decoded?.anchorLength ?? 0
    let nextOffset = decoded?.nextOffset ?? 0
    let start = Int(nextOffset) - anchorLength
    let chunk = TranscriptSourceChunk(
      identity: identity,
      totalBytes: UInt64(data.count),
      offset: UInt64(start),
      data: data.subdata(in: start..<data.count),
      authenticatedOffset: nextOffset,
      authenticatedPrefixHash: GraphcodeSHA256.hex(Data(data.prefix(Int(nextOffset)))),
      completeSource: data)
    return try TranscriptReader.page(
      nodeID: nodeID,
      provider: provider,
      query: TranscriptQuery(
        nodeID: nodeID, cursor: cursor, maxEntries: maxEntries, maxBytes: maxBytes),
      cursor: decoded,
      chunk: chunk)
  }

  func testSyntheticProviderFixturesNormalizeWithoutLosslessPayloads() throws {
    let claude = try page(
      data: fixture("transcript-claude-synthetic.jsonl"), provider: .claudeCode)
    XCTAssertEqual(claude.entries.map(\.kind), [.prompt, .assistant, .toolResult])

    let copilot = try page(
      data: fixture("transcript-copilot-synthetic.jsonl"), provider: .copilotCLI)
    XCTAssertEqual(
      copilot.entries.map(\.kind), [.prompt, .assistant, .toolUse, .toolResult])

    let codex = try page(
      data: fixture("transcript-codex-synthetic.jsonl"), provider: .codex)
    XCTAssertEqual(codex.entries.map(\.kind), [.prompt, .assistant, .toolUse, .toolResult])

    let encoded = String(
      decoding: try JSONEncoder().encode([claude, copilot, codex]), as: UTF8.self)
    XCTAssertFalse(encoded.contains("synthetic file contents"))
    XCTAssertFalse(encoded.contains("synthetic command output"))
    XCTAssertFalse(encoded.contains("synthetic-model"))
  }

  func testRedactionCoversPromptsToolInputsPathsSecretsAndModelMetadata() throws {
    let page = try page(
      data: fixture("transcript-claude-synthetic.jsonl"), provider: .claudeCode)
    XCTAssertEqual(page.entries[0].text, "[redacted prompt]")
    XCTAssertTrue(page.entries[0].redactions.contains(.prompt))
    XCTAssertEqual(
      page.entries[1].text,
      "[redacted assistant text]\n[used tool with redacted input]")
    XCTAssertTrue(page.entries[1].redactions.contains(.toolInput))
    XCTAssertTrue(page.entries[1].redactions.contains(.filesystemPath))
    XCTAssertTrue(page.entries[1].redactions.contains(.secret))
    XCTAssertTrue(page.entries[1].redactions.contains(.modelMetadata))
    XCTAssertFalse(page.entries[1].text.contains("synthetic-model"))
  }

  func testCursorRemainsStableAcrossAppendAndRejectsBoundaryRewrite() throws {
    let nodeID = UUID()
    let first = Data(
      [
        #"{"type":"user.message","data":{"content":"first"}}"#,
        #"{"type":"assistant.message","data":{"content":"second"}}"#,
      ].joined(separator: "\n").appending("\n").utf8)
    let firstPage = try page(
      data: first, provider: .copilotCLI, nodeID: nodeID, maxEntries: 1)
    let cursor = try XCTUnwrap(firstPage.nextCursor)

    let appended =
      first
      + Data(
        #"{"type":"assistant.message","data":{"content":"third"}}"#.appending("\n").utf8)
    let secondPage = try page(
      data: appended, provider: .copilotCLI, nodeID: nodeID, cursor: cursor)
    XCTAssertEqual(secondPage.entries.map(\.kind), [.assistant, .assistant])
    XCTAssertFalse(secondPage.hasMore)

    var rewritten = appended
    let anchor = try TranscriptCursor.decode(cursor)
    let boundary = Int(anchor.nextOffset) - anchor.anchorLength
    rewritten[boundary + 2] ^= 1
    XCTAssertThrowsError(
      try page(
        data: rewritten, provider: .copilotCLI, nodeID: nodeID, cursor: cursor)
    ) { error in
      XCTAssertEqual(error as? TranscriptReadError, .invalidCursor)
    }
  }

  func testCursorRejectsEarlierPrefixMutationAndUnchangedAnchorTruncateRegrow() throws {
    let nodeID = UUID()
    let original = Data(
      [
        #"{"type":"assistant.message","data":{"content":"first"}}"#,
        #"{"type":"assistant.message","data":{"content":"anchor"}}"#,
        #"{"type":"assistant.message","data":{"content":"later"}}"#,
      ].joined(separator: "\n").appending("\n").utf8)
    let firstPage = try page(
      data: original, provider: .copilotCLI, nodeID: nodeID, maxEntries: 2)
    let cursor = try XCTUnwrap(firstPage.nextCursor)

    var earlierMutation = original
    earlierMutation[20] ^= 1
    XCTAssertThrowsError(
      try page(
        data: earlierMutation, provider: .copilotCLI, nodeID: nodeID, cursor: cursor)
    ) { error in
      XCTAssertEqual(error as? TranscriptReadError, .invalidCursor)
    }

    let regrown = Data(
      [
        #"{"type":"assistant.message","data":{"content":"other"}}"#,
        #"{"type":"assistant.message","data":{"content":"anchor"}}"#,
        #"{"type":"assistant.message","data":{"content":"later"}}"#,
      ].joined(separator: "\n").appending("\n").utf8)
    XCTAssertEqual(regrown.count, original.count)
    XCTAssertThrowsError(
      try page(data: regrown, provider: .copilotCLI, nodeID: nodeID, cursor: cursor)
    ) { error in
      XCTAssertEqual(error as? TranscriptReadError, .invalidCursor)
    }
  }

  func testReplacementDuringReadIsInvalidCursor() {
    XCTAssertThrowsError(
      try TranscriptReader.validateStableRead(
        identityBefore: "same-inode",
        prefixHashBefore: String(repeating: "a", count: 64),
        identityAfter: "same-inode",
        prefixHashAfter: String(repeating: "b", count: 64))
    ) { error in
      XCTAssertEqual(error as? TranscriptReadError, .invalidCursor)
    }
  }

  func testStreamingPrefixDigestMatchesInMemorySHA256() throws {
    let data = Data((0..<(200 * 1024 + 37)).map { UInt8(truncatingIfNeeded: $0) })
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("transcript-prefix-\(UUID()).bin")
    try data.write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }

    XCTAssertEqual(
      try GraphcodeSHA256.hex(reading: handle, through: UInt64(data.count)),
      GraphcodeSHA256.hex(data))
  }

  func testAdversarialProviderStringsNeverReachEncodedPage() throws {
    let forbidden = [
      "AKIAIOSFODNN7EXAMPLE",
      "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
      "IQoJb3JpZ2luX2VjEExampleSessionToken",
      "Bearer " + "abcdefghijklmnopqrstuvwxyz",
      "Basic dXNlcjpwYXNz",
      "https://" + "user:password@example.test/private",
      "eyJhbGciOiJIUzI1NiJ9." + "eyJzdWIiOiIxMjM0NTY3ODkwIn0.signaturevalue",
      "-----BEGIN PRIVATE KEY-----\nsecret\n-----END PRIVATE KEY-----",
      "ghp_abcdefghijklmnopqrstuvwxyz123456",
      "github_pat_abcdefghijklmnopqrstuvwxyz123456",
      "azure_token_abcdefghijklmnopqrstuvwxyz123456",
      "sk-abcdefghijklmnopqrstuvwxyz123456",
      #"C:\Users\Synthetic User\private file.txt"#,
      "/Users/Synthetic User/private file.txt",
    ]
    let records = try forbidden.flatMap { literal -> [Data] in
      [
        try JSONSerialization.data(
          withJSONObject: [
            "type": "assistant.message",
            "timestamp": "not-safe-\(literal)",
            "data": ["content": literal],
          ]),
        try JSONSerialization.data(
          withJSONObject: [
            "type": "tool.execution_start",
            "data": ["toolName": literal, "arguments": ["value": literal]],
          ]),
      ]
    }
    let source = records.reduce(into: Data()) {
      $0.append($1)
      $0.append(0x0a)
    }
    let result = try page(data: source, provider: .copilotCLI)
    let encoded = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
    for literal in forbidden {
      XCTAssertFalse(encoded.contains(literal), "encoded page leaked \(literal)")
    }
    XCTAssertTrue(
      result.entries.filter { $0.kind == .toolUse }.allSatisfy {
        $0.toolName == "tool" && $0.text == "Used tool with redacted input"
      })
    XCTAssertTrue(
      result.entries.filter { $0.kind == .assistant }.allSatisfy {
        $0.text == "[redacted assistant text]" && $0.timestamp == nil
      })
  }

  func testCodexProviderResolutionUsesExactBankedRolloutForSameCWDNodes() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("transcript-codex-exact-\(UUID())", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let firstNode = UUID()
    let secondNode = UUID()
    let firstThread = UUID().uuidString.lowercased()
    let secondThread = UUID().uuidString.lowercased()
    let firstRollout = root.appendingPathComponent(
      "rollout-2026-01-01T00-00-00-\(firstThread).jsonl")
    let secondRollout = root.appendingPathComponent(
      "rollout-2026-01-01T00-00-01-\(secondThread).jsonl")
    let sameCWD = #"{"type":"session_meta","payload":{"cwd":"C:\\same\\project"}}"#
    try sameCWD.write(to: firstRollout, atomically: true, encoding: .utf8)
    try sameCWD.write(to: secondRollout, atomically: true, encoding: .utf8)
    let rollouts = [secondRollout, firstRollout]

    XCTAssertEqual(
      TranscriptReader.codexLocalURL(
        nodeID: firstNode, banked: firstThread, database: nil, rollouts: rollouts),
      firstRollout)
    XCTAssertEqual(
      TranscriptReader.codexLocalURL(
        nodeID: secondNode, banked: secondThread, database: nil, rollouts: rollouts),
      secondRollout)
    XCTAssertNil(
      TranscriptReader.codexLocalURL(
        nodeID: firstNode, banked: UUID().uuidString, database: nil, rollouts: rollouts))

    var node = LoopNode(
      id: firstNode, title: "Codex", loopType: .turnBased, firstInstruction: "test")
    node.backend = .codex
    let remote = TranscriptReader.remoteFind(
      node: node,
      location: RemoteProjectLocation(host: "synthetic", remotePath: "/same/project"))
    XCTAssertTrue(remote.contains(firstNode.uuidString))
    XCTAssertTrue(remote.contains("SELECT id FROM threads WHERE id="))
    XCTAssertTrue(remote.contains("rollout-*-$T.jsonl"))
    XCTAssertFalse(remote.contains(#""cwd":"#))
  }

  #if canImport(SQLite3)
    func testCodexProviderResolutionBindsTwoSameCWDNodesToExactRollouts() throws {
      let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("transcript-codex-resolution-\(UUID())", isDirectory: true)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: root) }

      let firstNode = UUID()
      let secondNode = UUID()
      let firstThread = UUID().uuidString.lowercased()
      let secondThread = UUID().uuidString.lowercased()
      let firstRollout = root.appendingPathComponent(
        "rollout-2026-01-01T00-00-00-\(firstThread).jsonl")
      let secondRollout = root.appendingPathComponent(
        "rollout-2026-01-01T00-00-01-\(secondThread).jsonl")
      let sameCWD = #"{"type":"session_meta","payload":{"cwd":"C:\\same\\project"}}"#
      try sameCWD.write(to: firstRollout, atomically: true, encoding: .utf8)
      try sameCWD.write(to: secondRollout, atomically: true, encoding: .utf8)

      let database = root.appendingPathComponent("state_1.sqlite")
      var handle: OpaquePointer?
      XCTAssertEqual(sqlite3_open(database.path, &handle), SQLITE_OK)
      defer { sqlite3_close(handle) }
      sqlite3_exec(
        handle,
        "CREATE TABLE threads (id TEXT PRIMARY KEY, first_user_message TEXT, created_at_ms INTEGER)",
        nil, nil, nil)
      sqlite3_exec(
        handle,
        "INSERT INTO threads VALUES ('\(firstThread)', '/goal \(firstNode.uuidString)', 1)",
        nil, nil, nil)
      sqlite3_exec(
        handle,
        "INSERT INTO threads VALUES ('\(secondThread)', '/goal \(secondNode.uuidString)', 2)",
        nil, nil, nil)

      let rollouts = [secondRollout, firstRollout]
      XCTAssertEqual(
        TranscriptReader.codexLocalURL(
          nodeID: firstNode, banked: UUID().uuidString, database: database,
          rollouts: rollouts),
        firstRollout)
      XCTAssertEqual(
        TranscriptReader.codexLocalURL(
          nodeID: secondNode, banked: UUID().uuidString, database: database,
          rollouts: rollouts),
        secondRollout)
      XCTAssertNil(
        TranscriptReader.codexLocalURL(
          nodeID: UUID(), banked: UUID().uuidString, database: database,
          rollouts: rollouts))
    }
  #endif

  func testEntryAndByteBoundsAreStrict() throws {
    XCTAssertThrowsError(
      try TranscriptQuery(nodeID: UUID(), maxEntries: 0).validated()
    ) { error in
      XCTAssertEqual(error as? TranscriptReadError, .invalidBounds)
    }

    let huge = Data(
      (#"{"type":"assistant.message","data":{"content":""#
        + String(repeating: "x", count: TranscriptReader.maximumSourceRecordBytes + 1)
        + "\"}}\n").utf8)
    XCTAssertThrowsError(try page(data: huge, provider: .copilotCLI)) { error in
      XCTAssertEqual(error as? TranscriptReadError, .oversized)
    }

    let records =
      (0..<10).map {
        #"{"type":"assistant.message","data":{"content":"entry \#($0)"}}"#
      }.joined(separator: "\n") + "\n"
    let bounded = try page(
      data: Data(records.utf8), provider: .copilotCLI, maxEntries: 2)
    XCTAssertEqual(bounded.entries.count, 2)
    XCTAssertTrue(bounded.hasMore)
    XCTAssertNotNil(bounded.nextCursor)
  }

  func testWireCompatibilityAndRequestScopedEventShape() throws {
    let legacy = try JSONEncoder().encode(DaemonCommand.listRecentProjects)
    guard case .v1(.listRecentProjects) = try DaemonWireProtocol.decodeClientFrame(legacy) else {
      return XCTFail("legacy command did not remain v1")
    }

    let nodeID = UUID()
    let command = DaemonCommand.transcript(
      projectPath: "C:\\synthetic\\project",
      query: TranscriptQuery(nodeID: nodeID))
    let requestID = UUID()
    let request = try JSONEncoder().encode(
      DaemonWireEnvelope.request(id: requestID, command: command))
    guard case .v2(let decoded) = try DaemonWireProtocol.decodeClientFrame(request) else {
      return XCTFail("transcript request did not decode as v2")
    }
    XCTAssertEqual(decoded.requestID, requestID)
    XCTAssertEqual(decoded.command, command)
  }

  func testRegistryRequiresConnectionProjectAndNodeOwnership() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("graphcode-transcript-auth-\(UUID().uuidString)", isDirectory: true)
    let project = root.appendingPathComponent("project", isDirectory: true)
    let support = root.appendingPathComponent("support", isDirectory: true)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

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
      readTranscript: { node, _, query in
        if query.cursor == "missing" { return .failure(.missing) }
        if query.cursor == "corrupt" { return .failure(.corrupt) }
        if query.cursor == "oversized" { return .failure(.oversized) }
        if query.cursor == "invalid" { return .failure(.invalidCursor) }
        return .success(
          TranscriptPage(
            nodeID: node.id,
            provider: node.backend,
            entries: [],
            nextCursor: query.cursor,
            hasMore: false))
      },
      persistsSynchronously: true)

    let owner = TranscriptRecordingConnection()
    await registry.addConnection(
      id: owner.id,
      channel: DaemonConnectionChannel(
        connection: owner, mode: .v2(version: 2), clientID: UUID()))
    _ = await registry.apply(.openProject(path: project.path), connectionID: owner.id)
    _ = await registry.apply(
      .graphCommand(
        projectPath: project.path,
        command: .createNode(
          NodeDraft(title: "Synthetic", loopType: .turnBased, firstInstruction: "test"))),
      connectionID: owner.id)
    let graph = try XCTUnwrap(
      ProjectPersistence(baseDirectory: support).loadGraph(path: project.path))
    let nodeID = try XCTUnwrap(graph.nodes.first?.id)

    let framesBeforeRead = owner.frames.count
    let allowed = await registry.apply(
      .transcript(projectPath: project.path, query: TranscriptQuery(nodeID: nodeID)),
      connectionID: owner.id)
    guard case .transcriptPage(let page) = allowed?.response else {
      return XCTFail("joined owner did not receive a transcript page")
    }
    XCTAssertEqual(page.nodeID, nodeID)
    XCTAssertEqual(owner.frames.count, framesBeforeRead)

    let stranger = TranscriptRecordingConnection()
    await registry.addConnection(
      id: stranger.id,
      channel: DaemonConnectionChannel(
        connection: stranger, mode: .v2(version: 2), clientID: UUID()))
    let denied = await registry.apply(
      .transcript(projectPath: project.path, query: TranscriptQuery(nodeID: nodeID)),
      connectionID: stranger.id)
    XCTAssertEqual(denied?.errorCode, .transcriptUnauthorized)

    let unknownNode = await registry.apply(
      .transcript(projectPath: project.path, query: TranscriptQuery(nodeID: UUID())),
      connectionID: owner.id)
    XCTAssertEqual(unknownNode?.errorCode, .transcriptUnauthorized)

    for (cursor, code) in [
      ("missing", DaemonWireErrorCode.transcriptMissing),
      ("corrupt", .transcriptCorrupt),
      ("oversized", .transcriptOversized),
      ("invalid", .transcriptInvalidCursor),
    ] {
      let failure = await registry.apply(
        .transcript(
          projectPath: project.path,
          query: TranscriptQuery(nodeID: nodeID, cursor: cursor)),
        connectionID: owner.id)
      XCTAssertEqual(failure?.errorCode, code)
    }
  }
}
private final class TranscriptRecordingConnection: @unchecked Sendable, DaemonConnection {
  let id = UUID()
  let endpoint: DaemonEndpoint = .namedPipe("transcript-test")
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
