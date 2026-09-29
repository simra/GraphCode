import Foundation
import XCTest

@testable import GraphcodeKit

final class SharedSettingsContractTests: XCTestCase {
  private func fixture(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .appendingPathComponent("fixtures/settings/\(name).json")
  }

  private func temporarySettings(copying source: URL? = nil) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("graphcode-shared-settings-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("settings.json")
    if let source {
      try FileManager.default.copyItem(at: source, to: url)
    }
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    return url
  }

  func testMacOSDefaultFixtureMatchesTheSharedDecoder() throws {
    let url = try temporarySettings(copying: fixture("macos-defaults"))
    let snapshot = try GraphcodeSettingsStore.snapshot(from: url)

    XCTAssertEqual(snapshot.settings, GraphcodeSettings())
    XCTAssertTrue(snapshot.exists)
    XCTAssertEqual(snapshot.fields, GraphcodeSettingsContract.fields)
    XCTAssertTrue(snapshot.fields.allSatisfy { $0.timing != .daemonRestart })
  }

  func testMacOSLegacyFixtureUsesTheSameMigrationsAndPreservesUnknownFields() throws {
    let url = try temporarySettings(copying: fixture("macos-legacy-migration"))
    let loaded = try GraphcodeSettingsStore.snapshot(from: url)

    XCTAssertFalse(loaded.settings.mailroomEnabled)
    XCTAssertEqual(loaded.settings.endsResolvedSessionsAfterMinutes, 0)

    var edited = loaded.settings
    edited.daemonHeartbeatEnabled = true
    _ = try GraphcodeSettingsStore.update(
      edited, expectedRevision: loaded.revision, at: url)

    let saved = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    XCTAssertEqual((saved["futureSetting"] as? [String: Any])?["version"] as? Int, 7)
    XCTAssertEqual(saved["windowOpacity"] as? Double, 0.7)
    XCTAssertEqual(saved["artifactoryEnabled"] as? Bool, false)
    XCTAssertEqual(saved["mailroomEnabled"] as? Bool, false)
    XCTAssertEqual(saved["daemonHeartbeatEnabled"] as? Bool, true)
  }

  func testConcurrentWritersReceiveAnExplicitRevisionConflict() throws {
    let url = try temporarySettings(copying: fixture("macos-defaults"))
    let original = try GraphcodeSettingsStore.snapshot(from: url)
    var first = original.settings
    first.daemonHeartbeatEnabled = true
    let saved = try GraphcodeSettingsStore.update(
      first, expectedRevision: original.revision, at: url)

    var stale = original.settings
    stale.mailroomEnabled = false
    XCTAssertThrowsError(
      try GraphcodeSettingsStore.update(
        stale, expectedRevision: original.revision, at: url)
    ) { error in
      XCTAssertEqual(
        error as? GraphcodeSettingsStore.StoreError,
        .conflict(currentRevision: saved.revision))
    }
    XCTAssertEqual(try GraphcodeSettingsStore.snapshot(from: url).settings, first)
  }

  func testCorruptFileIsRecoverableAndNeverSilentlyReset() throws {
    let url = try temporarySettings()
    let corrupt = Data("{ definitely not settings".utf8)
    try corrupt.write(to: url)

    XCTAssertThrowsError(try GraphcodeSettingsStore.snapshot(from: url)) { error in
      guard case GraphcodeSettingsStore.StoreError.corrupt = error else {
        return XCTFail("expected corrupt settings error, got \(error)")
      }
    }
    XCTAssertThrowsError(
      try GraphcodeSettingsStore.update(
        GraphcodeSettings(), expectedRevision: GraphcodeSHA256.hex(corrupt), at: url))
    XCTAssertEqual(try Data(contentsOf: url), corrupt)
  }

