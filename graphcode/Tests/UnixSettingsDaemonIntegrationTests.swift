import Foundation
import GraphcodeKit
import Testing

#if canImport(Darwin)
  @Suite(.serialized)
  struct UnixSettingsDaemonIntegrationTests {
    @Test
    func productionSocketLoadsAndUpdatesSettings() throws {
      try withDaemon { socket, _ in
        let loaded = try settingsSnapshot(from: request(.loadSettings, socket: socket))
        #expect(loaded.settings == GraphcodeSettings())
        #expect(loaded.exists == false)

        var changed = loaded.settings
        changed.daemonHeartbeatEnabled = true
        let saved = try settingsSnapshot(
          from: request(
            .updateSettings(expectedRevision: loaded.revision, settings: changed),
            socket: socket))
        #expect(saved.settings.daemonHeartbeatEnabled)
        #expect(saved.exists)
        #expect(saved.revision != loaded.revision)
      }
    }

    @Test
    func productionSocketReturnsCorrelatedRevisionConflicts() throws {
      try withDaemon { socket, _ in
        let loaded = try settingsSnapshot(from: request(.loadSettings, socket: socket))
        var changed = loaded.settings
        changed.daemonHeartbeatEnabled = true
        _ = try request(
          .updateSettings(expectedRevision: loaded.revision, settings: changed),
          socket: socket)

        do {
          _ = try request(
            .updateSettings(expectedRevision: loaded.revision, settings: loaded.settings),
            socket: socket)
          Issue.record("expected settingsConflict")
        } catch DaemonSocketClient.ClientError.daemon(let code, _) {
          #expect(code == DaemonWireErrorCode.settingsConflict.rawValue)
        }
      }
    }

    @Test
    func productionSocketReportsCorruptionWithoutReplacingBytes() throws {
      try withDaemon { socket, settingsURL in
        let corrupt = Data("{ not settings".utf8)
        try corrupt.write(to: settingsURL)

        do {
          _ = try request(.loadSettings, socket: socket)
          Issue.record("expected settingsCorrupt")
        } catch DaemonSocketClient.ClientError.daemon(let code, _) {
          #expect(code == DaemonWireErrorCode.settingsCorrupt.rawValue)
        }
        #expect(try Data(contentsOf: settingsURL) == corrupt)
      }
    }

    private func withDaemon(
      _ body: (URL, URL) throws -> Void
    ) throws {
      let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("graphcoded-settings-\(UUID().uuidString)", isDirectory: true)
      let support = root.appendingPathComponent("support", isDirectory: true)
      let socket = root.appendingPathComponent("daemon.sock")
      try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: root) }

      let process = Process()
      process.executableURL = try graphcodedExecutable()
      var environment = ProcessInfo.processInfo.environment
      environment[SupportDirectory.environmentKey] = support.path
      environment[DaemonSocketPath.environmentKey] = socket.path
      process.environment = environment
      process.standardOutput = Pipe()
      process.standardError = Pipe()
      try process.run()
      defer {
        if process.isRunning {
          process.terminate()
          process.waitUntilExit()
        }
      }

      for _ in 0..<200 where !FileManager.default.fileExists(atPath: socket.path) {
        Thread.sleep(forTimeInterval: 0.01)
      }
      #expect(FileManager.default.fileExists(atPath: socket.path))
      try body(socket, support.appendingPathComponent("settings.json"))
    }

    private func request(_ command: DaemonCommand, socket: URL) throws -> DaemonEvent? {
      let client = try DaemonSocketClient(socketPath: socket, timeout: 2, dialAttempts: 20)
      defer { client.closeConnection() }
      return try client.request(command)
    }

    private func settingsSnapshot(from event: DaemonEvent?) throws
      -> GraphcodeSettingsSnapshot
    {
      guard case .settingsChanged(let snapshot) = event else {
        throw DaemonSocketClient.ClientError.malformedResponse
      }
      return snapshot
    }

    private func graphcodedExecutable() throws -> URL {
      let products = Bundle(for: TestBundleMarker.self).bundleURL.deletingLastPathComponent()
      let executable = products.appendingPathComponent("graphcoded")
      guard FileManager.default.isExecutableFile(atPath: executable.path) else {
        throw IntegrationError.missingGraphcoded(executable.path)
      }
      return executable
    }

    private enum IntegrationError: Error {
      case missingGraphcoded(String)
    }
  }

  private final class TestBundleMarker {}
#endif
