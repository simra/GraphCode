import Foundation
import XCTest

@testable import GraphcodeKit

#if canImport(SQLite3)
  import SQLite3
#endif

final class TranscriptReadTests: XCTestCase {
  private func pythonExecutable() throws -> URL {
    let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
    for directory in path.split(separator: ";").map(String.init) {
      for name in ["python.exe", "python3.exe"] {
        let candidate = URL(fileURLWithPath: directory).appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: candidate.path) {
          return candidate
        }
      }
    }
    throw XCTSkip("Python is unavailable for the synthetic remote resolver test")
  }

  private func runPython(_ program: String, arguments: [String]) throws -> String {
    let process = Process()
    process.executableURL = try pythonExecutable()
    process.arguments = ["-c", program] + arguments
    let output = Pipe()
    let error = Pipe()
    process.standardOutput = output
    process.standardError = error
    try process.run()
    process.waitUntilExit()
    let stderr = String(
      decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    XCTAssertEqual(process.terminationStatus, 0, stderr)
    return String(
      decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self
    ).trimmingCharacters(in: .whitespacesAndNewlines)
  }

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
    let chunk = TranscriptSourceChunk(
      identity: identity,
      totalBytes: UInt64(data.count),
      data: data,
      sourceWorkBytes: data.count,
      remoteTransferBytes: 0)
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
      try TranscriptReader.validateSnapshot(
        snapshot: Data("before".utf8),
        currentPrefix: Data("rewritten".utf8),
        initialIdentity: "same-inode",
        finalIdentity: "same-inode",
        finalSize: 9)
    ) { error in
      XCTAssertEqual(error as? TranscriptReadError, .invalidCursor)
    }
  }

  func testRewriteBetweenParseAndFinalizationFailsWhileAppendSucceeds() throws {
    let nodeID = UUID()
    let source = Data(
      [
        #"{"type":"assistant.message","data":{"content":"first"}}"#,
        #"{"type":"assistant.message","data":{"content":"second"}}"#,
        #"{"type":"assistant.message","data":{"content":"third"}}"#,
      ].joined(separator: "\n").appending("\n").utf8)
    let chunk = TranscriptSourceChunk(
      identity: "generation",
      totalBytes: UInt64(source.count),
      data: source,
      sourceWorkBytes: source.count,
      remoteTransferBytes: 0)
    let first = try TranscriptReader.page(
      nodeID: nodeID,
      provider: .copilotCLI,
      query: TranscriptQuery(nodeID: nodeID, maxEntries: 1),
      cursor: nil,
      chunk: chunk)
    let cursorValue = try XCTUnwrap(first.nextCursor)
    let cursor = try TranscriptCursor.decode(cursorValue)
    let query = TranscriptQuery(nodeID: nodeID, cursor: cursorValue, maxEntries: 1)

    var rewritten = source
    rewritten[Int(cursor.nextOffset) + 10] ^= 1
    XCTAssertThrowsError(
      try TranscriptReader.page(
        nodeID: nodeID, provider: .copilotCLI, query: query, cursor: cursor, chunk: chunk,
        afterParse: {
          TranscriptSourceChunk(
            identity: "generation",
            totalBytes: UInt64(rewritten.count),
            data: rewritten,
            sourceWorkBytes: rewritten.count,
            remoteTransferBytes: 0)
        })
    ) { error in
      XCTAssertEqual(error as? TranscriptReadError, .invalidCursor)
    }

    let appended =
      source
      + Data(
        #"{"type":"assistant.message","data":{"content":"fourth"}}"#.appending("\n").utf8)
    let page = try TranscriptReader.page(
      nodeID: nodeID, provider: .copilotCLI, query: query, cursor: cursor, chunk: chunk,
      afterParse: {
        TranscriptSourceChunk(
          identity: "generation",
          totalBytes: UInt64(appended.count),
          data: appended,
          sourceWorkBytes: source.count,
          remoteTransferBytes: 0)
      })
    XCTAssertTrue(page.hasMore)
    XCTAssertNotNil(page.nextCursor)
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
    XCTAssertTrue(remote.contains(firstNode.uuidString.lowercased()))
    XCTAssertTrue(remote.contains("SELECT id FROM threads WHERE id = ?"))
    XCTAssertTrue(remote.contains("name.endswith(suffix)"))
    XCTAssertFalse(remote.contains(#""cwd":"#))
  }

  func testClaudeResolutionRejectsUntrustedIdsAndCrossProjectCandidates() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("transcript-claude-id-\(UUID())", isDirectory: true)
    let working = root.appendingPathComponent("authorized-worktree", isDirectory: true)
    try FileManager.default.createDirectory(at: working, withIntermediateDirectories: true)
    let authorized = root.appendingPathComponent(
      SessionTransplant.claudeProjectSlug(forWorkingDirectory: working.path),
      isDirectory: true)
    let other = root.appendingPathComponent("other-project", isDirectory: true)
    try FileManager.default.createDirectory(at: authorized, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let sessionID = UUID().uuidString.lowercased()
    let transcript = authorized.appendingPathComponent("\(sessionID).jsonl")
    try Data().write(to: transcript)
    let crossProjectID = UUID().uuidString.lowercased()
    try Data().write(to: other.appendingPathComponent("\(crossProjectID).jsonl"))
    let nestedID = UUID().uuidString.lowercased()
    let nested = authorized.appendingPathComponent("nested", isDirectory: true)
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    try Data().write(to: nested.appendingPathComponent("\(nestedID).jsonl"))
    let previous = ClaudeSessionLog.projectsDirectory
    ClaudeSessionLog.projectsDirectory = root
    defer { ClaudeSessionLog.projectsDirectory = previous }

    XCTAssertEqual(
      ClaudeSessionLog.transcript(
        forSessionID: sessionID.uppercased(), projectPath: working.path),
      transcript)
    for value in [
      "../\(sessionID)", "..\\\(sessionID)", "/tmp/\(sessionID)",
      "C:\\tmp\\\(sessionID)", ".", "..", "\(sessionID)/child",
      "\(sessionID)\n", "\(sessionID)\u{0001}", "*?\(sessionID)", "';\(sessionID)",
    ] {
      XCTAssertNil(
        ClaudeSessionLog.transcript(forSessionID: value, projectPath: working.path),
        "unsafe Claude identifier resolved: \(value.debugDescription)")
    }
    XCTAssertNil(
      ClaudeSessionLog.transcript(
        forSessionID: crossProjectID, projectPath: working.path))
    XCTAssertNil(
      ClaudeSessionLog.transcript(forSessionID: nestedID, projectPath: working.path))
  }

  func testRemoteClaudeResolutionValidatesBeforeExactChildLookup() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("rc-\(UUID().uuidString.prefix(8))", isDirectory: true)
    let projects = root.appendingPathComponent("projects", isDirectory: true)
    let working = root.appendingPathComponent("authorized", isDirectory: true)
    let idFile = root.appendingPathComponent("node.id")
    try FileManager.default.createDirectory(at: working, withIntermediateDirectories: true)
    let slug = try runPython(
      "import os, re, sys; print(re.sub(r'[^A-Za-z0-9]', '-', os.path.realpath(sys.argv[1])))",
      arguments: [working.path])
    let project = projects.appendingPathComponent(slug, isDirectory: true)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let sessionID = UUID().uuidString.lowercased()
    let transcript = project.appendingPathComponent("\(sessionID).jsonl")
    try Data().write(to: transcript)
    try sessionID.uppercased().write(to: idFile, atomically: true, encoding: .ascii)
    XCTAssertEqual(
      try runPython(
        ClaudeSessionLog.remoteTranscriptResolverProgram,
        arguments: [idFile.path, projects.path, working.path]
      ).replacingOccurrences(of: "\\", with: "/"),
      transcript.path.replacingOccurrences(of: "\\", with: "/"))

    for value in [
      "../\(sessionID)", "..\\\(sessionID)", "/tmp/\(sessionID)",
      "C:\\tmp\\\(sessionID)", ".", "..", "\(sessionID)\n",
      "\(sessionID)\u{0001}", "*?\(sessionID)", "';\(sessionID)",
    ] {
      try Data(value.utf8).write(to: idFile)
      XCTAssertEqual(
        try runPython(
          ClaudeSessionLog.remoteTranscriptResolverProgram,
          arguments: [idFile.path, projects.path, working.path]),
        "")
    }

    let crossProjectID = UUID().uuidString.lowercased()
    let other = projects.appendingPathComponent("other", isDirectory: true)
    try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
    try Data().write(to: other.appendingPathComponent("\(crossProjectID).jsonl"))
    try crossProjectID.write(to: idFile, atomically: true, encoding: .ascii)
    XCTAssertEqual(
      try runPython(
        ClaudeSessionLog.remoteTranscriptResolverProgram,
        arguments: [idFile.path, projects.path, working.path]),
      "")

    var node = LoopNode(
      id: UUID(), title: "Claude", loopType: .turnBased, firstInstruction: "test")
    node.backend = .claudeCode
    let command = TranscriptReader.remoteFind(
      node: node,
      location: RemoteProjectLocation(host: "synthetic", remotePath: "/authorized project"))
    XCTAssertTrue(command.contains("python3 -c"))
    XCTAssertFalse(command.contains(".claude/projects/*"))
    XCTAssertFalse(command.contains("ls -t"))
  }

  func testCodexExactLookupSearchesBeyondRecentRolloutLimit() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("transcript-codex-complete-\(UUID())", isDirectory: true)
    let targetThread = UUID().uuidString.lowercased()
    let old = root.appendingPathComponent("2025/01/01", isDirectory: true)
    try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
    let target = old.appendingPathComponent(
      "rollout-2025-01-01T00-00-00-\(targetThread).jsonl")
    try Data().write(to: target)
    for index in 0..<(CodexSessionLog.recentRolloutLimit + 5) {
      let directory = root.appendingPathComponent(
        "2026/01/\(String(format: "%02d", index % 28 + 1))", isDirectory: true)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let rollout = directory.appendingPathComponent(
        "rollout-2026-01-01T00-00-\(String(format: "%02d", index))-\(UUID().uuidString).jsonl")
      try Data().write(to: rollout)
      try FileManager.default.setAttributes(
        [.modificationDate: Date().addingTimeInterval(Double(index + 1))],
        ofItemAtPath: rollout.path)
    }
    defer { try? FileManager.default.removeItem(at: root) }
    let original = CodexSessionLog.sessionsDirectory
    CodexSessionLog.sessionsDirectory = root
    defer { CodexSessionLog.sessionsDirectory = original }

    XCTAssertFalse(CodexSessionLog.recentRollouts().contains(target))
    XCTAssertEqual(
      TranscriptReader.codexLocalURL(
        nodeID: UUID(), banked: targetThread, database: nil),
      target)
  }

  func testRemoteCodexResolverRejectsUnsafeIdentifiersAndNormalizesUppercase() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("transcript-remote-codex-id-\(UUID())", isDirectory: true)
    let codex = root.appendingPathComponent("codex", isDirectory: true)
    let sessions = codex.appendingPathComponent("sessions/2026/09/29", isDirectory: true)
    let idFile = root.appendingPathComponent("node.id")
    try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let nodeID = UUID().uuidString.lowercased()
    let marker = "/graphcode/project/\(nodeID)/PROMPT.md"
    let threadID = UUID().uuidString.lowercased()
    let rollout = sessions.appendingPathComponent(
      "rollout-2026-09-29T00-00-00-\(threadID).jsonl")
    try Data().write(to: rollout)

    try threadID.uppercased().write(to: idFile, atomically: true, encoding: .ascii)
    XCTAssertEqual(
      try runPython(
        TranscriptReader.remoteCodexResolverProgram,
        arguments: [
          idFile.path, codex.path, codex.appendingPathComponent("sessions").path, nodeID, marker,
        ]
      ).replacingOccurrences(of: "\\", with: "/"),
      rollout.path.replacingOccurrences(of: "\\", with: "/"))

    let malformed = [
      "'",
      "*?[abc]",
      " \(threadID)",
      "\(threadID)\n",
      "\(threadID)\u{0000}",
      "x'OR 1---aaaa-bbbb-cccc-dddddddddddd",
    ]
    for value in malformed {
      try Data(value.utf8).write(to: idFile)
      XCTAssertEqual(
        try runPython(
          TranscriptReader.remoteCodexResolverProgram,
          arguments: [
            idFile.path, codex.path, codex.appendingPathComponent("sessions").path, nodeID,
            marker,
          ]),
        "",
        "unsafe banked identifier selected a rollout: \(value.debugDescription)")
    }

    let resolver = TranscriptReader.remoteCodexResolverProgram
    XCTAssertTrue(resolver.contains("WHERE id = ?"))
    XCTAssertTrue(resolver.contains("instr(first_user_message, ?) > 0 LIMIT 2"))
    XCTAssertTrue(resolver.contains("name.endswith(suffix)"))
    XCTAssertFalse(resolver.contains("WHERE id='"))
    var node = LoopNode(
      id: UUID(), title: "Remote Codex", loopType: .turnBased, firstInstruction: "test")
    node.backend = .codex
    let command = TranscriptReader.remoteFind(
      node: node,
      location: RemoteProjectLocation(host: "synthetic", remotePath: "/project"))
    XCTAssertFalse(command.contains("sqlite3 "))
    XCTAssertFalse(command.contains("find "))
    XCTAssertFalse(command.contains("-name"))
    XCTAssertFalse(command.contains("*?[abc]"))
    XCTAssertFalse(command.contains("x'OR 1---aaaa-bbbb-cccc-dddddddddddd"))
    XCTAssertFalse(command.contains(" \(threadID)"))
  }

  func testRemoteCodexResolverValidatesResolvedSQLiteThreadID() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("transcript-remote-codex-db-\(UUID())", isDirectory: true)
    let codex = root.appendingPathComponent("codex", isDirectory: true)
    let sessions = codex.appendingPathComponent("sessions/2026/09/29", isDirectory: true)
    let idFile = root.appendingPathComponent("node.id")
    let database = codex.appendingPathComponent("state_12.sqlite")
    try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let nodeID = UUID().uuidString.lowercased()
    let marker = "/graphcode/project/\(nodeID)/PROMPT.md"
    let banked = UUID().uuidString.lowercased()
    let resolved = UUID().uuidString.lowercased()
    try banked.write(to: idFile, atomically: true, encoding: .ascii)
    let rollout = sessions.appendingPathComponent(
      "rollout-2026-09-29T00-00-00-\(resolved).jsonl")
    try Data().write(to: rollout)

    let createDatabase = """
      import sqlite3, sys
      database, identifier, message = sys.argv[1:4]
      with sqlite3.connect(database) as connection:
          connection.execute(
              "CREATE TABLE threads (id TEXT PRIMARY KEY, first_user_message TEXT, created_at_ms INTEGER)"
          )
          connection.execute("INSERT INTO threads VALUES (?, ?, 1)", (identifier, message))
      """
    _ = try runPython(
      createDatabase,
      arguments: [database.path, resolved.uppercased(), "/goal read \(marker)"])
    XCTAssertEqual(
      try runPython(
        TranscriptReader.remoteCodexResolverProgram,
        arguments: [
          idFile.path, codex.path, codex.appendingPathComponent("sessions").path, nodeID, marker,
        ]
      ).replacingOccurrences(of: "\\", with: "/"),
      rollout.path.replacingOccurrences(of: "\\", with: "/"))

    try FileManager.default.removeItem(at: database)
    _ = try runPython(
      createDatabase,
      arguments: [
        database.path,
        "x'OR 1---aaaa-bbbb-cccc-dddddddddddd",
        "/goal read \(marker)",
      ])
    XCTAssertEqual(
      try runPython(
        TranscriptReader.remoteCodexResolverProgram,
        arguments: [
          idFile.path, codex.path, codex.appendingPathComponent("sessions").path, nodeID, marker,
        ]),
      "")
  }

  func testRemoteCodexFallbackRequiresOneExactLaunchMarker() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("transcript-remote-codex-marker-\(UUID())", isDirectory: true)
    let codex = root.appendingPathComponent("codex", isDirectory: true)
    let sessions = codex.appendingPathComponent("sessions", isDirectory: true)
    let idFile = root.appendingPathComponent("node.id")
    let database = codex.appendingPathComponent("state_1.sqlite")
    try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let nodeID = UUID().uuidString.lowercased()
    let marker = "/graphcode/project/\(nodeID)/PROMPT.md"
    let banked = UUID().uuidString.lowercased()
    try banked.write(to: idFile, atomically: true, encoding: .ascii)
    let createDatabase = """
      import sqlite3, sys
      database, rows = sys.argv[1:3]
      with sqlite3.connect(database) as connection:
          connection.execute(
              "CREATE TABLE threads (id TEXT PRIMARY KEY, first_user_message TEXT, created_at_ms INTEGER)"
          )
          for index, pair in enumerate(rows.split("\\n")):
              identifier, message = pair.split("|", 1)
              connection.execute("INSERT INTO threads VALUES (?, ?, ?)", (identifier, message, index))
      """
    func resolve(_ rows: [(String, String)]) throws -> String {
      try? FileManager.default.removeItem(at: database)
      let encoded = rows.map { "\($0.0)|\($0.1)" }.joined(separator: "\n")
      _ = try runPython(createDatabase, arguments: [database.path, encoded])
      return try runPython(
        TranscriptReader.remoteCodexResolverProgram,
        arguments: [
          idFile.path, codex.path, sessions.path, nodeID, marker,
        ])
    }

    XCTAssertEqual(
      try resolve([
        (UUID().uuidString.lowercased(), "newer unrelated mention \(nodeID)")
      ]),
      "")
    XCTAssertEqual(
      try resolve([
        (UUID().uuidString.lowercased(), "read \(marker)"),
        (UUID().uuidString.lowercased(), "/goal read \(marker)"),
      ]),
      "")
    XCTAssertEqual(
      try resolve([
        ("x'OR 1---aaaa-bbbb-cccc-dddddddddddd", "read \(marker)")
      ]),
      "")
  }

  func testSourceWorkIsBoundedIndependentOfCursorDepth() throws {
    let record = #"{"type":"assistant.message","data":{"content":"bounded"}}"# + "\n"
    let source = Data(String(repeating: record, count: 50).utf8)
    let nodeID = UUID()
    var cursor: String?
    var pages = 0
    repeat {
      let chunk = TranscriptSourceChunk(
        identity: "bounded-source",
        totalBytes: UInt64(source.count),
        data: source,
        sourceWorkBytes: source.count * 2,
        remoteTransferBytes: source.base64EncodedString().utf8.count)
      XCTAssertLessThanOrEqual(chunk.sourceWorkBytes, TranscriptReader.maximumSourceWorkBytes)
      XCTAssertLessThanOrEqual(
        chunk.remoteTransferBytes, TranscriptReader.maximumRemoteTransferBytes)
      let result = try TranscriptReader.page(
        nodeID: nodeID,
        provider: .copilotCLI,
        query: TranscriptQuery(nodeID: nodeID, cursor: cursor, maxEntries: 1),
        cursor: try cursor.map(TranscriptCursor.decode),
        chunk: chunk)
      cursor = result.nextCursor
      pages += 1
    } while cursor != nil
    XCTAssertGreaterThan(pages, 40)

    var node = LoopNode(
      id: nodeID, title: "Remote", loopType: .turnBased, firstInstruction: "test")
    node.backend = .copilotCLI
    let remoteData = Data(count: TranscriptReader.maximumReadableTranscriptBytes)
    let marker =
      TranscriptReader.remoteMarker + " data 1:2 \(remoteData.count) "
      + "\(remoteData.count * 2) \(remoteData.base64EncodedString())"
    let remoteChunk = try TranscriptReader.decodeRemoteSnapshotMarker(marker, node: node)
    XCTAssertEqual(remoteChunk.sourceWorkBytes, TranscriptReader.maximumSourceWorkBytes)
    XCTAssertLessThanOrEqual(
      remoteChunk.remoteTransferBytes, TranscriptReader.maximumRemoteTransferBytes)
    XCTAssertEqual(remoteChunk.data.count, TranscriptReader.maximumReadableTranscriptBytes)

    let oversized = TranscriptSourceChunk(
      identity: "oversized",
      totalBytes: UInt64(TranscriptReader.maximumReadableTranscriptBytes + 1),
      data: Data(count: TranscriptReader.maximumReadableTranscriptBytes + 1),
      sourceWorkBytes: TranscriptReader.maximumReadableTranscriptBytes + 1,
      remoteTransferBytes: 0)
    XCTAssertThrowsError(
      try TranscriptReader.page(
        nodeID: nodeID,
        provider: .copilotCLI,
        query: TranscriptQuery(nodeID: nodeID),
        cursor: nil,
        chunk: oversized)
    ) { error in
      XCTAssertEqual(error as? TranscriptReadError, .oversized)
    }
  }

  #if canImport(SQLite3)
    func testCodexProviderResolutionBindsTwoSameCWDNodesToExactRollouts() throws {
      let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("transcript-codex-resolution-\(UUID())", isDirectory: true)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: root) }

      let firstNode = UUID()
      let secondNode = UUID()
      let projectPath = "C:\\same\\project"
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
        "INSERT INTO threads VALUES ('\(firstThread)', '/goal read \(CodexThreadResolver.launchMarker(forNodeID: firstNode, projectPath: projectPath))', 1)",
        nil, nil, nil)
      sqlite3_exec(
        handle,
        "INSERT INTO threads VALUES ('\(secondThread)', '/goal read \(CodexThreadResolver.launchMarker(forNodeID: secondNode, projectPath: projectPath))', 2)",
        nil, nil, nil)

      let rollouts = [secondRollout, firstRollout]
      XCTAssertEqual(
        TranscriptReader.codexLocalURL(
          nodeID: firstNode, banked: UUID().uuidString, projectPath: projectPath,
          database: database,
          rollouts: rollouts),
        firstRollout)
      XCTAssertEqual(
        TranscriptReader.codexLocalURL(
          nodeID: secondNode, banked: UUID().uuidString, projectPath: projectPath,
          database: database,
          rollouts: rollouts),
        secondRollout)
      XCTAssertNil(
        TranscriptReader.codexLocalURL(
          nodeID: UUID(), banked: UUID().uuidString, projectPath: projectPath,
          database: database,
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
