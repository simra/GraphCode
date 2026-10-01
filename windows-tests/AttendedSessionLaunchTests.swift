import Foundation
import Testing

@testable import GraphcodeKit

private actor SessionStartRecorder {
  private var count = 0

  func record() { count += 1 }
  func value() -> Int { count }
}

private final class TerminalGuardConnection: @unchecked Sendable, DaemonConnection {
  let id = UUID()
  let endpoint: DaemonEndpoint = .namedPipe("\\\\.\\pipe\\graphcode-terminal-guard-test")

  func receiveFrame() async throws -> Data { Data() }
  func sendFrame(_ data: Data) async throws {}
  func close() async throws {}
}

@Suite
struct AttendedSessionLaunchTests {
  @Test
  func blankSketchUsesTheConfiguredBackendLaunchPlan() {
    let node = LoopNode(
      title: "Main", loopType: .sketch, backend: .claudeCode, modelTier: .capable)
    let arguments =
      ZmxSessionLauncher.arguments(
        forNode: node,
        settings: GraphcodeSettings(autoSelectsModel: true),
        allowsEmptyPrompt: true) ?? []

    let name = SurfaceRef(id: node.id, launchesClaudeCode: true).zmxSessionName
    #expect(Array(arguments.prefix(3)) == ["run", name, "-d"])
    #expect(arguments.contains("claude"))
    #expect(arguments.contains("--model"))
    #expect(arguments.contains("opus"))
  }

  @Test
  func blankSketchStillReceivesBriefingConfiguration() {
    let briefing = "C:\\graphcode\\briefings\\project\\AGENTS.md"
    let claude = CLISessionBackendKind.claudeCode.launchArguments(
      prompt: nil, tier: .standard, briefingPath: briefing)
    let copilot = CLISessionBackendKind.copilotCLI.launchArguments(
      prompt: nil, tier: .standard, briefingPath: briefing,
      settings: GraphcodeSettings(copilotPermissions: .allowTools))

    #expect(claude.suffix(2) == ["--append-system-prompt-file", briefing])
    #expect(copilot.contains("--add-dir"))
    #expect(!copilot.contains("--interactive"))
  }

  @Test
  func remoteTerminalCompatibilityFailsClosedBeforeLaunch() {
    let path = "C:\\synthetic\\same"
    let message = ProjectRegistry.terminalCompatibilityError(
      project: ProjectRef(path: path, name: "SSH", metadata: .ssh))

    #expect(
      message
        == "interactive terminals are not supported for this project; no session was started")
    #expect(
      ProjectRegistry.terminalCompatibilityError(
        project: ProjectRef(path: path, name: "Local", metadata: .local)) == nil)
    #expect(
      ProjectRegistry.terminalCompatibilityError(
        project: ProjectRef(path: path, name: "Legacy")) != nil)
    #expect(
      ProjectRegistry.terminalCompatibilityError(
        project: ProjectRef(path: LoopGraphScope.globalPath, name: "Global")) == nil)
  }

  @Test
  func remoteOpenCommandNeverReachesTheSessionLauncher() async {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("graphcode-tests-\(UUID().uuidString)", isDirectory: true)
    let starts = SessionStartRecorder()
    let registry = ProjectRegistry(
      persistenceDirectory: directory,
      startNodeSession: { _, _ in
        await starts.record()
        return .success(.started)
      },
      nodeSessionExists: { _, _ in false },
      findMissingProvider: { _, _ in nil },
      persistsSynchronously: true)
    let connection = TerminalGuardConnection()
    let connectionID = connection.id
    let projectPath = "ssh://dev@build-box/workspaces/project"
    await registry.addConnection(
      id: connectionID,
      channel: DaemonConnectionChannel(connection: connection, mode: .v1))
    await registry.handle(.openProject(path: projectPath), connectionID: connectionID)
    let sketchID = UUID()
    let created = await registry.apply(
      .graphCommand(
        projectPath: projectPath,
        command: .createNode(NodeDraft(id: sketchID, title: "Main", loopType: .sketch))),
      connectionID: connectionID)
    #expect(created?.error == nil)

    let result = await registry.apply(
      .openNodeSession(projectPath: projectPath, nodeID: sketchID),
      connectionID: connectionID)

    #expect(await starts.value() == 0)
    #expect(result?.response == nil)
    #expect(
      result?.error
        == "interactive terminals are not supported for this project; no session was started")
  }
}