  func testOversizedDocumentsAreRejectedBeforeTheyCanEnterAV2Frame() throws {
    let url = try temporarySettings()
    var oversized = Data(#"{"futureSetting":""#.utf8)
    oversized.append(Data(repeating: 0x61, count: GraphcodeSettingsStore.maxDocumentBytes))
    oversized.append(Data(#""}"#.utf8))
    try oversized.write(to: url)

    XCTAssertThrowsError(try GraphcodeSettingsStore.snapshot(from: url)) { error in
      XCTAssertEqual(error as? GraphcodeSettingsStore.StoreError, .payloadTooLarge)
    }
    XCTAssertEqual(try Data(contentsOf: url), oversized)
  }

  func testSettingsProtocolRoundTripsWithoutChangingExistingCases() throws {
    let snapshot = GraphcodeSettingsSnapshot(
      settings: GraphcodeSettings(daemonHeartbeatEnabled: true),
      revision: "revision",
      exists: true,
      supportDirectory: "fixture",
      filePath: "fixture/settings.json")
    let event = DaemonEvent.settingsChanged(snapshot)
    XCTAssertEqual(
      try JSONDecoder().decode(DaemonEvent.self, from: JSONEncoder().encode(event)),
      event)

    let legacy = DaemonCommand.listRecentProjects
    XCTAssertEqual(
      try JSONDecoder().decode(DaemonCommand.self, from: JSONEncoder().encode(legacy)),
      legacy)
    XCTAssertEqual(event.requiredCapability, .settingsChanged)
  }

  func testRegistryBroadcastsRefreshAndClassifiesConflicts() async throws {
    let settingsURL = try temporarySettings(copying: fixture("macos-defaults"))
    let persistence = settingsURL.deletingLastPathComponent().appendingPathComponent("graphs")
    let first = SettingsRecordingConnection()
    let second = SettingsRecordingConnection()
    let legacy = SettingsRecordingConnection()
    let registry = ProjectRegistry(
      persistenceDirectory: persistence,
      settingsURL: settingsURL,
      readPresence: nil,
      enumerateQuickChatSessions: { [] })
    await registry.addConnection(
      id: first.id, connection: first, mode: .v2(version: 2), clientID: first.id)
    await registry.addConnection(
      id: second.id, connection: second, mode: .v2(version: 2), clientID: second.id)
    await registry.addConnection(id: legacy.id, connection: legacy)
    _ = await registry.apply(
      .announce(capabilities: [ClientCapability.settingsChanged.rawValue]),
      connectionID: first.id)
    _ = await registry.apply(
      .announce(capabilities: [ClientCapability.settingsChanged.rawValue]),
      connectionID: second.id)
    let legacyLoad = await registry.apply(.loadSettings, connectionID: legacy.id)
    XCTAssertEqual(legacyLoad?.error, "shared settings requests require daemon protocol v2")

    let loadResult = await registry.apply(.loadSettings, connectionID: first.id)
    let loaded = try XCTUnwrap(loadResult?.response)
    guard case .settingsChanged(let original) = loaded else {
      return XCTFail("expected settings snapshot")
    }
    var changed = original.settings
    changed.daemonHeartbeatEnabled = true
    let saved = await registry.apply(
      .updateSettings(expectedRevision: original.revision, settings: changed),
      connectionID: first.id)
    XCTAssertNil(saved?.error)

    let stale = await registry.apply(
      .updateSettings(expectedRevision: original.revision, settings: original.settings),
      connectionID: second.id)
    XCTAssertEqual(stale?.errorCode, .settingsConflict)

    let frames = await second.recordedFrames()
    XCTAssertTrue(
      try frames.contains {
        let envelope = try JSONDecoder().decode(DaemonWireEnvelope.self, from: $0)
        guard case .settingsChanged(let snapshot) = envelope.event else { return false }
        return snapshot.settings.daemonHeartbeatEnabled
      })
    let legacyFrames = await legacy.recordedFrames()
    XCTAssertTrue(legacyFrames.isEmpty)
  }

  func testRegistryReportsCorruptionWithoutReplacingTheFile() async throws {
    let settingsURL = try temporarySettings()
    let corrupt = Data("{ broken".utf8)
    try corrupt.write(to: settingsURL)
    let connection = SettingsRecordingConnection()
    let registry = ProjectRegistry(
      persistenceDirectory: settingsURL.deletingLastPathComponent().appendingPathComponent(
        "graphs"),
      settingsURL: settingsURL,
      readPresence: nil,
      enumerateQuickChatSessions: { [] })
    await registry.addConnection(
      id: connection.id, connection: connection, mode: .v2(version: 2),
      clientID: connection.id)

    let result = await registry.apply(.loadSettings, connectionID: connection.id)
    XCTAssertEqual(result?.errorCode, .settingsCorrupt)
    XCTAssertEqual(try Data(contentsOf: settingsURL), corrupt)
  }
}
private actor SettingsRecordingConnection: DaemonConnection {
  nonisolated let id = UUID()
  nonisolated let endpoint: DaemonEndpoint = .namedPipe("\\\\.\\pipe\\graphcode-settings-test")
  private var frames: [Data] = []

  func receiveFrame() async throws -> Data {
    throw RecordingError.closed
  }

  func sendFrame(_ data: Data) async throws {
    frames.append(data)
  }

  func close() async throws {}

  func recordedFrames() -> [Data] {
    frames
  }

  private enum RecordingError: Error {
    case closed
  }
}
