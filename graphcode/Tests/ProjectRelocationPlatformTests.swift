import Foundation
import GraphcodeKit
import Testing

#if !os(Windows)
  @Suite
  struct ProjectRelocationPlatformTests {
    @Test
    func nonWindowsEntryPointsReturnUnsupportedWithoutFilesystemAccess() throws {
      let hello = DaemonWireEnvelope.helloResponse(selectedVersion: 2)
      #expect(
        hello.capabilities?.contains(ServerCapability.projectRelocation.rawValue) != true)

      let testRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
        "graphcode-relocation-platform-\(UUID().uuidString)", isDirectory: true)
      let persistenceSetup = testRoot.appendingPathComponent(
        "persistence-setup", isDirectory: true)
      let coordinatorSupport = testRoot.appendingPathComponent(
        "nonexistent-coordinator-support", isDirectory: true)
      try FileManager.default.createDirectory(
        at: persistenceSetup, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: testRoot) }
      #expect(!FileManager.default.fileExists(atPath: coordinatorSupport.path))

      let coordinator = ProjectRelocationCoordinator(supportDirectory: coordinatorSupport)
      let operationID = UUID()
      let request = ProjectRelocationRequest(
        operationID: operationID,
        sourcePath: coordinatorSupport.appendingPathComponent("source").path,
        destinationPath: coordinatorSupport.appendingPathComponent("destination").path,
        expectedSourceIdentity: "unsupported",
        expectedGraphRevision: 0)
      let persistence = ProjectPersistence(baseDirectory: persistenceSetup)
      let graph = LoopGraph(
        project: ProjectRef(path: request.sourcePath, name: "unsupported"))

      #expect(throws: ProjectRelocationError.unsupported) {
        _ = try coordinator.prepare(
          operationID: operationID,
          sourcePath: request.sourcePath,
          destinationPath: request.destinationPath,
          graphRevision: 0)
      }
      #expect(!FileManager.default.fileExists(atPath: coordinatorSupport.path))
      #expect(throws: ProjectRelocationError.unsupported) {
        _ = try coordinator.relocate(
          request,
          graph: graph,
          persistence: persistence)
      }
      #expect(!FileManager.default.fileExists(atPath: coordinatorSupport.path))
      #expect(throws: ProjectRelocationError.unsupported) {
        _ = try coordinator.replayResult(
          for: request,
          authorizedClientID: UUID())
      }
      #expect(!FileManager.default.fileExists(atPath: coordinatorSupport.path))
      let recovery = coordinator.recoverPending(persistence: persistence)
      #expect(recovery.count == 1)
      #expect(recovery.first?.disposition == .unsupported)
      #expect(!FileManager.default.fileExists(atPath: coordinatorSupport.path))
    }
  }
#endif
