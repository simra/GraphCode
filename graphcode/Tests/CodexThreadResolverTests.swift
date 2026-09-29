import Foundation
import SQLite3
import Testing

@testable import GraphcodeKit

/// Codex's `notify` can bank a thread id Codex never persists; the node's real thread is
/// found from Codex's own `threads` table instead (#346).
@Suite
struct CodexThreadResolverTests {
  private func database(_ rows: [(id: String, message: String, createdAt: Int)]) -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("state-\(UUID().uuidString).sqlite")
    var handle: OpaquePointer?
    sqlite3_open(url.path, &handle)
    sqlite3_exec(
      handle,
      "CREATE TABLE threads (id TEXT PRIMARY KEY, first_user_message TEXT, created_at_ms INTEGER)",
      nil, nil, nil)
    for row in rows {
      let message = row.message.replacingOccurrences(of: "'", with: "''")
      sqlite3_exec(
        handle, "INSERT INTO threads VALUES ('\(row.id)', '\(message)', \(row.createdAt))", nil,
        nil, nil)
    }
    sqlite3_close(handle)
    return url
  }

  @Test
  func aBankedIdCodexKnowsIsKept() {
    let node = UUID()
    let projectPath = "/repo/project"
    let real = UUID().uuidString.lowercased()
    let url = database([(real, "ordinary prompt", 1)])
    defer { try? FileManager.default.removeItem(at: url) }

    #expect(
      CodexThreadResolver.threadID(
        forNodeID: node, banked: real.uppercased(), projectPath: projectPath, database: url)
        == real)
  }

  @Test
  func anEphemeralBankedIdResolvesOnlyThroughOneExactProjectMarker() {
    let node = UUID()
    let projectPath = "/repo/project"
    let marker = CodexThreadResolver.launchMarker(forNodeID: node, projectPath: projectPath)
    let resolved = UUID().uuidString.lowercased()
    let url = database([
      (resolved, "/goal read \(marker)", 1),
      (UUID().uuidString.lowercased(), "newer prompt mentions \(node.uuidString)", 2),
    ])
    defer { try? FileManager.default.removeItem(at: url) }

    #expect(
      CodexThreadResolver.threadID(
        forNodeID: node, banked: UUID().uuidString, projectPath: projectPath, database: url)
        == resolved)
  }

  @Test
  func zeroOrMultipleExactMarkersAreRefused() {
    let node = UUID()
    let projectPath = "/repo/project"
    let marker = CodexThreadResolver.launchMarker(forNodeID: node, projectPath: projectPath)
    let noMatch = database([
      (UUID().uuidString.lowercased(), "mentions only \(node.uuidString)", 1)
    ])
    defer { try? FileManager.default.removeItem(at: noMatch) }
    #expect(
      CodexThreadResolver.threadID(
        forNodeID: node, banked: UUID().uuidString, projectPath: projectPath,
        database: noMatch) == nil)

    let ambiguous = database([
      (UUID().uuidString.lowercased(), "read \(marker)", 1),
      (UUID().uuidString.lowercased(), "/goal read \(marker)", 2),
    ])
    defer { try? FileManager.default.removeItem(at: ambiguous) }
    #expect(
      CodexThreadResolver.threadID(
        forNodeID: node, banked: UUID().uuidString, projectPath: projectPath,
        database: ambiguous) == nil)
  }

  @Test
  func malformedBankedIdsAreRefusedBeforeLookup() {
    let url = database([(UUID().uuidString.lowercased(), "no node here", 1)])
    defer { try? FileManager.default.removeItem(at: url) }

    #expect(
      CodexThreadResolver.threadID(
        forNodeID: UUID(), banked: "../thread", projectPath: "/repo", database: url) == nil)
  }

  @Test
  func theNewestStateDatabaseVersionIsTheOneRead() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("codex-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    for name in ["state_4.sqlite", "state_12.sqlite", "goals_1.sqlite", "state_5.sqlite-wal"] {
      FileManager.default.createFile(
        atPath: directory.appendingPathComponent(name).path, contents: nil)
    }
    let original = CodexThreadResolver.codexDirectory
    CodexThreadResolver.codexDirectory = directory
    defer { CodexThreadResolver.codexDirectory = original }

    #expect(CodexThreadResolver.stateDatabase()?.lastPathComponent == "state_12.sqlite")
  }
}
