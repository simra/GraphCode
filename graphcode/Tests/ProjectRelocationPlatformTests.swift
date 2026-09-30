import Foundation

import GraphcodeKit

import Testing

#if !os(Windows)
  @Suite
  struct ProjectRelocationPlatformTests {
    @Test
    func nonWindowsBuildsDoNotAdvertiseOrPreflightRelocation() {
      let hello = DaemonWireEnvelope.helloResponse(selectedVersion: 2)
      #expect(
        hello.capabilities?.contains(ServerCapability.projectRelocation.rawValue) != true)

      let fixture = FileManager.default.temporaryDirectory.appendingPathComponent(
        "graphcode-relocation-platform-\(UUID().uuidString)", isDirectory: true)
      let coordinator = ProjectRelocationCoordinator(supportDirectory: fixture)
      #expect(throws: ProjectRelocationError.unsupported) {
        _ = try coordinator.prepare(
          sourcePath: fixture.appendingPathComponent("source").path,
          destinationPath: fixture.appendingPathComponent("destination").path,
          graphRevision: 0)
      }
      #expect(!FileManager.default.fileExists(atPath: fixture.path))
    }
  }
#endif
