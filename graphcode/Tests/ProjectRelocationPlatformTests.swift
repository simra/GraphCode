import Foundation
import GraphcodeKit
import Testing

#if !os(Windows)
  @Suite
  struct ProjectRelocationPlatformTests {
    @Test
    func nonWindowsEntryPointsReturnUnsupportedWithoutFilesystemAccess() {
      let hello = DaemonWireEnvelope.helloResponse(selectedVersion: 2)
      #expect(
        hello.capabilities?.contains(ServerCapability.projectRelocation.rawValue) != true)

      let fixture = FileManager.default.temporaryDirectory.appendingPathComponent(
        "graphcode-relocation-platform-\(UUID().uuidString)", isDirectory: true)
      let coordinator = ProjectRelocationCoordinator(supportDirectory: fixture)
      let operationID = UUID()
      let request = ProjectRelocationRequest(
        operationID: operationID,
        sourcePath: fixture.appendingPathComponent("source").path,
        destinationPath: fixture.appendingPathComponent("destination").path,
        expectedSourceIdentity: "unsupported",
        expectedGraphRevision: 0)
      let persistence = ProjectPersistence(baseDirectory: fixture)
      let graph = LoopGraph(
        project: ProjectRef(path: request.sourcePath, name: "unsupported"))

      #expect(throws: ProjectRelocationError.unsupported) {
        _ = try coordinator.prepare(
          operationID: operationID,
          sourcePath: request.sourcePath,
          destinationPath: request.destinationPath,
          graphRevision: 0)
      }
      #expect(throws: ProjectRelocationError.unsupported) {
        _ = try coordinator.relocate(
          request,
          graph: graph,
          persistence: persistence)
      }
      #expect(throws: ProjectRelocationError.unsupported) {
        _ = try coordinator.replayResult(
          for: request,
          authorizedClientID: UUID())
      }
      let recovery = coordinator.recoverPending(persistence: persistence)
      #expect(recovery.count == 1)
      #expect(recovery.first?.disposition == .unsupported)
      #expect(!FileManager.default.fileExists(atPath: fixture.path))
    }
  }
#endif
